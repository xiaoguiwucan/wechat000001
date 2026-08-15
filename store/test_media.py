"""Media handling tests for wechat-ingest (todo 15, TDD).

Locks ``store/media.py`` — the store-side mirror of the PKC CDN/silk download
path (``pkcAutoDownloadImgOrVideo``, ``getAudioFileName:LocalID:``,
``WCDownloadVideoCDNMgr`` on the device; the fnOS consumer indexes whatever the
device drops next to the inbox json). Contract under test:

1. an image fixture's bytes are copied into ``groups/<chat>/media/`` and
   ``media_path`` records the relative path;
2. a voice fixture is stored as its silk file + placeholder text ``[voice]``
   (NO ASR — the store never transcribes, it only records what the device
   downloaded);
3. a video body larger than 2GB is stored METADATA-ONLY: the row is inserted,
   ``media_path`` stays empty and ``extra_json`` records why no body was
   copied; video bodies at/below the cap are copied;
4. a failed download (a media-typed event whose file never arrived next to the
   inbox json) still inserts its SQLite row with ``media_path`` empty and a
   ``media_error`` in ``extra_json`` — the event is NEVER dropped because its
   media is missing.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from pathlib import Path

import pytest

import consumer
import media

MAX_VIDEO_BYTES = media.MAX_VIDEO_BYTES

IMAGE_EVENT = {
    "chat_id": "room1",
    "chat_kind": "group",
    "msg_id": "g-img",
    "msg_type": "image",
    "sender": "wxid_a",
    "ts": 1720000002,
    "text": "[image]",
    "media_path": None,
    "extra_json": None,
}

VOICE_EVENT = {
    "chat_id": "room1",
    "chat_kind": "group",
    "msg_id": "g-voice",
    "msg_type": "voice",
    "sender": "wxid_a",
    "ts": 1720000004,
    "text": None,  # the store must normalize a missing voice text to "[voice]"
    "media_path": None,
    "extra_json": None,
}

VIDEO_EVENT = {
    "chat_id": "room1",
    "chat_kind": "group",
    "msg_id": "g-video",
    "msg_type": "video",
    "sender": "wxid_a",
    "ts": 1720000005,
    "text": "[video]",
    "media_path": None,
    "extra_json": None,
}


def _stem() -> str:
    return uuid.uuid4().hex


def place_event(root: Path, event: dict, *, media_bytes: bytes | None = None,
                media_suffix: str = ".bin") -> str:
    """Write ``inbox/<uuid>.json`` (+ optional ``inbox/<uuid><suffix>``) and
    return the uuid stem."""
    stem = _stem()
    inbox = root / consumer.DIR_INBOX
    inbox.mkdir(parents=True, exist_ok=True)
    (inbox / f"{stem}.json").write_text(json.dumps(event), encoding="utf-8")
    if media_bytes is not None:
        (inbox / f"{stem}{media_suffix}").write_bytes(media_bytes)
    return stem


def place_sparse(root: Path, event: dict, size: int, media_suffix: str = ".bin") -> str:
    """Like :func:`place_event` but creates a *size*-byte file without writing
    all of it to disk (sparse seek) — used for the >50MB video fixture."""
    stem = _stem()
    inbox = root / consumer.DIR_INBOX
    inbox.mkdir(parents=True, exist_ok=True)
    (inbox / f"{stem}.json").write_text(json.dumps(event), encoding="utf-8")
    with (inbox / f"{stem}{media_suffix}").open("wb") as fh:
        fh.seek(size - 1)
        fh.write(b"\0")
    return stem


def _conn(root: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(root / consumer.FILE_INDEX)
    conn.row_factory = sqlite3.Row
    return conn


def fetch_row(conn: sqlite3.Connection, msg_id: str) -> sqlite3.Row:
    return conn.execute("SELECT * FROM events WHERE msg_id = ?", (msg_id,)).fetchone()


def media_files(root: Path, chat_kind: str, chat_id: str) -> list[Path]:
    chat = root / (consumer.DIR_GROUPS if chat_kind == "group" else consumer.DIR_DMS) / chat_id
    out: list[Path] = []
    for sub in (media.DIR_IMAGES, media.DIR_VOICE, media.DIR_VIDEO, media.DIR_FILES, consumer.DIR_MEDIA):
        folder = chat / sub
        if folder.is_dir():
            out.extend(p for p in folder.iterdir() if p.is_file())
    return sorted(out)


@pytest.fixture()
def root(tmp_path: Path) -> Path:
    return tmp_path / "wechat-ingest"


def test_media_folder_by_type_and_ext() -> None:
    assert media.media_folder("image", "a.bin") == media.DIR_IMAGES
    assert media.media_folder("voice", "a.bin") == media.DIR_VOICE
    assert media.media_folder("video", "a.bin") == media.DIR_VIDEO
    assert media.media_folder("raw", "x.pic") == media.DIR_IMAGES
    assert media.media_folder("raw", "x.aud") == media.DIR_VOICE
    assert media.media_folder("raw", "x.mp4") == media.DIR_VIDEO
    assert media.media_folder("raw", "x.zip") == media.DIR_FILES


def test_migrate_splits_flat_media_dir(root: Path) -> None:
    chat = root / consumer.DIR_GROUPS / "值班群"
    pile = chat / consumer.DIR_MEDIA
    pile.mkdir(parents=True)
    (pile / "a.pic").write_bytes(b"pic")
    (pile / "b.aud").write_bytes(b"aud")
    (pile / "c.mp4").write_bytes(b"mp4")
    (chat / consumer.FILE_EVENTS).write_text(
        json.dumps({"media_path": "群聊/值班群/媒体/a.pic", "msg_id": "1"}, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    assert consumer.migrate_media_layout(root) == 3
    assert (chat / media.DIR_IMAGES / "a.pic").is_file()
    assert (chat / media.DIR_VOICE / "b.aud").is_file()
    assert (chat / media.DIR_VIDEO / "c.mp4").is_file()
    line = json.loads((chat / consumer.FILE_EVENTS).read_text(encoding="utf-8").splitlines()[0])
    assert line["media_path"] == "群聊/值班群/图片/a.pic"


# ------------------------------------------------------------- happy paths

def test_image_bytes_copied_to_chat_media_dir(root: Path) -> None:
    png = b"\x89PNG\r\n\x1a\n fake png bytes"
    stem = place_event(root, IMAGE_EVENT, media_bytes=png, media_suffix=".png")

    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        row = fetch_row(conn, "g-img")
        assert row["media_path"] == f"{consumer.DIR_GROUPS}/room1/{media.DIR_IMAGES}/{stem}.png"
    finally:
        conn.close()

    assert (root / f"{consumer.DIR_GROUPS}/room1/{media.DIR_IMAGES}/{stem}.png").read_bytes() == png
    assert (root / f"{consumer.DIR_GROUPS}/room1/{media.DIR_IMAGES}/{stem}.png").is_file()
    assert not list((root / consumer.DIR_INBOX).glob(f"{stem}.*"))  # inbox json + media unlinked


def test_voice_silk_stored_with_voice_placeholder_text(root: Path) -> None:
    silk = b"\x02silk_v3 fake silk payload"
    stem = place_event(root, VOICE_EVENT, media_bytes=silk, media_suffix=".silk")

    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        row = fetch_row(conn, "g-voice")
        assert row["msg_type"] == "voice"
        assert row["text"] == "[voice]"          # placeholder, never ASR-transcribed
        assert row["media_path"] == f"{consumer.DIR_GROUPS}/room1/{media.DIR_VOICE}/{stem}.silk"
    finally:
        conn.close()

    assert (root / f"{consumer.DIR_GROUPS}/room1/{media.DIR_VOICE}/{stem}.silk").read_bytes() == silk
    # the stored silk is verbatim bytes — no transcript, no ASR artifact anywhere
    assert media_files(root, "group", "room1") == [root / f"{consumer.DIR_GROUPS}/room1/{media.DIR_VOICE}/{stem}.silk"]


def test_video_below_cap_copies_body(root: Path) -> None:
    clip = b"\x00\x00\x00\x18ftypmp42 fake video bytes"
    stem = place_event(root, VIDEO_EVENT, media_bytes=clip, media_suffix=".mp4")

    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        row = fetch_row(conn, "g-video")
        assert row["media_path"] == f"{consumer.DIR_GROUPS}/room1/{media.DIR_VIDEO}/{stem}.mp4"
        assert row["extra_json"] is None  # no media_error on the happy path
    finally:
        conn.close()
    assert (root / f"{consumer.DIR_GROUPS}/room1/{media.DIR_VIDEO}/{stem}.mp4").read_bytes() == clip


# ------------------------------------------------------- large video cap

def test_video_over_cap_stores_metadata_only(root: Path) -> None:
    big_size = MAX_VIDEO_BYTES + 1
    place_sparse(root, VIDEO_EVENT, big_size, media_suffix=".mp4")

    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        row = fetch_row(conn, "g-video")
        assert row["msg_type"] == "video"
        assert row["text"] == "[video]"
        assert row["media_path"] is None
        extra = json.loads(row["extra_json"])
        assert "media_error" in extra and "2GB" in extra["media_error"]
    finally:
        conn.close()

    assert media_files(root, "group", "room1") == []
    assert not list((root / consumer.DIR_INBOX).glob("*.mp4"))


def test_video_at_exactly_cap_copies_body(root: Path) -> None:
    place_sparse(root, VIDEO_EVENT, MAX_VIDEO_BYTES, media_suffix=".mp4")
    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        row = fetch_row(conn, "g-video")
        assert row["media_path"] is not None  # at/under the cap → body copied
        assert row["extra_json"] is None
    finally:
        conn.close()
    assert len(media_files(root, "group", "room1")) == 1


# --------------------------------------------------------- failed download

def test_failed_download_still_inserts_row(root: Path) -> None:
    # image event whose media file never arrived next to the inbox json
    place_event(root, IMAGE_EVENT, media_bytes=None)

    assert consumer.consume_inbox(root) == (1, 0)  # NOT (0,1): never dropped

    conn = _conn(root)
    try:
        row = fetch_row(conn, "g-img")
        assert row["msg_type"] == "image"
        assert row["media_path"] is None          # empty media_path
        extra = json.loads(row["extra_json"])
        assert "media_error" in extra             # extra_json records the failure
    finally:
        conn.close()
    assert media_files(root, "group", "room1") == []
    assert (root / consumer.DIR_GROUPS / "room1" / consumer.FILE_EVENTS).is_file()


def test_failed_download_merges_into_existing_extra_json(root: Path) -> None:
    ev = dict(IMAGE_EVENT)
    ev["msg_id"] = "g-img2"
    ev["extra_json"] = json.dumps({"raw_type": 3})
    place_event(root, ev, media_bytes=None)

    assert consumer.consume_inbox(root) == (1, 0)

    conn = _conn(root)
    try:
        extra = json.loads(fetch_row(conn, "g-img2")["extra_json"])
    finally:
        conn.close()
    assert extra["raw_type"] == 3        # existing payload preserved
    assert "media_error" in extra        # error merged alongside


# ------------------------------------------------ pure decision function

def test_decide_media_caps_video_at_50mb() -> None:
    assert media.decide_media("video", MAX_VIDEO_BYTES).copy_body is True
    assert media.decide_media("video", MAX_VIDEO_BYTES + 1).copy_body is False
    assert media.decide_media("video", MAX_VIDEO_BYTES + 1).reason is not None
    # image/voice are never size-capped (silk + image bodies are always copied)
    assert media.decide_media("image", 2 * MAX_VIDEO_BYTES).copy_body is True
    assert media.decide_media("voice", 2 * MAX_VIDEO_BYTES).copy_body is True


def test_decide_media_missing_file_reports_failed_download() -> None:
    decision = media.decide_media("image", None)
    assert decision.copy_body is False
    assert decision.reason is not None
    assert "download failed" in decision.reason


def test_decide_media_non_media_type_never_reports_error() -> None:
    assert media.decide_media("text", None).copy_body is False
    assert media.decide_media("text", None).reason is None


def test_merge_media_error_preserves_payload() -> None:
    merged = media.merge_media_error(json.dumps({"raw_type": 43}), "media download failed")
    assert json.loads(merged) == {"raw_type": 43, "media_error": "media download failed"}
    assert json.loads(media.merge_media_error(None, "boom")) == {"media_error": "boom"}
