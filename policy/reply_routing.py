"""Reply-pipe routing — todo-13: group @/cmd only, protocol-3 identity.

Pure decision + request builder for the OpenClaw CHAT path, kept separate from
the ingest gate (todo-11). An OpenClaw chat request is only ever built when
``decide(event, config)["reply"]`` is True — a whitelisted group message that
@'s the bot or starts with the command prefix. Ingest-only messages
(``reply=False``) return None and must NEVER open an OpenClaw session.

The hello identity is the todo-3 protocol-3 fixture
(``contracts/protocol3_hello.json``): client=openclaw-control-ui, mode=webchat,
version=1.0.0, userAgent=pkc-openclaw-client/1.0.0, role=operator, protocol=3.
Protocol 4 is never produced. The session key is the group chat id (per-chat
sessions), matching the PKC reply path
``oc_connectOpenClawWithURL:token:sessionKey:completion:`` (identity ported,
method never invoked — we replicate the client identity, not PKC's method).

This module is the Python twin of ``tweak/hooks/OpenClawReply.m``
(``WeChatIngestOpenClawChatRequest`` / ``WeChatIngestShouldOpenOpenClawSession``)
and must stay in lockstep with it.
"""

from __future__ import annotations

from ingest_policy import decide

# Protocol-3 client identity (fnOS OpenClaw whitelist), locked by
# contracts/protocol3_hello.json — client=openclaw-control-ui, mode=webchat,
# version=1.0.0, userAgent=pkc-openclaw-client/1.0.0, role=operator, protocol=3.
PROTOCOL3_HELLO: dict[str, object] = {
    "client": "openclaw-control-ui",
    "mode": "webchat",
    "version": "1.0.0",
    "userAgent": "pkc-openclaw-client/1.0.0",
    "role": "operator",
    "protocol": 3,
}


def openclaw_chat_request(event: dict, config: dict) -> dict | None:
    """The OpenClaw chat request for *event*, or None for an ingest-only one.

    Returns None unless the event replies — a whitelisted group message that
    is not the user's own and either @'s the bot or starts with the command
    prefix (``decide(event, config)["reply"]``). When it replies, the request
    carries the protocol-3 hello identity (``PROTOCOL3_HELLO``) and a per-chat
    ``session_key`` equal to the group chat id. DMs, self-messages,
    non-whitelisted chats, and pre-``enabled_at`` backfill never produce a
    request. Protocol 4 is never produced.
    """
    if not decide(event, config)["reply"]:
        return None
    return {
        "hello": dict(PROTOCOL3_HELLO),
        "session_key": event.get("chat_id", ""),
        "text": event.get("text", ""),
    }
