"""Read-only ingest CLI tests for wechat-ingest (todo 7, TDD).

Locks store/cli.py AFTER the consumer (todo 5) and systemd unit (todo 6)
exist.  The CLI is the stable query API a later skill will call, so the tests
pin its contract: list-chats / export / stats are pure reads over the SQLite
index, seeded through the real inbox-consumer path.  Acceptance cases:

- ``list-chats`` after fixtures shows one group and one dm.
- ``export --chat <id>`` returns only that chat's events, oldest first.
- unknown ``chat_id`` exits 2 (argparse's usage-error convention).
- the CLI never creates or mutates ``index.sqlite`` (strictly read-only).
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

import cli
import consumer

GROUP_EVENTS = [
    {
        "chat_id": "room1", "chat_kind": "group", "msg_id": "g-1", "msg_type": "text",
        "sender": "wxid_a", "ts": 1720000001, "text": "hello world",
        "media_path": None, "extra_json": None,
    },
    {
        "chat_id": "room1", "chat_kind": "group", "msg_id": "g-2", "msg_type": "image",
        "sender": "wxid_b", "ts": 1720000005, "text": "[image]",
        "media_path": f"{consumer.DIR_GROUPS}/room1/图片/g-2.png", "extra_json": None,
    },
]

DM_EVENTS = [
    {
        "chat_id": "d1", "chat_kind": "dm", "msg_id": "d-1", "msg_type": "text",
        "sender": "wxid_d", "ts": 1720000003, "text": "dm hello",
        "media_path": None, "extra_json": None,
    },
]


def seed(root: Path, events: list[dict]) -> None:
    """Drop the events into the inbox and consume them, exactly like the real
    plugin + systemd path, so the CLI reads a store built end-to-end.  A media
    file is placed beside the json when the event carries a media payload."""
    inbox = root / consumer.DIR_INBOX
    inbox.mkdir(parents=True, exist_ok=True)
    for index, event in enumerate(events):
        (inbox / f"seed-{index}.json").write_text(json.dumps(event), encoding="utf-8")
        if event["msg_type"] == "image":
            (inbox / f"seed-{index}.png").write_bytes(b"\x89PNG fake image bytes")
    assert consumer.consume_inbox(root) == (len(events), 0)


@pytest.fixture()
def root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    ingest_root = tmp_path / "wechat-ingest"
    ingest_root.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("WECHAT_INGEST_ROOT", str(ingest_root))
    return ingest_root


def exported_lines(out: str) -> list[dict]:
    return [json.loads(line) for line in out.splitlines() if line.strip()]


# -------------------------------------------------------------- list-chats

def test_list_chats_after_fixtures_shows_one_group_and_one_dm(root: Path, capsys: pytest.CaptureFixture) -> None:
    seed(root, GROUP_EVENTS + DM_EVENTS)
    assert cli.main(["list-chats"]) == 0
    lines = [line.split("\t") for line in capsys.readouterr().out.splitlines()]
    assert lines[0] == ["chat_id", "chat_kind", "message_count", "last_ts"]
    rows = {fields[0]: fields[1] for fields in lines[1:] if len(fields) == 4}
    assert rows == {"room1": "group", "d1": "dm"}


def test_list_chats_reports_message_count_and_last_ts(root: Path, capsys: pytest.CaptureFixture) -> None:
    seed(root, GROUP_EVENTS + DM_EVENTS)
    cli.main(["list-chats"])
    lines = [line.split("\t") for line in capsys.readouterr().out.splitlines()]
    by_chat = {fields[0]: fields for fields in lines[1:] if len(fields) == 4}
    assert by_chat["room1"][2] == "2" and by_chat["room1"][3] == "1720000005"
    assert by_chat["d1"][2] == "1" and by_chat["d1"][3] == "1720000003"


def test_list_chats_on_missing_store_is_empty_but_exits_0(root: Path, capsys: pytest.CaptureFixture) -> None:
    assert cli.main(["list-chats"]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0] == "chat_id\tchat_kind\tmessage_count\tlast_ts"
    assert len(lines) == 1


# ------------------------------------------------------------------ export

def test_export_of_group_returns_only_that_chats_events(root: Path, capsys: pytest.CaptureFixture) -> None:
    seed(root, GROUP_EVENTS + DM_EVENTS)
    assert cli.main(["export", "--chat", "room1"]) == 0
    events = exported_lines(capsys.readouterr().out)
    assert [e["msg_id"] for e in events] == ["g-1", "g-2"]  # oldest first, no dm event
    assert all(e["chat_id"] == "room1" for e in events)
    # the image event's media was copied to its recorded media_path
    assert events[1]["media_path"] == f"{consumer.DIR_GROUPS}/room1/图片/seed-1.png"


def test_export_of_dm_returns_only_dm_events(root: Path, capsys: pytest.CaptureFixture) -> None:
    seed(root, GROUP_EVENTS + DM_EVENTS)
    assert cli.main(["export", "--chat", "d1"]) == 0
    events = exported_lines(capsys.readouterr().out)
    assert [e["msg_id"] for e in events] == ["d-1"]
    assert all(e["chat_kind"] == "dm" for e in events)


def test_export_since_filters_events_inclusively(root: Path, capsys: pytest.CaptureFixture) -> None:
    seed(root, GROUP_EVENTS + DM_EVENTS)
    assert cli.main(["export", "--chat", "room1", "--since", "1720000005"]) == 0
    events = exported_lines(capsys.readouterr().out)
    assert [e["msg_id"] for e in events] == ["g-2"]  # ts >= since


def test_export_unknown_chat_id_exits_2(root: Path, capsys: pytest.CaptureFixture) -> None:
    seed(root, GROUP_EVENTS)
    with pytest.raises(SystemExit) as exc:
        cli.main(["export", "--chat", "nope"])
    assert exc.value.code == 2
    assert "nope" in capsys.readouterr().err


def test_export_unknown_chat_on_missing_store_exits_2(root: Path, capsys: pytest.CaptureFixture) -> None:
    with pytest.raises(SystemExit) as exc:
        cli.main(["export", "--chat", "room1"])
    assert exc.value.code == 2


# ------------------------------------------------------------------ stats

def test_stats_counts_chats_groups_dms_messages(root: Path, capsys: pytest.CaptureFixture) -> None:
    seed(root, GROUP_EVENTS + DM_EVENTS)
    assert cli.main(["stats"]) == 0
    counts = dict(line.split("\t") for line in capsys.readouterr().out.splitlines())
    assert counts == {"chats": "2", "groups": "1", "dms": "1", "messages": "3"}


def test_stats_on_missing_store_shows_zeros(root: Path, capsys: pytest.CaptureFixture) -> None:
    assert cli.main(["stats"]) == 0
    counts = dict(line.split("\t") for line in capsys.readouterr().out.splitlines())
    assert counts == {"chats": "0", "groups": "0", "dms": "0", "messages": "0"}


# ------------------------------------------------------------ usage / readonly

def test_no_command_is_a_usage_error_exit_2(root: Path, capsys: pytest.CaptureFixture) -> None:
    with pytest.raises(SystemExit) as exc:
        cli.main([])
    assert exc.value.code == 2


def test_cli_never_creates_or_mutates_the_index(root: Path, capsys: pytest.CaptureFixture) -> None:
    # Reads on a fresh root must not create the DB (strictly read-only).
    cli.main(["list-chats"])
    cli.main(["stats"])
    assert not (root / consumer.FILE_INDEX).exists()

    # Reads on a seeded store must leave it byte-for-byte untouched.
    seed(root, GROUP_EVENTS + DM_EVENTS)
    db_path = root / consumer.FILE_INDEX
    before = db_path.read_bytes()
    cli.main(["list-chats"])
    cli.main(["export", "--chat", "room1"])
    cli.main(["stats"])
    assert db_path.read_bytes() == before
    conn = sqlite3.connect(db_path)
    try:
        assert conn.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 3
    finally:
        conn.close()
