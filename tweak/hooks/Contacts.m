#import "Contacts.h"
#import "SftpInboxClient.h"

#import <objc/message.h>
#import <objc/runtime.h>

@implementation WXIngestContact
@end

static id WXIngestMsgSend0(id obj, SEL sel) {
    if (obj == nil || ![obj respondsToSelector:sel]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static id WXIngestMsgSend1(id obj, SEL sel, id arg) {
    if (obj == nil || ![obj respondsToSelector:sel]) {
        return nil;
    }
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
}

static id WXIngestGetService(const char *className) {
    Class svcClass = objc_getClass(className);
    if (svcClass == NULL) {
        return nil;
    }
    Class centerClass = objc_getClass("MMServiceCenter");
    id center = nil;
    if (centerClass && class_getClassMethod(centerClass, @selector(defaultCenter))) {
        center = ((id (*)(id, SEL))objc_msgSend)(centerClass, @selector(defaultCenter));
    }
    if (center == nil) {
        Class ctxClass = objc_getClass("MMContext");
        if (ctxClass && class_getClassMethod(ctxClass, @selector(currentContext))) {
            center = ((id (*)(id, SEL))objc_msgSend)(ctxClass, @selector(currentContext));
        }
    }
    if (center == nil) {
        return nil;
    }
    if ([center respondsToSelector:@selector(getService:)]) {
        return ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), svcClass);
    }
    return nil;
}

static NSString *WXIngestStringValue(id obj, NSArray<NSString *> *keys) {
    if (obj == nil) {
        return nil;
    }
    for (NSString *key in keys) {
        @try {
            id value = [obj valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        } @catch (NSException *e) {
        }
    }
    return nil;
}

static BOOL WXIngestIsSystemUser(NSString *username) {
    if (username.length == 0) {
        return YES;
    }
    static NSSet *blocked = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = [NSSet setWithArray:@[
            @"filehelper", @"fmessage", @"medianote", @"floatbottle", @"masssendapp",
            @"newsapp", @"notification_messages", @"blogapp", @"voiceinputapp",
            @"mphelper", @"tmessage", @"qmessage", @"qqmail", @"facebookapp",
            @"weixin", @"shakeapp", @"linkedinplugin", @"lbsapp", @"iwatchholder",
            @"feedsapp", @"opencustomerservicemsg", @"brandsessionholder",
            @"brandsessionholder_weapp", @"fav_weapp_messages", @"chatroom_session_box",
            @"officialaccounts", @"gh_43f2581f6fd6"
        ]];
    });
    if ([blocked containsObject:username]) {
        return YES;
    }
    if ([username hasPrefix:@"gh_"] || [username hasPrefix:@"fake_"] ||
        [username containsString:@"@openim"] || [username hasSuffix:@"@im.chatroom"]) {
        return YES;
    }
    return NO;
}

static NSString *WXIngestDisplayName(id contact, NSString *username) {
    NSString *name = WXIngestStringValue(contact, @[
        @"m_nsRemark", @"m_nsNickName", @"m_nsDisplayName",
        @"m_nsChatRoomName", @"m_nsAliasName"
    ]);
    return name.length > 0 ? name : username;
}

static NSArray<NSString *> *WXIngestAllUsernames(id mgr) {
    NSArray *names = WXIngestMsgSend0(mgr, @selector(getAllContactUserName));
    if (![names isKindOfClass:[NSArray class]] || names.count == 0) {
        names = WXIngestMsgSend0(mgr, @selector(getAllContactUserNameFromCache));
    }
    if ([names isKindOfClass:[NSArray class]] && names.count > 0) {
        return names;
    }

    const char *listSels[] = {
        "getContactList:contactType:",
        "getContactListFromContactDB:",
        NULL
    };
    (void)listSels;
    if ([mgr respondsToSelector:sel_registerName("getContactList:contactType:")]) {
        NSArray *list = ((id (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(
            mgr, sel_registerName("getContactList:contactType:"), 1, 0xffffffff);
        if ([list isKindOfClass:[NSArray class]]) {
            NSMutableArray *out = [NSMutableArray array];
            for (id c in list) {
                NSString *u = WXIngestStringValue(c, @[@"m_nsUsrName", @"userName"]);
                if (u.length) {
                    [out addObject:u];
                }
            }
            return out;
        }
    }
    return [NSArray array];
}

static NSArray<WXIngestContact *> *WXIngestCollect(BOOL wantGroup) {
    id mgr = WXIngestGetService("CContactMgr");
    NSMutableDictionary<NSString *, WXIngestContact *> *map = [NSMutableDictionary dictionary];

    void (^addUsername)(NSString *) = ^(NSString *username) {
        if (![username isKindOfClass:[NSString class]] || WXIngestIsSystemUser(username)) {
            return;
        }
        BOOL isGroup = [username hasSuffix:@"@chatroom"];
        if (isGroup != wantGroup) {
            return;
        }
        if (map[username] != nil) {
            return;
        }
        id contact = WXIngestMsgSend1(mgr, @selector(getContactByName:), username);
        WXIngestContact *item = [WXIngestContact new];
        item.username = username;
        item.displayName = WXIngestDisplayName(contact, username);
        item.isGroup = isGroup;
        map[username] = item;
    };

    for (NSString *name in WXIngestAllUsernames(mgr)) {
        addUsername(name);
    }

    id sessionMgr = WXIngestGetService("MMNewSessionMgr");
    if (sessionMgr == nil) {
        sessionMgr = WXIngestGetService("MMSessionMgr");
    }
    if (sessionMgr) {
        NSInteger count = 0;
        if ([sessionMgr respondsToSelector:@selector(GetSessionCount)]) {
            count = ((NSInteger (*)(id, SEL))objc_msgSend)(sessionMgr, @selector(GetSessionCount));
        } else if ([sessionMgr respondsToSelector:sel_registerName("getSessionCount")]) {
            count = ((NSInteger (*)(id, SEL))objc_msgSend)(sessionMgr, sel_registerName("getSessionCount"));
        }
        SEL atSel = @selector(GetSessionAtIndex:);
        if (![sessionMgr respondsToSelector:atSel]) {
            atSel = sel_registerName("getSessionAtIndex:");
        }
        for (NSInteger i = 0; i < count && i < 2000; i++) {
            id session = ((id (*)(id, SEL, unsigned int))objc_msgSend)(sessionMgr, atSel, (unsigned int)i);
            NSString *username = WXIngestStringValue(session, @[
                @"m_nsUserName", @"m_nsUsrName", @"username", @"m_contact.m_nsUsrName"
            ]);
            if (username.length == 0) {
                id contact = nil;
                @try { contact = [session valueForKey:@"m_contact"]; } @catch (NSException *e) {}
                username = WXIngestStringValue(contact, @[@"m_nsUsrName", @"userName"]);
            }
            addUsername(username);
        }
    }

    NSArray<WXIngestContact *> *all = map.allValues;
    return [all sortedArrayUsingComparator:^NSComparisonResult(WXIngestContact *a, WXIngestContact *b) {
        return [a.displayName localizedStandardCompare:b.displayName];
    }];
}

@implementation WXIngestContacts

+ (NSArray<WXIngestContact *> *)groups {
    return WXIngestCollect(YES);
}

+ (NSArray<WXIngestContact *> *)people {
    return WXIngestCollect(NO);
}

static NSInteger WXIngestPositiveInt(id value) {
    if (value == nil || value == [NSNull null]) {
        return 0;
    }
    if ([value respondsToSelector:@selector(longLongValue)]) {
        long long n = [value longLongValue];
        if (n > 0 && n < 8000000) {
            return (NSInteger)n;
        }
    }
    return 0;
}

static NSInteger WXIngestHintFromObject(id obj) {
    if (obj == nil) {
        return 0;
    }
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            @"m_uLastMsgLocalId", @"m_uiLastMsgLocalId", @"m_uLastLocalId",
            @"m_uiLastLocalId", @"m_uMsgLocalID", @"m_uiMsgLocalID",
            @"m_uLastMsg", @"m_uiLastMsg", @"m_n64LastSvrId",
            @"m_uUnReadCount", @"m_uiUnReadCount", @"m_uUnReadCnt",
        ];
    });
    NSInteger best = 0;
    for (NSString *key in keys) {
        @try {
            NSInteger n = WXIngestPositiveInt([obj valueForKey:key]);
            if ([key.lowercaseString containsString:@"unread"]) {
                continue;
            }
            if (n > best) {
                best = n;
            }
        } @catch (NSException *e) {
        }
    }
    for (NSString *key in @[@"m_oLastMsg", @"m_lastMsg", @"m_oMsgWrap", @"m_msgWrap"]) {
        @try {
            id wrap = [obj valueForKey:key];
            if (wrap) {
                NSInteger n = WXIngestPositiveInt([wrap valueForKey:@"m_uiMesLocalID"]);
                if (n > best) {
                    best = n;
                }
            }
        } @catch (NSException *e) {
        }
    }
    return best;
}

+ (NSArray<WXIngestContact *> *)visibleSessions {
    id mgr = WXIngestGetService("CContactMgr");
    id sessionMgr = WXIngestGetService("MMNewSessionMgr");
    if (sessionMgr == nil) {
        sessionMgr = WXIngestGetService("MMSessionMgr");
    }
    NSMutableArray<WXIngestContact *> *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    if (sessionMgr == nil) {
        return out;
    }
    NSInteger count = 0;
    @try {
        if ([sessionMgr respondsToSelector:@selector(GetSessionCount)]) {
            count = ((NSInteger (*)(id, SEL))objc_msgSend)(sessionMgr, @selector(GetSessionCount));
        } else if ([sessionMgr respondsToSelector:sel_registerName("getSessionCount")]) {
            count = ((NSInteger (*)(id, SEL))objc_msgSend)(sessionMgr, sel_registerName("getSessionCount"));
        }
    } @catch (NSException *e) {
        count = 0;
    }
    if (count < 0) {
        count = 0;
    }
    if (count > 2000) {
        count = 2000;
    }
    SEL atSel = @selector(GetSessionAtIndex:);
    if (![sessionMgr respondsToSelector:atSel]) {
        atSel = sel_registerName("getSessionAtIndex:");
    }
    for (NSInteger i = 0; i < count; i++) {
        id session = nil;
        @try {
            session = ((id (*)(id, SEL, unsigned int))objc_msgSend)(sessionMgr, atSel, (unsigned int)i);
        } @catch (NSException *e) {
            session = nil;
        }
        if (session == nil) {
            continue;
        }
        NSString *username = WXIngestStringValue(session, @[
            @"m_nsUserName", @"m_nsUsrName", @"username", @"m_contact.m_nsUsrName"
        ]);
        if (username.length == 0) {
            id contact = nil;
            @try { contact = [session valueForKey:@"m_contact"]; } @catch (NSException *e) {}
            username = WXIngestStringValue(contact, @[@"m_nsUsrName", @"userName"]);
        }
        if (![username isKindOfClass:[NSString class]] || WXIngestIsSystemUser(username) ||
            [seen containsObject:username]) {
            continue;
        }
        [seen addObject:username];
        id contact = WXIngestMsgSend1(mgr, @selector(getContactByName:), username);
        WXIngestContact *item = [WXIngestContact new];
        item.username = username;
        item.displayName = WXIngestDisplayName(contact, username);
        item.isGroup = [username hasSuffix:@"@chatroom"];
        item.lastLocalId = WXIngestHintFromObject(session);
        item.msgHint = item.lastLocalId;
        [out addObject:item];
    }
    return out;
}

+ (NSArray<WXIngestContact *> *)contactsOfKind:(NSString *)kind {
    return [kind isEqualToString:@"dm"] ? [self people] : [self groups];
}

+ (NSString *)displayNameForUsername:(NSString *)username {
    if (username.length == 0) {
        return @"";
    }
    id mgr = WXIngestGetService("CContactMgr");
    id contact = WXIngestMsgSend1(mgr, @selector(getContactByName:), username);
    NSString *name = WXIngestDisplayName(contact, username);
    if (name.length > 0 && ![name isEqualToString:username]) {
        return name;
    }
    return name.length ? name : username;
}

+ (NSDictionary<NSString *, NSString *> *)nameMap {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    void (^put)(NSArray *) = ^(NSArray *list) {
        for (WXIngestContact *item in list) {
            if (item.username.length && item.displayName.length) {
                map[item.username] = item.displayName;
            }
        }
    };
    put([self groups]);
    put([self people]);
    // officials: temporarily collect gh_ by scanning usernames
    id mgr = WXIngestGetService("CContactMgr");
    for (NSString *name in WXIngestAllUsernames(mgr)) {
        if ([name hasPrefix:@"gh_"]) {
            map[name] = [self displayNameForUsername:name];
        }
    }
    return map;
}

+ (void)syncNamesToServer {
    NSDictionary *map = [self nameMap];
    if (map.count == 0) {
        NSLog(@"[WeChatIngest] name map empty — skip sync");
        return;
    }
    [[WeChatIngestSftpInboxClient sharedClientWithDefaults] enqueueNameMap:map];
    NSLog(@"[WeChatIngest] queued name map (%lu)", (unsigned long)map.count);
}

@end
