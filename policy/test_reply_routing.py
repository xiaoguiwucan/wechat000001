"""Reply-pipe routing contract — todo-13: group @/cmd only, protocol 3.

Locks the rule that the OpenClaw CHAT path is separate from ingest: an
ingest-only message (whitelisted chat, no @, no command prefix) is ingested
but NEVER enqueues an OpenClaw chat request. Only a whitelisted group message
that @'s the bot or starts with the command prefix (``reply=True``) builds a
request, carrying the protocol-3 hello identity
(``contracts/protocol3_hello.json``) and a per-chat session key equal to the
group chat id.

This file is the Python twin of the ObjC reply path in
``tweak/hooks/OpenClawReply.m``: ``openclaw_chat_request`` mirrors
``WeChatIngestOpenClawChatRequest`` and must stay in lockstep with it.
``hook_reply_request`` mirrors the hook seam: map the CMessageWrap
(``map_msg_wrap``), decorate with ``is_at_me``/``is_self``, then route.

Protocol 4 is never produced; ``protocol`` is always the integer 3.
"""

from __future__ import annotations

import json
from pathlib import Path

from ingest_policy import decide
from reply_routing import PROTOCOL3_HELLO, openclaw_chat_request
from test_msgwrap_map import make_wrap, map_msg_wrap

PROTOCOL3_FIXTURE = (
    Path(__file__).resolve().parent.parent / "contracts" / "protocol3_hello.json"
)


def make_config(**overrides):
    config = {
        "group_whitelist": ["room1@chatroom"],
        "dm_whitelist": ["wxid_x"],
        "command_prefix": "/oc",
        "enabled_at": 1700000000,
    }
    config.update(overrides)
    return config


def hook_reply_request(
    wrap: dict, config: dict, *, is_at_me: bool = False, is_self: bool = False
) -> dict | None:
    """Python twin of the ObjC reply seam: map wrap → route to OpenClaw.

    Returns the OpenClaw chat request when the mapped event replies (group +
    not self + (@ or prefix)), else None — an ingest-only message opens no
    OpenClaw session. A wrap rejected by the mapper (missing
    ``m_uiMesLocalID``) also returns None.
    """
    event = map_msg_wrap(wrap)
    if event is None:
        return None
    decision_event = {**event, "is_at_me": is_at_me, "is_self": is_self}
    return openclaw_chat_request(decision_event, config)


def load_protocol3_fixture() -> dict[str, object]:
    with open(PROTOCOL3_FIXTURE, encoding="utf-8") as fh:
        return json.load(fh)


# ---------------------------------------------------------------------------
# happy path — group @ / command prefix opens an OpenClaw session
# ---------------------------------------------------------------------------


def test_group_at_mention_enqueues_openclaw_chat_request():
    """happy: '@bot 今天怎样' ingests AND opens an OpenClaw chat request."""
    config = make_config()
    wrap = make_wrap(
        m_nsToUsr="room1@chatroom",
        m_nsContent="@bot 今天怎样",
        m_uiMessageType=1,
    )

    request = hook_reply_request(wrap, config, is_at_me=True)

    decision = decide(
        {**map_msg_wrap(wrap), "is_at_me": True, "is_self": False}, config
    )
    assert decision == {"ingest": True, "reply": True}
    assert request is not None
    assert request["session_key"] == "room1@chatroom"
    assert request["text"] == "@bot 今天怎样"


def test_group_command_prefix_enqueues_openclaw_chat_request():
    """happy: a group message starting with the command prefix opens a session."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="/oc status")

    request = hook_reply_request(wrap, config)

    assert request is not None
    assert request["session_key"] == "room1@chatroom"
    assert request["text"] == "/oc status"


def test_group_at_mention_request_uses_protocol3_hello_identity():
    """The request's hello identity is exactly the protocol-3 fixture fields."""
    config = make_config()
    wrap = make_wrap(
        m_nsToUsr="room1@chatroom", m_nsContent="@bot hi", m_uiMessageType=1
    )

    request = hook_reply_request(wrap, config, is_at_me=True)

    assert request is not None
    assert request["hello"] == PROTOCOL3_HELLO
    assert request["hello"] == load_protocol3_fixture()
    assert request["hello"]["protocol"] == 3
    assert request["hello"]["protocol"] != 4  # protocol 4 must never appear


# ---------------------------------------------------------------------------
# ingest-only — NO OpenClaw session
# ---------------------------------------------------------------------------


def test_group_ingest_only_does_not_enqueue_openclaw_chat_request():
    """failure path: '今天怎样' (no @, no prefix) ingests but opens NO session."""
    config = make_config()
    wrap = make_wrap(
        m_nsToUsr="room1@chatroom",
        m_nsContent="今天怎样",
        m_uiMessageType=1,
    )

    request = hook_reply_request(wrap, config)

    event = map_msg_wrap(wrap)
    assert event is not None
    decision = decide({**event, "is_at_me": False, "is_self": False}, config)
    assert decision == {"ingest": True, "reply": False}  # ingest still happens
    assert request is None  # ...but no OpenClaw chat request is enqueued


def test_group_banter_ingests_without_openclaw_request():
    """Ingest pipe and reply pipe are independent: banter lands in store only."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="just chatting")

    request = hook_reply_request(wrap, config)

    assert request is None
    event = map_msg_wrap(wrap)
    assert decide({**event, "is_at_me": False, "is_self": False}, config) == {
        "ingest": True,
        "reply": False,
    }


def test_ingest_only_without_trigger_still_ingests_but_never_opens_session():
    """Direct function check: reply=False ⇒ openclaw_chat_request is None."""
    config = make_config()
    event = {
        "chat_id": "room1@chatroom",
        "chat_kind": "group",
        "is_at_me": False,
        "is_self": False,
        "text": "今天怎样",
        "ts": 1700000100,
    }

    assert openclaw_chat_request(event, config) is None
    assert decide(event, config) == {"ingest": True, "reply": False}


# ---------------------------------------------------------------------------
# never enqueue — DM / self / not whitelisted / backfill / empty whitelist
# ---------------------------------------------------------------------------


def test_dm_at_mention_ingests_but_never_enqueues_openclaw_request():
    """A DM that @'s the bot is ingested but NEVER opens an OpenClaw session."""
    config = make_config()
    wrap = make_wrap(
        m_nsToUsr="wxid_x",
        m_nsContent="@bot help me",
        m_uiMessageType=1,
    )

    request = hook_reply_request(wrap, config, is_at_me=True)

    event = map_msg_wrap(wrap)
    assert event is not None
    assert event["chat_kind"] == "dm"
    assert decide({**event, "is_at_me": True, "is_self": False}, config) == {
        "ingest": True,
        "reply": False,
    }
    assert request is None


def test_dm_command_prefix_never_enqueues_openclaw_request():
    """A DM with the command prefix is ingested, never opened for OpenClaw."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="wxid_x", m_nsContent="/oc status")

    request = hook_reply_request(wrap, config)

    assert request is None
    event = map_msg_wrap(wrap)
    assert decide({**event, "is_at_me": False, "is_self": False}, config) == {
        "ingest": True,
        "reply": False,
    }


def test_self_message_never_enqueues_openclaw_request():
    """The user's own group message never opens a session, even with @."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="@bot status")

    request = hook_reply_request(wrap, config, is_at_me=True, is_self=True)

    assert request is None
    event = map_msg_wrap(wrap)
    assert decide({**event, "is_at_me": True, "is_self": True}, config) == {
        "ingest": True,
        "reply": False,
    }


def test_group_outside_whitelist_never_enqueues_openclaw_request():
    """A group not on the whitelist opens no session even with @."""
    config = make_config()
    wrap = make_wrap(
        m_nsToUsr="otherroom@chatroom", m_nsContent="@bot hi", m_uiMessageType=1
    )

    request = hook_reply_request(wrap, config, is_at_me=True)

    assert request is None
    event = map_msg_wrap(wrap)
    assert decide({**event, "is_at_me": True, "is_self": False}, config) == {
        "ingest": False,
        "reply": False,
    }


def test_before_enabled_at_never_enqueues_openclaw_request():
    """Pre-enable (backfill) messages never open an OpenClaw session."""
    config = make_config(enabled_at=1700000000)
    wrap = make_wrap(
        m_nsToUsr="room1@chatroom", m_nsContent="@bot hi", ts=1699999999
    )

    request = hook_reply_request(wrap, config, is_at_me=True)

    assert request is None
    assert decide(
        {**map_msg_wrap(wrap), "is_at_me": True, "is_self": False}, config
    ) == {"ingest": False, "reply": False}


def test_empty_whitelist_never_enqueues_openclaw_request():
    """Fail closed: no whitelist configured ⇒ no OpenClaw session at all."""
    config = make_config(group_whitelist=[], dm_whitelist=[])
    wrap = make_wrap(
        m_nsToUsr="room1@chatroom", m_nsContent="@bot hi", m_uiMessageType=1
    )

    request = hook_reply_request(wrap, config, is_at_me=True)

    assert request is None
    assert decide(
        {**map_msg_wrap(wrap), "is_at_me": True, "is_self": False}, config
    ) == {"ingest": False, "reply": False}


def test_wrap_rejected_by_mapper_never_enqueues_openclaw_request():
    """A wrap missing m_uiMesLocalID is rejected and opens no session."""
    config = make_config()
    wrap = dict(make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="@bot hi"))
    del wrap["m_uiMesLocalID"]

    assert hook_reply_request(wrap, config, is_at_me=True) is None


# ---------------------------------------------------------------------------
# session key = per-chat group id (never the sender, never shared across chats)
# ---------------------------------------------------------------------------


def test_session_key_is_the_group_chat_id_not_the_sender():
    """session_key is the group chat id — oc_connect uses per-chat sessions."""
    config = make_config()
    wrap = make_wrap(
        m_nsToUsr="room1@chatroom",
        m_nsFromUsr="wxid_a",
        m_nsContent="@bot hi",
        m_uiMessageType=1,
    )

    request = hook_reply_request(wrap, config, is_at_me=True)

    assert request is not None
    assert request["session_key"] == "room1@chatroom"
    assert request["session_key"] != "wxid_a"


def test_session_key_is_per_group_chat():
    """Two different groups get different session keys (per-chat sessions)."""
    config = make_config(group_whitelist=["room1@chatroom", "room2@chatroom"])

    req1 = hook_reply_request(
        make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="@bot hi"),
        config,
        is_at_me=True,
    )
    req2 = hook_reply_request(
        make_wrap(m_nsToUsr="room2@chatroom", m_nsContent="@bot hi"),
        config,
        is_at_me=True,
    )

    assert req1 is not None and req2 is not None
    assert req1["session_key"] == "room1@chatroom"
    assert req2["session_key"] == "room2@chatroom"
    assert req1["session_key"] != req2["session_key"]
    assert req1["hello"] == req2["hello"]  # same protocol-3 identity


# ---------------------------------------------------------------------------
# identity contract — protocol 3 only, matches contracts/protocol3_hello.json
# ---------------------------------------------------------------------------


def test_hello_identity_matches_protocol3_fixture():
    """The routed hello equals the todo-3 protocol-3 fixture, field for field."""
    assert PROTOCOL3_HELLO == {
        "client": "openclaw-control-ui",
        "mode": "webchat",
        "version": "1.0.0",
        "userAgent": "pkc-openclaw-client/1.0.0",
        "role": "operator",
        "protocol": 3,
    }
    assert PROTOCOL3_HELLO == load_protocol3_fixture()


def test_hello_protocol_is_integer_3_never_4():
    """protocol is the integer 3; protocol 4 must never be produced."""
    assert isinstance(PROTOCOL3_HELLO["protocol"], int)
    assert PROTOCOL3_HELLO["protocol"] == 3
    assert PROTOCOL3_HELLO["protocol"] != 4
