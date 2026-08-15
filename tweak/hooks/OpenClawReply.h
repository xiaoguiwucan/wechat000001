// WeChatIngest — tweak/hooks/OpenClawReply.h (todo-13).
//
// Reply-pipe routing for the OpenClaw CHAT path. Ports the protocol-3 client
// identity of PKC's oc_connectOpenClawWithURL:token:sessionKey:completion:
// (todo 3, locked by contracts/protocol3_hello.json) as a pure module: an
// OpenClaw chat request is built ONLY when the policy says reply=True — a
// whitelisted group message that @'s the bot or starts with the command
// prefix — and the session key is the group chat id (per-chat sessions).
// Ingest-only messages never open an OpenClaw session. Protocol 4 is never
// used.
//
// This is the ObjC twin of policy/reply_routing.py (PROTOCOL3_HELLO /
// openclaw_chat_request) and must stay in lockstep with it.
//
// The identity is PORTED, not invoked: we never call PKC's
// oc_connectOpenClawWithURL:token:sessionKey:completion: — we replicate the
// protocol-3 client identity and open our own connection to the gateway once
// the transport (todo-12 SSH local-forward to 127.0.0.1:18790 → OpenClaw
// 18789) lands. Until then the request is only logged (the reply seam below).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The protocol-3 hello identity (contracts/protocol3_hello.json):
/// client=openclaw-control-ui, mode=webchat, version=1.0.0,
/// userAgent=pkc-openclaw-client/1.0.0, role=operator, protocol=3.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *WeChatIngestOpenClawHello(void);

/// Whether *event* (mapped event decorated with is_at_me / is_self) should
/// open an OpenClaw session. True only when the policy reply=True — a
/// whitelisted group message that is not the user's own and either @'s the
/// bot or starts with the command prefix. Never True for a DM, self-message,
/// non-whitelisted chat, or pre-enabled_at backfill.
FOUNDATION_EXPORT BOOL WeChatIngestShouldOpenOpenClawSession(NSDictionary *event,
                                                             NSDictionary *config);

/// The OpenClaw chat request (hello identity + session_key = the group chat
/// id + text) when *event* replies, else nil. An ingest-only message returns
/// nil — no OpenClaw session is opened.
FOUNDATION_EXPORT NSDictionary *_Nullable WeChatIngestOpenClawChatRequest(NSDictionary *event,
                                                                          NSDictionary *config);

/// Reply seam (mirror of WeChatIngestEnqueueEvent for the ingest pipe): logs
/// the request built by WeChatIngestOpenClawChatRequest. Transport (todo-12
/// SSH local-forward to 127.0.0.1:18790 → OpenClaw 18789) delivers it later.
FOUNDATION_EXPORT void WeChatIngestEnqueueOpenClawRequest(NSDictionary *_Nullable request);

NS_ASSUME_NONNULL_END
