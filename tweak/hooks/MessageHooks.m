// WeChatIngest — tweak/hooks/MessageHooks.m (todo-10 deliverable).
//
// Swizzles the three PKC-proven CMessageMgr message selectors (runtime
// selector literals per contracts/pkc-selectors.json):
//   - AddMsg:MsgWrap:
//   - AsyncOnPreAddMsg:MsgWrap:
//   - HandleAppMsg:MsgWrap:
//
// Substrate-free: each hook is installed with class_addMethod (our
// replacement IMP under a prefixed selector) + method_exchangeImplementations
// (the swap), so nothing links CydiaSubstrate and no PKC class is hooked —
// the host class is WeChat's own CMessageMgr. Every replacement IMP forwards
// to the original IMP FIRST (via the swapped selector), then hands the
// CMessageWrap's five capture fields to WeChatIngestMapMessageWrap — the ObjC
// mirror of map_msg_wrap() in policy/test_msgwrap_map.py. A wrap missing
// m_uiMesLocalID is rejected (mapper returns nil, nothing is enqueued).
//
// WeChat headers are deliberately not imported: CMessageMgr / CMessageWrap
// are resolved at runtime (objc_getClass) and their fields are read via KVC
// (safe @try/@catch valueForKey:), so this compiles against Foundation only.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

#import "MessageHooks.h"
#import "SftpInboxClient.h"
#import "Contacts.h"
#import "MediaExtract.h"
#import "StatusSync.h"
#import "DebugLog.h"
#import "../Settings.h"

#import <ifaddrs.h>
#import <net/if.h>

#pragma mark - forward helpers (original IMP first)

/// objc_msgSend trampolines for the swapped selectors. After the exchange the
/// original IMP lives under the prefixed selector; calling it here is the
/// "forward original first" step every hook MUST perform before capturing.
static void WeChatIngestForwardVoid(id self, SEL selector, id a, id b) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(self, selector, a, b);
}

static BOOL WeChatIngestForwardBOOL(id self, SEL selector, id a, id b) {
    return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(self, selector, a, b);
}

#pragma mark - safe KVC field read

/// One CMessageWrap field via KVC; nil when the field is absent or the key is
/// not KVC-compliant on this WeChat build (never crashes WeChat).
static id WeChatIngestWrapFieldValue(id wrap, NSString *key) {
    if (wrap == nil) {
        return nil;
    }
    @try {
        id value = [wrap valueForKey:key];
        if (value == nil || value == [NSNull null]) {
            return nil;
        }
        return value;
    } @catch (NSException *exception) {
        return nil;
    }
}

#pragma mark - type mapping (mirror of policy/test_msgwrap_map.py)

/// Numeric map for the common WeChat message types. Type 49 is the appmsg
/// family (red packet / url card) and maps to the ingest vocabulary's
/// "redpacket" bucket. Types 10000/10002 are sysmsg (revoke / announcement)
/// and are classified from the content in WeChatIngestMapType.
static NSDictionary *WeChatIngestNumericTypeMap(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @1: @"text",
            @3: @"image",
            @34: @"voice",
            @43: @"video",
            @44: @"video",
            @62: @"video",
            @47: @"emoji",
            @49: @"redpacket",
        };
    });
    return map;
}

/// 1=text, 3=image, 34=voice, 43=video, 49=redpacket/appmsg,
/// 10000/10002=revoke (announcement sysmsg → "announcement"), else "raw".
static NSString *WeChatIngestMapType(NSNumber *rawType, NSString *content) {
    if (rawType == nil) {
        return @"raw";
    }
    NSInteger typeValue = [rawType integerValue];
    if (typeValue == 10000 || typeValue == 10002) {
        NSString *lowered = [(content ?: @"") lowercaseString];
        if ([lowered containsString:@"revokemsg"] || [lowered containsString:@"撤回"]) {
            return @"revoke";
        }
        if ([lowered containsString:@"announcement"] ||
            [content containsString:@"群公告"] ||
            [content containsString:@"修改群公告"]) {
            return @"announcement";
        }
        return typeValue == 10000 ? @"announcement" : @"revoke";
    }
    if (typeValue == 49) {
        NSString *lowered = [(content ?: @"") lowercaseString];
        if ([lowered containsString:@"<type>2001</type>"] ||
            [lowered containsString:@"hongbao"] ||
            [lowered containsString:@"wxpay"] ||
            [content containsString:@"红包"]) {
            return @"redpacket";
        }
        if ([lowered containsString:@"<type>6</type>"] ||
            [lowered containsString:@"<appattach"] ||
            [lowered containsString:@"<fileext>"]) {
            return @"file";
        }
        if ([lowered containsString:@"<type>4</type>"] ||
            [lowered containsString:@"<videomsg"]) {
            return @"video";
        }
        return @"raw";
    }
    NSString *mapped = WeChatIngestNumericTypeMap()[rawType];
    return mapped ?: @"raw";
}

/// Text payload: raw content for text/revoke/announcement/raw, a
/// media placeholder for image/voice/video/redpacket (schema convention:
/// "Message text, or placeholder like '[voice]'/'[image]' for media").
static NSString *WeChatIngestTextForType(NSString *msgType, NSString *content) {
    if ([msgType isEqualToString:@"text"]) {
        return content;
    }
    if ([msgType isEqualToString:@"image"] ||
        [msgType isEqualToString:@"voice"] ||
        [msgType isEqualToString:@"video"] ||
        [msgType isEqualToString:@"emoji"] ||
        [msgType isEqualToString:@"file"] ||
        [msgType isEqualToString:@"redpacket"]) {
        return [NSString stringWithFormat:@"[%@]", msgType];
    }
    return content;
}

static NSString *WeChatIngestXMLTag(NSString *xml, NSString *tag) {
    if (xml.length == 0 || tag.length == 0) {
        return @"";
    }
    NSString *open = [NSString stringWithFormat:@"<%@>", tag];
    NSRange start = [xml rangeOfString:open options:NSCaseInsensitiveSearch];
    if (start.location == NSNotFound) {
        return @"";
    }
    NSUInteger from = start.location + start.length;
    NSString *close = [NSString stringWithFormat:@"</%@>", tag];
    NSRange end = [xml rangeOfString:close options:NSCaseInsensitiveSearch
                             range:NSMakeRange(from, xml.length - from)];
    if (end.location == NSNotFound) {
        return @"";
    }
    return [[xml substringWithRange:NSMakeRange(from, end.location - from)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *WeChatIngestJSONString(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:0
                                                     error:NULL];
    if (data == nil) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

#pragma mark - pure mapper (mirror of map_msg_wrap in policy/test_msgwrap_map.py)

/// Maps one CMessageWrap field dict (m_uiMessageType, m_nsContent,
/// m_nsFromUsr, m_nsToUsr, m_uiMesLocalID, optional ts) to a
/// store/event.schema.json event dict. Returns nil — the event is REJECTED —
/// when m_uiMesLocalID is missing. Kept in lockstep with the Python fixture
/// so the ObjC capture path is contract-tested on the host machine.
static NSDictionary *WeChatIngestMapMessageWrap(NSDictionary *fields) {
    NSNumber *localID = fields[@"m_uiMesLocalID"];
    if (localID == nil || ![localID isKindOfClass:[NSNumber class]]) {
        return nil;  // missing m_uiMesLocalID → event rejected
    }

    NSNumber *rawType = fields[@"m_uiMessageType"];
    NSString *content = fields[@"m_nsContent"] ?: @"";
    NSString *fromUser = fields[@"m_nsFromUsr"] ?: @"";
    NSString *toUser = fields[@"m_nsToUsr"] ?: @"";
    NSNumber *ts = fields[@"ts"] ?: @0;

    NSString *msgType = WeChatIngestMapType(rawType, content);
    NSString *text = WeChatIngestTextForType(msgType, content);

    NSString *extra = nil;
    if ([msgType isEqualToString:@"raw"] && rawType != nil) {
        extra = WeChatIngestJSONString(@{ @"raw_type": rawType });
    }

    BOOL isGroup = [toUser hasSuffix:@"@chatroom"];
    return @{
        @"chat_id": toUser,
        @"chat_kind": isGroup ? @"group" : @"dm",
        @"msg_id": [localID stringValue],
        @"msg_type": msgType,
        @"sender": fromUser,
        @"ts": ts,
        @"text": text,
        @"media_path": [NSNull null],
        @"extra_json": (extra != nil) ? extra : [NSNull null],
    };
}

#pragma mark - wrap field extraction + ingest seam

/// The five capture fields plus the message timestamp when CMessageWrap
/// exposes it (best-effort; ts defaults to 0 in the mapper when absent).
static NSDictionary *WeChatIngestMessageWrapFields(id wrap) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithDictionary:@{
        @"m_uiMessageType": WeChatIngestWrapFieldValue(wrap, @"m_uiMessageType") ?: @0,
        @"m_nsContent": WeChatIngestWrapFieldValue(wrap, @"m_nsContent") ?: @"",
        @"m_nsFromUsr": WeChatIngestWrapFieldValue(wrap, @"m_nsFromUsr") ?: @"",
        @"m_nsToUsr": WeChatIngestWrapFieldValue(wrap, @"m_nsToUsr") ?: @"",
        @"m_uiMesLocalID": WeChatIngestWrapFieldValue(wrap, @"m_uiMesLocalID"),
    }];
    NSNumber *createTime = WeChatIngestWrapFieldValue(wrap, @"m_uiCreateTime");
    if (createTime != nil) {
        fields[@"ts"] = createTime;
    }
    return fields;
}

/// Ingest seam (todo-11 rule, locked by policy/test_no_trigger_gate.py):
/// enqueueing requires ONLY the chat policy — whitelist + no-backfill
/// (decide_ingest in policy/ingest_policy.py). It never requires an
/// @-mention or the command prefix, so a whitelisted chat's message is
/// ingested silently even when nothing triggers a reply. Reply stays a
/// separate decision (todos 13/14). Todo-12: once the ingest pipeline lands,
/// this hands the event to it (SFTP put into wechat-ingest/inbox/). Until
/// then the mapped event is only logged so the swizzle→map→gate path is
/// observable in the WeChat process.
static NSString *WeChatIngestDisplayNameForUser(NSString *username) {
    if (username.length == 0) {
        return @"";
    }
    Class mgrClass = objc_getClass("CContactMgr");
    if (mgrClass == NULL) {
        return username;
    }
    id mgr = nil;
    SEL sharedSels[] = {
        @selector(sharedContext),
        sel_registerName("sharedInstance"),
        sel_registerName("sharedMgr"),
        sel_registerName("getInstance"),
    };
    for (size_t i = 0; i < sizeof(sharedSels) / sizeof(sharedSels[0]); i++) {
        if (class_getClassMethod(mgrClass, sharedSels[i])) {
            mgr = ((id (*)(id, SEL))objc_msgSend)(mgrClass, sharedSels[i]);
            if (mgr != nil) {
                break;
            }
        }
    }
    if (mgr == nil) {
        Class centerClass = objc_getClass("MMServiceCenter");
        if (centerClass && class_getClassMethod(centerClass, @selector(defaultCenter))) {
            id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, @selector(defaultCenter));
            if ([center respondsToSelector:@selector(getService:)]) {
                mgr = ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), mgrClass);
            }
        }
    }
    if (mgr == nil || ![mgr respondsToSelector:@selector(getContactByName:)]) {
        return username;
    }
    id contact = ((id (*)(id, SEL, id))objc_msgSend)(mgr, @selector(getContactByName:), username);
    if (contact == nil) {
        return username;
    }
    NSArray<NSString *> *keys = @[@"m_nsRemark", @"m_nsNickName", @"m_nsDisplayName", @"m_nsChatRoomName"];
    for (NSString *key in keys) {
        id value = WeChatIngestWrapFieldValue(contact, key);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }
    return username;
}

static NSString *WeChatIngestSelfWxid(void) {
    Class mgrClass = objc_getClass("CContactMgr");
    if (mgrClass == NULL) {
        return @"";
    }
    SEL sharedSels[] = {
        @selector(sharedContext),
        sel_registerName("sharedInstance"),
        sel_registerName("sharedMgr"),
        sel_registerName("getInstance"),
    };
    id mgr = nil;
    for (size_t i = 0; i < sizeof(sharedSels) / sizeof(sharedSels[0]); i++) {
        if (class_getClassMethod(mgrClass, sharedSels[i])) {
            mgr = ((id (*)(id, SEL))objc_msgSend)(mgrClass, sharedSels[i]);
            if (mgr != nil) {
                break;
            }
        }
    }
    if (mgr == nil) {
        return @"";
    }
    id contact = nil;
    if ([mgr respondsToSelector:@selector(getSelfContact)]) {
        contact = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(getSelfContact));
    }
    if (contact == nil) {
        return @"";
    }
    @try {
        NSString *name = [contact valueForKey:@"m_nsUsrName"];
        return [name isKindOfClass:[NSString class]] ? name : @"";
    } @catch (NSException *e) {
        return @"";
    }
}

static BOOL WeChatIngestOnWifi(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return NO;
    }
    BOOL wifi = NO;
    for (struct ifaddrs *addr = interfaces; addr != NULL; addr = addr->ifa_next) {
        if (addr->ifa_addr == NULL || addr->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if ((addr->ifa_flags & IFF_UP) && addr->ifa_name && strncmp(addr->ifa_name, "en0", 3) == 0) {
            wifi = YES;
            break;
        }
    }
    freeifaddrs(interfaces);
    return wifi;
}

static NSString *WeChatIngestMergeExtra(id existing, NSDictionary *add) {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    if ([existing isKindOfClass:[NSString class]] && [existing length] > 0) {
        id parsed = [NSJSONSerialization JSONObjectWithData:[(NSString *)existing dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0
                                                      error:NULL];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            [payload addEntriesFromDictionary:parsed];
        }
    }
    if (add.count) {
        [payload addEntriesFromDictionary:add];
    }
    NSArray *keys = payload.allKeys;
    for (id key in keys) {
        if (payload[key] == [NSNull null]) {
            [payload removeObjectForKey:key];
        }
    }
    return payload.count ? WeChatIngestJSONString(payload) : nil;
}

static NSMutableDictionary *WeChatIngestPendingMedia(void) {
    static NSMutableDictionary *pending = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pending = [NSMutableDictionary dictionary];
    });
    return pending;
}

static NSString *WeChatIngestPendingKey(id wrap, NSDictionary *event) {
    NSString *chat = event[@"chat_id"] ?: @"";
    NSString *msg = event[@"msg_id"] ?: @"";
    if (msg.length == 0) {
        id lid = WeChatIngestWrapFieldValue(wrap, @"m_uiMesLocalID");
        msg = [lid respondsToSelector:@selector(stringValue)] ? [lid stringValue] : [lid description];
    }
    return [NSString stringWithFormat:@"%@|%@", chat, msg ?: @""];
}

static NSDictionary *WeChatIngestPolicyConfig(void) {
    return @{
        @"group_whitelist": [WXIngestSettings groupList] ?: [NSArray array],
        @"dm_whitelist": [WXIngestSettings dmList] ?: [NSArray array],
        @"group_exclude": [WXIngestSettings groupExclude] ?: [NSArray array],
        @"dm_exclude": [WXIngestSettings dmExclude] ?: [NSArray array],
        @"record_all_groups": @([WXIngestSettings recordAllGroups]),
        @"record_all_dms": @([WXIngestSettings recordAllDMs]),
        @"command_prefix": [WXIngestSettings commandPrefix] ?: @"/",
        @"enabled_at": @0,
    };
}

static BOOL WeChatIngestTextLooksLikeAtMe(NSString *text, NSString *selfWxid) {
    if (text.length == 0) {
        return NO;
    }
    if ([text containsString:@"@所有人"] || [text containsString:@"@all"]) {
        return YES;
    }
    if (selfWxid.length > 0 && [text containsString:selfWxid]) {
        return YES;
    }
    return NO;
}

static void WeChatIngestEnqueueEvent(NSDictionary *event) {
    NSLog(@"[WeChatIngest] mapped event: %@", event);
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueEvent:event
                                                               mediaData:nil
                                                             mediaSuffix:nil];
}

/// One captured CMessageWrap: map it; a wrap missing m_uiMesLocalID is
/// rejected (mapper returned nil) and nothing is enqueued. The original IMP
/// was already forwarded by the hook before this runs. Ingest gate: any
/// mapped event passes (no @/prefix requirement — todo-11); whitelist /
/// backfill enforcement mirrors decide_ingest in policy/ingest_policy.py
/// and lands with the settings wiring (todos 13/14).
static NSMutableSet<NSString *> *WeChatIngestSeenKeys(void) {
    static NSMutableSet<NSString *> *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seen = [NSMutableSet set];
    });
    return seen;
}

static BOOL WeChatIngestMarkSeen(NSString *chatId, NSString *msgId) {
    if (msgId.length == 0) {
        return NO;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@", chatId ?: @"", msgId];
    NSMutableSet *seen = WeChatIngestSeenKeys();
    @synchronized (seen) {
        if ([seen containsObject:key]) {
            return YES;
        }
        [seen addObject:key];
        if (seen.count > 500) {
            [seen removeAllObjects];
            [seen addObject:key];
        }
        return NO;
    }
}

static BOOL WeChatIngestShouldSkipChat(NSString *chatId) {
    if (chatId.length == 0) {
        return YES;
    }
    if ([chatId hasPrefix:@"gh_"] && ![WXIngestSettings collectOfficials]) {
        return YES;
    }
    static NSSet *blocked = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = [NSSet setWithArray:@[
            @"filehelper", @"fmessage", @"medianote", @"floatbottle",
            @"newsapp", @"notification_messages", @"masssendapp"
        ]];
    });
    return [blocked containsObject:chatId];
}

static void WeChatIngestEnqueueReady(NSMutableDictionary *storeEvent, NSData *mediaData, NSString *mediaSuffix) {
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueEvent:storeEvent
                                                               mediaData:mediaData
                                                             mediaSuffix:mediaSuffix];
    WeChatIngestNoteEvent(YES, mediaData.length > 0, nil);
}

static BOOL WeChatIngestUploadEnabled(NSString *msgType) {
    if ([msgType isEqualToString:@"image"] || [msgType isEqualToString:@"emoji"]) {
        return [WXIngestSettings uploadImage];
    }
    if ([msgType isEqualToString:@"voice"]) {
        return [WXIngestSettings uploadVoice];
    }
    if ([msgType isEqualToString:@"video"] || [msgType isEqualToString:@"file"]) {
        return [WXIngestSettings uploadVideo];
    }
    return YES;
}

static NSInteger WeChatIngestMaxBytes(NSString *msgType, BOOL historyMode) {
    if (historyMode) {
        return (NSInteger)(2LL * 1024 * 1024 * 1024);
    }
    if ([msgType isEqualToString:@"image"] || [msgType isEqualToString:@"emoji"]) {
        return [WXIngestSettings imageMaxMB] * 1024 * 1024;
    }
    if ([msgType isEqualToString:@"video"] || [msgType isEqualToString:@"file"]) {
        return [WXIngestSettings videoMaxMB] * 1024 * 1024;
    }
    return NSIntegerMax;
}

static void WeChatIngestFinishMedia(NSString *key, NSMutableDictionary *storeEvent, NSData *mediaData, NSString *suffix, NSString *reason) {
    NSMutableDictionary *pending = WeChatIngestPendingMedia();
    BOOL upgrade = NO;
    @synchronized (pending) {
        NSMutableDictionary *item = pending[key];
        if ([item[@"sent"] boolValue]) {
            if (mediaData.length == 0 || [item[@"has_media"] boolValue]) {
                return;
            }
            upgrade = YES;
        }
        if (item) {
            item[@"sent"] = @YES;
            if (mediaData.length > 0) {
                item[@"has_media"] = @YES;
            }
        } else {
            pending[key] = [@{
                @"sent": @YES,
                @"has_media": @(mediaData.length > 0),
            } mutableCopy];
        }
    }
    if (upgrade) {
        WeChatIngestDebugLog(@"media upgrade %@ bytes=%lu",
                             storeEvent[@"msg_type"] ?: @"",
                             (unsigned long)mediaData.length);
        storeEvent[@"extra_json"] = WeChatIngestMergeExtra(storeEvent[@"extra_json"], @{
            @"media_skip": [NSNull null],
            @"media_upgrade": @YES,
        });
    } else if (reason.length) {
        storeEvent[@"extra_json"] = WeChatIngestMergeExtra(storeEvent[@"extra_json"], @{@"media_skip": reason});
    }
    WeChatIngestEnqueueReady(storeEvent, mediaData, suffix);
}

static void WeChatIngestTryPendingMedia(NSString *key, NSInteger attempt);

static void WeChatIngestHandlePendingWrap(id wrap) {
    NSMutableDictionary *pending = WeChatIngestPendingMedia();
    NSArray *items = nil;
    @synchronized (pending) {
        items = [pending.allValues copy];
    }
    for (NSDictionary *item in items) {
        if ([item[@"sent"] boolValue] && [item[@"has_media"] boolValue]) {
            continue;
        }
        if (item[@"wrap"] == wrap) {
            WeChatIngestTryPendingMedia(item[@"key"], 0);
            return;
        }
        id lid = WeChatIngestWrapFieldValue(wrap, @"m_uiMesLocalID");
        NSString *msg = [lid respondsToSelector:@selector(stringValue)] ? [lid stringValue] : [lid description];
        if (msg.length && [item[@"msg_id"] isEqualToString:msg]) {
            WeChatIngestTryPendingMedia(item[@"key"], 0);
        }
    }
}

static void WeChatIngestTryPendingMedia(NSString *key, NSInteger attempt) {
    NSMutableDictionary *item = nil;
    @synchronized (WeChatIngestPendingMedia()) {
        item = WeChatIngestPendingMedia()[key];
    }
    if (item == nil) {
        return;
    }
    if ([item[@"sent"] boolValue] && [item[@"has_media"] boolValue]) {
        return;
    }
    id wrap = item[@"wrap"];
    id fresh = WeChatIngestRefreshWrap(wrap);
    if (fresh != nil && fresh != wrap) {
        wrap = fresh;
        @synchronized (WeChatIngestPendingMedia()) {
            WeChatIngestPendingMedia()[key][@"wrap"] = wrap;
        }
    }
    NSString *msgType = item[@"msg_type"] ?: @"";
    NSMutableDictionary *storeEvent = [item[@"event"] mutableCopy];
    WeChatIngestDebugLog(@"[try] n=%ld type=%@ lid=%@ chat=%@",
                         (long)attempt, msgType,
                         item[@"msg_id"] ?: @"",
                         storeEvent[@"chat_name"] ?: storeEvent[@"chat_id"] ?: @"");
    NSString *suffix = nil;
    NSString *debug = nil;
    NSData *mediaData = WeChatIngestExtractMediaData(wrap, msgType, &suffix, &debug);
    BOOL historyMode = [item[@"history"] boolValue];
    NSInteger maxBytes = WeChatIngestMaxBytes(msgType, historyMode);
    if (mediaData.length > 0 && mediaData.length > maxBytes) {
        WeChatIngestFinishMedia(key, storeEvent, nil, nil,
                                [NSString stringWithFormat:@"%@ exceeds %ldMB", msgType, (long)(maxBytes / (1024 * 1024))]);
        return;
    }
    if (mediaData.length > 0) {
        WeChatIngestDebugLog(@"media ok %@ %@ bytes=%lu %@",
                             msgType, suffix ?: @"",
                             (unsigned long)mediaData.length, debug ?: @"");
        WeChatIngestFinishMedia(key, storeEvent, mediaData, suffix, nil);
        return;
    }
    NSInteger maxAttempts = historyMode ? 2 : 20;
    if (attempt >= maxAttempts) {
        WeChatIngestDebugLog(@"media miss %@ after retries (%@)", msgType, debug ?: @"miss");
        WeChatIngestFinishMedia(key, storeEvent, nil, nil,
                                [NSString stringWithFormat:@"media not found after download (%@)", debug ?: @"miss"]);
        return;
    }
    WeChatIngestRequestMediaDownload(wrap, msgType);
    NSTimeInterval delay = historyMode ? 0.35 : (0.8 + attempt * 1.1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        WeChatIngestTryPendingMedia(key, attempt + 1);
    });
}

static void WeChatIngestStartMedia(NSMutableDictionary *storeEvent, id wrap, NSString *msgType, BOOL historyMode) {
    NSString *key = WeChatIngestPendingKey(wrap, storeEvent);
    NSMutableDictionary *item = [@{
        @"key": key,
        @"event": storeEvent,
        @"wrap": wrap ?: [NSNull null],
        @"msg_type": msgType,
        @"msg_id": storeEvent[@"msg_id"] ?: @"",
        @"sent": @NO,
        @"history": @(historyMode),
    } mutableCopy];
    @synchronized (WeChatIngestPendingMedia()) {
        WeChatIngestPendingMedia()[key] = item;
    }
    WeChatIngestRequestMediaDownload(wrap, msgType);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        WeChatIngestTryPendingMedia(key, 0);
    });
}

static void WeChatIngestHandleMessageWrapImpl(id wrap, BOOL historyMode);

static void WeChatIngestHandleMessageWrap(id wrap) {
    @try {
        WeChatIngestHandleMessageWrapImpl(wrap, NO);
    } @catch (NSException *e) {
        NSLog(@"[WeChatIngest] handle wrap crashed: %@", e);
    }
}

void WeChatIngestCaptureHistoryWrap(id wrap) {
    @try {
        WeChatIngestHandleMessageWrapImpl(wrap, YES);
    } @catch (NSException *e) {
        NSLog(@"[WeChatIngest] history wrap crashed: %@", e);
    }
}

static void WeChatIngestHandleMessageWrapImpl(id wrap, BOOL historyMode) {
    if (!historyMode && ![WXIngestSettings isEnabled]) {
        return;
    }
    NSDictionary *fields = WeChatIngestMessageWrapFields(wrap);
    NSDictionary *mapped = WeChatIngestMapMessageWrap(fields);
    if (mapped == nil) {
        WeChatIngestDebugLog(@"drop wrap: no localID type=%@", fields[@"m_uiMessageType"]);
        return;
    }

    NSString *selfWxid = WeChatIngestSelfWxid();
    NSString *fromUser = fields[@"m_nsFromUsr"] ?: @"";
    NSString *toUser = fields[@"m_nsToUsr"] ?: @"";
    BOOL isGroup = [toUser hasSuffix:@"@chatroom"] || [fromUser hasSuffix:@"@chatroom"];
    NSString *chatId = WeChatIngestConversationId(wrap);
    if (chatId.length == 0) {
        WeChatIngestDebugLog(@"drop wrap: no chat from=%@ to=%@", fromUser, toUser);
        return;
    }

    if (WeChatIngestShouldSkipChat(chatId)) {
        WeChatIngestDebugLog(@"skip system chat %@", chatId);
        return;
    }
    NSString *msgId = [mapped[@"msg_id"] isKindOfClass:[NSString class]] ? mapped[@"msg_id"] : [mapped[@"msg_id"] description];
    if (!historyMode && WeChatIngestMarkSeen(chatId, msgId)) {
        return;
    }

    BOOL isSelf = selfWxid.length > 0 && [fromUser isEqualToString:selfWxid];
    NSString *text = mapped[@"text"] ?: @"";
    BOOL isAtMe = WeChatIngestTextLooksLikeAtMe(text, selfWxid);

    NSMutableDictionary *event = [mapped mutableCopy];
    event[@"chat_id"] = chatId ?: @"";
    event[@"chat_kind"] = isGroup ? @"group" : @"dm";
    event[@"is_self"] = @(isSelf);
    event[@"is_at_me"] = @(isAtMe);

    NSDictionary *config = WeChatIngestPolicyConfig();
    NSArray *groups = config[@"group_whitelist"];
    NSArray *dms = config[@"dm_whitelist"];
    NSArray *groupExclude = config[@"group_exclude"];
    NSArray *dmExclude = config[@"dm_exclude"];
    BOOL recordAllGroups = [config[@"record_all_groups"] boolValue];
    BOOL recordAllDMs = [config[@"record_all_dms"] boolValue];
    BOOL allowed = NO;
    if (isGroup) {
        if ([groupExclude containsObject:chatId]) {
            allowed = NO;
        } else {
            allowed = recordAllGroups || [groups containsObject:chatId];
        }
    } else {
        if ([dmExclude containsObject:chatId]) {
            allowed = NO;
        } else {
            allowed = recordAllDMs || [dms containsObject:chatId];
        }
    }
    if (!allowed && !historyMode) {
        WeChatIngestDebugLog(@"skip not-selected %@ %@ %@",
                             isGroup ? @"group" : @"dm", chatId, mapped[@"msg_type"]);
        return;
    }

    NSMutableDictionary *storeEvent = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"chat_id", @"chat_kind", @"msg_id", @"msg_type", @"sender", @"ts", @"text", @"media_path", @"extra_json", @"is_self"]) {
        id value = event[key];
        if (value != nil) {
            storeEvent[key] = value;
        }
    }
    NSString *chatName = [WXIngestContacts displayNameForUsername:chatId];
    if (chatName.length == 0) {
        chatName = WeChatIngestDisplayNameForUser(chatId);
    }
    if (chatName.length > 0) {
        storeEvent[@"chat_name"] = chatName;
    }
    id realSender = WeChatIngestWrapFieldValue(wrap, @"m_nsRealChatUsr");
    if (isSelf && selfWxid.length) {
        storeEvent[@"sender"] = selfWxid;
    } else if ([realSender isKindOfClass:[NSString class]] && [realSender length] > 0 &&
               ![(NSString *)realSender hasSuffix:@"@chatroom"]) {
        storeEvent[@"sender"] = realSender;
    } else if (isGroup && fromUser.length && ![fromUser hasSuffix:@"@chatroom"]) {
        storeEvent[@"sender"] = fromUser;
    }
    NSString *senderId = [storeEvent[@"sender"] isKindOfClass:[NSString class]] ? storeEvent[@"sender"] : @"";
    NSString *senderName = [WXIngestContacts displayNameForUsername:senderId];
    if (senderName.length == 0) {
        senderName = WeChatIngestDisplayNameForUser(senderId);
    }
    if (senderName.length > 0) {
        storeEvent[@"sender_name"] = senderName;
    }

    NSString *msgType = storeEvent[@"msg_type"] ?: @"";
    NSString *rawContent = fields[@"m_nsContent"] ?: @"";
    if ([msgType isEqualToString:@"emoji"] || [msgType isEqualToString:@"raw"] ||
        [msgType isEqualToString:@"file"]) {
        if (rawContent.length) {
            storeEvent[@"extra_json"] = WeChatIngestMergeExtra(storeEvent[@"extra_json"], @{@"xml": rawContent});
        }
    }
    NSString *lowered = rawContent.lowercaseString;
    BOOL isFile = [msgType isEqualToString:@"file"] ||
                  [lowered containsString:@"<type>6</type>"] ||
                  [lowered containsString:@"<appattach"] ||
                  [lowered containsString:@"<fileext>"];
    NSString *mediaKind = isFile ? @"file" : msgType;
    if (isFile) {
        storeEvent[@"msg_type"] = @"file";
        NSString *title = WeChatIngestXMLTag(rawContent, @"title");
        NSString *ext = WeChatIngestXMLTag(rawContent, @"fileext");
        NSMutableDictionary *meta = [NSMutableDictionary dictionary];
        if (title.length) {
            meta[@"filename"] = title;
            storeEvent[@"text"] = title;
        }
        if (ext.length) {
            meta[@"fileext"] = ext;
        }
        if (meta.count) {
            storeEvent[@"extra_json"] = WeChatIngestMergeExtra(storeEvent[@"extra_json"], meta);
        }
    }
    if (historyMode) {
        storeEvent[@"extra_json"] = WeChatIngestMergeExtra(storeEvent[@"extra_json"], @{@"full_export": @YES});
    }
    if ([mediaKind isEqualToString:@"emoji"]) {
        WeChatIngestDebugLog(@"capture emoji id=%@ chat=%@ xml-only",
                             storeEvent[@"msg_id"],
                             storeEvent[@"chat_name"] ?: chatId);
        WeChatIngestEnqueueReady(storeEvent, nil, nil);
        return;
    }
    BOOL mediaType = [mediaKind isEqualToString:@"image"] ||
                     [mediaKind isEqualToString:@"voice"] ||
                     [mediaKind isEqualToString:@"video"] ||
                     [mediaKind isEqualToString:@"file"];
    if (mediaType) {
        if (!historyMode && !WeChatIngestUploadEnabled(mediaKind)) {
            WeChatIngestDebugLog(@"media skip upload-disabled %@", mediaKind);
            storeEvent[@"extra_json"] = WeChatIngestMergeExtra(storeEvent[@"extra_json"], @{@"media_skip": @"upload disabled"});
            WeChatIngestEnqueueReady(storeEvent, nil, nil);
            return;
        }
        BOOL videoOnlyWifi = !historyMode && [WXIngestSettings wifiOnlyMedia] &&
            ([mediaKind isEqualToString:@"video"] || [mediaKind isEqualToString:@"file"]);
        if (videoOnlyWifi && !WeChatIngestOnWifi()) {
            storeEvent[@"extra_json"] = WeChatIngestMergeExtra(storeEvent[@"extra_json"], @{@"media_skip": @"wifi_only_video"});
            WeChatIngestEnqueueReady(storeEvent, nil, nil);
            return;
        }
        WeChatIngestDebugLog(@"capture %@ id=%@ chat=%@ media=%@ history=%d",
                             storeEvent[@"msg_type"], storeEvent[@"msg_id"],
                             storeEvent[@"chat_name"] ?: chatId, mediaKind, historyMode);
        if (historyMode) {
            NSString *suffix = nil;
            NSString *debug = nil;
            NSData *mediaData = WeChatIngestExtractMediaData(wrap, mediaKind, &suffix, &debug);
            NSInteger maxBytes = WeChatIngestMaxBytes(mediaKind, YES);
            if (mediaData.length > 0 && mediaData.length > maxBytes) {
                storeEvent[@"extra_json"] = WeChatIngestMergeExtra(storeEvent[@"extra_json"], @{
                    @"media_skip": [NSString stringWithFormat:@"%@ exceeds %ldMB",
                                    mediaKind, (long)(maxBytes / (1024 * 1024))],
                });
                WeChatIngestEnqueueReady(storeEvent, nil, nil);
                return;
            }
            if (mediaData.length > 0) {
                WeChatIngestDebugLog(@"history media ok %@ %@ bytes=%lu %@",
                                     mediaKind, suffix ?: @"",
                                     (unsigned long)mediaData.length, debug ?: @"");
                WeChatIngestEnqueueReady(storeEvent, mediaData, suffix);
                return;
            }
            storeEvent[@"extra_json"] = WeChatIngestMergeExtra(storeEvent[@"extra_json"], @{
                @"media_skip": debug.length ? debug : @"local media missing",
            });
            WeChatIngestEnqueueReady(storeEvent, nil, nil);
            return;
        }
        WeChatIngestStartMedia(storeEvent, wrap, mediaKind, historyMode);
        return;
    }

    WeChatIngestDebugLog(@"capture %@ id=%@ chat=%@",
                         storeEvent[@"msg_type"], storeEvent[@"msg_id"],
                         storeEvent[@"chat_name"] ?: chatId);
    WeChatIngestEnqueueReady(storeEvent, nil, nil);
}

#pragma mark - hook IMPs (forward original FIRST, then capture)

static void WeChatIngestAddMsgHook(id self, SEL _cmd, id msg, id wrap) {
    (void)_cmd;
    WeChatIngestForwardVoid(self, sel_registerName("ing_AddMsg:MsgWrap:"), msg, wrap);
    WeChatIngestHandleMessageWrap(wrap);
}

static void WeChatIngestAsyncOnPreAddMsgHook(id self, SEL _cmd, id msg, id wrap) {
    (void)_cmd;
    WeChatIngestForwardVoid(self, sel_registerName("ing_AsyncOnPreAddMsg:MsgWrap:"), msg, wrap);
    WeChatIngestHandleMessageWrap(wrap);
}

static BOOL WeChatIngestHandleAppMsgHook(id self, SEL _cmd, id msg, id wrap) {
    (void)_cmd;
    BOOL result = WeChatIngestForwardBOOL(
        self, sel_registerName("ing_HandleAppMsg:MsgWrap:"), msg, wrap);
    WeChatIngestHandleMessageWrap(wrap);
    return result;
}

static void WeChatIngestForwardRevoke(id self, SEL selector, id a, id b, unsigned int c) {
    ((void (*)(id, SEL, id, id, unsigned int))objc_msgSend)(self, selector, a, b, c);
}

static void WeChatIngestRevokeMsgHook(id self, SEL _cmd, id msg, id wrap, unsigned int counter) {
    (void)_cmd;
    WeChatIngestForwardRevoke(self, sel_registerName("ing_RevokeMsg:MsgWrap:Counter:"), msg, wrap, counter);
    WeChatIngestHandleMessageWrap(wrap);
}

#pragma mark - install

/// Installs one hook: add our replacement IMP under the prefixed selector on
/// the host class, then method_exchangeImplementations swaps the two IMPs so
/// the original runs when WeChat sends the original selector and our hook runs
/// when we forward to the prefixed selector. Never double-installs.
static BOOL WeChatIngestInstallMessageHook(Class host,
                                           SEL originalSelector,
                                           SEL replacementSelector,
                                           IMP replacementIMP) {
    Method originalMethod = class_getInstanceMethod(host, originalSelector);
    if (originalMethod == NULL) {
        NSLog(@"[WeChatIngest] selector %s not found on %s — hook skipped",
              sel_getName(originalSelector), class_getName(host));
        return NO;
    }
    const char *types = method_getTypeEncoding(originalMethod);
    if (!class_addMethod(host, replacementSelector, replacementIMP, types)) {
        NSLog(@"[WeChatIngest] %s already installed — skipping",
              sel_getName(replacementSelector));
        return NO;
    }
    Method replacementMethod = class_getInstanceMethod(host, replacementSelector);
    method_exchangeImplementations(originalMethod, replacementMethod);
    return YES;
}

NSUInteger WeChatIngestInstallMessageHooks(void) {
    Class messageMgr = objc_getClass("CMessageMgr");
    if (messageMgr == NULL) {
        NSLog(@"[WeChatIngest] CMessageMgr class not found — hooks not installed");
        return 0;
    }

    NSUInteger installed = 0;
    installed += WeChatIngestInstallMessageHook(
        messageMgr,
        @selector(AddMsg:MsgWrap:),
        sel_registerName("ing_AddMsg:MsgWrap:"),
        (IMP)WeChatIngestAddMsgHook) ? 1 : 0;
    installed += WeChatIngestInstallMessageHook(
        messageMgr,
        @selector(AsyncOnPreAddMsg:MsgWrap:),
        sel_registerName("ing_AsyncOnPreAddMsg:MsgWrap:"),
        (IMP)WeChatIngestAsyncOnPreAddMsgHook) ? 1 : 0;
    installed += WeChatIngestInstallMessageHook(
        messageMgr,
        @selector(HandleAppMsg:MsgWrap:),
        sel_registerName("ing_HandleAppMsg:MsgWrap:"),
        (IMP)WeChatIngestHandleAppMsgHook) ? 1 : 0;
    NSLog(@"[WeChatIngest] installed %lu CMessageMgr message hooks",
          (unsigned long)installed);
    return installed;
}
