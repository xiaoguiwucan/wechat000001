"""End-to-end ingest fixture — todo 18: phone-shaped events → store → no DM reply.

Feeds a scripted WeChat stream through the REAL policy + store pipeline with
zero hardware — no phone, no network, no gpt-line/LLM:

    CMessageWrap field dict (phone shape)
      → ``map_msg_wrap``            (todo-10 mapping contract)
      → ``ingest_policy.decide``    (todo-11 ingest / reply decision)
      → ``reply_routing.openclaw_chat_request``  (todo-13, reply pipe only)
      → ``send_gate.canSendReply``  (todo-14, DM/self hard-disable)
      → ``SftpInboxTransporter.drop`` over a fake SFTP transport (todo-12)
      → ``consumer.consume_inbox`` into ``groups|dms/<id>/events.jsonl`` +
        ``index.sqlite`` (todo-5), with ``media.decide_media`` for the image
        (todo-15).

The scripted stream is the plan's todo-18 list verbatim: group text, group @,
DM text, DM @, revoke, image, self msg. The reply flag is folded into each
event's ``extra_json`` (the store column schema.sql documents for the reply
flag) before the drop, so both the JSONL log and SQLite carry it.

Assertions (the plan's QA contract):

- every message lands as exactly one SQLite row — 7 rows,
  ``consume_inbox == (7, 0)``;
- the directory layout is ``groups/<chat_id>/events.jsonl`` and
  ``dms/<chat_id>/events.jsonl``, with line counts matching the stream;
- exactly ONE stored event carries ``reply=True`` — the whitelisted group
  message that @'s the bot — and every DM (including the DM-@), self-message,
  revoke and image stays ``reply=False``;
- a DM is always ingested but never replies: ``decide`` never returns
  reply=True for it, ``openclaw_chat_request`` returns None, and
  ``canSendReply("dm", ...)`` is False even when a ``reply=True`` is injected
  into the stored DM event — the injection FAILS the test by construction
  (QA failure mode: "injecting a DM reply=True fails the test").

Every stage is an in-process fixture (``FakeSftpTransport`` from
``store/test_sftp_inbox.py`` + local SQLite), so the suite is deterministic.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

import consumer
from consumer import consume_inbox
from ingest_policy import decide
from reply_routing import openclaw_chat_request
from send_gate import canSendReply
from sftp_inbox import SftpConfig, SftpInboxTransporter
from test_msgwrap_map import make_wrap, map_msg_wrap
from test_sftp_inbox import FakeSftpTransport

GROUP_ID = "room1@chatroom"
DM_ID = "wxid_friend"
REMOTE_ROOT = "wechat-ingest"

# Image body dropped beside the inbox json — exercises the todo-15 media store.
IMAGE_BYTES = b"\x89PNG\r\n\x1a\nfake-image-bytes"


def make_config(**overrides):
    config = {
        "group_whitelist": [GROUP_ID],
        "dm_whitelist": [DM_ID],
        "command_prefix": "/oc",
        "enabled_at": 1700000000,
    }
    config.update(overrides)
    return config


# (label, wrap overrides, is_at_me, is_self) — the todo-18 scripted stream.
STREAM = [
    (
        "group text",
        {"m_nsToUsr": GROUP_ID, "m_nsContent": "hello everyone", "m_uiMessageType": 1, "m_uiMesLocalID": 101},
        False,
        False,
    ),
    (
        "group @",
        {"m_nsToUsr": GROUP_ID, "m_nsContent": "@bot 今天怎样", "m_uiMessageType": 1, "m_uiMesLocalID": 102},
        True,
        False,
    ),
    (
        "dm text",
        {"m_nsToUsr": DM_ID, "m_nsContent": "hi there", "m_uiMessageType": 1, "m_uiMesLocalID": 103},
        False,
        False,
    ),
    (
        "dm @",
        {"m_nsToUsr": DM_ID, "m_nsContent": "@bot help me", "m_uiMessageType": 1, "m_uiMesLocalID": 104},
        True,
        False,
    ),
    (
        "revoke",
        {
            "m_nsToUsr": GROUP_ID,
            "m_nsContent": '<sysmsg type="revokemsg"><revokemsg>...</revokemsg></sysmsg>',
            "m_uiMessageType": 10002,
            "m_uiMesLocalID": 105,
        },
        False,
        False,
    ),
    (
        "image",
        {"m_nsToUsr": GROUP_ID, "m_nsContent": "", "m_uiMessageType": 3, "m_uiMesLocalID": 106},
        False,
        False,
    ),
    (
        "self msg",
        {"m_nsToUsr": GROUP_ID, "m_nsContent": "I typed this myself", "m_uiMessageType": 1, "m_uiMesLocalID": 107},
        False,
        True,
    ),
]


def decide_event(wrap: dict, config: dict, *, is_at_me: bool = False, is_self: bool = False):
    """map → decide, folding the reply flag into ``extra_json`` (the store
    column schema.sql documents for the reply flag).

    Returns ``(store_event, decision_event, decision)``: ``store_event`` is
    what is dropped into the inbox (only the 9 schema fields, so the consumer
    accepts it); ``decision_event`` additionally carries ``is_at_me`` /
    ``is_self`` for the reply-side routers (``openclaw_chat_request`` /
    ``canSendReply``), which are never stored.
    """
    event = map_msg_wrap(wrap)
    assert event is not None  # the scripted wraps all carry m_uiMesLocalID
    decision_event = {**event, "is_at_me": is_at_me, "is_self": is_self}
    decision = decide(decision_event, config)
    payload = json.loads(event["extra_json"]) if event["extra_json"] else {}
    payload["reply"] = decision["reply"]
    event["extra_json"] = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    return event, decision_event, decision


def drop_stream(transporter, *, config=None, stream=STREAM):
    """Drop every scripted event into the fake-SFTP inbox, decorated with its
    reply flag. Returns ``{label: (store_event, decision_event, decision)}``."""
    config = config if config is not None else make_config()
    dropped = {}
    for label, overrides, is_at_me, is_self in stream:
        wrap = make_wrap(**overrides)
        store_event, decision_event, decision = decide_event(
            wrap, config, is_at_me=is_at_me, is_self=is_self
        )
        if label == "image":
            transporter.drop(store_event, media_bytes=IMAGE_BYTES, media_suffix=".png")
        else:
            transporter.drop(store_event)
        dropped[label] = (store_event, decision_event, decision)
    return dropped


@pytest.fixture()
def ingested(tmp_path: Path):
    """Run the full fixture once: scripted stream → fake SFTP → consumer.

    Returns ``(root, dropped, rows)`` where ``root`` is the ingest root,
    ``dropped`` is the ``drop_stream`` map, and ``rows`` is every SQLite
    ``events`` row as a dict, ordered by ``msg_id``.
    """
    config = make_config()
    base = tmp_path / "sftp-base"
    fake = FakeSftpTransport(base)
    transporter = SftpInboxTransporter(
        config=SftpConfig(host="127.0.0.1", port=22, user="tester", password="pw"),
        root=REMOTE_ROOT,
        transport=fake,
        max_attempts=3,
        retry_delay=0.0,
    )
    try:
        dropped = drop_stream(transporter, config=config)
    finally:
        transporter.close()

    root = base / REMOTE_ROOT
    consumed, failed = consume_inbox(root)
    assert (consumed, failed) == (7, 0)

    conn = sqlite3.connect(root / consumer.FILE_INDEX)
    conn.row_factory = sqlite3.Row
    try:
        rows = [
            dict(row)
            for row in conn.execute(
                "SELECT chat_id, chat_kind, msg_id, msg_type, sender, ts, text, "
                "media_path, extra_json FROM events ORDER BY msg_id"
            ).fetchall()
        ]
    finally:
        conn.close()
    return root, dropped, rows


def _reply_flag(row: dict) -> bool:
    return json.loads(row["extra_json"])["reply"]


# ---------------------------------------------------------------------------
# SQLite rows + directory layout
# ---------------------------------------------------------------------------


def test_all_seven_events_land_in_sqlite_and_layout(ingested):
    """Acceptance: 7 events stored, `groups/<id>/events.jsonl` +
    `dms/<id>/events.jsonl` layout, inbox drained."""
    root, _dropped, rows = ingested
    assert len(rows) == 7

    expected = {
        "101": ("group", GROUP_ID, "text"),
        "102": ("group", GROUP_ID, "text"),
        "103": ("dm", DM_ID, "text"),
        "104": ("dm", DM_ID, "text"),
        "105": ("group", GROUP_ID, "revoke"),
        "106": ("group", GROUP_ID, "image"),
        "107": ("group", GROUP_ID, "text"),
    }
    for row in rows:
        kind, chat_id, msg_type = expected[row["msg_id"]]
        assert (row["chat_kind"], row["chat_id"], row["msg_type"]) == (kind, chat_id, msg_type)

    group_log = root / consumer.DIR_GROUPS / GROUP_ID / consumer.FILE_EVENTS
    dm_log = root / consumer.DIR_DMS / DM_ID / consumer.FILE_EVENTS
    assert group_log.is_file()
    assert dm_log.is_file()
    assert len(group_log.read_text(encoding="utf-8").splitlines()) == 5
    assert len(dm_log.read_text(encoding="utf-8").splitlines()) == 2

    # every JSONL line matches its SQLite row (msg_id + reply flag)
    for log in (group_log, dm_log):
        for line in log.read_text(encoding="utf-8").splitlines():
            line_event = json.loads(line)
            row = next(r for r in rows if r["msg_id"] == line_event["msg_id"])
            assert line_event["chat_kind"] == row["chat_kind"]
            assert line_event["extra_json"] == row["extra_json"]
            assert json.loads(line_event["extra_json"]).get("reply") == _reply_flag(row)

    assert not list((root / consumer.DIR_INBOX).glob("*.json"))  # every inbox json consumed


def test_image_media_body_is_copied_into_group_media(ingested):
    """The image's media file lands under groups/<id>/media/ with a path row."""
    root, _dropped, rows = ingested
    image_row = next(row for row in rows if row["msg_id"] == "106")
    assert image_row["msg_type"] == "image"
    assert image_row["media_path"].startswith(f"{consumer.DIR_GROUPS}/{GROUP_ID}/图片/")
    assert (root / image_row["media_path"]).read_bytes() == IMAGE_BYTES


# ---------------------------------------------------------------------------
# reply flags — only the group-@ item is reply=True
# ---------------------------------------------------------------------------


def test_only_group_at_is_marked_reply_true(ingested):
    """Exactly one stored event carries reply=True: the whitelisted group @."""
    _root, _dropped, rows = ingested
    flagged = {row["msg_id"] for row in rows if _reply_flag(row) is True}
    assert flagged == {"102"}

    by_id = {row["msg_id"]: row for row in rows}
    assert by_id["102"]["chat_kind"] == "group"
    assert by_id["102"]["chat_id"] == GROUP_ID

    # every DM (including the DM-@) is ingested but reply=False
    for msg_id in ("103", "104"):
        assert by_id[msg_id]["chat_kind"] == "dm"
        assert _reply_flag(by_id[msg_id]) is False
    # revoke / image / self msg all reply=False
    for msg_id in ("105", "106", "107"):
        assert _reply_flag(by_id[msg_id]) is False


# ---------------------------------------------------------------------------
# reply-side routers never fire outside the group-@ item
# ---------------------------------------------------------------------------


def test_openclaw_chat_request_only_for_group_at(ingested):
    """openclaw_chat_request builds a protocol-3 request for the group-@ only;
    every other event (DM, self, revoke, image, plain text) gets None — no
    OpenClaw session is ever opened."""
    _root, dropped, _rows = ingested
    config = make_config()
    for label, (_store_event, decision_event, decision) in dropped.items():
        request = openclaw_chat_request(decision_event, config)
        if label == "group @":
            assert decision["reply"] is True
            assert request is not None
            assert request["session_key"] == GROUP_ID
            assert request["hello"]["protocol"] == 3
            assert request["text"] == "@bot 今天怎样"
        else:
            assert decision["reply"] is False
            assert request is None


def test_send_gate_only_opens_for_non_self_group(ingested):
    """canSendReply is False for every DM and self-message; a non-self group
    opens the gate. The @-trigger is enforced UPSTREAM by ``decide`` (todo-11)
    — so the gate alone never sends: gate+decision fires only for the group-@
    item, while a plain group text opens the gate but stays ingest-only."""
    _root, dropped, _rows = ingested
    config = make_config()
    for label, (_store_event, decision_event, decision) in dropped.items():
        is_self = decision_event["is_self"]
        gate = canSendReply(decision_event["chat_kind"], is_self, config)
        if label in ("dm text", "dm @", "self msg"):
            assert gate is False
        else:  # every non-self group event (incl. revoke/image) opens the gate
            assert gate is True
        # gate + reply decision together fire exactly once, for the group-@
        assert (decision["reply"] and gate) is (label == "group @")


# ---------------------------------------------------------------------------
# QA failure mode — injecting a DM reply=True fails the test
# ---------------------------------------------------------------------------


def test_injecting_dm_reply_true_fails_the_test(ingested):
    """QA failure mode: a DM reply=True cannot survive the pipeline.

    A DM is always ingested, but every reply boundary refuses it — even when
    ``reply=True`` is injected straight into the stored event's ``extra_json``:

    - ``decide`` never returns reply=True for a DM (even with an @-mention),
    - ``openclaw_chat_request`` returns None (no OpenClaw session),
    - ``canSendReply("dm", ...)`` is False (the todo-14 hard-disable).

    Were any layer to start honoring a DM reply, one of these assertions fails
    and the test fails loudly — the plan's "injecting a DM reply=True fails
    the test".
    """
    _root, dropped, rows = ingested
    config = make_config()

    dm_at = dropped["dm @"][1]  # decision_event (carries is_at_me/is_self)
    assert dm_at["chat_kind"] == "dm"
    assert decide(dm_at, config) == {"ingest": True, "reply": False}
    assert openclaw_chat_request(dm_at, config) is None
    assert canSendReply("dm", isSelf=False, policy=config) is False

    # no stored DM row carries reply=True
    for row in rows:
        if row["chat_kind"] == "dm":
            assert _reply_flag(row) is False

    # injecting reply=True into the stored DM event still cannot reach a send
    injected = {**dm_at, "extra_json": json.dumps({"reply": True}, sort_keys=True)}
    assert openclaw_chat_request(injected, config) is None
    assert canSendReply(injected["chat_kind"], injected["is_self"], config) is False
