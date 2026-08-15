"""Inbox consumer for wechat-ingest (todo 5).

Reads ``<root>/inbox/<uuid>.json`` — one event per file, with an optional
media file ``<root>/inbox/<uuid>.<ext>`` beside it — then:

1. appends the event as one JSON line to
   ``<root>/groups|dms/<chat_id>/events.jsonl``
2. copies the optional media file to
   ``<root>/groups|dms/<chat_id>/media/<uuid>.<ext>`` and records its
   relative path as ``media_path``
3. upserts the row into ``<root>/index.sqlite`` (schema from schema.sql)
4. unlinks the inbox json and media file

Idempotency: ``UNIQUE(chat_id, msg_id)`` plus ``INSERT OR IGNORE`` means a
replayed inbox payload yields exactly one SQLite row, and a crash part-way
through a file is safe to re-run.  Each file is first atomically renamed into
``inbox/.processing/`` so a concurrent consumer can never read it twice; a
stale claim left by a crash is re-claimed by the next run, and nothing is
unlinked until the JSONL append, media copy, and SQLite upsert all succeeded.

Malformed or schema-invalid payloads are moved to ``<root>/inbox/failed/``
and leave both the JSONL log and SQLite untouched.  Unknown message types
are normalized to ``'raw'`` (never dropped), mirroring the store contract.

The ingest root comes from the ``WECHAT_INGEST_ROOT`` env var (default
``/root/.openclaw/wechat-ingest``) and can be overridden per call.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import history_map
import media

DEFAULT_ROOT = "/data/wechat-ingest"
_PERSIST_LOCK = threading.Lock()

DIR_GROUPS = "群聊"
DIR_DMS = "私聊"
DIR_OFFICIAL = "公众号"
DIR_INBOX = "待入库"
DIR_MEDIA = "媒体"
DIR_DIGESTS = "日报"
DIR_FAILED = "失败"
DIR_HIST_MEDIA = "hist-media"
FILE_EVENTS = "消息.jsonl"
FILE_CHATS = "会话对照.json"
FILE_INDEX = "索引.sqlite"

REQUIRED_FIELDS = ("chat_id", "chat_kind", "msg_id", "msg_type", "sender", "ts")
OPTIONAL_FIELDS = ("text", "media_path", "extra_json", "chat_name", "sender_name", "is_self")
KNOWN_MSG_TYPES = {"text", "image", "voice", "video", "emoji", "file", "redpacket", "revoke", "announcement", "raw"}

INSERT_SQL = (
    "INSERT INTO events "
    "(chat_id, chat_kind, msg_id, msg_type, sender, ts, text, media_path, extra_json) "
    "VALUES (:chat_id, :chat_kind, :msg_id, :msg_type, :sender, :ts, :text, :media_path, :extra_json) "
    "ON CONFLICT(chat_id, msg_id) DO UPDATE SET "
    "text=excluded.text, "
    "media_path=excluded.media_path, "
    "extra_json=excluded.extra_json "
    "WHERE (events.media_path IS NULL OR events.media_path = '') "
    "AND excluded.media_path IS NOT NULL AND excluded.media_path != ''"
)


def default_root() -> Path:
    """The ingest root: ``WECHAT_INGEST_ROOT`` env var or the fnOS default."""
    return Path(os.environ.get("WECHAT_INGEST_ROOT", DEFAULT_ROOT))


def _schema_sql() -> str:
    return (Path(__file__).resolve().parent / "schema.sql").read_text(encoding="utf-8")


def init_db(root: Path) -> sqlite3.Connection:
    """Open (creating if needed) ``<root>/index.sqlite`` and apply schema.sql."""
    root = Path(root)
    db_path = root / FILE_INDEX
    if not db_path.is_file() and (root / "index.sqlite").is_file():
        db_path = root / "index.sqlite"
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.executescript(_schema_sql())
    return conn


def _normalize_event(raw: object) -> dict[str, object]:
    """Validate one parsed inbox payload and normalize it to a DB row.

    Mirrors store/event.schema.json: required fields, chat_kind enum, no
    unknown top-level keys.  Unknown msg types are mapped to 'raw' so no
    event is ever dropped (consistent with store/test_schema.py).
    """
    if not isinstance(raw, dict):
        raise ValueError("payload is not a JSON object")

    missing = [k for k in REQUIRED_FIELDS if k not in raw]
    if missing:
        raise ValueError(f"event missing required field(s): {missing}")

    # Extra plugin fields (is_at_me, debug, …) are ignored so a new key
    # never sends a valid message to 失败/.
    chat_id = raw["chat_id"]
    msg_id = raw["msg_id"]
    if not isinstance(chat_id, str) or not chat_id:
        raise ValueError("chat_id must be a non-empty string")
    if "/" in chat_id or "\\" in chat_id or chat_id in (".", ".."):
        raise ValueError("chat_id must not contain path separators")
    if not isinstance(msg_id, str) or not msg_id:
        raise ValueError("msg_id must be a non-empty string")

    chat_kind = raw["chat_kind"]
    if chat_kind not in ("group", "dm"):
        raise ValueError(f"chat_kind must be 'group' or 'dm', got {chat_kind!r}")

    if not isinstance(raw["ts"], int):
        raise ValueError("ts must be an integer")
    if not isinstance(raw["sender"], str):
        raise ValueError("sender must be a string")

    msg_type = raw["msg_type"]
    if not isinstance(msg_type, str) or msg_type not in KNOWN_MSG_TYPES:
        msg_type = "raw"

    for name in OPTIONAL_FIELDS:
        if name == "is_self":
            continue
        value = raw.get(name)
        if value is not None and not isinstance(value, str):
            raise ValueError(f"{name} must be a string or null")

    is_self = raw.get("is_self")
    if is_self is not None and not isinstance(is_self, bool):
        if is_self in (0, 1):
            is_self = bool(is_self)
        else:
            raise ValueError("is_self must be a boolean")

    return {
        "chat_id": chat_id,
        "chat_kind": chat_kind,
        "msg_id": msg_id,
        "msg_type": msg_type,
        "sender": raw["sender"],
        "ts": raw["ts"],
        "text": raw.get("text"),
        "media_path": raw.get("media_path"),
        "extra_json": raw.get("extra_json"),
        "chat_name": raw.get("chat_name"),
        "sender_name": raw.get("sender_name"),
        "is_self": is_self,
    }


def _sanitize_folder_name(name: str) -> str:
    cleaned = "".join("_" if ch in '<>:"/\\|?*' or ord(ch) < 32 else ch for ch in name)
    cleaned = cleaned.strip(" .")
    if not cleaned or cleaned in {".", ".."}:
        return ""
    return cleaned[:80]


def _chats_map_path(root: Path) -> Path:
    root = Path(root)
    cn = root / FILE_CHATS
    en = root / "chats.json"
    return cn if cn.is_file() or not en.is_file() else en


def _load_chats_map(root: Path) -> dict:
    path = _chats_map_path(root)
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_chats_map(root: Path, mapping: dict) -> None:
    path = Path(root) / FILE_CHATS
    path.write_text(json.dumps(mapping, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def resolve_chat_dir(root: Path, chat_kind: str, chat_id: str, chat_name: str | None) -> Path:
    """Return groups|dms/<display-name>, renaming the old wxid folder when possible."""
    root = Path(root)
    if chat_id.startswith("gh_"):
        kind_dir_name = DIR_OFFICIAL
    elif chat_kind == "group":
        kind_dir_name = DIR_GROUPS
    else:
        kind_dir_name = DIR_DMS
    kind_dir = root / kind_dir_name
    legacy = root / ("groups" if chat_kind == "group" else "dms")
    if not chat_id.startswith("gh_") and not kind_dir.exists() and legacy.is_dir():
        kind_dir = legacy
    kind_dir.mkdir(parents=True, exist_ok=True)

    mapping = _load_chats_map(root)
    key = f"{chat_kind}:{chat_id}"
    existing = mapping.get(key) or {}
    current_folder = existing.get("folder")
    named = _sanitize_folder_name(chat_name or "")
    # Never downgrade a human folder name back to the raw wxid/chatroom id.
    if named:
        wanted = named
    elif current_folder and current_folder != chat_id:
        wanted = current_folder
    else:
        wanted = chat_id

    existing = mapping.get(key) or {}
    current_folder = existing.get("folder")
    if current_folder:
        current_path = kind_dir / current_folder
        upgrading = named and current_folder == chat_id and wanted != current_folder
        if current_path.is_dir() and upgrading and not (kind_dir / wanted).exists():
            current_path.rename(kind_dir / wanted)
            current_folder = wanted
        if current_path.is_dir() or (kind_dir / (current_folder or "")).is_dir():
            folder = wanted if (kind_dir / wanted).is_dir() else current_folder
            mapping[key] = {"chat_id": chat_id, "chat_kind": chat_kind, "chat_name": chat_name or existing.get("chat_name"), "folder": folder}
            _save_chats_map(root, mapping)
            return kind_dir / folder

    folder = wanted
    target = kind_dir / folder
    if target.exists() and mapping.get(key, {}).get("folder") != folder:
        # another chat already owns this display name
        owner = next((k for k, v in mapping.items() if v.get("folder") == folder and k != key), None)
        if owner:
            folder = f"{wanted}_{chat_id[:12]}"
            target = kind_dir / folder

    old = kind_dir / chat_id
    if not old.is_dir() and chat_id.startswith("gh_"):
        old = root / DIR_DMS / chat_id
    if old.is_dir() and old.resolve() != target.resolve():
        if not target.exists():
            old.rename(target)
        else:
            old_log = old / FILE_EVENTS if (old / FILE_EVENTS).is_file() else old / "events.jsonl"
            new_log = target / FILE_EVENTS
            if old_log.is_file():
                target.mkdir(parents=True, exist_ok=True)
                with new_log.open("a", encoding="utf-8") as out, old_log.open(encoding="utf-8") as src:
                    out.write(src.read())
            old_media = old / DIR_MEDIA if (old / DIR_MEDIA).is_dir() else old / "media"
            if old_media.is_dir():
                dest_media = target / DIR_MEDIA
                dest_media.mkdir(parents=True, exist_ok=True)
                for item in old_media.iterdir():
                    dest = dest_media / item.name
                    if not dest.exists():
                        shutil.move(str(item), str(dest))
            shutil.rmtree(old, ignore_errors=True)

    target.mkdir(parents=True, exist_ok=True)
    mapping[key] = {
        "chat_id": chat_id,
        "chat_kind": chat_kind,
        "chat_name": chat_name or "",
        "folder": folder,
    }
    _save_chats_map(root, mapping)
    return target


def _find_media_next_to(inbox_dir: Path, stem: str) -> Path | None:
    """The optional media ``<uuid>.<ext>`` sitting next to the inbox json.

    Searches the top-level inbox dir (not the claimed file's location) because
    only the json is claimed into ``.processing/``; a crash between the claim
    and the copy leaves the media behind in ``inbox/`` where the recovery run
    can still find it.
    """
    matches = sorted(p for p in inbox_dir.glob(f"{stem}.*") if p.suffix != ".json")
    return matches[0] if matches else None


def wipe_imported(root: Path) -> None:
    """Delete already-imported 群聊/私聊/索引 so a full export can start clean."""
    root = Path(root)
    for name in (DIR_GROUPS, DIR_DMS, DIR_OFFICIAL, "groups", "dms"):
        shutil.rmtree(root / name, ignore_errors=True)
    for name in (FILE_INDEX, FILE_CHATS):
        path = root / name
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    inbox = root / DIR_INBOX
    if not inbox.is_dir() and (root / "inbox").is_dir():
        inbox = root / "inbox"
    shutil.rmtree(inbox / DIR_HIST_MEDIA, ignore_errors=True)


def _persist_event(root: Path, inbox_dir: Path, event: dict, media_file: Path | None) -> None:
    chat_kind = event["chat_kind"]
    if str(event["chat_id"]).startswith("gh_"):
        kind_dir = DIR_OFFICIAL
    elif chat_kind == "group":
        kind_dir = DIR_GROUPS
    else:
        kind_dir = DIR_DMS
    chat_name = event.get("chat_name") if isinstance(event.get("chat_name"), str) else None
    chat_dir = resolve_chat_dir(root, str(chat_kind), str(event["chat_id"]), chat_name)
    chat_dir.mkdir(parents=True, exist_ok=True)

    event["text"] = media.media_text(event["msg_type"], event["text"])
    media_size = media_file.stat().st_size if media_file is not None else None
    decision = media.decide_media(event["msg_type"], media_size)
    skipped = False
    try:
        extra_obj = json.loads(event["extra_json"]) if event.get("extra_json") else {}
        skipped = isinstance(extra_obj, dict) and bool(extra_obj.get("media_skip"))
    except (json.JSONDecodeError, TypeError):
        skipped = False
    if decision.copy_body and media_file is not None:
        sub = media.media_folder(str(event.get("msg_type") or ""), media_file.name)
        media_dir = chat_dir / sub
        media_dir.mkdir(parents=True, exist_ok=True)
        rel = f"{kind_dir}/{chat_dir.name}/{sub}/{media_file.name}"
        event["media_path"] = rel
        dest = root / event["media_path"]
        if media_file.resolve() != dest.resolve():
            shutil.copy2(media_file, dest)
        try:
            import wxgf
            wxgf.ensure_preview(dest)
        except Exception:
            pass
        if event["msg_type"] == "voice":
            try:
                import transcribe
                wav = dest.with_suffix(".wav")
                transcribe.to_wav(dest, wav)
            except Exception:
                pass
    else:
        event["media_path"] = None
    if decision.reason is not None and not skipped:
        event["extra_json"] = media.merge_media_error(event["extra_json"], decision.reason)
    if event.get("is_self") is None:
        event.pop("is_self", None)
    row = {k: event.get(k) for k in (
        "chat_id", "chat_kind", "msg_id", "msg_type", "sender", "ts", "text", "media_path", "extra_json"
    )}
    with _PERSIST_LOCK:
        conn = init_db(root)
        try:
            prev = conn.execute(
                "SELECT media_path FROM events WHERE chat_id = ? AND msg_id = ?",
                (event["chat_id"], event["msg_id"]),
            ).fetchone()
            conn.execute(INSERT_SQL, row)
            conn.commit()
        finally:
            conn.close()
        prev_media = prev[0] if prev else None
        new_media = event.get("media_path")
        should_append = prev is None or ((not prev_media) and bool(new_media))
        if should_append:
            with (chat_dir / FILE_EVENTS).open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(event, ensure_ascii=False) + "\n")


def _ingest_history_rows(
    root: Path,
    inbox_dir: Path,
    *,
    chat_id: str,
    chat_kind: str,
    self_wxid: str,
    chat_name: str | None,
    media_key: str,
    rows,
    failed_dir: Path | None = None,
) -> tuple[int, int]:
    """Map+persist raw Chat_* rows. Returns (kept, row_errors). Never aborts the pack."""
    if chat_kind not in ("group", "dm"):
        chat_kind = "group" if chat_id.endswith("@chatroom") else "dm"
    media_root = inbox_dir / DIR_HIST_MEDIA / media_key if media_key else inbox_dir / DIR_HIST_MEDIA
    kept = errors = 0
    for raw in rows:
        if not isinstance(raw, dict):
            errors += 1
            continue
        try:
            event = history_map.map_history_row(
                chat_id=chat_id,
                chat_kind=chat_kind,
                self_wxid=self_wxid,
                row=raw,
            )
        except Exception as exc:
            errors += 1
            if failed_dir is not None:
                failed_dir.mkdir(parents=True, exist_ok=True)
                name = f"history-row-{chat_id}-{raw.get('lid', 'x')}.json"
                try:
                    (failed_dir / name).write_text(
                        json.dumps({"error": str(exc), "row": raw}, ensure_ascii=False),
                        encoding="utf-8",
                    )
                except OSError:
                    pass
            continue
        if chat_name:
            event["chat_name"] = chat_name
        xml = ""
        try:
            extra = json.loads(event["extra_json"]) if event.get("extra_json") else {}
            if isinstance(extra, dict):
                xml = str(extra.get("xml") or "")
        except (json.JSONDecodeError, TypeError):
            xml = ""
        media_file = history_map.find_hist_media(media_root, str(event["msg_id"]), xml)
        _persist_event(root, inbox_dir, event, media_file)
        kept += 1
    return kept, errors


def consume_history_batch(root: Path, inbox_dir: Path, payload: dict) -> int:
    """Ingest one phone-dumped Chat_* batch. Returns number of rows kept."""
    chat_id = payload.get("chat_id")
    if not isinstance(chat_id, str) or not chat_id:
        raise ValueError("history_batch missing chat_id")
    rows = payload.get("rows")
    if not isinstance(rows, list):
        raise ValueError("history_batch rows must be a list")
    kept, _err = _ingest_history_rows(
        root,
        inbox_dir,
        chat_id=chat_id,
        chat_kind=str(payload.get("chat_kind") or ""),
        self_wxid=payload.get("self_wxid") if isinstance(payload.get("self_wxid"), str) else "",
        chat_name=payload.get("chat_name") if isinstance(payload.get("chat_name"), str) else None,
        media_key=payload.get("media_key") if isinstance(payload.get("media_key"), str) else "",
        rows=rows,
    )
    return kept


def consume_history_jsonl(root: Path, inbox_dir: Path, path: Path, failed_dir: Path) -> int:
    """Line-by-line ingest of one chat pack. Incomplete files are put back."""
    header = None
    rows: list[dict] = []
    trailer = None
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"bad jsonl line: {exc}") from exc
            if not isinstance(obj, dict):
                continue
            if obj.get("cmd") == "history_jsonl" and header is None:
                header = obj
                continue
            if obj.get("end") is True:
                trailer = obj
                continue
            rows.append(obj)
    if header is None:
        raise ValueError("history_jsonl missing header")
    if trailer is None:
        age = time.time() - path.stat().st_mtime
        if age < 45:
            raise TimeoutError("history_jsonl still uploading")
        raise ValueError("history_jsonl missing end marker")
    chat_id = header.get("chat_id")
    if not isinstance(chat_id, str) or not chat_id:
        raise ValueError("history_jsonl missing chat_id")
    kept, errors = _ingest_history_rows(
        root,
        inbox_dir,
        chat_id=chat_id,
        chat_kind=str(header.get("chat_kind") or ""),
        self_wxid=header.get("self_wxid") if isinstance(header.get("self_wxid"), str) else "",
        chat_name=header.get("chat_name") if isinstance(header.get("chat_name"), str) else None,
        media_key=header.get("media_key") if isinstance(header.get("media_key"), str) else "",
        rows=rows,
        failed_dir=failed_dir,
    )
    declared = trailer.get("rows")
    print(
        f"wechat-ingest: jsonl {path.name} chat={chat_id} kept={kept} "
        f"declared={declared} errors={errors}",
        flush=True,
    )
    return kept


def consume_one(root: Path, inbox_json: Path) -> bool:
    """Ingest one ``inbox/<uuid>.json``; True on success, False when it was
    moved to ``inbox/failed/`` (or was already claimed by a concurrent
    consumer).

    The file is first renamed into ``inbox/.processing/`` so a concurrent
    consumer can never read it twice; a stale claim (crash mid-way) is
    re-claimed by the next ``consume_inbox`` run.
    """
    root = Path(root)
    inbox_dir = root / DIR_INBOX
    if not inbox_dir.is_dir() and (root / "inbox").is_dir():
        inbox_dir = root / "inbox"
    processing_dir = inbox_dir / ".processing"
    failed_dir = inbox_dir / DIR_FAILED
    if not failed_dir.is_dir() and (inbox_dir / "failed").is_dir():
        failed_dir = inbox_dir / "failed"
    processing_dir.mkdir(parents=True, exist_ok=True)
    failed_dir.mkdir(parents=True, exist_ok=True)

    claimed = processing_dir / inbox_json.name
    try:
        inbox_json.rename(claimed)
    except FileNotFoundError:
        return None  # a concurrent consumer already claimed it

    if claimed.suffix == ".jsonl":
        try:
            consume_history_jsonl(root, inbox_dir, claimed, failed_dir)
            claimed.unlink(missing_ok=True)
            return True
        except TimeoutError:
            claimed.replace(inbox_dir / inbox_json.name)
            return None
        except (json.JSONDecodeError, UnicodeDecodeError, OSError, ValueError):
            try:
                age = time.time() - claimed.stat().st_mtime
            except OSError:
                age = 999.0
            if age < 45:
                claimed.replace(inbox_dir / inbox_json.name)
                return None
            try:
                claimed.replace(failed_dir / inbox_json.name)
            except FileNotFoundError:
                return None
            return False

    try:
        raw_obj = json.loads(claimed.read_text(encoding="utf-8"))
        if isinstance(raw_obj, dict) and raw_obj.get("cmd") == "wipe_imported":
            wipe_imported(root)
            claimed.unlink(missing_ok=True)
            return True
        if isinstance(raw_obj, dict) and raw_obj.get("cmd") == "history_batch":
            consume_history_batch(root, inbox_dir, raw_obj)
            claimed.unlink(missing_ok=True)
            return True
        event = _normalize_event(raw_obj)
    except (json.JSONDecodeError, UnicodeDecodeError):
        # SFTP writes the json in place. Path/timer can pick it up mid-write;
        # moving a young bad parse to 失败/ loses a valid event once the
        # writer finishes on the renamed inode.
        try:
            age = time.time() - claimed.stat().st_mtime
        except OSError:
            age = 999.0
        if age < 15:
            claimed.replace(inbox_dir / inbox_json.name)
            return None
        claimed.replace(failed_dir / inbox_json.name)
        return False
    except (OSError, ValueError):
        claimed.replace(failed_dir / inbox_json.name)
        return False

    media_file = _find_media_next_to(inbox_dir, claimed.stem)
    _persist_event(root, inbox_dir, event, media_file)
    claimed.unlink(missing_ok=True)
    if media_file is not None:
        media_file.unlink(missing_ok=True)
    return True


def apply_name_map(root: Path, names: dict) -> int:
    """Remember display names and rename folders that already have messages.

    Does not create empty chat folders. Name sync used to mkdir every contact
    and made the file manager look like data had arrived when it had not.
    """
    if not isinstance(names, dict):
        return 0
    mapping = _load_chats_map(root)
    changed = 0
    for chat_id, name in names.items():
        if not isinstance(chat_id, str) or not isinstance(name, str):
            continue
        if not chat_id or not name.strip():
            continue
        kind = "group" if chat_id.endswith("@chatroom") else "dm"
        key = f"{kind}:{chat_id}"
        entry = mapping.get(key) or {}
        folder = entry.get("folder")
        mapping[key] = {
            "chat_id": chat_id,
            "chat_kind": kind,
            "chat_name": name.strip(),
            "folder": folder or "",
        }
        if folder:
            kind_dir = root / (DIR_OFFICIAL if chat_id.startswith("gh_") else DIR_GROUPS if kind == "group" else DIR_DMS)
            current = kind_dir / folder
            wanted = _sanitize_folder_name(name) or folder
            if current.is_dir() and wanted != folder and not (kind_dir / wanted).exists():
                current.rename(kind_dir / wanted)
                mapping[key]["folder"] = wanted
                changed += 1
    _save_chats_map(root, mapping)
    return changed


def migrate_media_layout(root: Path) -> int:
    """Move flat ``媒体/`` files into 图片/语音/视频/文件 and rewrite paths."""
    moved = 0
    for kind in (DIR_GROUPS, DIR_DMS, DIR_OFFICIAL, "groups", "dms"):
        base = Path(root) / kind
        if not base.is_dir():
            continue
        for chat in base.iterdir():
            if not chat.is_dir():
                continue
            pile = chat / DIR_MEDIA
            if not pile.is_dir():
                pile = chat / "media"
            if not pile.is_dir():
                continue
            path_map: dict[str, str] = {}
            for item in list(pile.iterdir()):
                if not item.is_file():
                    continue
                sub = media.media_folder("", item.name)
                dest_dir = chat / sub
                dest_dir.mkdir(parents=True, exist_ok=True)
                dest = dest_dir / item.name
                if dest.exists():
                    item.unlink(missing_ok=True)
                else:
                    item.replace(dest)
                path_map[item.name] = f"{kind}/{chat.name}/{sub}/{item.name}"
                moved += 1
            log = chat / FILE_EVENTS
            if not log.is_file():
                log = chat / "events.jsonl"
            if log.is_file() and path_map:
                lines = []
                changed = False
                for line in log.read_text(encoding="utf-8").splitlines():
                    if not line.strip():
                        continue
                    try:
                        ev = json.loads(line)
                    except json.JSONDecodeError:
                        lines.append(line)
                        continue
                    mp = ev.get("media_path") if isinstance(ev, dict) else None
                    if isinstance(mp, str) and mp:
                        name = Path(mp).name
                        if name in path_map and mp != path_map[name]:
                            ev["media_path"] = path_map[name]
                            changed = True
                    lines.append(json.dumps(ev, ensure_ascii=False))
                if changed:
                    log.write_text("\n".join(lines) + "\n", encoding="utf-8")
    db = Path(root) / FILE_INDEX
    if db.is_file() and moved:
        conn = sqlite3.connect(db)
        try:
            rows = conn.execute(
                "SELECT rowid, media_path FROM events WHERE media_path IS NOT NULL"
            ).fetchall()
            for rowid, mp in rows:
                if not mp:
                    continue
                name = Path(mp).name
                sub = media.media_folder("", name)
                parts = Path(mp).parts
                if len(parts) >= 2 and parts[-2] != sub:
                    new = str(Path(*parts[:-1]).parent / sub / name)
                    conn.execute("UPDATE events SET media_path = ? WHERE rowid = ?", (new, rowid))
            conn.commit()
        finally:
            conn.close()
    return moved


def attach_loose_hist_media(root: Path, inbox_dir: Path) -> int:
    """Attach hist-media files that arrived after the chat pack was ingested."""
    base = inbox_dir / DIR_HIST_MEDIA
    if not base.is_dir():
        return 0
    db = root / FILE_INDEX
    if not db.is_file() and (root / "index.sqlite").is_file():
        db = root / "index.sqlite"
    if not db.is_file():
        return 0
    attached = 0
    with _PERSIST_LOCK:
        conn = init_db(root)
        try:
            rows = conn.execute(
                "SELECT chat_id, msg_id, msg_type, extra_json FROM events "
                "WHERE (media_path IS NULL OR media_path = '') "
                "AND msg_type IN ('image','voice','video','file','emoji')"
            ).fetchall()
            if not rows:
                return 0
            by_key: dict[str, dict[str, tuple]] = {}
            for chat_id, msg_id, msg_type, extra in rows:
                key = hashlib.md5(str(chat_id).encode("utf-8")).hexdigest()
                by_key.setdefault(key, {})[str(msg_id)] = (chat_id, str(msg_id), msg_type, extra)
            for key_dir in base.iterdir():
                if not key_dir.is_dir():
                    continue
                wanted = by_key.get(key_dir.name)
                if not wanted:
                    continue
                for chat_id, msg_id, msg_type, extra in list(wanted.values()):
                    xml = ""
                    try:
                        obj = json.loads(extra) if extra else {}
                        if isinstance(obj, dict):
                            xml = str(obj.get("xml") or "")
                    except (json.JSONDecodeError, TypeError):
                        xml = ""
                    media_file = history_map.find_hist_media(key_dir, msg_id, xml)
                    if media_file is None:
                        continue
                    kind = "group" if str(chat_id).endswith("@chatroom") else "dm"
                    chat_dir = resolve_chat_dir(root, kind, str(chat_id), None)
                    if not chat_dir.is_dir():
                        continue
                    kind_dir = DIR_GROUPS if kind == "group" else DIR_DMS
                    if str(chat_id).startswith("gh_"):
                        kind_dir = DIR_OFFICIAL
                    sub = media.media_folder(str(msg_type or ""), media_file.name)
                    dest_dir = chat_dir / sub
                    dest_dir.mkdir(parents=True, exist_ok=True)
                    dest = dest_dir / media_file.name
                    if media_file.resolve() != dest.resolve():
                        shutil.copy2(media_file, dest)
                    rel = f"{kind_dir}/{chat_dir.name}/{sub}/{media_file.name}"
                    conn.execute(
                        "UPDATE events SET media_path = ? WHERE chat_id = ? AND msg_id = ? "
                        "AND (media_path IS NULL OR media_path = '')",
                        (rel, chat_id, msg_id),
                    )
                    attached += 1
            conn.commit()
        finally:
            conn.close()
    return attached


def consume_inbox(root: Path | None = None, *, migrate: bool = True, workers: int = 1) -> tuple[int, int]:
    """Consume every pending inbox file under ``root``; returns ``(consumed, failed)``.

    Pending = ``inbox/*.json`` plus any stale ``inbox/.processing/*.json`` left
    by a crash mid-way.
    """
    root = Path(root) if root is not None else default_root()
    if migrate:
        migrate_media_layout(root)
    inbox_dir = root / DIR_INBOX
    if not inbox_dir.is_dir() and (root / "inbox").is_dir():
        inbox_dir = root / "inbox"
    if not inbox_dir.is_dir():
        return (0, 0)

    for name_file in list(inbox_dir.glob("names.json")) + list(inbox_dir.glob("names-*.json")):
        try:
            names = json.loads(name_file.read_text(encoding="utf-8"))
            n = apply_name_map(root, names)
            print(f"wechat-ingest: applied {n} names from {name_file.name}")
            name_file.unlink(missing_ok=True)
        except (json.JSONDecodeError, OSError, TypeError) as exc:
            print(f"wechat-ingest: name map failed {name_file.name}: {exc}")

    failed_dir = inbox_dir / DIR_FAILED
    if not failed_dir.is_dir() and (inbox_dir / "failed").is_dir():
        failed_dir = inbox_dir / "failed"
    if failed_dir.is_dir():
        for failed in list(failed_dir.glob("*.json")):
            try:
                obj = json.loads(failed.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError, UnicodeDecodeError):
                continue
            if isinstance(obj, dict) and obj.get("cmd") == "wipe_imported":
                dest = inbox_dir / failed.name
                try:
                    failed.replace(dest)
                except OSError:
                    pass

    # Live plugin drops inbox/<uuid>.json. Leftover wxhist-*.jsonl from the
    # retired full-export must not block or lock the live path.
    pending = [
        p for p in sorted(inbox_dir.glob("*.json"))
        if not p.name.startswith("names") and not p.name.startswith("wxhist-")
    ]
    processing_dir = inbox_dir / ".processing"
    if processing_dir.is_dir():
        pending.extend(
            sorted(
                p for p in processing_dir.glob("*.json")
                if not p.name.startswith("wxhist-")
            )
        )

    consumed = failed = 0
    if workers <= 1 or len(pending) <= 1:
        results = [consume_one(root, path) for path in pending]
    else:
        results = []
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futs = [pool.submit(consume_one, root, path) for path in pending]
            for fut in as_completed(futs):
                results.append(fut.result())
    for result in results:
        if result is True:
            consumed += 1
        elif result is False:
            failed += 1
    if consumed:
        try:
            import readable
            readable.refresh(root)
        except Exception:
            pass
    return (consumed, failed)


def watch_inbox(root: Path | None = None, interval: float = 0.4, workers: int = 1) -> None:
    """Stay up and drain the inbox as files land. Used by the systemd daemon."""
    root = Path(root) if root is not None else default_root()
    try:
        migrate_media_layout(root)
    except Exception as exc:
        print(f"wechat-ingest: migrate skipped: {exc}")
    print(f"wechat-ingest: watch root={root} workers={workers} interval={interval}")
    while True:
        try:
            consumed, failed = consume_inbox(root, migrate=False, workers=workers)
            if consumed or failed:
                print(f"wechat-ingest: consumed={consumed} failed={failed}", flush=True)
        except Exception as exc:
            print(f"wechat-ingest: watch error: {exc}", flush=True)
        time.sleep(interval)


if __name__ == "__main__":
    import sys
    if "--watch" in sys.argv:
        watch_inbox()
    else:
        consumed, failed = consume_inbox()
        print(f"wechat-ingest: consumed={consumed} failed={failed}")
