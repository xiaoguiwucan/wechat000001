"""CMessageWrap → event mapping fixture (todo-10).

Maps one ``CMessageWrap`` field dict (``m_uiMessageType``, ``m_nsContent``,
``m_nsFromUsr``, ``m_nsToUsr``, ``m_uiMesLocalID``, optional ``ts``) to a
``store/event.schema.json`` event dict. This is the canonical, test-locked
mapping contract; the ObjC capture path in ``tweak/hooks/MessageHooks.m``
(``WeChatIngestMapMessageWrap``) is its mirror and must stay in lockstep.

Type map (plan todo-10):
    1 → text, 3 → image, 34 → voice, 43 → video, 49 → redpacket/appmsg,
    10000/10002 → revoke (sysmsg; a group-announcement sysmsg → announcement),
    anything else → raw (original type preserved in ``extra_json.raw_type``).

A wrap missing ``m_uiMesLocalID`` is REJECTED (``map_msg_wrap`` returns None)
so no event without a stable message id can reach the ingest pipeline.
"""

from __future__ import annotations

import json
from pathlib import Path

import jsonschema
import pytest

EVENT_SCHEMA_JSON = Path(__file__).resolve().parent.parent / "store" / "event.schema.json"

# ---------------------------------------------------------------------------
# map_msg_wrap — the fixture under test (mirrored by tweak/hooks/MessageHooks.m)
# ---------------------------------------------------------------------------

# Numeric WeChat message types → ingest vocabulary. 49 is the appmsg family
# (red packet / url card) and lands in the "redpacket" bucket.
TYPE_MAP = {1: "text", 3: "image", 34: "voice", 43: "video", 47: "emoji", 49: "redpacket"}

# WeChat sysmsg types: revoke or group announcement, decided by content below.
SYSMSG_TYPES = {10000, 10002}

_MEDIA_PLACEHOLDERS = {"image", "voice", "video", "emoji", "file", "redpacket"}


def map_msg_type(raw_type, content: str) -> str:
    """The ingest vocabulary type for one raw WeChat type + content."""
    if raw_type in SYSMSG_TYPES:
        lowered = (content or "").lower()
        if "revokemsg" in lowered:
            return "revoke"
        if "announcement" in lowered:
            return "announcement"
        return "revoke"  # plain sysmsg defaults to revoke per the type map
    if raw_type == 49:
        lowered = (content or "").lower()
        if "<type>6</type>" in lowered or "<appattach" in lowered or "<fileext>" in lowered:
            return "file"
        if "hongbao" in lowered or "wxpay" in lowered or "红包" in (content or "") or "<type>2001</type>" in lowered:
            return "redpacket"
        if "<type>4</type>" in lowered or "<videomsg" in lowered:
            return "video"
        return "redpacket"
    return TYPE_MAP.get(raw_type, "raw")


def _text_for(msg_type: str, content: str) -> str:
    """text/revoke/announcement/raw keep the content; media get placeholders."""
    if msg_type == "text":
        return content
    if msg_type in _MEDIA_PLACEHOLDERS:
        return f"[{msg_type}]"
    return content


def map_msg_wrap(wrap: dict) -> dict | None:
    """Map one CMessageWrap field dict to a store event dict.

    Returns ``None`` (event rejected) when ``m_uiMesLocalID`` is missing.
    """
    local_id = wrap.get("m_uiMesLocalID")
    if local_id is None:
        return None  # missing m_uiMesLocalID → event rejected

    raw_type = wrap.get("m_uiMessageType")
    content = wrap.get("m_nsContent") or ""
    from_user = wrap.get("m_nsFromUsr") or ""
    to_user = wrap.get("m_nsToUsr") or ""
    try:
        ts = int(wrap.get("ts", 0))
    except (TypeError, ValueError):
        ts = 0

    msg_type = map_msg_type(raw_type, content)
    text = _text_for(msg_type, content)

    extra = None
    if msg_type == "raw" and raw_type is not None:
        extra = json.dumps({"raw_type": raw_type}, ensure_ascii=False, sort_keys=True)

    return {
        "chat_id": to_user,
        "chat_kind": "group" if to_user.endswith("@chatroom") else "dm",
        "msg_id": str(local_id),
        "msg_type": msg_type,
        "sender": from_user,
        "ts": ts,
        "text": text,
        "media_path": None,
        "extra_json": extra,
    }


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

def make_wrap(**overrides):
    wrap = {
        "m_uiMessageType": 1,
        "m_nsContent": "hello",
        "m_nsFromUsr": "wxid_a",
        "m_nsToUsr": "room1@chatroom",
        "m_uiMesLocalID": 12345,
        "ts": 1720000001,
    }
    wrap.update(overrides)
    return wrap


def _schema():
    return json.loads(EVENT_SCHEMA_JSON.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# happy path — type map
# ---------------------------------------------------------------------------

def test_text_type_1_maps_to_text_event():
    event = map_msg_wrap(make_wrap())
    assert event is not None
    assert event["msg_type"] == "text"
    assert event["text"] == "hello"
    assert event["sender"] == "wxid_a"
    assert event["msg_id"] == "12345"
    assert event["ts"] == 1720000001


def test_appmsg_file_type_6_maps_to_file():
    xml = "<appmsg><type>6</type><title>合同.pdf</title><fileext>pdf</fileext></appmsg>"
    event = map_msg_wrap(make_wrap(m_uiMessageType=49, m_nsContent=xml))
    assert event["msg_type"] == "file"


@pytest.mark.parametrize(
    ("raw_type", "expected"),
    [
        (1, "text"),
        (3, "image"),
        (34, "voice"),
        (43, "video"),
        (47, "emoji"),
        (49, "redpacket"),
        (10000, "revoke"),
        (10002, "revoke"),
    ],
)
def test_happy_type_map(raw_type, expected):
    """The seven PKC-flagged types map to the correct ingest vocabulary."""
    assert map_msg_wrap(make_wrap(m_uiMessageType=raw_type))["msg_type"] == expected


def test_revoke_sysmsg_with_revokemsg_content_maps_to_revoke():
    wrap = make_wrap(
        m_uiMessageType=10002,
        m_nsContent='<sysmsg type="revokemsg"><revokemsg>...</revokemsg></sysmsg>',
    )
    assert map_msg_wrap(wrap)["msg_type"] == "revoke"


def test_announcement_sysmsg_maps_to_announcement():
    wrap = make_wrap(
        m_uiMessageType=10002,
        m_nsContent='<sysmsg type="GroupAnnouncement"><text>server news</text></sysmsg>',
    )
    assert map_msg_wrap(wrap)["msg_type"] == "announcement"


def test_unknown_type_maps_to_raw_with_raw_type_preserved():
    event = map_msg_wrap(make_wrap(m_uiMessageType=9999, m_nsContent="?"))
    assert event["msg_type"] == "raw"
    assert json.loads(event["extra_json"]) == {"raw_type": 9999}


# ---------------------------------------------------------------------------
# text / media payloads
# ---------------------------------------------------------------------------

def test_media_types_get_placeholder_text():
    for raw_type, placeholder in ((3, "[image]"), (34, "[voice]"), (43, "[video]"), (47, "[emoji]"), (49, "[redpacket]")):
        event = map_msg_wrap(make_wrap(m_uiMessageType=raw_type, m_nsContent="ignored"))
        assert event["text"] == placeholder


def test_text_message_keeps_content():
    event = map_msg_wrap(make_wrap(m_uiMessageType=1, m_nsContent="ping"))
    assert event["text"] == "ping"


# ---------------------------------------------------------------------------
# chat kind / id derivation
# ---------------------------------------------------------------------------

def test_group_chat_kind_from_at_chatroom_suffix():
    event = map_msg_wrap(make_wrap(m_nsToUsr="room9@chatroom"))
    assert event["chat_kind"] == "group"
    assert event["chat_id"] == "room9@chatroom"


def test_dm_chat_kind_without_at_chatroom_suffix():
    event = map_msg_wrap(make_wrap(m_nsToUsr="wxid_friend"))
    assert event["chat_kind"] == "dm"
    assert event["chat_id"] == "wxid_friend"


# ---------------------------------------------------------------------------
# failure path — missing m_uiMesLocalID rejects the event
# ---------------------------------------------------------------------------

def test_missing_m_ui_mes_local_id_event_rejected():
    wrap = dict(make_wrap())
    del wrap["m_uiMesLocalID"]
    assert map_msg_wrap(wrap) is None


def test_none_m_ui_mes_local_id_event_rejected():
    assert map_msg_wrap(make_wrap(m_uiMesLocalID=None)) is None


def test_empty_to_user_still_maps_but_without_at_chatroom_is_dm():
    event = map_msg_wrap(make_wrap(m_nsToUsr="", m_uiMesLocalID=7))
    assert event is not None
    assert event["chat_id"] == ""
    assert event["chat_kind"] == "dm"


# ---------------------------------------------------------------------------
# schema conformance
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "raw_type",
    [1, 3, 34, 43, 47, 49, 10000, 10002, 9999],
)
def test_mapped_event_validates_against_event_schema(raw_type):
    """Every mapped event (happy + raw) validates against store/event.schema.json."""
    event = map_msg_wrap(make_wrap(m_uiMessageType=raw_type))
    assert event is not None
    jsonschema.validate(event, _schema())
