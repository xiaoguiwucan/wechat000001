"""Ingest gate contract — todo-11: no trigger required for ingest.

Locks the rule that ENQUEUEING does not require an @-mention or the command
prefix: any message from a whitelisted chat is ingested (ingest=True) even
when it would never be replied to (reply=False). The ingest gate is only the
chat policy — ``decide(event, config)["ingest"]`` (whitelist + no-backfill).

This file is the Python twin of the ObjC hook path in
``tweak/hooks/MessageHooks.m``: map the CMessageWrap (``map_msg_wrap`` →
``WeChatIngestMapMessageWrap``), then apply the ingest gate and enqueue the
inbox payload when it passes. ``hook_ingest_payload`` mirrors
``WeChatIngestHandleMessageWrap`` + ``WeChatIngestEnqueueEvent`` and must
stay in lockstep with it.

The reply decision is deliberately separate (todos 13/14): the gate never
reads ``is_at_me`` / ``command_prefix`` for the ingest decision.
"""

from __future__ import annotations

from ingest_policy import decide, decide_ingest
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


def hook_ingest_payload(wrap: dict, config: dict, *, is_at_me: bool = False, is_self: bool = False) -> dict | None:
    """Python twin of the hook path: map → ingest gate → inbox payload.

    Returns the mapped event (the payload the hook would enqueue into the
    ingest inbox) when the gate says ingest, else None (dropped). The gate
    requires only the chat policy — never @ or prefix.
    """
    event = map_msg_wrap(wrap)
    if event is None:
        return None  # wrap rejected: missing m_uiMesLocalID
    decision_event = {**event, "is_at_me": is_at_me, "is_self": is_self}
    if not decide_ingest(decision_event, config):
        return None
    return event


def test_whitelisted_group_hello_ingests_without_reply():
    """A whitelisted group 'hello' with no @ and no prefix is ingested, never replied."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="hello", m_uiMessageType=1)

    payload = hook_ingest_payload(wrap, config)

    assert payload is not None
    assert payload["chat_id"] == "room1@chatroom"
    assert payload["text"] == "hello"
    decision = decide({**payload, "is_at_me": False, "is_self": False}, config)
    assert decision == {"ingest": True, "reply": False}


def test_same_hello_outside_whitelist_is_not_ingested():
    """The same 'hello' from a chat absent from the whitelist is dropped."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="otherroom@chatroom", m_nsContent="hello")

    payload = hook_ingest_payload(wrap, config)

    assert payload is None
    decision_event = {**map_msg_wrap(wrap), "is_at_me": False, "is_self": False}
    assert decide(decision_event, config) == {"ingest": False, "reply": False}


def test_ingest_does_not_require_at_mention():
    """@-mention must not be a precondition for ingest in a whitelisted chat."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="plain text, no @")

    payload = hook_ingest_payload(wrap, config)

    assert payload is not None
    assert payload["text"] == "plain text, no @"


def test_ingest_does_not_require_command_prefix():
    """The command prefix must not gate ingest — only reply does."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="banter without /oc")

    payload = hook_ingest_payload(wrap, config)

    assert payload is not None
    assert payload["text"] == "banter without /oc"


def test_whitelisted_dm_ingests_without_trigger_but_never_replies():
    """A whitelisted DM is ingested even with no @/prefix; reply stays False."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="wxid_x", m_nsContent="hello")

    payload = hook_ingest_payload(wrap, config)

    assert payload is not None
    assert payload["chat_kind"] == "dm"
    decision = decide({**payload, "is_at_me": False, "is_self": False}, config)
    assert decision == {"ingest": True, "reply": False}


def test_reply_flag_only_from_at_or_prefix_while_ingest_stays_true():
    """Reply changes with @/prefix but ingest stays True — reply is separate."""
    config = make_config()

    at_payload = hook_ingest_payload(
        make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="@WeChatIngest hi"),
        config,
        is_at_me=True,
    )
    prefix_payload = hook_ingest_payload(
        make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="/oc status"), config
    )

    assert at_payload is not None
    assert prefix_payload is not None
    assert decide({**at_payload, "is_at_me": True, "is_self": False}, config) == {
        "ingest": True,
        "reply": True,
    }
    assert decide({**prefix_payload, "is_at_me": False, "is_self": False}, config) == {
        "ingest": True,
        "reply": True,
    }


def test_self_message_in_whitelisted_chat_is_ingested():
    """Even the user's own message in a whitelisted chat is ingested (reply False)."""
    config = make_config()
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="me typing")

    payload = hook_ingest_payload(wrap, config, is_self=True)

    assert payload is not None
    decision = decide({**payload, "is_at_me": False, "is_self": True}, config)
    assert decision == {"ingest": True, "reply": False}


def test_backfill_before_enabled_at_is_not_ingested():
    """No-trigger gate still respects no-backfill: pre-enable messages drop."""
    config = make_config(enabled_at=1700000000)
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="hello", ts=1699999999)

    payload = hook_ingest_payload(wrap, config)

    assert payload is None


def test_wrap_rejected_by_mapper_is_never_ingested():
    """A wrap the mapper rejects (missing m_uiMesLocalID) is never enqueued."""
    config = make_config()
    wrap = dict(make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="hello"))
    del wrap["m_uiMesLocalID"]

    assert hook_ingest_payload(wrap, config) is None


def test_empty_whitelist_drops_even_with_at_and_prefix():
    """Fail closed: no whitelist configured → no ingest even with a trigger."""
    config = make_config(group_whitelist=[], dm_whitelist=[])
    wrap = make_wrap(m_nsToUsr="room1@chatroom", m_nsContent="/oc help")

    assert hook_ingest_payload(wrap, config, is_at_me=True) is None
