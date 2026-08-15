#import "HistoryExport.h"
#import "Contacts.h"
#import "MediaExtract.h"
#import "MessageHooks.h"
#import "SftpInboxClient.h"
#import "StatusSync.h"
#import "DebugLog.h"
#import "../Settings.h"

#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <sqlite3.h>
#import <stdio.h>

static NSString * const kCursorKey = @"ingest.history.cursors";
static NSString * const kDoneKey = @"ingest.history.done";
static NSString * const kScanKey = @"ingest.history.scan";
static NSString * const kProgressKey = @"ingest.history.progress";

static BOOL gScanning = NO;
static BOOL gRunning = NO;
static NSMutableDictionary *gProgress = nil;

static NSArray<WXIngestContact *> *gScanChats = nil;
static NSMutableArray *gScanRows = nil;
static NSUInteger gScanIdx = 0;
static NSInteger gScanMsgTotal = 0;
static NSInteger gScanGroups = 0;
static NSInteger gScanDMs = 0;
static unsigned long long gScanBytes = 0;
static unsigned long long gScanMediaDone = 0;
static void (^gScanDone)(NSDictionary *) = nil;

static NSArray<WXIngestContact *> *gExpChats = nil;
static NSUInteger gExpIdx = 0;
static unsigned int gExpLid = 0;
static NSUInteger gExpFound = 0;
static NSInteger gExpExpect = 0;
static NSInteger gExpMiss = 0;
static NSUInteger gExpMsgTotal = 0;
static id gExpMgr = nil;
static NSMutableDictionary *gExpCursors = nil;
static NSMutableSet *gExpDone = nil;
static NSDictionary *gSqlCounts = nil;
static NSMutableDictionary *gSqlFiles = nil;
static NSMutableDictionary *gMediaByHash = nil;
static sqlite3 *gExpDB = NULL;
static NSString *gExpTable = nil;
static NSString *gExpColLocal = nil;
static NSString *gExpColType = nil;
static NSString *gExpColMsg = nil;
static NSString *gExpColTime = nil;
static NSString *gExpColDes = nil;
static NSString *gExpColSvr = nil;
static NSInteger gExpSqlOffset = 0;
static NSInteger gExpSqlTotal = 0;
static NSInteger gExpWrapHits = 0;
static NSInteger gExpBareHits = 0;
static NSString *gExpChatId = nil;
static BOOL gExpOpenDataQueued = NO;
static NSMutableSet *gExpSentMedia = nil;
static NSMutableDictionary *gExpRemoteBytes = nil;
static FILE *gExpJsonl = NULL;
static NSString *gExpJsonlPath = nil;
static NSInteger gExpJsonlRows = 0;
static BOOL gExpDidSweep = NO;

static void WXHistPushProgress(void);
static void WXHistScanTick(void);
static void WXHistExportBeginChat(void);
static void WXHistExportTick(void);

static NSString *WXHistFormatBytes(unsigned long long bytes) {
    if (bytes < 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    }
    if (bytes < 1024ULL * 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
    }
    return [NSString stringWithFormat:@"%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
}

static NSMutableDictionary *WXHistProgress(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *saved = [[WXIngestSettings sharedDefaults] dictionaryForKey:kProgressKey];
        if ([saved isKindOfClass:[NSDictionary class]] && saved.count) {
            gProgress = [saved mutableCopy];
        } else {
            gProgress = [@{
                @"state": @"idle",
                @"chats_done": @0,
                @"chats_total": @0,
                @"msgs": @0,
                @"bytes": @0,
                @"current": @"",
                @"error": @"",
                @"fraction": @0,
                @"dest": @"",
            } mutableCopy];
        }
    });
    return gProgress;
}

static void WXHistPersistProgress(void) {
    [[WXIngestSettings sharedDefaults] setObject:[WXHistProgress() copy] forKey:kProgressKey];
}

static void WXHistUpdateFraction(void) {
    NSMutableDictionary *p = WXHistProgress();
    NSString *state = [p[@"state"] description] ?: @"";
    if (![state isEqualToString:@"exporting"] && ![state isEqualToString:@"paused"] &&
        ![state isEqualToString:@"done"]) {
        p[@"fraction"] = @0;
        return;
    }
    NSDictionary *scan = [[WXIngestSettings sharedDefaults] dictionaryForKey:kScanKey];
    double expect = [scan[@"msgs"] doubleValue];
    double got = [p[@"msgs"] doubleValue];
    double chatsDone = [p[@"chats_done"] doubleValue];
    double chatsTotal = [p[@"chats_total"] doubleValue];
    float frac = 0;
    if (expect > 0) {
        frac = (float)MIN(1.0, got / expect);
    } else if (chatsTotal > 0) {
        frac = (float)(chatsDone / chatsTotal);
    }
    if ([state isEqualToString:@"done"]) {
        frac = 1;
    }
    if (frac < 0) frac = 0;
    if (frac > 1) frac = 1;
    p[@"fraction"] = @(frac);
}

static void WXHistNormalizeIdleState(void) {
    if (gRunning || gScanning) {
        return;
    }
    NSMutableDictionary *p = WXHistProgress();
    NSString *state = [p[@"state"] description] ?: @"";
    NSInteger scanned = [[[WXIngestSettings sharedDefaults] dictionaryForKey:kScanKey][@"msgs"] integerValue];
    NSInteger uploaded = [p[@"msgs"] integerValue];
    if ([state isEqualToString:@"scanning"]) {
        p[@"state"] = (scanned > 0) ? @"scanned" : @"idle";
        p[@"current"] = @"";
        p[@"fraction"] = @0;
    } else if ([state isEqualToString:@"exporting"]) {
        p[@"state"] = @"paused";
        p[@"current"] = @"";
    } else if ([state isEqualToString:@"done"] && scanned >= 30 && uploaded < MAX(3, scanned / 50)) {
        p[@"state"] = @"scanned";
        p[@"fraction"] = @0;
        p[@"current"] = @"";
    }
}

static NSString *WXHistDestPath(void) {
    NSString *inbox = [WXIngestSettings inboxPath];
    return inbox.length ? inbox : @"/data/inbox";
}

static NSString *WXHistMD5(NSString *text) {
    if (text.length == 0) {
        return @"";
    }
    Class util = objc_getClass("CUtility");
    if (util) {
        SEL sel = sel_registerName("GetMd5StrWithString:");
        if (class_getClassMethod(util, sel)) {
            id md = ((id (*)(id, SEL, id))objc_msgSend)(util, sel, text);
            if ([md isKindOfClass:[NSString class]] && [(NSString *)md length] == 32) {
                return [(NSString *)md lowercaseString];
            }
        }
    }
    const char *c = text.UTF8String;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(c, (CC_LONG)strlen(c), digest);
#pragma clang diagnostic pop
    NSMutableString *out = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [out appendFormat:@"%02x", digest[i]];
    }
    return out;
}

static id WXHistTryClassMsg(const char *clsName, const char *selName) {
    Class cls = objc_getClass(clsName);
    if (cls == NULL) {
        return nil;
    }
    SEL sel = sel_registerName(selName);
    if (!class_getClassMethod(cls, sel)) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
    } @catch (NSException *e) {
        WeChatIngestDebugLog(@"cls %@ %s threw %@", @(clsName), selName, e.reason);
        return nil;
    }
}

static NSString *WXHistSelfWxid(void) {
    id mgr = WeChatIngestFindService("CContactMgr");
    if (mgr == nil) {
        return @"";
    }
    id contact = nil;
    if ([mgr respondsToSelector:@selector(getSelfContact)]) {
        contact = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(getSelfContact));
    }
    @try {
        id name = [contact valueForKey:@"m_nsUsrName"];
        return [name isKindOfClass:[NSString class]] ? name : @"";
    } @catch (NSException *e) {
        return @"";
    }
}

static NSArray<NSString *> *WXHistWxidRoots(void) {
    NSString *home = NSHomeDirectory();
    NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *path) {
        if (path.length == 0 || [seen containsObject:path]) {
            return;
        }
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir) {
            [seen addObject:path];
            [out addObject:path];
        }
    };
    add(home);
    add(docs);
    id dataPath = WXHistTryClassMsg("CUtility", "GetDataPath");
    if ([dataPath isKindOfClass:[NSString class]]) {
        add((NSString *)dataPath);
        add([(NSString *)dataPath stringByDeletingLastPathComponent]);
    }
    add([home stringByAppendingPathComponent:@"Library"]);
    add([home stringByAppendingPathComponent:@"Library/WechatPrivate"]);
    NSString *selfWxid = WXHistSelfWxid();
    if (selfWxid.length) {
        add([docs stringByAppendingPathComponent:selfWxid]);
        add([[home stringByAppendingPathComponent:@"Library/WechatPrivate"] stringByAppendingPathComponent:selfWxid]);
    }
    NSArray *docsKids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:NULL];
    for (NSString *name in docsKids) {
        add([docs stringByAppendingPathComponent:name]);
    }
    // Re-sign / 覆盖安装会换容器 UUID，旧沙盒里可能还留着 .pic_hd。
    NSString *apps = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:apps error:NULL];
    NSUInteger recovered = 0;
    for (NSString *uuid in uuids) {
        NSString *app = [apps stringByAppendingPathComponent:uuid];
        NSString *appDocs = [app stringByAppendingPathComponent:@"Documents"];
        add(app);
        add(appDocs);
        NSArray *kids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appDocs error:NULL];
        for (NSString *name in kids) {
            NSString *child = [appDocs stringByAppendingPathComponent:name];
            add(child);
            if (name.length == 32) {
                NSString *img = [child stringByAppendingPathComponent:@"Img"];
                BOOL isDir = NO;
                if ([[NSFileManager defaultManager] fileExistsAtPath:img isDirectory:&isDir] && isDir) {
                    recovered += 1;
                    WeChatIngestDebugLog(@"recover container %@ Img present", uuid);
                }
            }
        }
    }
    if (uuids.count) {
        WeChatIngestDebugLog(@"recover apps=%lu hex-img=%lu", (unsigned long)uuids.count, (unsigned long)recovered);
    } else {
        WeChatIngestDebugLog(@"recover apps unlistable (sandbox?)");
    }
    return out;
}

static void WXHistLogKids(NSString *path, NSUInteger limit) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:path isDirectory:&isDir];
    if (!exists) {
        WeChatIngestDebugLog(@"ls miss %@", path);
        return;
    }
    if (!isDir) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
        WeChatIngestDebugLog(@"ls file %@ size=%@", path, attrs[NSFileSize]);
        return;
    }
    NSError *err = nil;
    NSArray *kids = [fm contentsOfDirectoryAtPath:path error:&err];
    WeChatIngestDebugLog(@"ls %@ kids=%lu err=%@", path, (unsigned long)kids.count, err.localizedDescription ?: @"-");
    NSUInteger n = MIN(limit, kids.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSString *child = [path stringByAppendingPathComponent:kids[i]];
        BOOL childDir = NO;
        [fm fileExistsAtPath:child isDirectory:&childDir];
        if (childDir) {
            WeChatIngestDebugLog(@"  /%@", kids[i]);
        } else {
            NSDictionary *attrs = [fm attributesOfItemAtPath:child error:NULL];
            WeChatIngestDebugLog(@"  %@ %@", kids[i], attrs[NSFileSize] ?: @"?");
        }
    }
}

static unsigned long long WXHistSumFolder(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        return 0;
    }
    unsigned long long total = 0;
    NSUInteger files = 0;
    NSURL *root = [NSURL fileURLWithPath:path];
    NSDirectoryEnumerator *en = [fm enumeratorAtURL:root
                         includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                            options:0
                                       errorHandler:^BOOL(NSURL *url, NSError *err) {
        WeChatIngestDebugLog(@"enum-err %@ %@", url.path.lastPathComponent, err.localizedDescription);
        return YES;
    }];
    NSString *rootPath = path;
    if (![rootPath hasSuffix:@"/"]) {
        rootPath = [rootPath stringByAppendingString:@"/"];
    }
    void (^noteHash)(NSString *, unsigned long long) = ^(NSString *rel, unsigned long long sz) {
        if (gMediaByHash == nil || rel.length == 0 || sz == 0) {
            return;
        }
        NSArray *parts = rel.pathComponents;
        NSString *hash = nil;
        if (parts.count >= 1 && [parts[0] length] == 32) {
            hash = [parts[0] lowercaseString];
        } else if (parts.count >= 2 && [parts[0] length] == 2 && [parts[1] length] == 32) {
            hash = [parts[1] lowercaseString];
        }
        if (hash.length == 32) {
            unsigned long long old = [gMediaByHash[hash] unsignedLongLongValue];
            gMediaByHash[hash] = @(old + sz);
        }
    };
    for (NSURL *u in en) {
        NSNumber *isFile = nil;
        [u getResourceValue:&isFile forKey:NSURLIsRegularFileKey error:NULL];
        if (!isFile.boolValue) {
            continue;
        }
        NSNumber *sz = nil;
        [u getResourceValue:&sz forKey:NSURLFileSizeKey error:NULL];
        unsigned long long n = sz.unsignedLongLongValue;
        total += n;
        files += 1;
        NSString *full = u.path;
        if ([full hasPrefix:rootPath]) {
            noteHash([full substringFromIndex:rootPath.length], n);
        }
    }
    if (total == 0) {
        NSDirectoryEnumerator *en2 = [fm enumeratorAtPath:path];
        for (NSString *rel in en2) {
            NSDictionary *attrs = [en2 fileAttributes];
            if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular]) {
                unsigned long long n = [attrs[NSFileSize] unsignedLongLongValue];
                total += n;
                files += 1;
                noteHash(rel, n);
            }
        }
    }
    WeChatIngestDebugLog(@"sum %@ files=%lu bytes=%llu (%@)",
                         path, (unsigned long)files, total, WXHistFormatBytes(total));
    return total;
}

static unsigned long long WXHistSumAllMedia(void) {
    gMediaByHash = [NSMutableDictionary dictionary];
    NSString *home = NSHomeDirectory();
    NSString *selfWxid = WXHistSelfWxid();
    WeChatIngestDebugLog(@"history media-scan home=%@", home);
    WeChatIngestDebugLog(@"history media-scan self=%@", selfWxid.length ? selfWxid : @"(empty)");
    const char *classes[] = {"CUtility", "CPathService", "MMContext", NULL};
    const char *sels[] = {"GetDataPath", "GetRootPath", "GetDocPath", "GetUserDataPath", NULL};
    for (int ci = 0; classes[ci]; ci++) {
        for (int si = 0; sels[si]; si++) {
            id v = WXHistTryClassMsg(classes[ci], sels[si]);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
                WeChatIngestDebugLog(@"pathAPI %s %s = %@", classes[ci], sels[si], v);
            }
        }
    }
    id dataPath = WXHistTryClassMsg("CUtility", "GetDataPath");
    if ([dataPath isKindOfClass:[NSString class]] && [(NSString *)dataPath length]) {
        WXHistLogKids((NSString *)dataPath, 30);
    }
    WXHistLogKids(home, 20);
    WXHistLogKids([home stringByAppendingPathComponent:@"Documents"], 40);
    WXHistLogKids([home stringByAppendingPathComponent:@"Library"], 20);
    WXHistLogKids([home stringByAppendingPathComponent:@"Library/WechatPrivate"], 20);

    static NSArray<NSString *> *folders = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        folders = @[@"Img", @"Image", @"img", @"Audio", @"audio", @"Voice",
                    @"Video", @"video", @"OpenData", @"File", @"file", @"Attach"];
    });
    NSMutableSet *tried = [NSMutableSet set];
    unsigned long long total = 0;
    for (NSString *root in WXHistWxidRoots()) {
        WeChatIngestDebugLog(@"history root %@", root);
        if ([folders containsObject:root.lastPathComponent]) {
            total += WXHistSumFolder(root);
        }
        for (NSString *folder in folders) {
            NSString *path = [root stringByAppendingPathComponent:folder];
            if ([tried containsObject:path]) {
                continue;
            }
            [tried addObject:path];
            BOOL isDir = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
                continue;
            }
            total += WXHistSumFolder(path);
        }
    }
    WeChatIngestDebugLog(@"history media-scan total=%@ tried=%lu chatsWithMedia=%lu",
                         WXHistFormatBytes(total), (unsigned long)tried.count,
                         (unsigned long)gMediaByHash.count);
    WeChatIngestDebugLogFlushRemote();
    return total;
}

static NSArray<NSString *> *WXHistMMDBPaths(void) {
    NSMutableArray *paths = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^addPath)(NSString *) = ^(NSString *p) {
        if (p.length == 0 || [seen containsObject:p]) {
            return;
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            [seen addObject:p];
            [paths addObject:p];
            WeChatIngestDebugLog(@"mmdb path %@", p);
        }
    };
    id mgr = WeChatIngestFindService("CMessageMgr");
    NSMutableArray *holders = [NSMutableArray array];
    if (mgr) {
        [holders addObject:mgr];
    }
    id mmdbSvc = WeChatIngestFindService("CMMDB");
    if (mmdbSvc) {
        [holders addObject:mmdbSvc];
    }
    for (id holder in holders) {
        WeChatIngestDebugLog(@"mmdb holder %@", NSStringFromClass([holder class]));
        id mmdb = nil;
        for (NSString *key in @[@"m_oMMDB", @"m_oMsgDB", @"m_db", @"m_oDB"]) {
            @try {
                id v = [holder valueForKey:key];
                if (v) {
                    WeChatIngestDebugLog(@"mmdb key %@ -> %@", key, NSStringFromClass([v class]));
                    mmdb = v;
                    break;
                }
            } @catch (NSException *e) {
            }
        }
        if (mmdb == nil) {
            mmdb = holder;
        }
        id messages = nil;
        for (NSString *key in @[@"m_messages", @"m_arrMessages", @"m_messageDBs", @"messages"]) {
            @try {
                id v = [mmdb valueForKey:key];
                if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]]) {
                    WeChatIngestDebugLog(@"mmdb %@ count=%lu", key, (unsigned long)[v count]);
                    messages = v;
                    break;
                }
            } @catch (NSException *e) {
            }
        }
        if (messages) {
            for (id item in messages) {
                NSString *p = nil;
                @try { p = [item valueForKey:@"path"]; } @catch (NSException *e) {}
                if (![p isKindOfClass:[NSString class]]) {
                    @try { p = [item valueForKey:@"m_nsPath"]; } @catch (NSException *e) {}
                }
                if (![p isKindOfClass:[NSString class]] && [item isKindOfClass:[NSString class]]) {
                    p = (NSString *)item;
                }
                addPath(p);
            }
        }
        @try {
            id p = [mmdb valueForKey:@"m_nsDBPath"];
            if ([p isKindOfClass:[NSString class]]) {
                addPath(p);
            }
        } @catch (NSException *e) {
        }
    }
    WeChatIngestDebugLog(@"mmdb paths total=%lu", (unsigned long)paths.count);
    return paths;
}

static NSMutableDictionary *WXHistSqlFiles(void) {
    if (gSqlFiles == nil) {
        gSqlFiles = [NSMutableDictionary dictionary];
    }
    return gSqlFiles;
}

static void WXHistIngestSqliteFile(NSString *path, NSMutableDictionary *map) {
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        WeChatIngestDebugLog(@"sqlite open-fail %@ rc=%d", path.lastPathComponent, rc);
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_stmt *st = NULL;
    NSUInteger tables = 0;
    if (sqlite3_prepare_v2(db,
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Chat_%'",
            -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *t = sqlite3_column_text(st, 0);
            if (t == NULL) {
                continue;
            }
            NSString *table = [NSString stringWithUTF8String:(const char *)t];
            sqlite3_stmt *cst = NULL;
            NSString *csql = [NSString stringWithFormat:@"SELECT COUNT(*) FROM [%@]", table];
            if (sqlite3_prepare_v2(db, csql.UTF8String, -1, &cst, NULL) == SQLITE_OK) {
                if (sqlite3_step(cst) == SQLITE_ROW) {
                    int n = sqlite3_column_int(cst, 0);
                    if (n > 0) {
                        NSInteger old = [map[table] integerValue];
                        if (n > old) {
                            map[table] = @(n);
                            WXHistSqlFiles()[table] = path;
                        }
                        tables += 1;
                    }
                }
                sqlite3_finalize(cst);
            }
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    WeChatIngestDebugLog(@"sqlite %@ chats=%lu", path.lastPathComponent, (unsigned long)tables);
}

static NSDictionary<NSString *, NSNumber *> *WXHistSqliteAllChatCounts(void) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *path in WXHistMMDBPaths()) {
        if ([seen containsObject:path]) {
            continue;
        }
        [seen addObject:path];
        WXHistIngestSqliteFile(path, map);
    }
    for (NSString *root in WXHistWxidRoots()) {
        NSArray *probe = @[
            [root stringByAppendingPathComponent:@"DB"],
            [root stringByAppendingPathComponent:@"PackedDB"],
            [root stringByAppendingPathComponent:@"Message"],
            root,
        ];
        for (NSString *dir in probe) {
            NSArray *files = [fm contentsOfDirectoryAtPath:dir error:NULL];
            for (NSString *name in files) {
                NSString *low = name.lowercaseString;
                if (!([low hasSuffix:@".sqlite"] || [low hasSuffix:@".db"])) {
                    continue;
                }
                if ([low containsString:@"contact"] || [low containsString:@"fts"]) {
                    continue;
                }
                NSString *path = [dir stringByAppendingPathComponent:name];
                if ([seen containsObject:path]) {
                    continue;
                }
                [seen addObject:path];
                WXHistIngestSqliteFile(path, map);
            }
        }
    }
    WeChatIngestDebugLog(@"sqlite mapped chats=%lu", (unsigned long)map.count);
    return map;
}

static id WXHistMessageMgr(void) {
    return WeChatIngestFindService("CMessageMgr");
}

static NSInteger WXHistMsgCountAPI(id mgr, NSString *chat) {
    if (mgr == nil || chat.length == 0) {
        return -1;
    }
    const char *names[] = {
        "GetMsgCount:", "getMsgCount:", "GetLocalMsgCount:",
        "GetMsgCountForUsr:", "GetMsgCountFromDB:",
        NULL
    };
    for (const char **p = names; *p; p++) {
        SEL sel = sel_registerName(*p);
        if (![mgr respondsToSelector:sel]) {
            continue;
        }
        @try {
            NSInteger n = ((NSInteger (*)(id, SEL, id))objc_msgSend)(mgr, sel, chat);
            if (n > 0 && n < 8000000) {
                return n;
            }
        } @catch (NSException *e) {
        }
    }
    return -1;
}

static id WXHistLastMsg(id mgr, NSString *chat) {
    if (mgr == nil || chat.length == 0) {
        return nil;
    }
    const char *names[] = {"GetLastMsg:", "getLastMsg:", NULL};
    for (const char **p = names; *p; p++) {
        SEL sel = sel_registerName(*p);
        if (![mgr respondsToSelector:sel]) {
            continue;
        }
        @try {
            id wrap = ((id (*)(id, SEL, id))objc_msgSend)(mgr, sel, chat);
            if (wrap) {
                return wrap;
            }
        } @catch (NSException *e) {
        }
    }
    return nil;
}

static unsigned int WXHistLocalID(id wrap) {
    if (wrap == nil) {
        return 0;
    }
    @try {
        id v = [wrap valueForKey:@"m_uiMesLocalID"];
        if ([v respondsToSelector:@selector(unsignedIntValue)]) {
            return [v unsignedIntValue];
        }
    } @catch (NSException *e) {
    }
    return 0;
}

static id WXHistGetOne(id mgr, NSString *chat, unsigned int lid) {
    if (mgr == nil || chat.length == 0 || lid == 0) {
        return nil;
    }
    SEL sel = sel_registerName("GetMsg:LocalID:");
    if (![mgr respondsToSelector:sel]) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL, id, unsigned int))objc_msgSend)(mgr, sel, chat, lid);
    } @catch (NSException *e) {
        return nil;
    }
}

static void WXHistCloseExpDB(void) {
    if (gExpDB) {
        sqlite3_close(gExpDB);
        gExpDB = NULL;
    }
    gExpTable = nil;
    gExpColLocal = nil;
    gExpColType = nil;
    gExpColMsg = nil;
    gExpColTime = nil;
    gExpColDes = nil;
    gExpColSvr = nil;
}

static NSString *WXHistPickCol(NSArray<NSString *> *have, NSArray<NSString *> *want) {
    for (NSString *name in want) {
        for (NSString *col in have) {
            if ([col caseInsensitiveCompare:name] == NSOrderedSame) {
                return col;
            }
        }
    }
    return nil;
}

static BOOL WXHistOpenChatTable(NSString *username, NSInteger *outCount) {
    WXHistCloseExpDB();
    if (outCount) {
        *outCount = 0;
    }
    if (username.length == 0) {
        return NO;
    }
    NSString *md = WXHistMD5(username);
    NSArray *keys = @[
        [NSString stringWithFormat:@"Chat_%@", md],
        [NSString stringWithFormat:@"Chat_%@", md.uppercaseString],
        [NSString stringWithFormat:@"Chat_%@", username],
    ];
    NSString *table = nil;
    NSString *path = nil;
    NSDictionary *files = WXHistSqlFiles();
    for (NSString *key in keys) {
        path = files[key];
        if (path.length) {
            table = key;
            break;
        }
    }
    if (table.length == 0) {
        for (NSString *key in files) {
            if ([key.lowercaseString hasSuffix:md] || [key containsString:username]) {
                table = key;
                path = files[key];
                break;
            }
        }
    }
    if (path.length == 0 || table.length == 0) {
        return NO;
    }
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        WeChatIngestDebugLog(@"sqlite open chat-fail %@ %@", table, path.lastPathComponent);
        return NO;
    }
    NSMutableArray *cols = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    NSString *pragma = [NSString stringWithFormat:@"PRAGMA table_info([%@])", table];
    if (sqlite3_prepare_v2(db, pragma.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *t = sqlite3_column_text(st, 1);
            if (t) {
                [cols addObject:[NSString stringWithUTF8String:(const char *)t]];
            }
        }
        sqlite3_finalize(st);
    }
    NSString *colLocal = WXHistPickCol(cols, @[@"MesLocalID", @"mesLocalID", @"localId", @"LocalID"]);
    if (colLocal.length == 0) {
        sqlite3_close(db);
        WeChatIngestDebugLog(@"sqlite no MesLocalID %@ cols=%@", table, [cols componentsJoinedByString:@","]);
        return NO;
    }
    gExpDB = db;
    gExpTable = table;
    gExpColLocal = colLocal;
    gExpColType = WXHistPickCol(cols, @[@"Type", @"type", @"IntType"]);
    gExpColMsg = WXHistPickCol(cols, @[@"Message", @"message", @"Msg", @"msg"]);
    gExpColTime = WXHistPickCol(cols, @[@"CreateTime", @"createTime", @"Time"]);
    gExpColDes = WXHistPickCol(cols, @[@"Des", @"des"]);
    gExpColSvr = WXHistPickCol(cols, @[@"MesSvrID", @"mesSvrID", @"MsgSvrID"]);
    NSInteger count = 0;
    NSString *csql = [NSString stringWithFormat:@"SELECT COUNT(*) FROM [%@]", table];
    if (sqlite3_prepare_v2(db, csql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) {
            count = sqlite3_column_int(st, 0);
        }
        sqlite3_finalize(st);
    }
    if (outCount) {
        *outCount = count;
    }
    WeChatIngestDebugLog(@"sqlite chat table=%@ file=%@ rows=%ld cols=%@",
                         table, path.lastPathComponent, (long)count,
                         [cols componentsJoinedByString:@","]);
    return YES;
}

static NSString *WXHistSqlText(sqlite3_stmt *st, int idx) {
    if (idx < 0) {
        return @"";
    }
    const unsigned char *t = sqlite3_column_text(st, idx);
    if (t) {
        NSString *s = [NSString stringWithUTF8String:(const char *)t];
        if (s) {
            return s;
        }
    }
    const void *blob = sqlite3_column_blob(st, idx);
    int n = sqlite3_column_bytes(st, idx);
    if (blob == NULL || n <= 0) {
        return @"";
    }
    NSString *utf8 = [[NSString alloc] initWithBytes:blob length:(NSUInteger)n encoding:NSUTF8StringEncoding];
    if (utf8) {
        return utf8;
    }
    return [[NSString alloc] initWithBytes:blob length:(NSUInteger)n encoding:NSISOLatin1StringEncoding] ?: @"";
}

static void WXHistParseGroupBody(NSString *raw, NSString **outSender, NSString **outBody) {
    NSString *text = raw ?: @"";
    NSRange cut = [text rangeOfString:@":\n"];
    if (cut.location != NSNotFound && cut.location > 0 && cut.location < 80) {
        NSString *who = [text substringToIndex:cut.location];
        if ([who hasPrefix:@"wxid_"] || [who containsString:@"@"] || who.length < 40) {
            if (outSender) *outSender = who;
            if (outBody) *outBody = [text substringFromIndex:cut.location + 2];
            return;
        }
    }
    if (outBody) *outBody = text;
}

static void WXHistEmitRow(WXIngestContact *c, unsigned int lid, int type, NSString *message,
                          NSInteger createTime, int des) {
    if (lid == 0) {
        return;
    }
    id wrap = WXHistGetOne(gExpMgr, c.username, lid);
    if (wrap) {
        gExpWrapHits += 1;
        WeChatIngestCaptureHistoryWrap(wrap);
        return;
    }
    NSString *selfWxid = WXHistSelfWxid();
    NSString *from = @"";
    NSString *to = c.username ?: @"";
    NSString *body = message ?: @"";
    if (c.isGroup) {
        to = c.username;
        if (des == 0) {
            NSString *sender = @"";
            WXHistParseGroupBody(message, &sender, &body);
            from = sender.length ? sender : c.username;
        } else {
            from = selfWxid.length ? selfWxid : @"self";
        }
    } else if (des == 0) {
        from = c.username;
        to = selfWxid.length ? selfWxid : c.username;
    } else {
        from = selfWxid.length ? selfWxid : @"self";
        to = c.username;
    }
    wrap = WeChatIngestMakeBareWrap(c.username, from, to, lid, type, body.length ? body : message, createTime);
    if (wrap) {
        gExpBareHits += 1;
        WeChatIngestCaptureHistoryWrap(wrap);
    }
}

static BOOL WXHistLooksThumb(NSString *name) {
    NSString *low = name.lowercaseString;
    return [low containsString:@"thum"] || [low containsString:@"thumb"];
}

static void WXHistQueueFile(NSString *local, NSString *mediaKey, NSString *folder, NSString *name) {
    if (local.length == 0 || name.length == 0) {
        return;
    }
    if (WXHistLooksThumb(name)) {
        return;
    }
    if (gExpSentMedia == nil) {
        gExpSentMedia = [NSMutableSet set];
    }
    if (gExpRemoteBytes == nil) {
        gExpRemoteBytes = [NSMutableDictionary dictionary];
    }
    if ([gExpSentMedia containsObject:local]) {
        return;
    }
    unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:local error:NULL][NSFileSize] unsignedLongLongValue];
    NSString *rel = [NSString stringWithFormat:@"hist-media/%@/%@/%@", mediaKey, folder, name];
    unsigned long long old = [gExpRemoteBytes[rel] unsignedLongLongValue];
    if (old >= sz && old > 0) {
        return;
    }
    [gExpSentMedia addObject:local];
    gExpRemoteBytes[rel] = @(sz);
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueLocalFile:local remoteRelativePath:rel];
}

static void WXHistQueueLidMedia(NSString *chat, unsigned int lid) {
    if (chat.length == 0 || lid == 0) {
        return;
    }
    NSString *md = WXHistMD5(chat);
    if (md.length == 0) {
        return;
    }
    NSString *lidName = [NSString stringWithFormat:@"%u", lid];
    NSArray *folders = @[@"Img", @"Audio", @"Video"];
    NSArray *exts = @[@"pic", @"pic_hd", @"pic_thum", @"jpg", @"jpeg", @"png", @"gif",
                      @"wxam", @"heic", @"aud", @"silk", @"slk", @"mp4", @"mov"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pref = md.length >= 2 ? [md substringToIndex:2] : md;
    for (NSString *root in WXHistWxidRoots()) {
        for (NSString *folder in folders) {
            NSArray *dirs = @[
                [[root stringByAppendingPathComponent:folder] stringByAppendingPathComponent:md],
                [[[root stringByAppendingPathComponent:folder] stringByAppendingPathComponent:pref] stringByAppendingPathComponent:md],
            ];
            for (NSString *dir in dirs) {
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
                    continue;
                }
                for (NSString *ext in exts) {
                    NSString *path = [dir stringByAppendingPathComponent:
                                      [lidName stringByAppendingPathExtension:ext]];
                    if ([fm fileExistsAtPath:path]) {
                        WXHistQueueFile(path, md, folder, path.lastPathComponent);
                    }
                }
            }
        }
    }
}

static void WXHistQueueOpenData(NSString *chat) {
    if (gExpOpenDataQueued || chat.length == 0) {
        return;
    }
    gExpOpenDataQueued = YES;
    NSString *md = WXHistMD5(chat);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pref = md.length >= 2 ? [md substringToIndex:2] : md;
    NSInteger queued = 0;
    for (NSString *root in WXHistWxidRoots()) {
        NSArray *dirs = @[
            [[root stringByAppendingPathComponent:@"OpenData"] stringByAppendingPathComponent:md],
            [[[root stringByAppendingPathComponent:@"OpenData"] stringByAppendingPathComponent:pref] stringByAppendingPathComponent:md],
            [[root stringByAppendingPathComponent:@"File"] stringByAppendingPathComponent:md],
        ];
        for (NSString *dir in dirs) {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
                continue;
            }
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
            NSString *rel = nil;
            NSInteger seen = 0;
            while ((rel = [en nextObject]) && seen < 4000) {
                seen += 1;
                NSString *full = [dir stringByAppendingPathComponent:rel];
                BOOL childDir = NO;
                if (![fm fileExistsAtPath:full isDirectory:&childDir] || childDir) {
                    continue;
                }
                WXHistQueueFile(full, md, @"OpenData", rel.lastPathComponent);
                queued += 1;
            }
        }
    }
    if (queued) {
        WeChatIngestDebugLog(@"history opendata queued=%ld chat=%@", (long)queued, chat);
    }
}

static void WXHistQueueAllChatMedia(NSString *chat) {
    if (chat.length == 0) {
        return;
    }
    NSString *md = WXHistMD5(chat);
    if (md.length == 0) {
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pref = md.length >= 2 ? [md substringToIndex:2] : md;
    NSArray *folders = @[@"Img", @"Audio", @"Video", @"OpenData", @"File"];
    NSInteger queued = 0;
    for (NSString *root in WXHistWxidRoots()) {
        for (NSString *folder in folders) {
            NSArray *dirs = @[
                [[root stringByAppendingPathComponent:folder] stringByAppendingPathComponent:md],
                [[[root stringByAppendingPathComponent:folder] stringByAppendingPathComponent:pref] stringByAppendingPathComponent:md],
            ];
            for (NSString *dir in dirs) {
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
                    continue;
                }
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
                NSString *rel = nil;
                NSInteger seen = 0;
                while ((rel = [en nextObject]) && seen < 25000) {
                    seen += 1;
                    NSString *full = [dir stringByAppendingPathComponent:rel];
                    BOOL childDir = NO;
                    if (![fm fileExistsAtPath:full isDirectory:&childDir] || childDir) {
                        continue;
                    }
                    WXHistQueueFile(full, md, folder, rel.lastPathComponent);
                    queued += 1;
                }
            }
        }
    }
    WeChatIngestDebugLog(@"history media-all queued=%ld chat=%@", (long)queued, chat);
}

static void WXHistCloseJsonl(void) {
    if (gExpJsonl) {
        fclose(gExpJsonl);
        gExpJsonl = NULL;
    }
    if (gExpJsonlPath.length) {
        [[NSFileManager defaultManager] removeItemAtPath:gExpJsonlPath error:NULL];
    }
    gExpJsonlPath = nil;
    gExpJsonlRows = 0;
}

static BOOL WXHistWriteLine(NSString *line) {
    if (gExpJsonl == NULL || line.length == 0) {
        return NO;
    }
    const char *utf8 = line.UTF8String;
    if (utf8 == NULL) {
        return NO;
    }
    if (fputs(utf8, gExpJsonl) == EOF || fputc('\n', gExpJsonl) == EOF) {
        return NO;
    }
    return YES;
}

static BOOL WXHistStartJsonl(WXIngestContact *c) {
    WXHistCloseJsonl();
    NSString *dir = NSTemporaryDirectory();
    NSString *name = [NSString stringWithFormat:@"wxhist-%@.jsonl", [[NSUUID UUID] UUIDString]];
    gExpJsonlPath = [dir stringByAppendingPathComponent:name];
    gExpJsonl = fopen(gExpJsonlPath.fileSystemRepresentation, "wb");
    if (gExpJsonl == NULL) {
        WeChatIngestDebugLog(@"history jsonl open-fail %@", gExpJsonlPath);
        gExpJsonlPath = nil;
        return NO;
    }
    gExpJsonlRows = 0;
    NSDictionary *header = @{
        @"cmd": @"history_jsonl",
        @"role": @"history",
        @"chat_id": c.username ?: @"",
        @"chat_name": c.displayName ?: c.username ?: @"",
        @"chat_kind": c.isGroup ? @"group" : @"dm",
        @"self_wxid": WXHistSelfWxid() ?: @"",
        @"media_key": WXHistMD5(c.username) ?: @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:header options:0 error:NULL];
    NSString *line = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!WXHistWriteLine(line)) {
        WXHistCloseJsonl();
        return NO;
    }
    return YES;
}

static void WXHistFinishJsonl(void) {
    if (gExpJsonl == NULL) {
        return;
    }
    NSDictionary *tail = @{@"end": @YES, @"rows": @(gExpJsonlRows)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:tail options:0 error:NULL];
    NSString *line = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    WXHistWriteLine(line);
    fflush(gExpJsonl);
    fclose(gExpJsonl);
    gExpJsonl = NULL;
    if (gExpJsonlPath.length && gExpJsonlRows > 0) {
        NSString *remote = [NSString stringWithFormat:@"wxhist-%@.jsonl", [[NSUUID UUID] UUIDString]];
        [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueLocalFile:gExpJsonlPath
                                                              remoteRelativePath:remote];
        WeChatIngestDebugLog(@"history jsonl queued rows=%ld %@", (long)gExpJsonlRows, remote);
    }
    // keep file until SFTP finishes; delete later on next start
    gExpJsonlPath = nil;
    gExpJsonlRows = 0;
}

static NSInteger WXHistBestCount(id mgr, WXIngestContact *c, NSDictionary *sqlCounts) {
    if (sqlCounts.count) {
        NSString *md = WXHistMD5(c.username);
        for (NSString *key in @[
            [NSString stringWithFormat:@"Chat_%@", md],
            [NSString stringWithFormat:@"Chat_%@", md.uppercaseString],
            [NSString stringWithFormat:@"Chat_%@", c.username],
        ]) {
            NSInteger n = [sqlCounts[key] integerValue];
            if (n > 0) {
                return n;
            }
        }
    }
    NSInteger best = c.msgHint;
    NSInteger api = WXHistMsgCountAPI(mgr, c.username);
    if (api > best) {
        best = api;
    }
    id last = WXHistLastMsg(mgr, c.username);
    unsigned int lid = WXHistLocalID(last);
    if ((NSInteger)lid > 0) {
        c.lastLocalId = (NSInteger)lid;
    }
    if (best > 0) {
        return best;
    }
    return c.lastLocalId;
}

static void WXHistSaveScan(NSDictionary *report) {
    NSMutableDictionary *slim = [report mutableCopy];
    [slim removeObjectForKey:@"sessions"];
    [[WXIngestSettings sharedDefaults] setObject:slim forKey:kScanKey];
    [[WXIngestSettings sharedDefaults] synchronize];
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueNamedJSON:report
                                                                    fileName:@"history_scan.json"];
}

static void WXHistPushProgress(void) {
    WXHistUpdateFraction();
    WXHistProgress()[@"dest"] = WXHistDestPath();
    WXHistPersistProgress();
    NSMutableDictionary *snap = [WeChatIngestPluginStatusSnapshot() mutableCopy];
    snap[@"history"] = [WXHistProgress() copy];
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueStatus:snap];
}

static void WXHistClearCursors(void) {
    NSUserDefaults *defs = [WXIngestSettings sharedDefaults];
    [defs removeObjectForKey:kCursorKey];
    [defs removeObjectForKey:kDoneKey];
    [defs synchronize];
    WXHistProgress()[@"msgs"] = @0;
    WXHistProgress()[@"chats_done"] = @0;
    WXHistProgress()[@"current"] = @"";
    WXHistProgress()[@"error"] = @"";
    WXHistProgress()[@"fraction"] = @0;
    WXHistProgress()[@"engine"] = @"sqlite-batch";
    WXHistCloseExpDB();
}

static BOOL WXHistPreviousWasDud(void) {
    NSString *engine = [WXHistProgress()[@"engine"] description];
    if (![engine isEqualToString:@"sqlite-batch"]) {
        return YES;
    }
    NSInteger scanned = [[[WXIngestSettings sharedDefaults] dictionaryForKey:kScanKey][@"msgs"] integerValue];
    NSInteger uploaded = [WXHistProgress()[@"msgs"] integerValue];
    return scanned >= 30 && uploaded < MAX(3, scanned / 50);
}

static void WXHistAfter(NSTimeInterval sec, void (*fn)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fn();
    });
}

static void WXHistScanTick(void) {
    if (!gScanning) {
        return;
    }
    id mgr = WXHistMessageMgr();
    NSUInteger end = MIN(gScanIdx + 6, gScanChats.count);
    for (; gScanIdx < end; gScanIdx++) {
        WXIngestContact *c = gScanChats[gScanIdx];
        WXHistProgress()[@"current"] = [NSString stringWithFormat:@"统计消息 %@/%@",
                                        @(gScanIdx + 1), @(gScanChats.count)];
        if (c.isGroup) {
            gScanGroups += 1;
        } else {
            gScanDMs += 1;
        }
        NSInteger count = WXHistBestCount(mgr, c, gSqlCounts);
        if (count > 0) {
            gScanMsgTotal += count;
        }
        unsigned long long chatBytes = 0;
        NSString *md = WXHistMD5(c.username);
        if (md.length && gMediaByHash[md]) {
            chatBytes = [gMediaByHash[md] unsignedLongLongValue];
        }
        [gScanRows addObject:@{
            @"chat_id": c.username ?: @"",
            @"name": c.displayName ?: c.username ?: @"",
            @"kind": c.isGroup ? @"group" : @"dm",
            @"msgs": @(count),
            @"media_bytes": @(chatBytes),
            @"last_local_id": @(c.lastLocalId),
        }];
    }
    WXHistProgress()[@"chats_total"] = @(gScanChats.count);
    WXHistProgress()[@"chats_done"] = @(gScanIdx);
    WXHistProgress()[@"bytes"] = @(gScanMediaDone);
    WXHistPushProgress();
    if (gScanIdx < gScanChats.count) {
        WXHistAfter(0.02, WXHistScanTick);
        return;
    }
    [gScanRows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult bySize = [b[@"media_bytes"] compare:a[@"media_bytes"]];
        if (bySize != NSOrderedSame) {
            return bySize;
        }
        return [b[@"msgs"] compare:a[@"msgs"]];
    }];
    NSArray *top = [gScanRows subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, gScanRows.count))];
    unsigned long long bytes = gScanMediaDone > 0 ? gScanMediaDone : gScanBytes;
    NSDictionary *report = @{
        @"ts": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
        @"chats": @(gScanChats.count),
        @"groups": @(gScanGroups),
        @"dms": @(gScanDMs),
        @"msgs": @(gScanMsgTotal),
        @"media_bytes": @(bytes),
        @"dest": WXHistDestPath(),
        @"top": top,
        @"sessions": [gScanRows copy],
    };
    WXHistSaveScan(report);
    WXHistProgress()[@"state"] = @"scanned";
    WXHistProgress()[@"bytes"] = @(bytes);
    WXHistProgress()[@"current"] = @"";
    gScanning = NO;
    WXHistPushProgress();
    WeChatIngestDebugLog(@"history scan chats=%lu groups=%ld dms=%ld msgs=%ld media=%@ sqlTables=%lu",
                         (unsigned long)gScanChats.count, (long)gScanGroups, (long)gScanDMs,
                         (long)gScanMsgTotal, WXHistFormatBytes(bytes),
                         (unsigned long)gSqlCounts.count);
    WeChatIngestDebugLogFlushRemote();
    void (^done)(NSDictionary *) = gScanDone;
    gScanDone = nil;
    gScanChats = nil;
    gScanRows = nil;
    gSqlCounts = nil;
    if (done) {
        done(report);
    }
}

static void WXHistExportFinish(BOOL completed) {
    WXHistCloseExpDB();
    if (completed) {
        WXHistProgress()[@"state"] = @"done";
        WXHistProgress()[@"fraction"] = @1;
    } else if (!gRunning) {
        WXHistProgress()[@"state"] = @"paused";
    }
    WXHistProgress()[@"current"] = @"";
    gRunning = NO;
    gExpChats = nil;
    gExpMgr = nil;
    gExpCursors = nil;
    gExpDone = nil;
    gExpChatId = nil;
    WXHistCloseJsonl();
    WXHistPushProgress();
    WeChatIngestDebugLog(@"history export end state=%@ msgs=%@ wrap=%ld bare=%ld",
                         WXHistProgress()[@"state"], WXHistProgress()[@"msgs"],
                         (long)gExpWrapHits, (long)gExpBareHits);
}

static void WXHistExportBeginChat(void) {
    if (!gRunning) {
        WXHistExportFinish(NO);
        return;
    }
    while (gExpIdx < gExpChats.count &&
           [gExpDone containsObject:gExpChats[gExpIdx].username]) {
        gExpIdx += 1;
    }
    WXHistProgress()[@"chats_done"] = @(gExpIdx);
    WXHistProgress()[@"chats_total"] = @(gExpChats.count);
    WXHistProgress()[@"engine"] = @"sqlite-batch";
    if (gExpIdx >= gExpChats.count) {
        if (!gExpDidSweep && gExpChats.count) {
            gExpDidSweep = YES;
            NSInteger extra = 0;
            for (WXIngestContact *c in gExpChats) {
                NSInteger n = 0;
                if (WXHistOpenChatTable(c.username, &n) &&
                    n > [gExpCursors[c.username] integerValue]) {
                    [gExpDone removeObject:c.username];
                    extra += 1;
                }
                WXHistCloseExpDB();
            }
            WeChatIngestDebugLog(@"history sweep chats-with-new=%ld", (long)extra);
            if (extra > 0) {
                gExpIdx = 0;
                WXHistAfter(0.03, WXHistExportBeginChat);
                return;
            }
        }
        WXHistExportFinish(YES);
        return;
    }
    WXIngestContact *c = gExpChats[gExpIdx];
    WXHistProgress()[@"current"] = c.displayName ?: c.username;
    gExpFound = 0;
    gExpMiss = 0;
    gExpOpenDataQueued = NO;
    gExpChatId = c.username;
    gExpSqlOffset = [gExpCursors[c.username] integerValue];
    NSInteger sqlCount = 0;
    BOOL opened = WXHistOpenChatTable(c.username, &sqlCount);
    gExpSqlTotal = sqlCount;
    gExpExpect = sqlCount > 0 ? sqlCount : WXHistBestCount(gExpMgr, c, gSqlCounts);
    if (!opened || sqlCount <= 0) {
        id last = WXHistLastMsg(gExpMgr, c.username);
        if (last) {
            WeChatIngestCaptureHistoryWrap(last);
            gExpFound += 1;
            gExpMsgTotal += 1;
        }
        [gExpDone addObject:c.username];
        gExpCursors[c.username] = @(MAX(sqlCount, 1));
        [[WXIngestSettings sharedDefaults] setObject:gExpCursors forKey:kCursorKey];
        [[WXIngestSettings sharedDefaults] setObject:gExpDone.allObjects forKey:kDoneKey];
        WeChatIngestDebugLog(@"history chat no-table %@ last=%d expect=%ld",
                             c.displayName ?: c.username, last != nil, (long)gExpExpect);
        gExpIdx += 1;
        WXHistProgress()[@"msgs"] = @(gExpMsgTotal);
        WXHistProgress()[@"chats_done"] = @(gExpIdx);
        WXHistPushProgress();
        WXHistAfter(0.03, WXHistExportBeginChat);
        return;
    }
    WXHistProgress()[@"msgs"] = @(gExpMsgTotal);
    WXHistPushProgress();
    if (!WXHistStartJsonl(c)) {
        WeChatIngestDebugLog(@"history jsonl start-fail %@", c.username);
        gExpIdx += 1;
        WXHistAfter(0.03, WXHistExportBeginChat);
        return;
    }
    WXHistProgress()[@"current"] = [NSString stringWithFormat:@"打包 %@",
                                    c.displayName ?: c.username];
    WeChatIngestDebugLog(@"history chat start %@ table=%@ rows=%ld offset=%ld jsonl-first",
                         c.displayName ?: c.username, gExpTable,
                         (long)gExpSqlTotal, (long)gExpSqlOffset);
    WeChatIngestDebugLogFlushRemote();
    WXHistAfter(0.02, WXHistExportTick);
}

static void WXHistExportTick(void) {
    if (!gRunning) {
        WXHistExportFinish(NO);
        return;
    }
    if (gExpIdx >= gExpChats.count) {
        WXHistExportFinish(YES);
        return;
    }
    WXIngestContact *c = gExpChats[gExpIdx];
    if (gExpDB == NULL || gExpTable.length == 0) {
        gExpIdx += 1;
        WXHistAfter(0.02, WXHistExportBeginChat);
        return;
    }
    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"[%@]", gExpColLocal]];
    [parts addObject:gExpColType.length ? [NSString stringWithFormat:@"[%@]", gExpColType] : @"0"];
    [parts addObject:gExpColMsg.length ? [NSString stringWithFormat:@"[%@]", gExpColMsg] : @"''"];
    [parts addObject:gExpColTime.length ? [NSString stringWithFormat:@"[%@]", gExpColTime] : @"0"];
    [parts addObject:gExpColDes.length ? [NSString stringWithFormat:@"[%@]", gExpColDes] : @"0"];
    NSString *sql = [NSString stringWithFormat:
                     @"SELECT %@ FROM [%@] ORDER BY [%@] ASC LIMIT 2500 OFFSET %ld",
                     [parts componentsJoinedByString:@","], gExpTable, gExpColLocal,
                     (long)gExpSqlOffset];
    sqlite3_stmt *st = NULL;
    NSInteger got = 0;
    if (sqlite3_prepare_v2(gExpDB, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW && gRunning) {
            unsigned int lid = (unsigned int)sqlite3_column_int64(st, 0);
            int type = (int)sqlite3_column_int(st, 1);
            NSString *message = WXHistSqlText(st, 2);
            NSInteger ts = (NSInteger)sqlite3_column_int64(st, 3);
            int des = sqlite3_column_int(st, 4);
            NSDictionary *row = @{
                @"lid": @(lid),
                @"type": @(type),
                @"msg": message ?: @"",
                @"ts": @(ts),
                @"des": @(des),
            };
            NSData *payload = [NSJSONSerialization dataWithJSONObject:row options:0 error:NULL];
            NSString *line = payload ? [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] : nil;
            if (WXHistWriteLine(line)) {
                gExpJsonlRows += 1;
            }
            gExpFound += 1;
            gExpMsgTotal += 1;
            got += 1;
        }
        sqlite3_finalize(st);
    } else {
        WeChatIngestDebugLog(@"sqlite select fail %@ %s", gExpTable, sqlite3_errmsg(gExpDB));
        got = 0;
        gExpSqlOffset = gExpSqlTotal;
    }
    gExpSqlOffset += got;
    gExpCursors[c.username] = @(gExpSqlOffset);
    [[WXIngestSettings sharedDefaults] setObject:gExpCursors forKey:kCursorKey];
    WXHistProgress()[@"msgs"] = @(gExpMsgTotal);
    WXHistProgress()[@"current"] = c.displayName ?: c.username;
    WXHistProgress()[@"engine"] = @"sqlite-batch";
    if (got == 0 || gExpSqlOffset >= gExpSqlTotal || !gRunning) {
        NSInteger packed = gExpJsonlRows;
        WXHistFinishJsonl();
        NSString *chatForMedia = [c.username copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            WXHistQueueAllChatMedia(chatForMedia);
        });
        [gExpDone addObject:c.username];
        [[WXIngestSettings sharedDefaults] setObject:gExpDone.allObjects forKey:kDoneKey];
        [[WXIngestSettings sharedDefaults] synchronize];
        WeChatIngestDebugLog(@"history chat done %@ rows=%ld/%ld jsonl=%ld total=%lu",
                             c.displayName ?: c.username,
                             (long)gExpSqlOffset, (long)gExpSqlTotal,
                             (long)packed,
                             (unsigned long)gExpMsgTotal);
        WXHistCloseExpDB();
        gExpIdx += 1;
        WXHistProgress()[@"chats_done"] = @(gExpIdx);
        WXHistPushProgress();
        WXHistAfter(0.03, WXHistExportBeginChat);
        return;
    }
    WXHistPushProgress();
    WXHistAfter(0.02, WXHistExportTick);
}

@implementation WXIngestHistoryExport

+ (BOOL)isRunning { return gRunning; }
+ (BOOL)isScanning { return gScanning; }

+ (NSDictionary<NSString *, id> *)lastScan {
    id obj = [[WXIngestSettings sharedDefaults] objectForKey:kScanKey];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : [NSDictionary dictionary];
}

+ (NSDictionary<NSString *, id> *)progress {
    WXHistNormalizeIdleState();
    return [WXHistProgress() copy];
}

+ (float)fraction {
    WXHistNormalizeIdleState();
    WXHistUpdateFraction();
    return [WXHistProgress()[@"fraction"] floatValue];
}

+ (NSString *)destinationPath {
    return WXHistDestPath();
}

+ (void)resumeIfNeeded {
}

+ (NSString *)progressLine {
    NSDictionary *scan = [self lastScan];
    NSDictionary *p = WXHistProgress();
    if (gScanning) {
        NSString *cur = p[@"current"] ?: @"";
        return cur.length ? cur : @"正在扫描会话、消息条数和本地媒体…";
    }
    if (gRunning) {
        return [NSString stringWithFormat:@"正在按群打包 %@/%@ · 已交 %@ 条 · %@",
                p[@"chats_done"], p[@"chats_total"], p[@"msgs"], p[@"current"] ?: @""];
    }
    NSNumber *chats = scan[@"chats"];
    NSNumber *msgs = scan[@"msgs"];
    NSString *size = scan[@"media_bytes"] ? WXHistFormatBytes([scan[@"media_bytes"] unsignedLongLongValue]) : nil;
    if (chats == nil) {
        return @"还没扫描。先点「扫描会话和容量」。";
    }
    NSString *state = [p[@"state"] description];
    NSString *base = [NSString stringWithFormat:@"%@ 个会话 · 约 %@ 条消息 · 本地 %@",
                      chats, msgs ?: @"?", size ?: @"容量未知"];
    if ([state isEqualToString:@"paused"]) {
        return [NSString stringWithFormat:@"已暂停 · 已传 %@ 条 · 点导出继续", p[@"msgs"] ?: @0];
    }
    if ([state isEqualToString:@"done"]) {
        return [NSString stringWithFormat:@"上传已完成 · %@ 条", p[@"msgs"] ?: @0];
    }
    return [NSString stringWithFormat:@"%@ · 尚未上传", base];
}

+ (void)scanWithCompletion:(void (^)(NSDictionary<NSString *, id> *report))completion {
    if (gScanning || gRunning) {
        if (completion) {
            completion([self lastScan]);
        }
        return;
    }
    gScanning = YES;
    WXHistProgress()[@"state"] = @"scanning";
    WXHistProgress()[@"current"] = @"正在读取会话列表…";
    WXHistPushProgress();
    void (^work)(void) = ^{
        NSArray *sessions = nil;
        @try {
            sessions = [WXIngestContacts visibleSessions];
        } @catch (NSException *e) {
            sessions = @[];
            WeChatIngestDebugLog(@"history sessions failed: %@", e.reason);
        }
        if (sessions.count == 0) {
            NSMutableArray *all = [NSMutableArray array];
            [all addObjectsFromArray:[WXIngestContacts groups]];
            [all addObjectsFromArray:[WXIngestContacts people]];
            sessions = all;
        }
        gScanChats = sessions;
        gScanRows = [NSMutableArray array];
        gScanIdx = 0;
        gScanMsgTotal = 0;
        gScanGroups = 0;
        gScanDMs = 0;
        gScanBytes = 0;
        gScanMediaDone = 0;
        gScanDone = [completion copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            unsigned long long media = WXHistSumAllMedia();
            NSDictionary *sql = WXHistSqliteAllChatCounts();
            dispatch_async(dispatch_get_main_queue(), ^{
                gScanMediaDone = media;
                gScanBytes = media;
                gSqlCounts = sql;
                WXHistProgress()[@"bytes"] = @(media);
                WXHistProgress()[@"current"] = [NSString stringWithFormat:@"本地媒体 %@",
                                                WXHistFormatBytes(media)];
                WXHistPushProgress();
                WXHistScanTick();
            });
        });
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

+ (void)stopExport {
    gRunning = NO;
    WXHistProgress()[@"state"] = @"paused";
    WXHistPushProgress();
    WeChatIngestDebugLog(@"history export pause");
}

+ (void)startExport {
    [self startExportWipingRemote:NO];
}

+ (void)startExportWipingRemote:(BOOL)wipe {
    if (gRunning || gScanning) {
        return;
    }
    if (wipe || WXHistPreviousWasDud()) {
        WeChatIngestDebugLog(@"history reset cursors wipe=%d", wipe);
        WXHistClearCursors();
    }
    if (wipe) {
        [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueEvent:@{
            @"cmd": @"wipe_imported",
            @"role": @"control",
            @"ts": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
        } mediaData:nil mediaSuffix:nil];
        WeChatIngestDebugLog(@"history queued wipe_imported for fnOS");
    }
    gRunning = YES;
    gExpDidSweep = NO;
    gExpSentMedia = [NSMutableSet set];
    gExpRemoteBytes = [NSMutableDictionary dictionary];
    WXHistProgress()[@"state"] = @"exporting";
    WXHistProgress()[@"error"] = @"";
    WXHistProgress()[@"dest"] = WXHistDestPath();
    WXHistProgress()[@"engine"] = @"sqlite-batch";
    WXHistPushProgress();
    void (^work)(void) = ^{
        @try {
            gExpChats = [WXIngestContacts visibleSessions];
        } @catch (NSException *e) {
            gExpChats = @[];
        }
        if (gExpChats.count == 0) {
            NSMutableArray *all = [NSMutableArray array];
            [all addObjectsFromArray:[WXIngestContacts groups]];
            [all addObjectsFromArray:[WXIngestContacts people]];
            gExpChats = all;
        }
        gExpMgr = WXHistMessageMgr();
        if (WXHistSqlFiles().count == 0) {
            gSqlCounts = WXHistSqliteAllChatCounts();
        }
        NSUserDefaults *defs = [WXIngestSettings sharedDefaults];
        gExpCursors = [([defs dictionaryForKey:kCursorKey] ?: @{}) mutableCopy];
        gExpDone = [NSMutableSet setWithArray:([defs arrayForKey:kDoneKey] ?: @[])];
        gExpIdx = 0;
        gExpWrapHits = 0;
        gExpBareHits = 0;
        gExpMsgTotal = [WXHistProgress()[@"msgs"] unsignedIntegerValue];
        WXHistProgress()[@"chats_total"] = @(gExpChats.count);
        WeChatIngestDebugLog(@"history export start chats=%lu tables=%lu dest=%@ engine=sqlite-batch",
                             (unsigned long)gExpChats.count,
                             (unsigned long)WXHistSqlFiles().count,
                             WXHistDestPath());
        WXHistExportBeginChat();
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

@end
