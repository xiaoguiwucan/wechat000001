"""Schema contract tests for the wechat-ingest store (todo 2).

Locks store/schema.sql and store/event.schema.json BEFORE any consumer is
written.  Fixture events cover text / image / voice / video / redpacket /
revoke / announcement / unknown->raw.  The schema enforces
chat_kind IN ('group','dm'), UNIQUE(chat_id, msg_id), and the test helper
rejects events with a missing msg_id and normalizes unknown msg types to
'raw' (never drops an event).
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import jsonschema
import pytest

STORE_DIR = Path(__file__).resolve().parent
SCHEMA_SQL = STORE_DIR / "schema.sql"
EVENT_SCHEMA_JSON = STORE_DIR / "event.schema.json"

# Exact column list mandated by the plan (name, declared type).
EXPECTED_COLUMNS = [
    ("chat_id", "TEXT"),
    ("chat_kind", "TEXT"),
    ("msg_id", "TEXT"),
    ("msg_type", "TEXT"),
    ("sender", "TEXT"),
    ("ts", "INTEGER"),
    ("text", "TEXT"),
    ("media_path", "TEXT"),
    ("extra_json", "TEXT"),
]

KNOWN_MSG_TYPES = {"text", "image", "voice", "video", "redpacket", "revoke", "announcement"}

INSERT_SQL = (
    "INSERT INTO events (chat_id, chat_kind, msg_id, msg_type, sender, ts, "
    "text, media_path, extra_json) "
    "VALUES (:chat_id, :chat_kind, :msg_id, :msg_type, :sender, :ts, :text, "
    ":media_path, :extra_json)"
)

FIXTURE_EVENTS: list[dict[str, object]] = [
    # text
    {
        "chat_id": "room1", "chat_kind": "group", "msg_id": "g-1", "msg_type": "text",
        "sender": "wxid_a", "ts": 1720000001, "text": "hello world",
        "media_path": None, "extra_json": None,
    },
    # image
    {
        "chat_id": "room1", "chat_kind": "group", "msg_id": "g-2", "msg_type": "image",
        "sender": "wxid_a", "ts": 1720000002, "text": "[image]",
        "media_path": "groups/room1/media/g-2.png", "extra_json": None,
    },
    # voice (silk, no ASR)
    {
        "chat_id": "room1", "chat_kind": "group", "msg_id": "g-3", "msg_type": "voice",
        "sender": "wxid_b", "ts": 1720000003, "text": "[voice]",
        "media_path": "groups/room1/media/g-3.silk", "extra_json": None,
    },
    # video
    {
        "chat_id": "room1", "chat_kind": "group", "msg_id": "g-4", "msg_type": "video",
        "sender": "wxid_b", "ts": 1720000004, "text": "[video]",
        "media_path": "groups/room1/media/g-4.mp4", "extra_json": None,
    },
    # red packet (appmsg Type=49)
    {
        "chat_id": "room1", "chat_kind": "group", "msg_id": "g-5", "msg_type": "redpacket",
        "sender": "wxid_a", "ts": 1720000005, "text": "[redpacket]",
        "media_path": None, "extra_json": json.dumps({"hb_type": 1, "amount": "1.00"}),
    },
    # revoke (sys Type=10000/10002)
    {
        "chat_id": "room1", "chat_kind": "group", "msg_id": "g-6", "msg_type": "revoke",
        "sender": "wxid_b", "ts": 1720000006, "text": "[revoke]",
        "media_path": None, "extra_json": None,
    },
    # group announcement (sysmsg)
    {
        "chat_id": "room1", "chat_kind": "group", "msg_id": "g-7", "msg_type": "announcement",
        "sender": "wxid_c", "ts": 1720000007, "text": "New group rules",
        "media_path": None, "extra_json": None,
    },
    # unknown -> raw (recorded, never dropped)
    {
        "chat_id": "d1", "chat_kind": "dm", "msg_id": "d-1", "msg_type": "raw",
        "sender": "wxid_d", "ts": 1720000008, "text": "weird payload",
        "media_path": None, "extra_json": json.dumps({"raw_type": 99}),
    },
]


def normalize_type(msg_type: object) -> str:
    """Map a WeChat message type onto the ingest vocabulary.  Anything not
    in the known set becomes 'raw' so no event is ever dropped."""
    return msg_type if isinstance(msg_type, str) and msg_type in KNOWN_MSG_TYPES else "raw"


def insert_event(conn: sqlite3.Connection, event: dict[str, object], *, idempotent: bool = True) -> int:
    """Insert one event; returns rows changed (0 for an ignored duplicate).

    Rejects events without a msg_id before they reach the DB, normalizes
    unknown msg types to 'raw', and (idempotent mode) treats a repeated
    (chat_id, msg_id) as a no-op via INSERT OR IGNORE.
    """
    if not str(event.get("msg_id") or "").strip():
        raise ValueError("event missing msg_id")
    row = dict(event)
    row["msg_type"] = normalize_type(row["msg_type"])
    sql = INSERT_SQL if not idempotent else INSERT_SQL.replace("INSERT INTO", "INSERT OR IGNORE INTO", 1)
    cur = conn.execute(sql, row)
    conn.commit()
    return cur.rowcount


@pytest.fixture()
def conn(tmp_path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(tmp_path / "index.sqlite")
    db.executescript(SCHEMA_SQL.read_text(encoding="utf-8"))
    yield db
    db.close()


def _event_schema() -> dict[str, object]:
    return json.loads(EVENT_SCHEMA_JSON.read_text(encoding="utf-8"))


def row_count(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]


# ---------------------------------------------------------------- schema.sql

def test_schema_has_exact_columns(conn: sqlite3.Connection) -> None:
    cols = conn.execute("PRAGMA table_info(events)").fetchall()
    assert [(c[1], c[2]) for c in cols] == EXPECTED_COLUMNS


def test_schema_has_unique_chat_id_msg_id(conn: sqlite3.Connection) -> None:
    indexes = conn.execute("PRAGMA index_list(events)").fetchall()
    unique = next(i for i in indexes if i[2] == 1)  # sqlite auto-index for UNIQUE(...)
    cols = [r[2] for r in conn.execute(f"PRAGMA index_info({unique[1]})")]
    assert cols == ["chat_id", "msg_id"]


# ------------------------------------------------------------ fixture insert

def test_all_eight_fixture_types_land(conn: sqlite3.Connection) -> None:
    for ev in FIXTURE_EVENTS:
        insert_event(conn, ev)
    assert row_count(conn) == 8
    rows = conn.execute("SELECT chat_kind, msg_type FROM events ORDER BY ts").fetchall()
    assert {r[0] for r in rows} == {"group", "dm"}
    assert {r[1] for r in rows} == {"text", "image", "voice", "video", "redpacket",
                                     "revoke", "announcement", "raw"}


def test_unknown_type_stored_as_raw(conn: sqlite3.Connection) -> None:
    ev = dict(FIXTURE_EVENTS[0])
    ev["msg_id"] = "g-999"
    ev["msg_type"] = "mystery_type_99"
    insert_event(conn, ev)
    stored = conn.execute("SELECT msg_type FROM events WHERE msg_id = ?", (ev["msg_id"],)).fetchone()
    assert stored[0] == "raw"


def test_reinsert_same_msg_id_is_noop(conn: sqlite3.Connection) -> None:
    assert insert_event(conn, FIXTURE_EVENTS[0]) == 1
    assert insert_event(conn, FIXTURE_EVENTS[0]) == 0  # idempotent no-op
    assert row_count(conn) == 1


def test_duplicate_chat_id_msg_id_rejected_by_unique(conn: sqlite3.Connection) -> None:
    insert_event(conn, FIXTURE_EVENTS[0])
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(INSERT_SQL, FIXTURE_EVENTS[0])  # plain INSERT must hit UNIQUE


def test_chat_kind_room_rejected(conn: sqlite3.Connection) -> None:
    ev = dict(FIXTURE_EVENTS[0])
    ev["msg_id"] = "g-room"
    ev["chat_kind"] = "room"
    with pytest.raises(sqlite3.IntegrityError):  # CHECK(chat_kind IN ('group','dm'))
        insert_event(conn, ev, idempotent=False)
    assert row_count(conn) == 0


def test_missing_msg_id_rejected(conn: sqlite3.Connection) -> None:
    ev = {k: v for k, v in FIXTURE_EVENTS[0].items() if k != "msg_id"}
    with pytest.raises(ValueError, match="msg_id"):
        insert_event(conn, ev)
    assert row_count(conn) == 0


# ------------------------------------------------------ event.schema.json

def test_fixture_events_validate_against_event_schema() -> None:
    schema = _event_schema()
    for ev in FIXTURE_EVENTS:
        jsonschema.validate(ev, schema)


def test_event_schema_rejects_chat_kind_room() -> None:
    ev = {**FIXTURE_EVENTS[0], "chat_kind": "room"}
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(ev, _event_schema())


def test_event_schema_rejects_missing_msg_id() -> None:
    ev = {k: v for k, v in FIXTURE_EVENTS[0].items() if k != "msg_id"}
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(ev, _event_schema())


def test_event_schema_rejects_unmapped_msg_type() -> None:
    ev = {**FIXTURE_EVENTS[0], "msg_type": "mystery"}
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(ev, _event_schema())
