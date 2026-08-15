#import "MediaExtract.h"
#import "DebugLog.h"

#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <string.h>

#pragma mark - small helpers

static id WeChatIngestKVC(id obj, NSString *key) {
    if (obj == nil || key.length == 0) {
        return nil;
    }
    @try {
        id value = [obj valueForKey:key];
        return (value == nil || value == [NSNull null]) ? nil : value;
    } @catch (NSException *e) {
        return nil;
    }
}

static BOOL WeChatIngestFileOK(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    return attrs != nil && size > 8;
}

static unsigned long long WeChatIngestFileSize(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return [attrs[NSFileSize] unsignedLongLongValue];
}

static NSString *WeChatIngestMD5Hex(NSString *text) {
    if (text.length == 0) {
        return @"";
    }
    Class util = objc_getClass("CUtility");
    if (util) {
        SEL sel = sel_registerName("GetMd5StrWithString:");
        if (class_getClassMethod(util, sel)) {
            id md = ((id (*)(id, SEL, id))objc_msgSend)(util, sel, text);
            if ([md isKindOfClass:[NSString class]] && [md length] == 32) {
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

static NSString *WeChatIngestSelfWxid(void) {
    id mgr = WeChatIngestFindService("CContactMgr");
    if (mgr == nil) {
        return @"";
    }
    id contact = nil;
    if ([mgr respondsToSelector:@selector(getSelfContact)]) {
        contact = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(getSelfContact));
    }
    NSString *name = WeChatIngestKVC(contact, @"m_nsUsrName");
    return [name isKindOfClass:[NSString class]] ? name : @"";
}

static id WeChatIngestUnwrapService(id svc) {
    if (svc == nil) {
        return nil;
    }
    NSString *cls = NSStringFromClass([svc class]);
    if (![cls.lowercaseString containsString:@"wrapper"]) {
        return svc;
    }
    for (NSString *key in @[@"service", @"m_service", @"wrappedService", @"target", @"value"]) {
        id inner = WeChatIngestKVC(svc, key);
        if (inner != nil && inner != svc) {
            WeChatIngestDebugLog(@"[pkc] unwrap %@ -> %@", cls, NSStringFromClass([inner class]));
            return inner;
        }
    }
    SEL fwd = @selector(forwardingTargetForSelector:);
    if ([svc respondsToSelector:fwd]) {
        @try {
            id inner = ((id (*)(id, SEL, SEL))objc_msgSend)(
                svc, fwd, sel_registerName("getImageFromMessageWrap:withDefault:"));
            if (inner != nil && inner != svc) {
                WeChatIngestDebugLog(@"[pkc] unwrap-fwd %@ -> %@", cls, NSStringFromClass([inner class]));
                return inner;
            }
        } @catch (NSException *e) {
        }
    }
    WeChatIngestDebugLog(@"[pkc] unwrap failed %@", cls);
    return svc;
}

id WeChatIngestFindService(const char *className) {
    Class cls = objc_getClass(className);
    if (cls == NULL) {
        return nil;
    }
    Class ctxCls = objc_getClass("MMContext");
    if (ctxCls) {
        SEL currents[] = {
            sel_registerName("currentContext"),
            sel_registerName("activeUserContext"),
            sel_registerName("lastContext"),
        };
        for (size_t i = 0; i < sizeof(currents) / sizeof(currents[0]); i++) {
            if (!class_getClassMethod(ctxCls, currents[i])) {
                continue;
            }
            id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxCls, currents[i]);
            if (ctx == nil) {
                continue;
            }
            const char *svcSels[] = {"getService:", "serviceInstanceOfClass:", "getServiceInstance:"};
            for (size_t j = 0; j < 3; j++) {
                SEL sel = sel_registerName(svcSels[j]);
                if ([ctx respondsToSelector:sel]) {
                    id svc = ((id (*)(id, SEL, Class))objc_msgSend)(ctx, sel, cls);
                    if (svc) {
                        return WeChatIngestUnwrapService(svc);
                    }
                }
            }
        }
        SEL classSvc = sel_registerName("serviceInstanceOfClass:");
        if (class_getClassMethod(ctxCls, classSvc)) {
            id svc = ((id (*)(id, SEL, Class))objc_msgSend)(ctxCls, classSvc, cls);
            if (svc) {
                return WeChatIngestUnwrapService(svc);
            }
        }
    }
    Class centerCls = objc_getClass("MMServiceCenter");
    if (centerCls && class_getClassMethod(centerCls, @selector(defaultCenter))) {
        id center = ((id (*)(id, SEL))objc_msgSend)(centerCls, @selector(defaultCenter));
        if ([center respondsToSelector:@selector(getService:)]) {
            id svc = ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), cls);
            if (svc) {
                return WeChatIngestUnwrapService(svc);
            }
        }
    }
    const char *shared[] = {"sharedInstance", "sharedMgr", "GetInstance", "getInstance", "sharedContext"};
    for (size_t i = 0; i < sizeof(shared) / sizeof(shared[0]); i++) {
        SEL sel = sel_registerName(shared[i]);
        if (class_getClassMethod(cls, sel)) {
            id svc = ((id (*)(id, SEL))objc_msgSend)(cls, sel);
            if (svc) {
                return WeChatIngestUnwrapService(svc);
            }
        }
    }
    return nil;
}

#pragma mark - suffix / bytes

static NSString *WeChatIngestSuffixFromData(NSData *data, NSString *msgType) {
    if (data.length >= 8) {
        const unsigned char *b = data.bytes;
        if (b[0] == 0xFF && b[1] == 0xD8) {
            return @".jpg";
        }
        if (b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') {
            return @".png";
        }
        if (b[0] == 'G' && b[1] == 'I' && b[2] == 'F') {
            return @".gif";
        }
        if (data.length >= 12 && memcmp(b + 4, "ftyp", 4) == 0) {
            return @".mp4";
        }
        if (data.length >= 10 && memcmp(b, "#!SILK_V3", 9) == 0) {
            return @".aud";
        }
        if (b[0] == 0x02 && data.length > 64) {
            return @".aud";
        }
    }
    if ([msgType isEqualToString:@"voice"]) {
        return @".aud";
    }
    if ([msgType isEqualToString:@"video"]) {
        return @".mp4";
    }
    return @".jpg";
}

static NSData *WeChatIngestDataFromImage(id image) {
    if (![image isKindOfClass:[UIImage class]]) {
        return nil;
    }
    NSData *png = UIImagePNGRepresentation((UIImage *)image);
    if (png.length > 32) {
        return png;
    }
    return UIImageJPEGRepresentation((UIImage *)image, 0.92);
}

#pragma mark - disk paths

static NSArray<NSString *> *WeChatIngestMediaRoots(NSString *selfWxid) {
    NSString *home = NSHomeDirectory();
    NSMutableArray *roots = [NSMutableArray array];
    NSArray *bases = @[
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"Library/WechatPrivate"],
        [home stringByAppendingPathComponent:@"Library"],
    ];
    NSMutableArray *users = [NSMutableArray array];
    if (selfWxid.length) {
        [users addObject:selfWxid];
    }
    [users addObject:@""];
    for (NSString *base in bases) {
        for (NSString *user in users) {
            if (user.length) {
                [roots addObject:[base stringByAppendingPathComponent:user]];
            } else {
                [roots addObject:base];
            }
        }
    }
    return roots;
}

static NSString *WeChatIngestResolveMaybeRelative(NSString *path, NSString *selfWxid) {
    if (WeChatIngestFileOK(path)) {
        return path;
    }
    if (path.length == 0) {
        return nil;
    }
    for (NSString *root in WeChatIngestMediaRoots(selfWxid)) {
        NSString *full = [root stringByAppendingPathComponent:path];
        if (WeChatIngestFileOK(full)) {
            return full;
        }
    }
    return nil;
}

static BOOL WeChatIngestPathLooksThumb(NSString *path) {
    NSString *base = path.lastPathComponent.lowercaseString;
    return [base containsString:@"thum"] || [base containsString:@"thumb"] || [base hasSuffix:@".pic_thum"];
}

static NSString *WeChatIngestPreferPath(NSString *current, NSString *candidate) {
    if (!WeChatIngestFileOK(candidate)) {
        return current;
    }
    BOOL thumb = WeChatIngestPathLooksThumb(candidate);
    if (current == nil) {
        return candidate;
    }
    BOOL currentThumb = WeChatIngestPathLooksThumb(current);
    if (thumb && !currentThumb) {
        return current;
    }
    if (!thumb && currentThumb) {
        return candidate;
    }
    if (WeChatIngestFileSize(candidate) > WeChatIngestFileSize(current)) {
        return candidate;
    }
    return current;
}

static NSArray<NSString *> *WeChatIngestFolderNames(NSString *msgType) {
    if ([msgType isEqualToString:@"voice"]) {
        return @[@"Audio", @"audio", @"Voice", @"voice"];
    }
    if ([msgType isEqualToString:@"video"]) {
        return @[@"Video", @"video"];
    }
    if ([msgType isEqualToString:@"file"]) {
        return @[@"OpenData", @"File", @"file", @"AppAttach", @"Attach"];
    }
    if ([msgType isEqualToString:@"emoji"]) {
        return @[@"Emoji", @"emoji", @"Emoticon", @"Img"];
    }
    return @[@"Img", @"Image", @"img", @"image"];
}

static NSArray<NSString *> *WeChatIngestExts(NSString *msgType) {
    if ([msgType isEqualToString:@"voice"]) {
        return @[@"aud", @"silk", @"slk", @"amr"];
    }
    if ([msgType isEqualToString:@"video"]) {
        return @[@"mp4", @"mov", @"video"];
    }
    if ([msgType isEqualToString:@"file"]) {
        return @[@"pdf", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx", @"zip", @"rar", @"7z", @"txt", @"pages", @"bin"];
    }
    if ([msgType isEqualToString:@"emoji"]) {
        return @[@"gif", @"png", @"pic"];
    }
    return @[@"pic", @"pic_hd", @"pic_thum", @"jpg", @"jpeg", @"png", @"gif", @"heic", @"wxam", @"dat"];
}

static NSArray<NSString *> *WeChatIngestIDsFromWrap(id wrap) {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *key in @[@"m_uiMesLocalID", @"m_n64MesSvrID", @"m_uiMesSvrID", @"m_n64SvrId"]) {
        id v = WeChatIngestKVC(wrap, key);
        if (v == nil) {
            continue;
        }
        NSString *s = [v respondsToSelector:@selector(stringValue)] ? [v stringValue] : [v description];
        if (s.length > 0 && ![ids containsObject:s]) {
            [ids addObject:s];
        }
    }
    return ids;
}

static NSString *WeChatIngestConstructedPath(id wrap, NSString *msgType) {
    NSString *selfWxid = WeChatIngestSelfWxid();
    NSString *from = WeChatIngestKVC(wrap, @"m_nsFromUsr") ?: @"";
    NSString *to = WeChatIngestKVC(wrap, @"m_nsToUsr") ?: @"";
    NSMutableArray *peers = [NSMutableArray array];
    for (NSString *p in @[from, to]) {
        if (p.length && ![peers containsObject:p]) {
            [peers addObject:p];
        }
    }
    NSMutableArray *hashes = [NSMutableArray array];
    for (NSString *p in peers) {
        NSString *md = WeChatIngestMD5Hex(p);
        if (md.length && ![hashes containsObject:md]) {
            [hashes addObject:md];
        }
    }
    NSArray *ids = WeChatIngestIDsFromWrap(wrap);
    NSArray *folders = WeChatIngestFolderNames(msgType);
    NSArray *exts = WeChatIngestExts(msgType);
    NSString *best = nil;
    for (NSString *root in WeChatIngestMediaRoots(selfWxid)) {
        for (NSString *folder in folders) {
            NSString *folderPath = [root stringByAppendingPathComponent:folder];
            for (NSString *lid in ids) {
                for (NSString *ext in exts) {
                    NSMutableArray *cands = [NSMutableArray array];
                    [cands addObject:[NSString stringWithFormat:@"%@/%@.%@", folderPath, lid, ext]];
                    for (NSString *peer in peers) {
                        [cands addObject:[NSString stringWithFormat:@"%@/%@/%@.%@", folderPath, peer, lid, ext]];
                    }
                    for (NSString *md in hashes) {
                        NSString *pref = [md substringToIndex:MIN((NSUInteger)2, md.length)];
                        [cands addObject:[NSString stringWithFormat:@"%@/%@/%@/%@.%@", folderPath, pref, md, lid, ext]];
                        [cands addObject:[NSString stringWithFormat:@"%@/%@/%@.%@", folderPath, md, lid, ext]];
                        [cands addObject:[NSString stringWithFormat:@"%@/%@/%@.%@", folderPath, pref, lid, ext]];
                        [cands addObject:[NSString stringWithFormat:@"%@/%@/%@", folderPath, pref, md]];
                    }
                    for (NSString *path in cands) {
                        best = WeChatIngestPreferPath(best, path);
                    }
                }
            }
        }
    }
    return best;
}

static NSString *WeChatIngestScanByID(id wrap, NSString *msgType) {
    NSArray *ids = WeChatIngestIDsFromWrap(wrap);
    if (ids.count == 0) {
        return nil;
    }
    NSArray *folders = WeChatIngestFolderNames(msgType);
    NSArray *exts = WeChatIngestExts(msgType);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *best = nil;
    for (NSString *root in WeChatIngestMediaRoots(WeChatIngestSelfWxid())) {
        for (NSString *folder in folders) {
            NSString *dir = [root stringByAppendingPathComponent:folder];
            if (![fm fileExistsAtPath:dir]) {
                continue;
            }
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
            NSInteger seen = 0;
            for (NSString *rel in en) {
                if (++seen > 8000) {
                    break;
                }
                NSString *base = rel.lastPathComponent;
                BOOL hit = NO;
                for (NSString *lid in ids) {
                    if ([base containsString:lid] || [rel containsString:lid]) {
                        hit = YES;
                        break;
                    }
                }
                if (!hit) {
                    continue;
                }
                NSString *ext = base.pathExtension.lowercaseString;
                if (ext.length && ![exts containsObject:ext] && ![base hasSuffix:@".pic"] && ![base hasSuffix:@".aud"]) {
                    continue;
                }
                NSString *full = [dir stringByAppendingPathComponent:rel];
                best = WeChatIngestPreferPath(best, full);
            }
        }
    }
    return best;
}

static NSString *WeChatIngestCallPath(id target, SEL sel, id arg);

static NSString *WeChatIngestChatNameFromWrap(id wrap) {
    if (wrap == nil) {
        return @"";
    }
    SEL chatSel = sel_registerName("GetChatName");
    if ([wrap respondsToSelector:chatSel]) {
        @try {
            id name = ((id (*)(id, SEL))objc_msgSend)(wrap, chatSel);
            if ([name isKindOfClass:[NSString class]] && [name length] > 0) {
                return name;
            }
        } @catch (NSException *e) {
        }
    }
    NSString *from = WeChatIngestKVC(wrap, @"m_nsFromUsr") ?: @"";
    NSString *to = WeChatIngestKVC(wrap, @"m_nsToUsr") ?: @"";
    if ([from hasSuffix:@"@chatroom"]) {
        return from;
    }
    if ([to hasSuffix:@"@chatroom"]) {
        return to;
    }
    NSString *selfWxid = WeChatIngestSelfWxid();
    if (selfWxid.length && [to isEqualToString:selfWxid]) {
        return from;
    }
    return to.length ? to : from;
}

id WeChatIngestRefreshWrap(id wrap) {
    if (wrap == nil) {
        return nil;
    }
    id mgr = WeChatIngestFindService("CMessageMgr");
    NSString *chat = WeChatIngestChatNameFromWrap(wrap);
    id lid = WeChatIngestKVC(wrap, @"m_uiMesLocalID");
    id svr = WeChatIngestKVC(wrap, @"m_n64MesSvrID") ?: WeChatIngestKVC(wrap, @"m_uiMesSvrID");
    if (mgr == nil) {
        WeChatIngestDebugLog(@"[pkc] GetMsg skip mgr=nil chat=%@ lid=%@", chat, lid);
        return wrap;
    }
    id fresh = nil;
    SEL getMsg = sel_registerName("GetMsg:LocalID:");
    if (chat.length && lid != nil && [mgr respondsToSelector:getMsg]) {
        @try {
            fresh = ((id (*)(id, SEL, id, unsigned int))objc_msgSend)(
                mgr, getMsg, chat, [lid unsignedIntValue]);
        } @catch (NSException *e) {
            WeChatIngestDebugLog(@"[pkc] GetMsg:LocalID: %@", e.reason);
        }
    }
    if (fresh == nil && chat.length && svr != nil) {
        SEL bySvr = sel_registerName("GetMsg:n64SvrID:");
        if ([mgr respondsToSelector:bySvr]) {
            @try {
                long long sid = [svr respondsToSelector:@selector(longLongValue)]
                    ? [svr longLongValue] : 0;
                fresh = ((id (*)(id, SEL, id, long long))objc_msgSend)(mgr, bySvr, chat, sid);
            } @catch (NSException *e) {
                WeChatIngestDebugLog(@"[pkc] GetMsg:n64SvrID: %@", e.reason);
            }
        }
    }
    WeChatIngestDebugLog(@"[pkc] GetMsg chat=%@ lid=%@ svr=%@ fresh=%@ same=%d",
                         chat, lid, svr,
                         fresh ? NSStringFromClass([fresh class]) : @"(nil)",
                         fresh == wrap);
    return fresh ?: wrap;
}

id WeChatIngestMakeBareWrap(NSString *chatId,
                            NSString *fromUser,
                            NSString *toUser,
                            unsigned int localId,
                            int type,
                            NSString *content,
                            NSInteger createTime) {
    if (localId == 0) {
        return nil;
    }
    Class cls = objc_getClass("CMessageWrap");
    if (cls == NULL) {
        return nil;
    }
    id wrap = nil;
    SEL initType = sel_registerName("initWithMsgType:");
    @try {
        if (class_getInstanceMethod(cls, initType)) {
            wrap = ((id (*)(id, SEL, int))objc_msgSend)([cls alloc], initType, type);
        }
        if (wrap == nil) {
            wrap = [[cls alloc] init];
        }
    } @catch (NSException *e) {
        WeChatIngestDebugLog(@"bare wrap init %@", e.reason);
        return nil;
    }
    if (wrap == nil) {
        return nil;
    }
    void (^setKey)(NSString *, id) = ^(NSString *key, id value) {
        if (value == nil) {
            return;
        }
        @try {
            [wrap setValue:value forKey:key];
        } @catch (NSException *e) {
        }
    };
    setKey(@"m_uiMessageType", @(type));
    setKey(@"m_uiMesLocalID", @(localId));
    setKey(@"m_uiCreateTime", @(createTime));
    setKey(@"m_nsFromUsr", fromUser.length ? fromUser : @"");
    setKey(@"m_nsToUsr", toUser.length ? toUser : @"");
    setKey(@"m_nsContent", content.length ? content : @"");
    if (chatId.length) {
        SEL setChat = sel_registerName("setM_nsToUsr:");
        (void)setChat;
        @try {
            [wrap setValue:chatId forKey:@"m_nsChatUsr"];
        } @catch (NSException *e) {
        }
    }
    return wrap;
}

NSString *WeChatIngestConversationId(id wrap) {
    NSString *selfWxid = WeChatIngestSelfWxid();
    NSString *named = WeChatIngestChatNameFromWrap(wrap);
    NSString *from = WeChatIngestKVC(wrap, @"m_nsFromUsr") ?: @"";
    NSString *to = WeChatIngestKVC(wrap, @"m_nsToUsr") ?: @"";
    NSString *chat = named;
    if (chat.length == 0) {
        if ([from hasSuffix:@"@chatroom"] || [to hasSuffix:@"@chatroom"]) {
            chat = [from hasSuffix:@"@chatroom"] ? from : to;
        } else if (selfWxid.length && [to isEqualToString:selfWxid]) {
            chat = from;
        } else if (selfWxid.length && [from isEqualToString:selfWxid]) {
            chat = to;
        } else {
            chat = from.length ? from : to;
        }
    }
    if (selfWxid.length && [chat isEqualToString:selfWxid]) {
        if (from.length && ![from isEqualToString:selfWxid]) {
            chat = from;
        } else if (to.length && ![to isEqualToString:selfWxid]) {
            chat = to;
        } else {
            chat = @"";
        }
    }
    return chat;
}

static id WeChatIngestContactByName(NSString *name) {
    if (name.length == 0) {
        return nil;
    }
    id mgr = WeChatIngestFindService("CContactMgr");
    SEL sel = sel_registerName("getContactByName:");
    if (mgr == nil || ![mgr respondsToSelector:sel]) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(mgr, sel, name);
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *WeChatIngestSenderFromWrap(id wrap) {
    for (NSString *key in @[@"m_nsRealChatUsr", @"m_nsAtUserList"]) {
        id value = WeChatIngestKVC(wrap, key);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0 &&
            ![(NSString *)value hasSuffix:@"@chatroom"]) {
            return value;
        }
    }
    NSString *from = WeChatIngestKVC(wrap, @"m_nsFromUsr");
    if ([from isKindOfClass:[NSString class]] && ![from hasSuffix:@"@chatroom"]) {
        return from;
    }
    NSString *content = WeChatIngestKVC(wrap, @"m_nsContent") ?: @"";
    NSRange r = [content rangeOfString:@"fromusername=\""];
    if (r.location != NSNotFound) {
        NSString *rest = [content substringFromIndex:r.location + r.length];
        NSRange end = [rest rangeOfString:@"\""];
        if (end.location != NSNotFound) {
            return [rest substringToIndex:end.location];
        }
    }
    return from;
}

static NSData *WeChatIngestImageFromObject(id obj, NSString *tag, NSString **outDebug) {
    if (obj == nil) {
        return nil;
    }
    NSData *direct = WeChatIngestDataFromImage(obj);
    if (direct.length > 32) {
        if (outDebug) {
            *outDebug = [NSString stringWithFormat:@"vm-img:%@", tag];
        }
        return direct;
    }
    const char *getters[] = {
        "originImage", "hdImage", "thumbImage", "maskedThumbImage",
        "image", "getImage", "GetImg", "GetHDImg", "GetMidImg",
        "getThumbImage", "msgImage", NULL
    };
    for (const char **p = getters; *p; ++p) {
        SEL sel = sel_registerName(*p);
        if (![obj respondsToSelector:sel]) {
            continue;
        }
        @try {
            id img = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            NSData *data = WeChatIngestDataFromImage(img);
            if (data.length > 32) {
                if (outDebug) {
                    *outDebug = [NSString stringWithFormat:@"vm:%s", *p];
                }
                WeChatIngestDebugLog(@"[vm] %@ %s bytes=%lu", tag, *p, (unsigned long)data.length);
                return data;
            }
        } @catch (NSException *e) {
        }
    }
    return nil;
}

static id WeChatIngestMakeImageViewModel(id wrap) {
    if (wrap == nil) {
        return nil;
    }
    id cached = objc_getAssociatedObject(wrap, "wx.img.vm");
    if (cached) {
        return cached;
    }
    NSString *chat = WeChatIngestChatNameFromWrap(wrap);
    NSString *sender = WeChatIngestSenderFromWrap(wrap);
    id chatContact = WeChatIngestContactByName(chat);
    id senderContact = WeChatIngestContactByName(sender) ?: chatContact;
    WeChatIngestDebugLog(@"[vm] chat=%@ sender=%@ chatC=%@ sendC=%@",
                         chat, sender,
                         chatContact ? NSStringFromClass([chatContact class]) : @"(nil)",
                         senderContact ? NSStringFromClass([senderContact class]) : @"(nil)");
    NSArray *clsNames = @[
        @"ImageMessageViewModel", @"AppImageMessageViewModel",
        @"CommonMessageViewModel", @"BaseMessageViewModel"
    ];
    SEL create3 = sel_registerName("createMessageViewModelWithMessageWrap:contact:chatContact:");
    SEL create1 = sel_registerName("createViewModelWithMsgWrap:");
    SEL init3 = sel_registerName("initWithMessageWrap:contact:chatContact:");
    id vm = nil;
    for (NSString *name in clsNames) {
        Class cls = objc_getClass(name.UTF8String);
        if (cls == NULL) {
            continue;
        }
        @try {
            if (class_getClassMethod(cls, create3)) {
                vm = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                    cls, create3, wrap, senderContact, chatContact);
            }
            if (vm == nil && class_getClassMethod(cls, create1)) {
                vm = ((id (*)(id, SEL, id))objc_msgSend)(cls, create1, wrap);
            }
            if (vm == nil && class_getInstanceMethod(cls, init3)) {
                id alloced = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(alloc));
                vm = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                    alloced, init3, wrap, senderContact, chatContact);
            }
        } @catch (NSException *e) {
            WeChatIngestDebugLog(@"[vm] %@ create %@", name, e.reason);
            vm = nil;
        }
        if (vm) {
            WeChatIngestDebugLog(@"[vm] created %@ as %@", name, NSStringFromClass([vm class]));
            break;
        }
        WeChatIngestDebugLog(@"[vm] %@ create=nil c3=%d c1=%d i3=%d",
                             name,
                             class_getClassMethod(cls, create3) != NULL,
                             class_getClassMethod(cls, create1) != NULL,
                             class_getInstanceMethod(cls, init3) != NULL);
    }
    if (vm) {
        objc_setAssociatedObject(wrap, "wx.img.vm", vm, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return vm;
}

static void WeChatIngestForceViewModelDownload(id vm) {
    if (vm == nil) {
        return;
    }
    NSMutableArray *hits = [NSMutableArray array];
    const char *voidSels[] = {
        "downloadImage", "downloadHDImage", "DownloadImage", "DownloadHDImage",
        "startDownloadImage", "StartDownloadImage", "loadImage", "LoadImage",
        "updateThumbImage", "onAppear", NULL
    };
    for (const char **p = voidSels; *p; ++p) {
        SEL sel = sel_registerName(*p);
        if (![vm respondsToSelector:sel]) {
            continue;
        }
        @try {
            ((void (*)(id, SEL))objc_msgSend)(vm, sel);
            [hits addObject:@(*p)];
        } @catch (NSException *e) {
        }
    }
    SEL one = sel_registerName("StartDownloadImage:");
    if ([vm respondsToSelector:one]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(vm, one, vm);
            [hits addObject:@"StartDownloadImage:"];
        } @catch (NSException *e) {
        }
    }
    SEL hd = sel_registerName("StartDownloadImage:HD:");
    if ([vm respondsToSelector:hd]) {
        @try {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(vm, hd, vm, YES);
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(vm, hd, vm, NO);
            [hits addObject:@"StartDownloadImage:HD:"];
        } @catch (NSException *e) {
        }
    }
    WeChatIngestDebugLog(@"[vm] download-hits=%@",
                         hits.count ? [hits componentsJoinedByString:@","] : @"(none)");
}

static NSData *WeChatIngestPKCCircleImage(id wrap, NSString **outDebug);

static NSData *WeChatIngestImageViaChatViewModel(id wrap, NSString **outDebug) {
    id vm = WeChatIngestMakeImageViewModel(wrap);
    if (vm == nil) {
        return nil;
    }
    WeChatIngestForceViewModelDownload(vm);
    NSData *data = WeChatIngestImageFromObject(vm, NSStringFromClass([vm class]), outDebug);
    if (data.length > 32) {
        return data;
    }
    return WeChatIngestPKCCircleImage(wrap, outDebug);
}

static NSString *WeChatIngestDescribePath(NSString *path) {
    if (path.length == 0) {
        return @"(nil)";
    }
    return [NSString stringWithFormat:@"%@ exists=%@ size=%llu",
            path,
            WeChatIngestFileOK(path) ? @"Y" : @"N",
            WeChatIngestFileSize(path)];
}

static NSString *WeChatIngestTryClassPath(NSString *clsName, const char *selName, id wrap, BOOL log) {
    Class cls = objc_getClass(clsName.UTF8String);
    SEL sel = sel_registerName(selName);
    BOOL hasCls = cls != NULL && class_getClassMethod(cls, sel) != NULL;
    BOOL hasInst = wrap != nil && [wrap respondsToSelector:sel];
    NSString *path = nil;
    if (hasCls) {
        path = WeChatIngestCallPath(cls, sel, wrap);
    }
    if (path.length == 0 && hasInst) {
        path = WeChatIngestCallPath(wrap, sel, wrap);
    }
    if (log) {
        WeChatIngestDebugLog(@"[pkc] %@ %s cls=%d inst=%d %@",
                             clsName, selName, hasCls ? 1 : 0, hasInst ? 1 : 0,
                             WeChatIngestDescribePath(path));
    }
    return path;
}

static NSString *WeChatIngestTryHDPath(NSString *clsName, id wrap, BOOL log) {
    Class cls = objc_getClass(clsName.UTF8String);
    SEL hd = sel_registerName("GetPathOfMesImg:HD:");
    if (cls == NULL || !class_getClassMethod(cls, hd)) {
        if (log) {
            WeChatIngestDebugLog(@"[pkc] %@ GetPathOfMesImg:HD: missing", clsName);
        }
        return nil;
    }
    NSString *path = nil;
    @try {
        id value = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(cls, hd, wrap, YES);
        if ([value isKindOfClass:[NSString class]]) {
            path = value;
        }
    } @catch (NSException *e) {
        if (log) {
            WeChatIngestDebugLog(@"[pkc] %@ GetPathOfMesImg:HD: %@", clsName, e.reason);
        }
    }
    if (log) {
        WeChatIngestDebugLog(@"[pkc] %@ GetPathOfMesImg:HD: %@",
                             clsName, WeChatIngestDescribePath(path));
    }
    return path;
}

/// PKC: [CMessageWrap getPathOfMsgImg:] — keep the official path even if
/// the file is not on disk yet, so download retries can poll it.
static NSString *WeChatIngestPKCOfficialImgPath(id wrap) {
    if (wrap == nil) {
        return nil;
    }
    NSString *cached = objc_getAssociatedObject(wrap, "wx.pkc.imgpath");
    if ([cached isKindOfClass:[NSString class]] && cached.length) {
        return cached;
    }
    BOOL log = objc_getAssociatedObject(wrap, "wx.pkc.imgpath.logged") == nil;
    if (log) {
        objc_setAssociatedObject(wrap, "wx.pkc.imgpath.logged", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *selfWxid = WeChatIngestSelfWxid();
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *path) {
        if (path.length == 0) {
            return;
        }
        NSString *resolved = WeChatIngestResolveMaybeRelative(path, selfWxid) ?: path;
        if (![cands containsObject:resolved]) {
            [cands addObject:resolved];
        }
        if (![cands containsObject:path]) {
            [cands addObject:path];
        }
    };
    add(WeChatIngestTryClassPath(@"CMessageWrap", "getPathOfMsgImg:", wrap, log));
    add(WeChatIngestTryClassPath(@"CUtility", "getPathOfMsgImg:", wrap, log));
    add(WeChatIngestTryClassPath(@"CMessageMgr", "getPathOfMsgImg:", wrap, log));
    add(WeChatIngestTryClassPath(@"MMImageUtil", "getPathOfMsgImg:", wrap, log));
    add(WeChatIngestTryHDPath(@"CMessageWrap", wrap, log));
    add(WeChatIngestTryHDPath(@"CUtility", wrap, log));
    add(WeChatIngestTryClassPath(@"CUtility", "GetPathOfMesHDImg:", wrap, log));
    add(WeChatIngestTryClassPath(@"CMessageWrap", "GetPathOfMesImg:", wrap, log));
    add(WeChatIngestTryClassPath(@"CUtility", "GetPathOfMesImg:", wrap, log));
    NSString *bestExist = nil;
    NSString *bestAny = cands.firstObject;
    for (NSString *path in cands) {
        if (!WeChatIngestFileOK(path)) {
            continue;
        }
        if (!WeChatIngestPathLooksThumb(path)) {
            bestExist = path;
            break;
        }
        if (bestExist == nil) {
            bestExist = path;
        }
    }
    NSString *chosen = bestExist.length ? bestExist : bestAny;
    if (chosen.length && !WeChatIngestFileOK(chosen)) {
        NSString *dir = chosen.stringByDeletingLastPathComponent;
        NSString *stem = chosen.lastPathComponent.stringByDeletingPathExtension;
        NSArray *alts = @[@"pic", @"pic_hd", @"pic_thum", @"jpg", @"jpeg", @"png", @"wxam", @"dat", @"heic"];
        NSMutableArray *hits = [NSMutableArray array];
        for (NSString *ext in alts) {
            NSString *alt = [dir stringByAppendingPathComponent:[stem stringByAppendingPathExtension:ext]];
            if (WeChatIngestFileOK(alt)) {
                [hits addObject:[NSString stringWithFormat:@"%@:%llu",
                                 alt.lastPathComponent, WeChatIngestFileSize(alt)]];
                if (bestExist.length == 0 || WeChatIngestPathLooksThumb(bestExist)) {
                    bestExist = alt;
                    chosen = alt;
                }
            }
        }
        NSArray *kids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
        NSMutableArray *named = [NSMutableArray array];
        for (NSString *name in kids) {
            if ([name containsString:stem] && named.count < 12) {
                [named addObject:name];
            }
        }
        WeChatIngestDebugLog(@"[pkc] siblings=%@ dir=%@ files=%lu named=%@",
                             hits.count ? [hits componentsJoinedByString:@","] : @"(none)",
                             dir.lastPathComponent,
                             (unsigned long)kids.count,
                             named.count ? [named componentsJoinedByString:@","] : @"(none)");
    }
    if (log) {
        WeChatIngestDebugLog(@"[pkc] official=%@ exists=%@ size=%llu cands=%lu",
                             chosen.length ? chosen : @"(nil)",
                             WeChatIngestFileOK(chosen) ? @"Y" : @"N",
                             WeChatIngestFileSize(chosen),
                             (unsigned long)cands.count);
    }
    if (chosen.length) {
        objc_setAssociatedObject(wrap, "wx.pkc.imgpath", chosen, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return chosen;
}

/// PKC fallback: CircleToSearchMgr getImageFromMessageWrap:withDefault:
static NSData *WeChatIngestPKCCircleImage(id wrap, NSString **outDebug) {
    SEL sel = sel_registerName("getImageFromMessageWrap:withDefault:");
    NSArray *names = @[@"CircleToSearchMgr", @"CMessageMgr", @"MMImageLoader"];
    for (NSString *name in names) {
        id svc = WeChatIngestFindService(name.UTF8String);
        if (svc == nil) {
            Class cls = objc_getClass(name.UTF8String);
            if (cls && class_getClassMethod(cls, sel)) {
                svc = cls;
            }
        }
        BOOL responds = svc != nil && [svc respondsToSelector:sel];
        WeChatIngestDebugLog(@"[pkc] %@ getImageFromMessageWrap svc=%@ responds=%d",
                             name,
                             svc ? NSStringFromClass(object_getClass(svc)) : @"(nil)",
                             responds);
        if (!responds) {
            continue;
        }
        id img = nil;
        @try {
            img = ((id (*)(id, SEL, id, id))objc_msgSend)(svc, sel, wrap, nil);
        } @catch (NSException *e) {
            WeChatIngestDebugLog(@"[pkc] %@ getImageFromMessageWrap %@", name, e.reason);
            continue;
        }
        NSData *data = WeChatIngestDataFromImage(img);
        WeChatIngestDebugLog(@"[pkc] %@ getImageFromMessageWrap img=%@ bytes=%lu",
                             name,
                             img ? NSStringFromClass([img class]) : @"(nil)",
                             (unsigned long)data.length);
        if (data.length > 32) {
            if (outDebug) {
                *outDebug = [NSString stringWithFormat:@"pkc:%@", name];
            }
            return data;
        }
    }
    return nil;
}

static void WeChatIngestDebugDumpIvars(id wrap, NSString *phase) {
    if (wrap == nil || objc_getAssociatedObject(wrap, "wx.ivar.dumped")) {
        return;
    }
    objc_setAssociatedObject(wrap, "wx.ivar.dumped", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(wrap), &count);
    NSInteger logged = 0;
    for (unsigned int i = 0; i < count && logged < 40; i++) {
        const char *raw = ivar_getName(ivars[i]);
        if (raw == NULL) {
            continue;
        }
        NSString *name = @(raw);
        NSString *low = name.lowercaseString;
        BOOL interesting =
            [low containsString:@"img"] || [low containsString:@"path"] ||
            [low containsString:@"url"] || [low containsString:@"cdn"] ||
            [low containsString:@"aes"] || [low containsString:@"thumb"] ||
            [low containsString:@"pic"] || [low containsString:@"file"] ||
            [low containsString:@"data"] || [low containsString:@"hd"];
        if (!interesting) {
            continue;
        }
        id value = WeChatIngestKVC(wrap, [name hasPrefix:@"_"] ? [name substringFromIndex:1] : name);
        if (value == nil) {
            value = object_getIvar(wrap, ivars[i]);
        }
        logged += 1;
        if (value == nil) {
            WeChatIngestDebugLog(@"[%@] ivar %@=(nil)", phase, name);
            continue;
        }
        if ([value isKindOfClass:[NSNumber class]]) {
            WeChatIngestDebugLog(@"[%@] ivar %@=%@", phase, name, value);
            continue;
        }
        if ([value isKindOfClass:[NSString class]]) {
            NSString *text = (NSString *)value;
            if (text.length > 160) {
                text = [[text substringToIndex:160] stringByAppendingString:@"…"];
            }
            WeChatIngestDebugLog(@"[%@] ivar %@=%@", phase, name, text);
        } else if ([value isKindOfClass:[NSData class]]) {
            WeChatIngestDebugLog(@"[%@] ivar %@=NSData %lu", phase, name, (unsigned long)[(NSData *)value length]);
        } else {
            WeChatIngestDebugLog(@"[%@] ivar %@=%@", phase, name, NSStringFromClass([value class]));
        }
    }
    free(ivars);
    WeChatIngestDebugLog(@"[%@] ivar-logged=%ld / %u", phase, (long)logged, count);
}

static void WeChatIngestDebugDumpWrap(id wrap, NSString *msgType, NSString *phase) {
    if (wrap == nil) {
        WeChatIngestDebugLog(@"[%@] wrap=nil type=%@", phase, msgType);
        return;
    }
    NSString *from = WeChatIngestKVC(wrap, @"m_nsFromUsr") ?: @"";
    NSString *to = WeChatIngestKVC(wrap, @"m_nsToUsr") ?: @"";
    WeChatIngestDebugLog(@"[%@] class=%@ type=%@ chat=%@ from=%@ to=%@ lid=%@ svr=%@",
                         phase,
                         NSStringFromClass([wrap class]),
                         msgType,
                         WeChatIngestChatNameFromWrap(wrap),
                         from,
                         to,
                         WeChatIngestKVC(wrap, @"m_uiMesLocalID"),
                         WeChatIngestKVC(wrap, @"m_n64MesSvrID") ?: WeChatIngestKVC(wrap, @"m_uiMesSvrID"));
    NSArray *keys = @[
        @"m_nsImgPath", @"m_nsHDImgPath", @"m_nsImgMidImgPath", @"m_nsThumbImgPath",
        @"m_nsImgDataPath", @"m_nsVideoPath", @"m_nsAudioPath", @"m_nsFilePath",
        @"m_nsLocalFileName", @"m_dtHDImg", @"m_dtImg", @"m_dtMidImg", @"m_dtThumb",
        @"m_dtVoice", @"m_dtVideo", @"m_nsContent"
    ];
    for (NSString *key in keys) {
        id value = WeChatIngestKVC(wrap, key);
        if (value == nil) {
            continue;
        }
        if ([value isKindOfClass:[NSString class]]) {
            NSString *path = (NSString *)value;
            BOOL ok = WeChatIngestFileOK(path);
            WeChatIngestDebugLog(@"[%@] kvc %@=%@ exists=%@ size=%llu",
                                 phase, key, path.lastPathComponent ?: path,
                                 ok ? @"Y" : @"N", WeChatIngestFileSize(path));
        } else if ([value isKindOfClass:[NSData class]]) {
            WeChatIngestDebugLog(@"[%@] kvc %@=NSData %lu",
                                 phase, key, (unsigned long)[(NSData *)value length]);
        } else {
            WeChatIngestDebugLog(@"[%@] kvc %@=%@", phase, key, NSStringFromClass([value class]));
        }
    }
    WeChatIngestDebugDumpIvars(wrap, phase);
}

static NSString *WeChatIngestCallPath(id target, SEL sel, id arg) {
    if (target == nil || ![target respondsToSelector:sel]) {
        return nil;
    }
    @try {
        id value = ((id (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
        if ([value isKindOfClass:[NSString class]]) {
            return value;
        }
        if ([value isKindOfClass:[NSURL class]]) {
            return [(NSURL *)value path];
        }
    } @catch (NSException *e) {
    }
    return nil;
}

static NSString *WeChatIngestScanRecentFiles(id wrap, NSString *msgType);
static NSString *WeChatIngestScanSandboxRecent(id wrap);

static NSString *WeChatIngestGuessDiskPath(id wrap, NSString *msgType) {
    if ([msgType isEqualToString:@"image"] || [msgType isEqualToString:@"emoji"]) {
        NSString *official = WeChatIngestPKCOfficialImgPath(wrap);
        if (WeChatIngestFileOK(official)) {
            WeChatIngestDebugLog(@"[pkc] use official %@", WeChatIngestDescribePath(official));
            return official;
        }
        if (official.length) {
            WeChatIngestDebugLog(@"[pkc] official pending %@", WeChatIngestDescribePath(official));
        }
    }
    NSString *selfWxid = WeChatIngestSelfWxid();
    NSArray<NSString *> *keys = @[
        @"m_nsImgPath", @"m_nsHDImgPath", @"m_nsImgMidImgPath", @"m_nsThumbImgPath",
        @"m_nsVideoPath", @"m_nsAudioPath", @"m_nsFilePath", @"m_nsLocalFileName",
        @"m_nsMsgAttachUrl", @"m_nsImgDataPath"
    ];
    NSString *best = nil;
    for (NSString *key in keys) {
        id value = WeChatIngestKVC(wrap, key);
        if (![value isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *resolved = WeChatIngestResolveMaybeRelative(value, selfWxid);
        best = WeChatIngestPreferPath(best, resolved);
    }

    const char *sels[] = {
        "GetImgPath", "GetImgPath:", "getPathOfMsgImg:", "getImgByMsg:",
        "GetHDImgPath", "GetThumbPath", "GetMidImgPath",
        "GetPathOfMesAudio:", "getPathOfMsgAudio:", "GetAudioPath", "getPathOfAudio:",
        "GetPathOfMesVideoWithMessageWrap:", "getPathOfMsgVideo:",
        "getPathOfVideoMsgImgThumb:", "GetVideoPath", "GetFilePath",
        NULL
    };
    Class wrapClass = object_getClass(wrap);
    for (const char **p = sels; *p; ++p) {
        SEL sel = sel_registerName(*p);
        NSString *path = WeChatIngestCallPath(wrap, sel, wrap);
        if (path.length == 0 && wrapClass && class_getClassMethod(wrapClass, sel)) {
            path = WeChatIngestCallPath(wrapClass, sel, wrap);
        }
        best = WeChatIngestPreferPath(best, WeChatIngestResolveMaybeRelative(path, selfWxid));
    }

    NSArray<NSString *> *utilNames = @[@"CUtility", @"CMessageWrap", @"CMessageMgr", @"MMImageUtil"];
    const char *usels[] = {
        "getPathOfMsgImg:", "getPathOfAudio:", "getPathOfVideoMsgImgThumb:",
        "GetPathOfMesImg:", "GetPathOfMesHDImg:", "GetPathOfMesImgThumb:",
        "GetPathOfMesMidImg:", "GetPathOfMesAudio:",
        "GetPathOfMesVideoWithMessageWrap:", "GetPathOfMesVideo:",
        "GetPathOfMesImgWithMessageWrap:", "getImgByMsg:",
        NULL
    };
    for (NSString *clsName in utilNames) {
        Class util = objc_getClass(clsName.UTF8String);
        if (util == NULL) {
            continue;
        }
        for (const char **p = usels; *p; ++p) {
            SEL sel = sel_registerName(*p);
            NSString *path = WeChatIngestCallPath(util, sel, wrap);
            best = WeChatIngestPreferPath(best, WeChatIngestResolveMaybeRelative(path, selfWxid));
        }
        SEL hd = sel_registerName("GetPathOfMesImg:HD:");
        if (class_getClassMethod(util, hd)) {
            @try {
                id hdPath = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(util, hd, wrap, YES);
                if ([hdPath isKindOfClass:[NSString class]]) {
                    best = WeChatIngestPreferPath(best, WeChatIngestResolveMaybeRelative(hdPath, selfWxid));
                }
            } @catch (NSException *e) {
            }
        }
    }

    NSString *chat = WeChatIngestChatNameFromWrap(wrap);
    id lid = WeChatIngestKVC(wrap, @"m_uiMesLocalID");
    if (chat.length && lid != nil) {
        SEL audioSel = sel_registerName("getAudioFileName:LocalID:");
        NSArray<NSString *> *audioHosts = @[@"CUtility", @"CMessageWrap", @"CMessageMgr"];
        for (NSString *clsName in audioHosts) {
            Class cls = objc_getClass(clsName.UTF8String);
            if (cls == NULL || !class_getClassMethod(cls, audioSel)) {
                continue;
            }
            @try {
                id path = ((id (*)(id, SEL, id, unsigned int))objc_msgSend)(
                    cls, audioSel, chat, [lid unsignedIntValue]);
                if ([path isKindOfClass:[NSString class]]) {
                    best = WeChatIngestPreferPath(best, WeChatIngestResolveMaybeRelative(path, selfWxid));
                }
            } @catch (NSException *e) {
            }
        }
        if ([wrap respondsToSelector:audioSel]) {
            @try {
                id path = ((id (*)(id, SEL, id, unsigned int))objc_msgSend)(
                    wrap, audioSel, chat, [lid unsignedIntValue]);
                if ([path isKindOfClass:[NSString class]]) {
                    best = WeChatIngestPreferPath(best, WeChatIngestResolveMaybeRelative(path, selfWxid));
                }
            } @catch (NSException *e) {
            }
        }
    }
    if (best.length == 0) {
        best = WeChatIngestConstructedPath(wrap, msgType);
    }
    if (best.length == 0) {
        best = WeChatIngestScanByID(wrap, msgType);
    }
    if (best.length == 0) {
        best = WeChatIngestScanRecentFiles(wrap, msgType);
    }
    if (best.length == 0 && [msgType isEqualToString:@"image"]) {
        NSString *official = WeChatIngestPKCOfficialImgPath(wrap);
        if (official.length == 0) {
            best = WeChatIngestScanSandboxRecent(wrap);
        } else {
            WeChatIngestDebugLog(@"[scan] skip sandbox, wait official %@",
                                 WeChatIngestDescribePath(official));
        }
    }
    return best;
}

static NSMutableDictionary<NSString *, NSString *> *WXClaimedMedia(void) {
    static NSMutableDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static NSString *WeChatIngestMsgKey(id wrap) {
    id lid = WeChatIngestKVC(wrap, @"m_uiMesLocalID");
    return [lid respondsToSelector:@selector(stringValue)] ? [lid stringValue] : [lid description];
}

static NSArray<NSString *> *WeChatIngestImageDirs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *dirs = [NSMutableArray array];
    NSMutableArray *roots = [WeChatIngestMediaRoots(WeChatIngestSelfWxid()) mutableCopy];
    if (roots == nil) {
        roots = [NSMutableArray array];
    }
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [roots addObject:home];
        [roots addObject:[home stringByAppendingPathComponent:@"Library/WechatPrivate"]];
    }
    NSArray *names = @[@"Img", @"Image", @"image", @"Pic", @"pic", @"wxam"];
    for (NSString *root in roots) {
        if (root.length == 0 || ![fm fileExistsAtPath:root]) {
            continue;
        }
        for (NSString *name in names) {
            NSString *dir = [root stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:dir] && ![dirs containsObject:dir]) {
                [dirs addObject:dir];
            }
        }
        NSArray *subs = [fm contentsOfDirectoryAtPath:root error:NULL];
        NSInteger n = 0;
        for (NSString *sub in subs) {
            if (++n > 40) {
                break;
            }
            NSString *mid = [root stringByAppendingPathComponent:sub];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:mid isDirectory:&isDir] || !isDir) {
                continue;
            }
            for (NSString *name in names) {
                NSString *dir = [mid stringByAppendingPathComponent:name];
                if ([fm fileExistsAtPath:dir] && ![dirs containsObject:dir]) {
                    [dirs addObject:dir];
                }
            }
        }
    }
    return dirs;
}

static NSString *WeChatIngestScanSandboxRecent(id wrap) {
    NSString *msgKey = WeChatIngestMsgKey(wrap) ?: @"";
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval ts = 0;
    id rawTs = WeChatIngestKVC(wrap, @"m_uiCreateTime");
    if ([rawTs respondsToSelector:@selector(doubleValue)]) {
        ts = [rawTs doubleValue];
    }
    if (ts < 1000000000) {
        ts = now;
    }
    NSArray *exts = @[@"pic", @"pic_hd", @"jpg", @"jpeg", @"png", @"gif", @"heic", @"wxam", @"dat"];
    NSArray *dirs = WeChatIngestImageDirs();
    NSMutableArray *dirNames = [NSMutableArray array];
    for (NSString *dir in dirs) {
        [dirNames addObject:dir.lastPathComponent];
    }
    WeChatIngestDebugLog(@"[scan] imgdirs=%lu %@", (unsigned long)dirs.count,
                         [dirNames componentsJoinedByString:@","]);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *best = nil;
    NSTimeInterval bestScore = 180.0;
    NSInteger seen = 0;
    NSInteger hits = 0;
    NSMutableDictionary *claimed = WXClaimedMedia();
    for (NSString *dir in dirs) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
        for (NSString *rel in en) {
            if (++seen > 25000) {
                break;
            }
            NSString *base = rel.lastPathComponent.lowercaseString;
            NSString *ext = base.pathExtension;
            BOOL okExt = [exts containsObject:ext] || [base containsString:@".pic"];
            if (!okExt) {
                continue;
            }
            hits += 1;
            NSString *full = [dir stringByAppendingPathComponent:rel];
            NSString *owner = claimed[full];
            if (owner.length && ![owner isEqualToString:msgKey]) {
                continue;
            }
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
            if (size < 512) {
                continue;
            }
            NSDate *mtime = attrs[NSFileModificationDate] ?: attrs[NSFileCreationDate];
            NSTimeInterval mt = mtime.timeIntervalSince1970;
            NSTimeInterval age = now - mt;
            NSTimeInterval delta = fabs(mt - ts);
            if (age > 300 && delta > 300) {
                continue;
            }
            NSTimeInterval score = MIN(age, delta);
            if (WeChatIngestPathLooksThumb(full)) {
                score += 40;
            }
            if (best == nil || score < bestScore ||
                (fabs(score - bestScore) < 3 && size > WeChatIngestFileSize(best))) {
                best = full;
                bestScore = score;
            }
        }
    }
    if (best.length && msgKey.length) {
        claimed[best] = msgKey;
    }
    WeChatIngestDebugLog(@"[scan] seen=%ld hits=%ld best=%@ score=%.1f size=%llu",
                         (long)seen, (long)hits,
                         best.lastPathComponent ?: @"(none)",
                         bestScore,
                         WeChatIngestFileSize(best));
    return best;
}

static NSString *WeChatIngestScanRecentFiles(id wrap, NSString *msgType) {
    NSArray *folders = WeChatIngestFolderNames(msgType);
    NSArray *exts = WeChatIngestExts(msgType);
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval ts = 0;
    id rawTs = WeChatIngestKVC(wrap, @"m_uiCreateTime");
    if ([rawTs respondsToSelector:@selector(doubleValue)]) {
        ts = [rawTs doubleValue];
    }
    if (ts < 1000000000) {
        ts = now;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *best = nil;
    NSTimeInterval bestScore = 180.0;
    for (NSString *root in WeChatIngestMediaRoots(WeChatIngestSelfWxid())) {
        for (NSString *folder in folders) {
            NSString *dir = [root stringByAppendingPathComponent:folder];
            if (![fm fileExistsAtPath:dir]) {
                continue;
            }
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
            NSInteger seen = 0;
            for (NSString *rel in en) {
                if (++seen > 6000) {
                    break;
                }
                NSString *base = rel.lastPathComponent.lowercaseString;
                NSString *ext = base.pathExtension;
                BOOL okExt = [exts containsObject:ext] || [base hasSuffix:@".pic"] || [base hasSuffix:@".aud"] || [base hasSuffix:@".silk"];
                if (!okExt) {
                    continue;
                }
                NSString *full = [dir stringByAppendingPathComponent:rel];
                NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
                unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
                if (size <= 16) {
                    continue;
                }
                NSDate *mtime = attrs[NSFileModificationDate] ?: attrs[NSFileCreationDate];
                NSTimeInterval mt = mtime.timeIntervalSince1970;
                NSTimeInterval age = now - mt;
                NSTimeInterval delta = fabs(mt - ts);
                if (age > 240 && delta > 240) {
                    continue;
                }
                NSTimeInterval score = MIN(age, delta);
                if (WeChatIngestPathLooksThumb(full)) {
                    score += 30;
                }
                if (best == nil || score < bestScore ||
                    (fabs(score - bestScore) < 2 && size > WeChatIngestFileSize(best))) {
                    best = full;
                    bestScore = score;
                }
            }
        }
    }
    return best;
}

#pragma mark - wrap NSData / UIImage

static NSData *WeChatIngestWrapBody(id wrap, NSString *msgType, NSString **outSuffix, NSString **outDebug) {
    NSArray *dataKeys = [msgType isEqualToString:@"voice"]
        ? @[@"m_dtVoice", @"m_dtVoiceData", @"m_oVoiceData"]
        : ([msgType isEqualToString:@"video"]
           ? @[@"m_dtVideo", @"m_dtVideoData"]
           : @[@"m_dtHDImg", @"m_dtImg", @"m_dtMidImg", @"m_dtThumb", @"m_dtImgData", @"m_dtHDImgData"]);
    for (NSString *key in dataKeys) {
        id v = WeChatIngestKVC(wrap, key);
        if ([v isKindOfClass:[NSData class]] && [(NSData *)v length] > 32) {
            if (outSuffix) {
                *outSuffix = WeChatIngestSuffixFromData(v, msgType);
            }
            if (outDebug) {
                *outDebug = [NSString stringWithFormat:@"kvc:%@", key];
            }
            return v;
        }
    }

    if ([msgType isEqualToString:@"image"] || [msgType isEqualToString:@"emoji"]) {
        NSString *official = WeChatIngestPKCOfficialImgPath(wrap);
        if (WeChatIngestFileOK(official)) {
            NSData *data = [NSData dataWithContentsOfFile:official];
            if (data.length > 16) {
                if (outSuffix) {
                    NSString *ext = official.pathExtension.lowercaseString;
                    *outSuffix = ext.length ? [@"." stringByAppendingString:ext]
                                            : WeChatIngestSuffixFromData(data, msgType);
                }
                if (outDebug) {
                    *outDebug = [NSString stringWithFormat:@"pkc-file:%@", official.lastPathComponent];
                }
                WeChatIngestDebugLog(@"[pkc] read official %@", WeChatIngestDescribePath(official));
                return data;
            }
        }
        NSData *circle = WeChatIngestPKCCircleImage(wrap, outDebug);
        if (circle.length > 32) {
            if (outSuffix) {
                *outSuffix = WeChatIngestSuffixFromData(circle, msgType);
            }
            return circle;
        }
        NSData *viaVM = WeChatIngestImageViaChatViewModel(wrap, outDebug);
        if (viaVM.length > 32) {
            if (outSuffix) {
                *outSuffix = WeChatIngestSuffixFromData(viaVM, msgType);
            }
            return viaVM;
        }
    }

    NSString *path = WeChatIngestGuessDiskPath(wrap, msgType);
    if (path.length) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length > 16) {
            if (outSuffix) {
                NSString *ext = path.pathExtension.lowercaseString;
                *outSuffix = ext.length ? [@"." stringByAppendingString:ext] : WeChatIngestSuffixFromData(data, msgType);
            }
            if (outDebug) {
                *outDebug = [NSString stringWithFormat:@"file:%@", path.lastPathComponent];
            }
            return data;
        }
    }

    SEL imgByMsg = sel_registerName("getImgByMsg:");
    NSMutableArray *imgByMsgTried = [NSMutableArray array];
    for (NSString *clsName in @[@"CUtility", @"CMessageMgr", @"MMImageUtil", @"CMessageWrap"]) {
        Class cls = objc_getClass(clsName.UTF8String);
        if (cls == NULL || !class_getClassMethod(cls, imgByMsg)) {
            continue;
        }
        @try {
            id img = ((id (*)(id, SEL, id))objc_msgSend)(cls, imgByMsg, wrap);
            NSData *imgData = WeChatIngestDataFromImage(img);
            [imgByMsgTried addObject:[NSString stringWithFormat:@"%@/%lu",
                                      clsName, (unsigned long)imgData.length]];
            if (imgData.length > 32) {
                if (outSuffix) {
                    *outSuffix = WeChatIngestSuffixFromData(imgData, msgType);
                }
                if (outDebug) {
                    *outDebug = [NSString stringWithFormat:@"getImgByMsg:%@", clsName];
                }
                return imgData;
            }
        } @catch (NSException *e) {
            [imgByMsgTried addObject:[NSString stringWithFormat:@"%@/err", clsName]];
        }
    }
    id msgMgr = WeChatIngestFindService("CMessageMgr");
    if (msgMgr && [msgMgr respondsToSelector:imgByMsg]) {
        @try {
            id img = ((id (*)(id, SEL, id))objc_msgSend)(msgMgr, imgByMsg, wrap);
            NSData *imgData = WeChatIngestDataFromImage(img);
            [imgByMsgTried addObject:[NSString stringWithFormat:@"mgr/%lu",
                                      (unsigned long)imgData.length]];
            if (imgData.length > 32) {
                if (outSuffix) {
                    *outSuffix = WeChatIngestSuffixFromData(imgData, msgType);
                }
                if (outDebug) {
                    *outDebug = @"getImgByMsg:CMessageMgr-inst";
                }
                return imgData;
            }
        } @catch (NSException *e) {
            [imgByMsgTried addObject:@"mgr/err"];
        }
    }
    if ([msgType isEqualToString:@"image"] || [msgType isEqualToString:@"emoji"]) {
        WeChatIngestDebugLog(@"[pkc] getImgByMsg tried=%@",
                             imgByMsgTried.count ? [imgByMsgTried componentsJoinedByString:@","] : @"(none)");
    }

    const char *getters[] = {"GetVoiceData", "GetImgData", "GetHDImgData", "GetMidImgData", NULL};
    for (const char **p = getters; *p; ++p) {
        SEL sel = sel_registerName(*p);
        if (![wrap respondsToSelector:sel]) {
            continue;
        }
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(wrap, sel);
            if ([v isKindOfClass:[NSData class]] && [(NSData *)v length] > 32) {
                if (outSuffix) {
                    *outSuffix = WeChatIngestSuffixFromData(v, msgType);
                }
                if (outDebug) {
                    *outDebug = [NSString stringWithFormat:@"sel:%s", *p];
                }
                return v;
            }
            if ([v isKindOfClass:[UIImage class]]) {
                NSData *img = WeChatIngestDataFromImage(v);
                if (img.length > 32) {
                    if (outSuffix) {
                        *outSuffix = WeChatIngestSuffixFromData(img, msgType);
                    }
                    if (outDebug) {
                        *outDebug = [NSString stringWithFormat:@"img:%s", *p];
                    }
                    return img;
                }
            }
        } @catch (NSException *e) {
        }
    }
    for (NSString *key in @[@"m_oImage", @"m_image", @"m_oHDImage", @"m_oThumbImage"]) {
        NSData *img = WeChatIngestDataFromImage(WeChatIngestKVC(wrap, key));
        if (img.length > 32) {
            if (outSuffix) {
                *outSuffix = WeChatIngestSuffixFromData(img, msgType);
            }
            if (outDebug) {
                *outDebug = [NSString stringWithFormat:@"ui:%@", key];
            }
            return img;
        }
    }
    if (outDebug) {
        *outDebug = path.length ? [NSString stringWithFormat:@"empty:%@", path.lastPathComponent] : @"miss";
    }
    return nil;
}

NSData *WeChatIngestExtractMediaData(id wrap, NSString *msgType, NSString **outSuffix, NSString **outDebug) {
    NSData *data = WeChatIngestWrapBody(wrap, msgType, outSuffix, outDebug);
    if (data.length == 0) {
        WeChatIngestDebugDumpWrap(wrap, msgType, @"extract-miss");
        NSString *official = ([msgType isEqualToString:@"image"] || [msgType isEqualToString:@"emoji"])
            ? WeChatIngestPKCOfficialImgPath(wrap) : nil;
        NSString *guess = WeChatIngestGuessDiskPath(wrap, msgType);
        WeChatIngestDebugLog(@"[extract-miss] official=%@ guess=%@ debug=%@ imgStatus=%@ home=%@",
                             WeChatIngestDescribePath(official),
                             guess.lastPathComponent ?: @"(none)",
                             outDebug && *outDebug ? *outDebug : @"miss",
                             WeChatIngestKVC(wrap, @"m_uiImgStatus"),
                             NSHomeDirectory());
    } else {
        WeChatIngestDebugLog(@"[extract-ok] type=%@ bytes=%lu via=%@",
                             msgType, (unsigned long)data.length,
                             outDebug && *outDebug ? *outDebug : @"");
    }
    return data;
}

#pragma mark - download request

void WeChatIngestRequestMediaDownload(id wrap, NSString *msgType) {
    if (wrap == nil) {
        WeChatIngestDebugLog(@"[dl] wrap=nil type=%@", msgType);
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            WeChatIngestRequestMediaDownload(wrap, msgType);
        });
        return;
    }
    WeChatIngestDebugLog(@"[dl] start type=%@ lid=%@ main=1",
                         msgType, WeChatIngestKVC(wrap, @"m_uiMesLocalID"));
    if ([msgType isEqualToString:@"image"] || [msgType isEqualToString:@"emoji"]) {
        id vm = WeChatIngestMakeImageViewModel(wrap);
        WeChatIngestForceViewModelDownload(vm);
    }
    NSMutableArray *found = [NSMutableArray array];
    NSArray<NSString *> *mgrNames = @[
        @"CMessageMgr", @"WCDownloadImageCdnMgr", @"CdnComMgr", @"CdnDownloadMgr", @"MMImageLoader",
        @"CDownloadVoiceMgr", @"CVoiceDownloadMgr", @"MMNewVoiceDownloadMgr",
        @"WCDownloadVideoCDNMgr", @"CdnDownloadVideoMgr", @"AppAttachDownloadMgr"
    ];
    for (NSString *name in mgrNames) {
        id mgr = WeChatIngestFindService(name.UTF8String);
        if (mgr == nil) {
            continue;
        }
        [found addObject:name];
        @try {
            if ([msgType isEqualToString:@"image"]) {
                NSMutableArray *hits = [NSMutableArray array];
                SEL longSel = @selector(StartDownloadImage:HD:AutoDownload:SaveAlbum:Silent:);
                WeChatIngestDebugLog(@"[dl] %@ StartDownloadImage:HD:AutoDownload:SaveAlbum:Silent: %d",
                                     name, [mgr respondsToSelector:longSel]);
                if ([mgr respondsToSelector:longSel]) {
                    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL))objc_msgSend)(
                        mgr, longSel, wrap, YES, YES, NO, YES);
                    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL))objc_msgSend)(
                        mgr, longSel, wrap, NO, YES, NO, NO);
                    [hits addObject:@"HD5"];
                }
                SEL behave = sel_registerName("StartDownloadImage:HD:AutoDownload:SaveAlbum:Silent:behavior:");
                WeChatIngestDebugLog(@"[dl] %@ StartDownloadImage:...behavior: %d",
                                     name, [mgr respondsToSelector:behave]);
                if ([mgr respondsToSelector:behave]) {
                    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, int))objc_msgSend)(
                        mgr, behave, wrap, YES, YES, NO, YES, 0);
                    [hits addObject:@"behavior"];
                }
                SEL typed = sel_registerName("StartDownloadImage:downloadType:needNotify:force:");
                WeChatIngestDebugLog(@"[dl] %@ StartDownloadImage:downloadType:needNotify:force: %d",
                                     name, [mgr respondsToSelector:typed]);
                if ([mgr respondsToSelector:typed]) {
                    ((void (*)(id, SEL, id, int, BOOL, BOOL))objc_msgSend)(
                        mgr, typed, wrap, 1, YES, YES);
                    ((void (*)(id, SEL, id, int, BOOL, BOOL))objc_msgSend)(
                        mgr, typed, wrap, 0, YES, YES);
                    [hits addObject:@"typed"];
                }
                SEL hdSel = sel_registerName("StartDownloadImage:HD:");
                if ([mgr respondsToSelector:hdSel]) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(mgr, hdSel, wrap, YES);
                    [hits addObject:@"HD"];
                }
                SEL oneSel = sel_registerName("StartDownloadImage:");
                if ([mgr respondsToSelector:oneSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(mgr, oneSel, wrap);
                    [hits addObject:@"one"];
                }
                const char *extraImg[] = {
                    "downloadImageWithMsgWrap:", "loadImageForMessage:",
                    "LoadImageForMessageWrap:", "getImageForMessageWrap:",
                    "StartDownloadImageByMsgWrap:", NULL
                };
                for (const char **p = extraImg; *p; ++p) {
                    SEL s = sel_registerName(*p);
                    if ([mgr respondsToSelector:s]) {
                        WeChatIngestDebugLog(@"[dl] hit %s on %@", *p, name);
                        ((void (*)(id, SEL, id))objc_msgSend)(mgr, s, wrap);
                        [hits addObject:@(*p)];
                    }
                }
                WeChatIngestDebugLog(@"[dl] %@ image-hits=%@",
                                     name, hits.count ? [hits componentsJoinedByString:@","] : @"(none)");
            } else if ([msgType isEqualToString:@"voice"]) {
                const char *voiceSels[] = {
                    "StartDownloadVoice:", "DownloadVoice:", "StartDownload:",
                    "StartDownloadByMsgWrap:", "downloadVoice:", NULL
                };
                for (const char **p = voiceSels; *p; ++p) {
                    SEL s = sel_registerName(*p);
                    if ([mgr respondsToSelector:s]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(mgr, s, wrap);
                    }
                }
                id chat = WeChatIngestKVC(wrap, @"m_nsFromUsr") ?: WeChatIngestKVC(wrap, @"m_nsToUsr");
                id lid = WeChatIngestKVC(wrap, @"m_uiMesLocalID");
                SEL named = sel_registerName("StartDownloadWithChatName:MsgLocalID:");
                if ([mgr respondsToSelector:named] && chat && lid) {
                    ((void (*)(id, SEL, id, unsigned int))objc_msgSend)(
                        mgr, named, chat, [lid unsignedIntValue]);
                }
            } else if ([msgType isEqualToString:@"video"]) {
                SEL s = sel_registerName("StartDownloadVideo:DownloadMode:");
                if ([mgr respondsToSelector:s]) {
                    ((void (*)(id, SEL, id, int))objc_msgSend)(mgr, s, wrap, 1);
                }
                SEL pri = sel_registerName("StartDownloadVideo:MsgWrap:Priority:");
                if ([mgr respondsToSelector:pri]) {
                    ((void (*)(id, SEL, id, id, int))objc_msgSend)(mgr, pri, wrap, wrap, 1);
                }
                SEL one = sel_registerName("StartDownloadVideo:");
                if ([mgr respondsToSelector:one]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(mgr, one, wrap);
                }
            } else if ([msgType isEqualToString:@"file"]) {
                const char *fileSels[] = {
                    "StartDownloadAppAttach:", "StartDownloadByMsgWrap:",
                    "StartDownloadAppData:", "DownloadAppAttach:", NULL
                };
                for (const char **p = fileSels; *p; ++p) {
                    SEL s = sel_registerName(*p);
                    if ([mgr respondsToSelector:s]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(mgr, s, wrap);
                    }
                }
            } else if ([msgType isEqualToString:@"emoji"]) {
                SEL fromData = sel_registerName("startDownloadEmoticonFromMsgData");
                if ([mgr respondsToSelector:fromData]) {
                    ((void (*)(id, SEL))objc_msgSend)(mgr, fromData);
                }
                SEL byMd5 = sel_registerName("startDownloadEmoticonWithEmoticonMd5:");
                NSString *md5 = WeChatIngestKVC(wrap, @"m_nsEmoticonMD5");
                if (md5.length == 0) {
                    NSString *xml = WeChatIngestKVC(wrap, @"m_nsContent") ?: @"";
                    NSRange r = [xml rangeOfString:@"md5=\""];
                    if (r.location != NSNotFound) {
                        NSString *rest = [xml substringFromIndex:r.location + r.length];
                        NSRange end = [rest rangeOfString:@"\""];
                        if (end.location != NSNotFound) {
                            md5 = [rest substringToIndex:end.location];
                        }
                    }
                }
                if ([mgr respondsToSelector:byMd5] && md5.length) {
                    ((void (*)(id, SEL, id))objc_msgSend)(mgr, byMd5, md5);
                }
            }
        } @catch (NSException *e) {
            WeChatIngestDebugLog(@"[dl] exception %@: %@", name, e.reason);
        }
    }
    WeChatIngestDebugLog(@"[dl] services=%@", found.count ? [found componentsJoinedByString:@","] : @"(none)");
}

#pragma mark - download / setter hooks

static WXIngestMediaReadyHandler gMediaReadyHandler = nil;

void WeChatIngestSetMediaReadyHandler(WXIngestMediaReadyHandler handler) {
    gMediaReadyHandler = [handler copy];
}

NSUInteger WeChatIngestInstallDownloadHooks(void) {
    // Do not swizzle CMessageWrap setters or guessed download-complete
    // selectors. Wrong type encodings here crash WeChat on launch.
    (void)gMediaReadyHandler;
    return 0;
}
