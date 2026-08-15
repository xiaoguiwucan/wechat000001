"""Send gate contract — todo-14: hard-disable DM and self reply.

Locks the rule that EVERY reply-send path (``sendMsg:toUser:``,
``sendLocalMsg:toUser:``, ``pkcReplyMessage:``) goes through the single gate
``canSendReply(chatKind, isSelf, policy)``. A closed gate means the send
selector is never invoked: DMs and the user's own messages are hard-disabled
("不允许自动回复私人聊天"), and a policy that whitelists nothing fails closed.

The gate is the final defense-in-depth layer. The @-mention / command-prefix
trigger and the per-chat whitelist membership are enforced UPSTREAM by the
reply decision (``ingest_policy.decide`` / ``reply_routing.openclaw_chat_request``,
todos 11/13) — this file locks the send boundary itself.

This file is the Python twin of the ObjC send gate in
``tweak/hooks/SendGate.{h,m}`` (``WeChatIngestCanSendReply`` + the three gated
send wrappers): ``canSendReply`` mirrors ``WeChatIngestCanSendReply``, the
wrapper functions mirror ``WeChatIngestSendMsg`` / ``WeChatIngestSendLocalMsg`` /
``WeChatIngestPkcReplyMessage``, and ``hook_send_reply`` mirrors the reply-send
seam (map → reply decision → gate → send). All must stay in lockstep.
"""

from __future__ import annotations

from ingest_policy import decide
from send_gate import canSendReply, pkc_reply_message, send_local_msg, send_msg
from test_msgwrap_map import make_wrap, map_msg_wrap


def make_config(**overrides):
    config = {
        "group_whitelist": ["room1@chatroom"],
        "dm_whitelist": ["wxid_x"],
        "command_prefix": "/oc",
        "enabled_at": 1700000000,
    }
    config.update(overrides)
    return config


def hook_send_reply(
    wrap: dict, config: dict, *, is_at_me: bool = False, is_self: bool = False
) -> bool:
    """Python twin of the reply-send seam: map → reply decision → gate → send.

    Returns True only when the full reply pipeline would SEND: the mapped
    event replies (``decide`` reply=True — whitelisted group, not self, and
    @-mention or command prefix) AND ``canSendReply`` opens the gate. A DM,
    self-message, ingest-only group message, or wrap rejected by the mapper
    never sends.
    """
    event = map_msg_wrap(wrap)
    if event is None:
        return False  # wrap rejected: missing m_uiMesLocalID
    decision_event = {**event, "is_at_me": is_at_me, "is_self": is_self}
    if not decide(decision_event, config)["reply"]:
        return False  # no reply request is even built (todos 11/13)
    return canSendReply(event["chat_kind"], is_self, config)


# ---------------------------------------------------------------------------
# happy path — a non-self GROUP message may send
# ---------------------------------------------------------------------------


def test_group_non_self_may_send():
    """happy: a whitelisted group message (non-self) opens the send gate."""
    config = make_config()
    assert canSendReply("group", isSelf=False, policy=config) is True


def test_group_non_self_all_send_wrappers_send():
    """happy: every send wrapper sends when the gate is open."""
    config = make_config()
    assert send_msg("group", False, config) is True
    assert send_local_msg("group", False, config) is True
    assert pkc_reply_message("group", False, config) is True


def test_group_at_mention_full_pipeline_sends():
    """happy (acceptance): '@bot' in a whitelisted group may send end to end."""
    config = make_config()
    wrap = make_wrap(
        m_nsToUsr="room1@chatroom", m_nsContent="@bot 今天怎样", m_uiMessageType=1
    )

    assert hook_send_reply(wrap, config, is_at_me=True) is True
    assert decide(
        {**map_msg_wrap(wrap), "is_at_me": True, "is_self": False}, config
    ) == {"ingest": True, "reply": True}


# ---------------------------------------------------------------------------
# failure — DM never sends, even with @bot (acceptance)
# ---------------------------------------------------------------------------


def test_dm_at_bot_still_can_send_reply_false():
    """failure (acceptance): a DM that @'s the bot still canSendReply=False."""
    config = make_config()
    assert canSendReply("dm", isSelf=False, policy=config) is False


def test_dm_never_sends_through_any_wrapper():
    """A DM must never invoke sendMsg:/sendLocalMsg:/pkcReplyMessage:."""
    config = make_config()
    assert send_msg("dm", False, config) is False
    assert send_local_msg("dm", False, config) is False
    assert pkc_reply_message("dm", False, config) is False


def test_dm_at_bot_full_pipeline_never_sends():
    """A DM that @'s the bot ingests but the reply-send seam returns False."""
    config = make_config()
    wrap = make_wrap(
        m_nsToUsr="wxid_x", m_nsContent="@bot help me", m_uiMessageType=1
    )

    assert hook_send_reply(wrap, config, is_at_me=True) is False
    event = map_msg_wrap(wrap)
    assert event is not None
    assert event["chat_kind"] == "dm"
    assert decide({**event, "is_at_me": True, "is_self": False}, config) == {
        "ingest": True,
        "reply": False,
    }


def test_dm_command_prefix_never_sends():
    """A DM with the command prefix is ingested, never sent to."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="wxid_x", m_nsContent="/oc status")

    assert hook_send_reply(wrap, config) is False


# ---------------------------------------------------------------------------
# failure — the user's own message never sends
# ---------------------------------------------------------------------------


def test_self_group_message_never_sends():
    """The user's own group message never sends, even with @."""
    config = make_config()
    assert canSendReply("group", isSelf=True, policy=config) is False


def test_self_group_never_sends_through_any_wrapper():
    """Self-messages must never invoke a send selector."""
    config = make_config()
    assert send_msg("group", True, config) is False
    assert send_local_msg("group", True, config) is False
    assert pkc_reply_message("group", True, config) is False


def test_self_group_at_mention_full_pipeline_never_sends():
    """Self + @ in a group: the reply-send seam returns False."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="@bot status")

    assert hook_send_reply(wrap, config, is_at_me=True, is_self=True) is False
    assert decide(
        {**map_msg_wrap(wrap), "is_at_me": True, "is_self": True}, config
    ) == {"ingest": True, "reply": False}


def test_dm_self_message_never_sends():
    """A self DM is double hard-disabled (kind + isSelf)."""
    config = make_config()
    assert canSendReply("dm", isSelf=True, policy=config) is False
    assert send_msg("dm", True, config) is False


# ---------------------------------------------------------------------------
# failure — fail closed: no whitelist, no send
# ---------------------------------------------------------------------------


def test_empty_whitelist_fails_closed():
    """No whitelist configured → the gate is closed even for a group."""
    config = make_config(group_whitelist=[], dm_whitelist=[])
    assert canSendReply("group", isSelf=False, policy=config) is False
    assert send_msg("group", False, config) is False


def test_missing_policy_fails_closed():
    """An absent/empty policy dict → the gate is closed."""
    assert canSendReply("group", isSelf=False, policy={}) is False
    assert canSendReply("dm", isSelf=False, policy={}) is False


def test_none_policy_fails_closed():
    """A nil policy object → the gate is closed (defensive, matches ObjC)."""
    assert canSendReply("group", isSelf=False, policy=None) is False


# ---------------------------------------------------------------------------
# failure — an ingest-only group message never sends (trigger is upstream)
# ---------------------------------------------------------------------------


def test_group_without_at_or_prefix_never_sends():
    """'今天怎样' (no @, no prefix) ingests but the send seam returns False."""
    config = make_config()
    wrap = make_wrap(
        m_nsToUsr="room1@chatroom", m_nsContent="今天怎样", m_uiMessageType=1
    )

    assert hook_send_reply(wrap, config) is False
    assert decide(
        {**map_msg_wrap(wrap), "is_at_me": False, "is_self": False}, config
    ) == {"ingest": True, "reply": False}


def test_wrap_rejected_by_mapper_never_sends():
    """A wrap missing m_uiMesLocalID is rejected and never sends."""
    config = make_config()
    wrap = dict(make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="@bot hi"))
    del wrap["m_uiMesLocalID"]

    assert hook_send_reply(wrap, config, is_at_me=True) is False
