// WeChatIngest — tweak/hooks/SendGate.m (todo-14 deliverable).
//
// The single reply-send gate: EVERY send path — sendMsg:toUser:,
// sendLocalMsg:toUser:, pkcReplyMessage: — consults
// WeChatIngestCanSendReply(chatKind, isSelf, policy) FIRST. When the gate is
// closed (a DM, the user's own message, or a policy that whitelists nothing),
// the wrapper returns NO and the send selector is never invoked. This is the
// final defense-in-depth layer at the SEND boundary; the @-mention /
// command-prefix trigger and the per-chat whitelist membership are enforced
// upstream by the reply decision (tweak/hooks/OpenClawReply.m
// WeChatIngestReplyDecision, mirror of policy/ingest_policy.py decide()).
//
// The gate mirrors canSendReply(chatKind, isSelf, policy) and the three
// wrappers mirror the send wrappers in policy/send_gate.py; keep them in
// lockstep.
//
// No WeChat headers are imported: the send selectors are only NAMED here as
// the seam for the todo-18 e2e transport and are never invoked by this file —
// a closed gate returns NO before any selector is reached.

#import "SendGate.h"

BOOL WeChatIngestCanSendReply(NSString *chatKind, BOOL isSelf, NSDictionary *policy) {
    if (isSelf) {
        return NO;  // never reply to the user's own message
    }
    if (![chatKind isEqualToString:@"group"]) {
        return NO;  // DM replies are hard-disabled ("不允许自动回复私人聊天")
    }
    NSArray *groups = policy[@"group_whitelist"];
    NSArray *dms = policy[@"dm_whitelist"];
    if ((groups == nil || groups.count == 0) && (dms == nil || dms.count == 0)) {
        return NO;  // fail closed: nothing whitelisted
    }
    return YES;
}

BOOL WeChatIngestSendMsg(NSString *chatKind, BOOL isSelf, NSDictionary *policy,
                         NSString *toUser, NSString *content) {
    if (!WeChatIngestCanSendReply(chatKind, isSelf, policy)) {
        return NO;  // gate closed — sendMsg:toUser: is NOT called
    }
    // Todo-18 e2e seam: resolve the chat session and invoke sendMsg:toUser:.
    NSLog(@"[WeChatIngest] sendMsg:toUser: would send to %@: %@", toUser, content);
    return YES;
}

BOOL WeChatIngestSendLocalMsg(NSString *chatKind, BOOL isSelf, NSDictionary *policy,
                              NSString *toUser, NSString *content) {
    if (!WeChatIngestCanSendReply(chatKind, isSelf, policy)) {
        return NO;  // gate closed — sendLocalMsg:toUser: is NOT called
    }
    // Todo-18 e2e seam: invoke sendLocalMsg:toUser: on the resolved session.
    NSLog(@"[WeChatIngest] sendLocalMsg:toUser: would send to %@: %@", toUser, content);
    return YES;
}

BOOL WeChatIngestPkcReplyMessage(NSString *chatKind, BOOL isSelf, NSDictionary *policy,
                                 NSString *content) {
    if (!WeChatIngestCanSendReply(chatKind, isSelf, policy)) {
        return NO;  // gate closed — pkcReplyMessage: is NOT called
    }
    // Todo-18 e2e seam: invoke pkcReplyMessage: with the reply content.
    NSLog(@"[WeChatIngest] pkcReplyMessage: would send: %@", content);
    return YES;
}
