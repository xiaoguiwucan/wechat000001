"""Inbox consumer tests for wechat-ingest (todo 5, TDD).

Locks store/consumer.py BEFORE the daemon (todo 6) and CLI (todo 7) exist.
Covers the happy path (text + image fixtures land in per-chat JSONL and the
SQLite index, media is copied to its recorded media_path), idempotent replay
(the same inbox payload delivered twice yields exactly one SQLite row via
UNIQUE(chat_id, msg_id) + INSERT OR IGNORE), crash recovery (a stale
inbox/.processing/<uuid>.json claim left by a mid-way crash is re-consumed
on the next run without duplicating rows), and the failure path (truncated /
schema-invalid json is moved to inbox/failed/ with SQLite and JSONL
untouched).  Tests use an explicit temp root; WECHAT_INGEST_ROOT is covered
separately.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from pathlib import Path

import jsonschema
import pytest

import consumer
import media

EVENT_SCHEMA_JSON = Path(__file__).resolve().parent / "event.schema.json"

TEXT_EVENT = {
    "chat_id": "room1",
    "chat_kind": "group",
    "msg_id": "g-1",
    "msg_type": "text",
    "sender": "wxid_a",
    "ts": 1720000001,
    "text": "hello world",
    "media_path": None,
    "extra_json": None,
}

IMAGE_EVENT = {
    "chat_id": "room1",
    "chat_kind": "group",
    "msg_id": "g-2",
    "msg_type": "image",
    "sender": "wxid_a",
    "ts": 1720000002,
    "text": "[image]",
    "media_path": None,
    "extra_json": None,
}

DM_EVENT = {
    "chat_id": "d1",
    "chat_kind": "dm",
    "msg_id": "d-1",
    "msg_type": "text",
    "sender": "wxid_d",
    "ts": 1720000003,
    "text": "dm hello",
    "media_path": None,
    "extra_json": None,
}


def _new_uuid() -> str:
    return uuid.uuid4().hex


def place_event(root: Path, event: dict, *, media_bytes: bytes | None = None) -> tuple[Path, str]:
    """Write one event into ``inbox/`` as ``<uuid>.json`` plus an optional
    ``<uuid>.bin`` media file next to it.  Returns ``(json_path, uuid_stem)``."""
    stem = _new_uuid()
    inbox = root / consumer.DIR_INBOX
    inbox.mkdir(parents=True, exist_ok=True)
    json_path = inbox / f"{stem}.json"
    json_path.write_text(json.dumps(event), encoding="utf-8")
    if media_bytes is not None:
        (inbox / f"{stem}.bin").write_bytes(media_bytes)
    return json_path, stem


def _conn(root: Path) -> sqlite3.Connection:
    return sqlite3.connect(root / consumer.FILE_INDEX)


def row_count(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]


def fetch_row(conn: sqlite3.Connection, msg_id: str) -> sqlite3.Row:
    return conn.execute("SELECT * FROM events WHERE msg_id = ?", (msg_id,)).fetchone()


def jsonl_lines(root: Path, chat_kind: str, chat_id: str) -> list[dict]:
    path = root / (consumer.DIR_GROUPS if chat_kind == "group" else consumer.DIR_DMS) / chat_id / consumer.FILE_EVENTS
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


@pytest.fixture()
def root(tmp_path: Path) -> Path:
    return tmp_path / "wechat-ingest"


# ------------------------------------------------------------ happy path

def test_consume_text_event_lands_in_jsonl_and_sqlite(root: Path) -> None:
    place_event(root, TEXT_EVENT)
    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        assert row_count(conn) == 1
        row = fetch_row(conn, "g-1")
        assert (row[0], row[1], row[4], row[5], row[6]) == ("room1", "group", "wxid_a", 1720000001, "hello world")
    finally:
        conn.close()

    lines = jsonl_lines(root, "group", "room1")
    assert len(lines) == 1 and lines[0]["msg_id"] == "g-1"
    assert list((root / consumer.DIR_INBOX).glob("*.json")) == []  # inbox json unlinked


def test_group_and_dm_events_land_in_separate_chat_dirs(root: Path) -> None:
    place_event(root, TEXT_EVENT)
    place_event(root, DM_EVENT)
    assert consumer.consume_inbox(root) == (2, 0)

    assert (root / consumer.DIR_GROUPS / "room1" / consumer.FILE_EVENTS).is_file()
    assert (root / consumer.DIR_DMS / "d1" / consumer.FILE_EVENTS).is_file()
    conn = _conn(root)
    try:
        assert row_count(conn) == 2
    finally:
        conn.close()


def test_wipe_imported_removes_chats_and_index(root: Path) -> None:
    place_event(root, TEXT_EVENT)
    place_event(root, DM_EVENT)
    assert consumer.consume_inbox(root) == (2, 0)
    assert (root / consumer.DIR_GROUPS).is_dir()
    assert (root / consumer.FILE_INDEX).is_file()

    inbox = root / consumer.DIR_INBOX
    (inbox / "wipe.json").write_text(json.dumps({"cmd": "wipe_imported", "role": "control"}), encoding="utf-8")
    assert consumer.consume_inbox(root) == (1, 0)
    assert not (root / consumer.DIR_GROUPS).exists()
    assert not (root / consumer.DIR_DMS).exists()
    assert not (root / consumer.FILE_INDEX).exists()


def test_history_jsonl_pack_ingests_all_rows(root: Path) -> None:
    inbox = root / consumer.DIR_INBOX
    inbox.mkdir(parents=True)
    media_dir = inbox / consumer.DIR_HIST_MEDIA / "abcd" / "Img"
    media_dir.mkdir(parents=True)
    (media_dir / "2.pic").write_bytes(b"\x89PNG\r\n\x1a\nxxxx")
    lines = [
        json.dumps({
            "cmd": "history_jsonl",
            "chat_id": "room1@chatroom",
            "chat_kind": "group",
            "chat_name": "测试群",
            "self_wxid": "wxid_me",
            "media_key": "abcd",
        }, ensure_ascii=False),
        json.dumps({"lid": 1, "type": 1, "msg": "wxid_a:\nhi", "ts": 10, "des": 0}),
        json.dumps({"lid": 2, "type": 3, "msg": "", "ts": 11, "des": 0}),
        json.dumps({"lid": "bad", "type": 1, "msg": "x", "ts": 12, "des": 0}),
        json.dumps({"end": True, "rows": 3}),
    ]
    # one bad row: lid "bad" still maps (str lid is ok). use missing lid instead
    lines[3] = json.dumps({"type": 1, "msg": "orphan", "ts": 12, "des": 0})
    (inbox / "wxhist-pack.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    assert consumer.consume_inbox(root) == (1, 0)
    conn = _conn(root)
    try:
        assert row_count(conn) == 2
    finally:
        conn.close()
    assert len(jsonl_lines(root, "group", "测试群")) == 2
    failed = list((inbox / consumer.DIR_FAILED).glob("history-row-*.json"))
    assert len(failed) == 1


def test_late_hist_media_attaches_after_jsonl(root: Path) -> None:
    inbox = root / consumer.DIR_INBOX
    inbox.mkdir(parents=True)
    lines = [
        json.dumps({
            "cmd": "history_jsonl",
            "chat_id": "room1@chatroom",
            "chat_kind": "group",
            "chat_name": "测试群",
            "self_wxid": "wxid_me",
            "media_key": "abcd",
        }, ensure_ascii=False),
        json.dumps({"lid": 2, "type": 3, "msg": "", "ts": 11, "des": 0}),
        json.dumps({"end": True, "rows": 1}),
    ]
    pack = inbox / "wxhist-pack.jsonl"
    pack.write_text("\n".join(lines) + "\n", encoding="utf-8")
    assert consumer.consume_history_jsonl(root, inbox, pack, inbox / consumer.DIR_FAILED) == 1
    conn = _conn(root)
    try:
        assert conn.execute("SELECT media_path FROM events WHERE msg_id='2'").fetchone()[0] in (None, "")
    finally:
        conn.close()
    key = __import__("hashlib").md5(b"room1@chatroom").hexdigest()
    img = inbox / consumer.DIR_HIST_MEDIA / key / "Img"
    img.mkdir(parents=True)
    (img / "2.pic").write_bytes(b"\x89PNG\r\n\x1a\nxxxx")
    consumer.consume_inbox(root)
    conn = _conn(root)
    try:
        path = conn.execute("SELECT media_path FROM events WHERE msg_id='2'").fetchone()[0]
    finally:
        conn.close()
    assert path
    assert (root / path).is_file()


def test_history_jsonl_without_end_is_left_for_retry(root: Path) -> None:
    inbox = root / consumer.DIR_INBOX
    inbox.mkdir(parents=True)
    body = json.dumps({"cmd": "history_jsonl", "chat_id": "r@chatroom", "chat_kind": "group"}) + "\n"
    body += json.dumps({"lid": 1, "type": 1, "msg": "hi", "ts": 1, "des": 0}) + "\n"
    path = inbox / "wxhist-partial.jsonl"
    path.write_text(body, encoding="utf-8")
    assert consumer.consume_inbox(root) == (0, 0)
    assert path.is_file()


def test_history_batch_ingests_rows_and_media(root: Path) -> None:
    inbox = root / consumer.DIR_INBOX
    media_dir = inbox / consumer.DIR_HIST_MEDIA / "abcd"
    (media_dir / "Img").mkdir(parents=True)
    (media_dir / "Img" / "2.pic").write_bytes(b"\x89PNG\r\n\x1a\nxxxx")
    batch = {
        "cmd": "history_batch",
        "chat_id": "room1@chatroom",
        "chat_kind": "group",
        "chat_name": "测试群",
        "self_wxid": "wxid_me",
        "media_key": "abcd",
        "rows": [
            {"lid": 1, "type": 1, "msg": "wxid_a:\nhi", "ts": 10, "des": 0},
            {"lid": 2, "type": 3, "msg": "", "ts": 11, "des": 0},
        ],
    }
    (inbox / "batch.json").write_text(json.dumps(batch, ensure_ascii=False), encoding="utf-8")
    assert consumer.consume_inbox(root) == (1, 0)
    conn = _conn(root)
    try:
        assert row_count(conn) == 2
        types = {r[0] for r in conn.execute("SELECT msg_type FROM events")}
        assert types == {"text", "image"}
        img = conn.execute("SELECT media_path FROM events WHERE msg_id = '2'").fetchone()[0]
    finally:
        conn.close()
    assert img
    assert (root / img).is_file()
    lines = jsonl_lines(root, "group", "测试群")
    assert len(lines) == 2


def test_failed_wipe_is_replayed(root: Path) -> None:
    place_event(root, TEXT_EVENT)
    assert consumer.consume_inbox(root) == (1, 0)
    assert (root / consumer.DIR_GROUPS).is_dir()
    failed = root / consumer.DIR_INBOX / consumer.DIR_FAILED
    failed.mkdir(parents=True, exist_ok=True)
    (failed / "old-wipe.json").write_text(
        json.dumps({"cmd": "wipe_imported", "role": "control", "ts": 1}),
        encoding="utf-8",
    )
    assert consumer.consume_inbox(root) == (1, 0)
    assert not (root / consumer.DIR_GROUPS).exists()
    assert not (root / consumer.FILE_INDEX).exists()


def test_media_file_copied_and_exists_at_media_path(root: Path) -> None:
    media_bytes = b"\x89PNG\r\n\x1a\n fake image bytes"
    _, stem = place_event(root, IMAGE_EVENT, media_bytes=media_bytes)
    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        media_path = conn.execute("SELECT media_path FROM events WHERE msg_id = 'g-2'").fetchone()[0]
    finally:
        conn.close()
    assert media_path == f"{consumer.DIR_GROUPS}/room1/{media.DIR_IMAGES}/{stem}.bin"
    assert (root / media_path).is_file()  # media file exists at media_path
    assert (root / media_path).read_bytes() == media_bytes

    line = jsonl_lines(root, "group", "room1")[0]
    assert line["media_path"] == media_path
    assert not list((root / consumer.DIR_INBOX).glob(f"{stem}.*"))  # inbox json + media unlinked


# --------------------------------------------------- idempotency / crash

def test_media_arriving_after_skip_updates_sqlite_row(root: Path) -> None:
    skip = dict(IMAGE_EVENT)
    skip["extra_json"] = json.dumps({"media_skip": "media not found after download (miss)"})
    place_event(root, skip)
    assert consumer.consume_inbox(root) == (1, 0)

    media_bytes = b"\x89PNG\r\n\x1a\n upgraded"
    _, stem = place_event(root, IMAGE_EVENT, media_bytes=media_bytes)
    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        assert row_count(conn) == 1
        media_path = conn.execute("SELECT media_path FROM events WHERE msg_id = 'g-2'").fetchone()[0]
    finally:
        conn.close()
    assert media_path == f"{consumer.DIR_GROUPS}/room1/{media.DIR_IMAGES}/{stem}.bin"
    assert (root / media_path).read_bytes() == media_bytes


def test_replay_same_inbox_json_twice_yields_one_row(root: Path) -> None:
    path, stem = place_event(root, TEXT_EVENT)
    raw = path.read_text(encoding="utf-8")
    assert consumer.consume_inbox(root) == (1, 0)

    # Replay: the exact same inbox json is dropped into inbox/ again.
    (root / consumer.DIR_INBOX / f"{stem}.json").write_text(raw, encoding="utf-8")
    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        assert row_count(conn) == 1  # UNIQUE(chat_id, msg_id) keeps it idempotent
    finally:
        conn.close()
    assert len(jsonl_lines(root, "group", "room1")) == 1


def test_crash_leftover_processing_claim_is_reconsumed(root: Path) -> None:
    # Simulate a crash mid-way: the inbox json was atomically claimed into
    # inbox/.processing/ but never finished (no jsonl append, no row, no unlink).
    stem = _new_uuid()
    processing = root / consumer.DIR_INBOX / ".processing"
    processing.mkdir(parents=True, exist_ok=True)
    (processing / f"{stem}.json").write_text(json.dumps(TEXT_EVENT), encoding="utf-8")

    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        assert row_count(conn) == 1
    finally:
        conn.close()
    assert list(processing.glob("*.json")) == []
    assert (root / consumer.DIR_GROUPS / "room1" / consumer.FILE_EVENTS).is_file()


# ---------------------------------------------------------- failure path

def test_fresh_truncated_json_is_left_for_retry(root: Path) -> None:
    stem = _new_uuid()
    inbox = root / consumer.DIR_INBOX
    inbox.mkdir(parents=True)
    bad = inbox / f"{stem}.json"
    bad.write_text('{"chat_id": "room1", "msg_id": "g-partial"', encoding="utf-8")
    assert consumer.consume_inbox(root) == (0, 0)
    assert bad.is_file()
    assert not (inbox / consumer.DIR_FAILED / f"{stem}.json").exists()


def test_stale_truncated_json_moved_to_failed(root: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    stem = _new_uuid()
    inbox = root / consumer.DIR_INBOX
    inbox.mkdir(parents=True)
    bad = inbox / f"{stem}.json"
    bad.write_text('{"chat_id": "room1", "msg_id": "g-old"', encoding="utf-8")
    monkeypatch.setattr(consumer.time, "time", lambda: bad.stat().st_mtime + 30)
    assert consumer.consume_inbox(root) == (0, 1)
    assert (inbox / consumer.DIR_FAILED / f"{stem}.json").is_file()


def test_truncated_json_moved_to_failed_sqlite_unchanged(root: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    place_event(root, TEXT_EVENT)  # seed one good row so "unchanged" is provable
    assert consumer.consume_inbox(root) == (1, 0)

    stem = _new_uuid()
    bad = root / consumer.DIR_INBOX / f"{stem}.json"
    bad.write_text('{"chat_id": "room1", "msg_id": "g-x", "msg_type": "text", "sender": "wxid_a"', encoding="utf-8")
    monkeypatch.setattr(consumer.time, "time", lambda: bad.stat().st_mtime + 30)

    assert consumer.consume_inbox(root) == (0, 1)

    assert (root / consumer.DIR_INBOX / consumer.DIR_FAILED / f"{stem}.json").is_file()
    assert not bad.exists()  # original unlinked from inbox/
    conn = _conn(root)
    try:
        assert row_count(conn) == 1  # SQLite unchanged
    finally:
        conn.close()
    assert len(jsonl_lines(root, "group", "room1")) == 1  # JSONL unchanged


def test_schema_invalid_event_moved_to_failed(root: Path) -> None:
    bad = {k: v for k, v in TEXT_EVENT.items() if k != "msg_id"}
    place_event(root, bad)
    assert consumer.consume_inbox(root) == (0, 1)
    assert len(list((root / consumer.DIR_INBOX / consumer.DIR_FAILED).glob("*.json"))) == 1
    assert not (root / consumer.FILE_INDEX).exists()  # nothing reached the DB


def test_chat_id_with_path_separator_rejected(root: Path) -> None:
    ev = dict(TEXT_EVENT)
    ev["msg_id"] = "g-evil"
    ev["chat_id"] = "../escape"
    place_event(root, ev)
    assert consumer.consume_inbox(root) == (0, 1)
    assert not (root / consumer.DIR_GROUPS / ".." / "escape").exists()
    assert not (root / consumer.FILE_INDEX).exists()


# -------------------------------------------------------- normalization

def test_unknown_msg_type_normalized_to_raw(root: Path) -> None:
    ev = dict(TEXT_EVENT)
    ev["msg_id"] = "g-raw"
    ev["msg_type"] = "mystery_type_99"
    place_event(root, ev)
    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        assert conn.execute("SELECT msg_type FROM events WHERE msg_id = 'g-raw'").fetchone()[0] == "raw"
    finally:
        conn.close()
    assert jsonl_lines(root, "group", "room1")[0]["msg_type"] == "raw"


def test_jsonl_lines_validate_against_event_schema(root: Path) -> None:
    place_event(root, TEXT_EVENT)
    place_event(root, IMAGE_EVENT, media_bytes=b"img")
    assert consumer.consume_inbox(root) == (2, 0)

    schema = json.loads(EVENT_SCHEMA_JSON.read_text(encoding="utf-8"))
    for line in jsonl_lines(root, "group", "room1"):
        jsonschema.validate(line, schema)


# ------------------------------------------------------------ root config

def test_default_root_reads_wechat_ingest_root(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    custom = tmp_path / "custom-root"
    monkeypatch.setenv("WECHAT_INGEST_ROOT", str(custom))
    assert consumer.default_root() == custom


def test_empty_inbox_is_noop(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    assert consumer.consume_inbox(root) == (0, 0)


def test_unknown_top_level_fields_are_ignored(root: Path) -> None:
    ev = dict(TEXT_EVENT)
    ev["msg_id"] = "g-extra"
    ev["is_at_me"] = True
    ev["debug"] = "nope"
    place_event(root, ev)
    assert consumer.consume_inbox(root) == (1, 0)
    line = jsonl_lines(root, "group", "room1")[0]
    assert line["msg_id"] == "g-extra"
    assert "is_at_me" not in line
    assert "debug" not in line


def test_is_self_bool_is_kept(root: Path) -> None:
    ev = dict(TEXT_EVENT)
    ev["msg_id"] = "g-me"
    ev["is_self"] = True
    place_event(root, ev)
    assert consumer.consume_inbox(root) == (1, 0)
    assert jsonl_lines(root, "group", "room1")[0]["is_self"] is True


def test_voice_consume_does_not_call_asr(root: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    called = {"asr": 0}

    def boom(_src):
        called["asr"] += 1
        raise AssertionError("ASR must not run in the inbox hot path")

    monkeypatch.setattr("transcribe.transcribe_file", boom, raising=False)
    ev = dict(TEXT_EVENT)
    ev["msg_id"] = "g-voice"
    ev["msg_type"] = "voice"
    ev["text"] = "[voice]"
    place_event(root, ev, media_bytes=b"\x02#!SILK_V3fake")
    assert consumer.consume_inbox(root) == (1, 0)
    assert called["asr"] == 0
    assert jsonl_lines(root, "group", "room1")[0]["msg_type"] == "voice"
