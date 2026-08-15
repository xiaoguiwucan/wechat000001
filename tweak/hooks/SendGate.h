// WeChatIngest — tweak/hooks/SendGate.h (todo-14).
//
// The single reply-send gate. EVERY send path — sendMsg:toUser:,
// sendLocalMsg:toUser:, pkcReplyMessage: — consults
// WeChatIngestCanSendReply(chatKind, isSelf, policy) FIRST; when the gate is
// closed (a DM, the user's own message, or a policy that whitelists nothing)
// the wrapper returns NO and the send selector is never invoked. DMs and
// self-messages are hard-disabled ("不允许自动回复私人聊天").
//
// The gate is the ObjC twin of canSendReply(chatKind, isSelf, policy) and the
// wrappers are the twin of the send wrappers in policy/send_gate.py; keep the
// two in lockstep. The @-mention / command-prefix trigger and the per-chat
// whitelist membership are enforced upstream by the reply decision
// (tweak/hooks/OpenClawReply.m WeChatIngestReplyDecision, mirror of
// policy/ingest_policy.py decide()) — this gate is the final layer.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether a reply may be SENT for *chatKind* with *isSelf* under *policy*.
/// YES only for a non-self GROUP when the policy whitelists at least one chat
/// (fail closed); NO for a DM or a self-message (hard-disable). The trigger
/// (@/command prefix) and the specific chat's whitelist membership are
/// enforced upstream by the reply decision, so this gate carries no text or
/// chat_id — a routing bug cannot open it for a DM.
FOUNDATION_EXPORT BOOL WeChatIngestCanSendReply(NSString *chatKind,
                                                BOOL isSelf,
                                                NSDictionary *policy);

/// sendMsg:toUser: wrapper — returns YES iff the send was performed (gate
/// open). When the gate is closed the selector is NOT called and NO is
/// returned. Twin of policy/send_gate.py send_msg().
FOUNDATION_EXPORT BOOL WeChatIngestSendMsg(NSString *chatKind,
                                           BOOL isSelf,
                                           NSDictionary *policy,
                                           NSString *toUser,
                                           NSString *content);

/// sendLocalMsg:toUser: wrapper — same gate. Twin of send_local_msg().
FOUNDATION_EXPORT BOOL WeChatIngestSendLocalMsg(NSString *chatKind,
                                                BOOL isSelf,
                                                NSDictionary *policy,
                                                NSString *toUser,
                                                NSString *content);

/// pkcReplyMessage: wrapper — same gate. Twin of pkc_reply_message().
FOUNDATION_EXPORT BOOL WeChatIngestPkcReplyMessage(NSString *chatKind,
                                                   BOOL isSelf,
                                                   NSDictionary *policy,
                                                   NSString *content);

NS_ASSUME_NONNULL_END
