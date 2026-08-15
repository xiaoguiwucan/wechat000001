// WeChatIngest — tweak/hooks/OpenClawReply.m (todo-13 deliverable).
//
// Reply-pipe routing: the protocol-3 OpenClaw CHAT request is built ONLY when
// the policy says reply=True (whitelisted group message that @'s the bot or
// starts with the command prefix), with the todo-3 protocol-3 hello identity
// and session_key = the group chat id (per-chat sessions). Ingest-only
// messages return nil — no OpenClaw session is ever opened for them.
//
// The decision mirrors policy/ingest_policy.py decide() (rules 1–6) and the
// request shape mirrors policy/reply_routing.py openclaw_chat_request; keep
// the three in lockstep. No network here: this module only decides + builds
// the request. Delivery (todo-12 SSH local-forward 127.0.0.1:18790 → OpenClaw
// 18789) plugs into the seam below.

#import "OpenClawReply.h"

#pragma mark - config helpers (mirror of policy/ingest_policy.py decide())

static BOOL WeChatIngestStringHasPrefix(NSString *text, NSString *prefix) {
    if (text.length == 0 || prefix.length == 0) {
        return NO;
    }
    return [text hasPrefix:prefix];
}

static BOOL WeChatIngestConfigContainsID(NSArray<NSString *> * _Nullable list,
                                         NSString *chatID) {
    if (list == nil || chatID.length == 0) {
        return NO;
    }
    return [list containsObject:chatID];
}

/// The reply gate — exactly decide(event, config)["reply"] in
/// policy/ingest_policy.py: whitelisted under its own kind, group, not self,
/// and (@ or command prefix). No-backfill and fail-closed are respected first.
static BOOL WeChatIngestReplyDecision(NSDictionary *event, NSDictionary *config) {
    NSNumber *enabledAt = config[@"enabled_at"];
    NSNumber *ts = event[@"ts"];
    if (enabledAt != nil && ts != nil && [ts doubleValue] < [enabledAt doubleValue]) {
        return NO;  // no backfill of pre-enable history
    }

    NSArray<NSString *> *groups = config[@"group_whitelist"];
    NSArray<NSString *> *dms = config[@"dm_whitelist"];
    if ((groups == nil || groups.count == 0) && (dms == nil || dms.count == 0)) {
        return NO;  // fail closed: nothing whitelisted
    }

    NSString *kind = event[@"chat_kind"];
    NSString *chatID = event[@"chat_id"];
    BOOL allowed;
    if ([kind isEqualToString:@"group"]) {
        allowed = WeChatIngestConfigContainsID(groups, chatID);
    } else if ([kind isEqualToString:@"dm"]) {
        allowed = WeChatIngestConfigContainsID(dms, chatID);
    } else {
        allowed = NO;
    }
    if (!allowed) {
        return NO;  // chat not whitelisted under its own kind
    }

    // Reply is only ever True for a non-self GROUP message that @'s the bot
    // or starts with the command prefix. DMs and self-messages never reply.
    if (![kind isEqualToString:@"group"]) {
        return NO;
    }
    if ([event[@"is_self"] boolValue]) {
        return NO;
    }
    if ([event[@"is_at_me"] boolValue]) {
        return YES;
    }
    return WeChatIngestStringHasPrefix(event[@"text"], config[@"command_prefix"]);
}

#pragma mark - protocol-3 identity (contracts/protocol3_hello.json)

NSDictionary<NSString *, id> *WeChatIngestOpenClawHello(void) {
    return @{
        @"client": @"openclaw-control-ui",
        @"mode": @"webchat",
        @"version": @"1.0.0",
        @"userAgent": @"pkc-openclaw-client/1.0.0",
        @"role": @"operator",
        @"protocol": @3,  // protocol 4 is never produced
    };
}

#pragma mark - routing (mirror of policy/reply_routing.py)

BOOL WeChatIngestShouldOpenOpenClawSession(NSDictionary *event, NSDictionary *config) {
    return WeChatIngestReplyDecision(event, config);
}

NSDictionary *_Nullable WeChatIngestOpenClawChatRequest(NSDictionary *event,
                                                        NSDictionary *config) {
    if (!WeChatIngestReplyDecision(event, config)) {
        return nil;  // ingest-only message → no OpenClaw session
    }
    return @{
        @"hello": WeChatIngestOpenClawHello(),
        @"session_key": event[@"chat_id"] ?: @"",  // per-chat group session
        @"text": event[@"text"] ?: @"",
    };
}

void WeChatIngestEnqueueOpenClawRequest(NSDictionary *_Nullable request) {
    if (request == nil) {
        return;  // ingest-only — nothing is enqueued into the reply pipe
    }
    // Todo-12 transport seam: deliver `request` over the SSH local-forward to
    // 127.0.0.1:18790 → OpenClaw 18789 (oc_connectOpenClawWithURL:token:
    // sessionKey:completion: identity). Until then, log so the routing is
    // observable in the WeChat process.
    NSLog(@"[WeChatIngest] openclaw chat request: %@", request);
}
