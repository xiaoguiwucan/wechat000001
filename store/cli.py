"""Read-only ``wechat-ingest`` CLI (todo 7).

This is the stable query API a later skill (e.g. a daily digest) will call
against the ingest index built by ``consumer.py``.  It is strictly read-only:
``index.sqlite`` is opened in SQLite ``mode=ro`` and never created, written,
or mutated, so a missing store simply reads as empty.  It generates no
summaries and never calls a model — it only turns stored rows into text.

Commands
--------
list-chats              one row per chat: ``chat_id<TAB>chat_kind<TAB>
                        message_count<TAB>last_ts`` (tab-separated).
export --chat <id>      one JSON object per line (JSONL) for that chat,
  [--since <ts>]        oldest first; ``--since`` keeps events with
                        ``ts >= since`` (inclusive).
stats                   ``chats<TAB>n`` / ``groups`` / ``dms`` / ``messages``.

Exit codes: 0 success, 2 usage error or unknown ``chat_id`` (argparse's
convention).  The store root comes from ``WECHAT_INGEST_ROOT`` (default
``/home/zkx/wechat-ingest/data``), the same env contract consumer.py honors.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

from consumer import default_root

EVENT_COLUMNS = (
    "chat_id",
    "chat_kind",
    "msg_id",
    "msg_type",
    "sender",
    "ts",
    "text",
    "media_path",
    "extra_json",
)

SELECT_EVENTS = (
    f"SELECT {', '.join(EVENT_COLUMNS)} FROM events"
    " WHERE chat_id = :chat_id AND ts >= :since ORDER BY ts ASC, msg_id ASC"
)


def open_readonly(root: Path | None = None) -> sqlite3.Connection | None:
    """Open ``<root>/index.sqlite`` read-only, or None when the store does not
    exist yet (the CLI never creates it)."""
    base = root if root is not None else default_root()
    db_path = base / "索引.sqlite"
    if not db_path.is_file():
        db_path = base / "index.sqlite"
    if not db_path.is_file():
        return None
    conn = sqlite3.connect(f"file:{quote(str(db_path))}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def list_chats(conn: sqlite3.Connection | None) -> list[dict[str, object]]:
    """One row per chat: chat_id, chat_kind, message_count, last_ts."""
    if conn is None:
        return []
    rows = conn.execute(
        "SELECT chat_id, chat_kind, COUNT(*) AS message_count, MAX(ts) AS last_ts "
        "FROM events GROUP BY chat_id, chat_kind ORDER BY chat_kind, chat_id"
    )
    return [dict(row) for row in rows]


def chat_exists(conn: sqlite3.Connection | None, chat_id: str) -> bool:
    if conn is None:
        return False
    return conn.execute("SELECT 1 FROM events WHERE chat_id = ? LIMIT 1", (chat_id,)).fetchone() is not None


def export_events(conn: sqlite3.Connection | None, chat_id: str, since: int | None) -> list[dict[str, object]]:
    """Every event of one chat (oldest first), optionally filtered to ``ts >= since``."""
    if conn is None:
        return []
    params: dict[str, object] = {"chat_id": chat_id, "since": since if since is not None else 0}
    return [dict(row) for row in conn.execute(SELECT_EVENTS, params)]


def stats(conn: sqlite3.Connection | None) -> dict[str, int]:
    """Aggregate counts over the whole index; keys chats/groups/dms/messages."""
    counts = {"chats": 0, "groups": 0, "dms": 0, "messages": 0}
    if conn is None:
        return counts
    for kind, chat_count, message_count in conn.execute(
        "SELECT chat_kind, COUNT(DISTINCT chat_id), COUNT(*) FROM events GROUP BY chat_kind"
    ):
        counts[f"{kind}s"] = int(chat_count)  # 'group' -> 'groups', 'dm' -> 'dms'
        counts["messages"] += int(message_count)
    counts["chats"] = counts["groups"] + counts["dms"]
    return counts


# ------------------------------------------------------------- print helpers

def _print_list_chats(conn: sqlite3.Connection | None) -> None:
    print("\t".join(("chat_id", "chat_kind", "message_count", "last_ts")))
    for row in list_chats(conn):
        print("\t".join((row["chat_id"], row["chat_kind"], str(row["message_count"]), str(row["last_ts"]))))


def _print_export(conn: sqlite3.Connection | None, parser: argparse.ArgumentParser, chat_id: str, since: int | None) -> int:
    if not chat_exists(conn, chat_id):
        parser.error(f"unknown chat_id: {chat_id!r}")
    for event in export_events(conn, chat_id, since):
        print(json.dumps(event, ensure_ascii=False))
    return 0


def _print_stats(conn: sqlite3.Connection | None) -> None:
    for key, value in stats(conn).items():
        print(f"{key}\t{value}")


def _print_search(conn: sqlite3.Connection | None, query: str, kind: str | None, limit: int) -> None:
    if conn is None:
        return
    sql = (
        f"SELECT {', '.join(EVENT_COLUMNS)} FROM events "
        "WHERE text LIKE ? "
    )
    params: list[object] = [f"%{query}%"]
    if kind:
        sql += "AND chat_kind = ? "
        params.append(kind)
    sql += "ORDER BY ts DESC LIMIT ?"
    params.append(limit)
    for row in conn.execute(sql, params):
        print(json.dumps(dict(row), ensure_ascii=False))


def _print_digest(conn: sqlite3.Connection | None, date_text: str, kind: str) -> None:
    day = datetime.strptime(date_text, "%Y-%m-%d").replace(tzinfo=timezone(timedelta(hours=8)))
    start = int(day.timestamp())
    end = start + 86400
    if conn is None:
        print(f"# {date_text}\n无数据")
        return
    rows = [
        dict(row)
        for row in conn.execute(
            f"SELECT {', '.join(EVENT_COLUMNS)} FROM events "
            "WHERE chat_kind = ? AND ts >= ? AND ts < ? ORDER BY chat_id, ts, msg_id",
            (kind, start, end),
        )
    ]
    print(f"# 微信{'群' if kind == 'group' else '私聊'}日报 {date_text}")
    print(f"共 {len(rows)} 条")
    current = None
    for row in rows:
        if row["chat_id"] != current:
            current = row["chat_id"]
            print(f"\n## {current}")
        stamp = datetime.fromtimestamp(int(row["ts"] or 0), tz=timezone(timedelta(hours=8))).strftime("%H:%M")
        text = (row["text"] or "").replace("\n", " ")
        print(f"- {stamp} {row['sender']}: {text}")


# ------------------------------------------------------------------- entry

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wechat-ingest",
        description="Read-only query API over the wechat-ingest index (no summaries, no model calls).",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list-chats", help="list every chat with message count and last event ts")
    export = sub.add_parser("export", help="export one chat's events as JSONL, oldest first")
    export.add_argument("--chat", required=True, help="chat_id (group room id or dm wxid)")
    export.add_argument("--since", type=int, default=None, help="only events with ts >= since (inclusive)")
    sub.add_parser("stats", help="aggregate chats/groups/dms/messages counts")
    search = sub.add_parser("search", help="search event text")
    search.add_argument("query")
    search.add_argument("--kind", choices=("group", "dm"), default=None)
    search.add_argument("--limit", type=int, default=80)
    digest = sub.add_parser("digest", help="plain daily digest text for one day")
    digest.add_argument("--date", required=True, help="YYYY-MM-DD (local)")
    digest.add_argument("--kind", choices=("group", "dm"), default="group")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    conn = open_readonly()
    if args.command == "list-chats":
        _print_list_chats(conn)
    elif args.command == "export":
        return _print_export(conn, parser, args.chat, args.since)
    elif args.command == "search":
        _print_search(conn, args.query, args.kind, args.limit)
    elif args.command == "digest":
        _print_digest(conn, args.date, args.kind)
    else:
        _print_stats(conn)
    return 0


if __name__ == "__main__":
    sys.exit(main())
