"""Send gate — todo-14: hard-disable DM and self reply.

Single gate function ``canSendReply(chatKind, isSelf, policy)`` — the ONE
function every reply-send path (``sendMsg:toUser:``, ``sendLocalMsg:toUser:``,
``pkcReplyMessage:``) consults before sending. It hard-disables private chats
(DM) and the user's own messages ("不允许自动回复私人聊天") and fails closed when
the policy whitelists nothing.

The gate is the final defense-in-depth layer at the SEND boundary. The
@-mention / command-prefix trigger and the per-chat whitelist membership are
enforced UPSTREAM by the reply decision (:func:`ingest_policy.decide`) and the
todo-13 router (:func:`reply_routing.openclaw_chat_request`) — a closed gate
here means the send selector is never invoked, no matter what a routing bug
lets through.

This module is the Python twin of ``tweak/hooks/SendGate.{h,m}``
(``WeChatIngestCanSendReply`` + the three gated send wrappers) and must stay
in lockstep with it. ``canSendReply`` keeps its camelCase name to match the
plan contract and the ObjC twin (scripts/check-no-dm-send.sh greps it).
"""

from __future__ import annotations

from typing import Any

# ``policy`` is the same config dict shape consumed by ingest_policy.decide:
# group_whitelist / dm_whitelist / command_prefix / enabled_at. A None value
# is treated as an empty policy (fail closed), mirroring the ObjC nil check.
Policy = dict[str, Any] | None


def canSendReply(chatKind: str, isSelf: bool, policy: Policy) -> bool:
    """Whether a reply may be SENT for *chatKind* / *isSelf* under *policy*.

    Returns True only for a non-self GROUP message when the policy whitelists
    at least one chat (fail closed). Hard-disables DMs and the user's own
    messages. The @-mention / command-prefix trigger and the specific chat's
    whitelist membership are enforced upstream by the reply decision, so this
    gate carries no text / chat_id — a routing bug cannot open it for a DM.

    Rule order (mirror of ``WeChatIngestCanSendReply``):
    1. ``isSelf`` → False (never reply to the user's own message).
    2. ``chatKind != "group"`` → False (DM replies are hard-disabled).
    3. both whitelists empty (or policy None/{}) → False (fail closed).
    4. otherwise True.
    """
    if isSelf:
        return False
    if chatKind != "group":
        return False
    if not policy:
        return False  # None / empty policy → fail closed
    if not (policy.get("group_whitelist") or policy.get("dm_whitelist")):
        return False
    return True


def send_msg(chatKind: str, isSelf: bool, policy: Policy) -> bool:
    """``sendMsg:toUser:`` wrapper — True iff the send was performed.

    Returns False (and the send selector is NOT invoked) when the gate is
    closed. Twin of ``WeChatIngestSendMsg`` in tweak/hooks/SendGate.m.
    """
    if not canSendReply(chatKind, isSelf, policy):
        return False  # gate closed — sendMsg:toUser: is NOT called
    return True


def send_local_msg(chatKind: str, isSelf: bool, policy: Policy) -> bool:
    """``sendLocalMsg:toUser:`` wrapper — same gate.

    Twin of ``WeChatIngestSendLocalMsg`` in tweak/hooks/SendGate.m.
    """
    if not canSendReply(chatKind, isSelf, policy):
        return False  # gate closed — sendLocalMsg:toUser: is NOT called
    return True


def pkc_reply_message(chatKind: str, isSelf: bool, policy: Policy) -> bool:
    """``pkcReplyMessage:`` wrapper — same gate.

    Twin of ``WeChatIngestPkcReplyMessage`` in tweak/hooks/SendGate.m.
    """
    if not canSendReply(chatKind, isSelf, policy):
        return False  # gate closed — pkcReplyMessage: is NOT called
    return True
