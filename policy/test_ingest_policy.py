"""Tests for the ingest/reply policy engine (pure, no network)."""

import pytest

from ingest_policy import decide


def make_event(**overrides):
    event = {
        "chat_id": "room1@chatroom",
        "chat_kind": "group",
        "is_at_me": False,
        "is_self": False,
        "text": "hello",
        "ts": 1700000100,
    }
    event.update(overrides)
    return event


def make_config(**overrides):
    config = {
        "group_whitelist": ["room1@chatroom"],
        "dm_whitelist": ["wxid_x"],
        "command_prefix": "/oc",
        "enabled_at": 1700000000,
    }
    config.update(overrides)
    return config


def test_selected_group_text_with_at_bot_ingests_and_replies():
    """Policy may mark reply; the iOS dylib still never sends."""
    event = make_event(chat_kind="group", is_at_me=True)
    config = make_config()
    assert decide(event, config) == {"ingest": True, "reply": True}


def test_selected_group_text_with_command_prefix_ingests_and_replies():
    """A whitelisted group message with the command prefix can reply in policy."""
    event = make_event(chat_kind="group", text="/oc status")
    config = make_config()
    assert decide(event, config) == {"ingest": True, "reply": True}


def test_selected_group_text_without_at_or_prefix_ingests_but_never_replies():
    """A whitelisted group text without @ or prefix is ingested silently."""
    event = make_event(chat_kind="group", text="just chatting")
    config = make_config()
    assert decide(event, config) == {"ingest": True, "reply": False}


def test_selected_dm_with_at_bot_ingests_but_never_replies():
    """A whitelisted DM that @'s the bot is ingested but NEVER replied to."""
    event = make_event(
        chat_kind="dm", chat_id="wxid_x", is_at_me=True, text="/oc help"
    )
    config = make_config()
    assert decide(event, config) == {"ingest": True, "reply": False}


def test_selected_dm_with_command_prefix_ingests_but_never_replies():
    """A whitelisted DM with the command prefix is ingested but NEVER replied to."""
    event = make_event(chat_kind="dm", chat_id="wxid_x", text="/oc status")
    config = make_config()
    assert decide(event, config) == {"ingest": True, "reply": False}


def test_empty_whitelist_drops_everything():
    """Fail closed: no whitelist configured means nothing is ingested or replied to."""
    event = make_event(is_at_me=True, text="/oc help")
    config = make_config(group_whitelist=[], dm_whitelist=[])
    assert decide(event, config) == {"ingest": False, "reply": False}


def test_group_not_in_whitelist_is_dropped():
    """A chat absent from the whitelist is dropped even when it @'s the bot."""
    event = make_event(chat_id="otherroom@chatroom", is_at_me=True)
    config = make_config()
    assert decide(event, config) == {"ingest": False, "reply": False}


def test_dm_not_in_whitelist_is_dropped():
    """A DM absent from the whitelist is dropped even when it @'s the bot."""
    event = make_event(
        chat_kind="dm", chat_id="stranger", is_at_me=True, text="/oc help"
    )
    config = make_config()
    assert decide(event, config) == {"ingest": False, "reply": False}


def test_before_enabled_at_is_dropped_no_backfill():
    """Messages older than the enable timestamp are never backfilled."""
    event = make_event(is_at_me=True, ts=1699999999)
    config = make_config(enabled_at=1700000000)
    assert decide(event, config) == {"ingest": False, "reply": False}


def test_at_enabled_at_boundary_is_ingested():
    """A message exactly at the enable timestamp is ingested (not a backfill)."""
    event = make_event(ts=1700000000)
    config = make_config()
    assert decide(event, config) == {"ingest": True, "reply": False}


def test_self_message_ingests_if_chat_allowed_but_never_replies():
    """The user's own message in a whitelisted group ingests, reply is always False."""
    event = make_event(is_self=True, is_at_me=True, text="/oc help")
    config = make_config()
    assert decide(event, config) == {"ingest": True, "reply": False}


def test_self_message_outside_whitelist_is_dropped():
    """The user's own message in a non-whitelisted chat is dropped."""
    event = make_event(chat_id="otherroom@chatroom", is_self=True, is_at_me=True)
    config = make_config()
    assert decide(event, config) == {"ingest": False, "reply": False}


def test_unknown_chat_kind_is_dropped():
    """A chat kind that is neither group nor dm is never ingested."""
    event = make_event(chat_kind="room", is_at_me=True)
    config = make_config()
    assert decide(event, config) == {"ingest": False, "reply": False}


def test_group_id_listed_as_dm_only_is_dropped():
    """A chat must be whitelisted under its own kind, not the other list."""
    event = make_event(chat_kind="group", chat_id="wxid_x", is_at_me=True)
    config = make_config()
    assert decide(event, config) == {"ingest": False, "reply": False}


def test_missing_config_fails_closed():
    """An absent config (no whitelist) drops everything."""
    event = make_event(is_at_me=True, text="/oc help")
    assert decide(event, {}) == {"ingest": False, "reply": False}


def test_record_all_groups_ingests_unlisted_group():
    event = make_event(chat_id="otherroom@chatroom")
    config = make_config(record_all_groups=True)
    assert decide(event, config) == {"ingest": True, "reply": False}


def test_record_all_dms_ingests_unlisted_dm():
    event = make_event(chat_kind="dm", chat_id="stranger")
    config = make_config(record_all_dms=True)
    assert decide(event, config) == {"ingest": True, "reply": False}


def test_exclude_wins_over_record_all_groups():
    event = make_event(chat_id="spam@chatroom")
    config = make_config(record_all_groups=True, group_exclude=["spam@chatroom"])
    assert decide(event, config) == {"ingest": False, "reply": False}


def test_exclude_wins_over_record_all_dms():
    event = make_event(chat_kind="dm", chat_id="wxid_spam")
    config = make_config(record_all_dms=True, dm_exclude=["wxid_spam"])
    assert decide(event, config) == {"ingest": False, "reply": False}
