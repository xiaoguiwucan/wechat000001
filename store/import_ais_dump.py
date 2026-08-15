#!/usr/bin/env python3
"""Offline import of an 爱思-extracted iOS WeChat Documents dump.

Wipes 群聊/私聊/公众号/索引 (never the 历史记录 dump) and rebuilds the store
from message_1..4.sqlite + WCDB_Contact.sqlite + Img/Audio/Video/OpenData.

iOS dump conventions used here:
- Chat table name is Chat_<md5(username)>
- media lives at {Img|Audio|Video|OpenData}/<md5(username)>/<MesLocalID>.<ext>
- Des=0 is sent by self, Des=1 is received
- group incoming text is ``senderId:\\nbody``
- WCDB compresses non-text Message blobs with zstd dict id 5 (MsgDict.zstd).
  Without that dict, media XML/sender prefix is unavailable; files are still
  attached by MesLocalID.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import sqlite3
import sys
import time
from pathlib import Path

import consumer
import history_map
import media
import readable

SELF_WXID = os.environ.get("WECHAT_SELF_WXID", "")
SELF_NAME = os.environ.get("WECHAT_SELF_NAME", "")
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
_XML_TYPE = re.compile(r"<type>(\d+)</type>", re.I)
_MEMBER = re.compile(
    r'<Member\s+UserName="([^"]+)"[^>]*>(.*?)</Member>',
    re.I | re.S,
)
_DISPLAY = re.compile(r"<DisplayName>(.*?)</DisplayName>", re.I | re.S)


def proto_strings(blob: bytes | None) -> list[tuple[int, str]]:
    """Pull length-delimited UTF-8 strings out of a protobuf blob."""
    if not blob:
        return []
    out: list[tuple[int, str]] = []
    i = 0
    n = len(blob)
    while i < n:
        key = 0
        shift = 0
        while i < n:
            b = blob[i]
            i += 1
            key |= (b & 0x7F) << shift
            if not (b & 0x80):
                break
            shift += 7
            if shift > 35:
                return out
        field = key >> 3
        wtype = key & 7
        if wtype == 0:
            while i < n:
                b = blob[i]
                i += 1
                if not (b & 0x80):
                    break
        elif wtype == 1:
            i += 8
        elif wtype == 5:
            i += 4
        elif wtype == 2:
            ln = 0
            shift = 0
            while i < n:
                b = blob[i]
                i += 1
                ln |= (b & 0x7F) << shift
                if not (b & 0x80):
                    break
                shift += 7
            chunk = blob[i : i + ln]
            i += ln
            try:
                text = chunk.decode("utf-8")
            except UnicodeDecodeError:
                out.extend((field * 100 + f, s) for f, s in proto_strings(chunk))
                continue
            if text:
                out.append((field, text))
        else:
            break
    return out


def parse_remark(blob: bytes | None) -> dict[str, str]:
    fields: dict[int, str] = {}
    for num, text in proto_strings(blob):
        fields.setdefault(num, text)
    return {
        "nickname": fields.get(1, ""),
        "alias": fields.get(2, ""),
        "remark": fields.get(3, ""),
    }


def display_name(info: dict[str, str], *, prefer_id: bool = False) -> str:
    if prefer_id:
        return info.get("alias") or info.get("username") or ""
    raw = (
        info.get("remark")
        or info.get("nickname")
        or info.get("alias")
        or info.get("username")
        or ""
    )
    return html.unescape(raw) if raw else ""


def looks_thumb(name: str) -> bool:
    low = name.lower()
    return "thum" in low or "thumb" in low


def media_score(path: Path) -> tuple[int, int]:
    name = path.name.lower()
    rank = 0
    if name.endswith(".pic_hd"):
        rank = 100
    elif name.endswith(".mp4") or name.endswith(".mov"):
        rank = 90
    elif name.endswith(".pic") or name.endswith(".jpg") or name.endswith(".jpeg") or name.endswith(".png"):
        rank = 80
    elif name.endswith(".gif") or name.endswith(".wxam"):
        rank = 75
    elif name.endswith(".aud") or name.endswith(".silk") or name.endswith(".slk"):
        rank = 70
    elif path.suffix.lower() in {".xlsx", ".xls", ".docx", ".doc", ".pptx", ".ppt", ".pdf", ".txt", ".md", ".csv"}:
        rank = 85
    else:
        rank = 40
    try:
        size = path.stat().st_size
    except OSError:
        size = 0
    return (rank, size)


def index_chat_media(dump: Path, chat_md5: str) -> dict[str, Path]:
    """Best non-thumb file per MesLocalID for one chat."""
    found: dict[str, Path] = {}
    scores: dict[str, tuple[int, int]] = {}
    for kind in ("Img", "Audio", "Video", "OpenData"):
        folder = dump / kind / chat_md5
        if not folder.is_dir():
            continue
        try:
            entries = folder.iterdir()
        except OSError:
            continue
        for path in entries:
            if not path.is_file() or looks_thumb(path.name):
                continue
            lid = path.name.split(".", 1)[0]
            if not lid:
                continue
            score = media_score(path)
            prev = scores.get(lid)
            if prev is None or score > prev:
                found[lid] = path
                scores[lid] = score
    return found


def decode_message(raw, decompressor) -> str:
    if raw is None:
        return ""
    if isinstance(raw, str):
        return raw
    if not isinstance(raw, (bytes, bytearray)):
        return str(raw)
    data = bytes(raw)
    if data.startswith(ZSTD_MAGIC):
        if decompressor is None:
            return ""
        try:
            out = decompressor.decompress(data)
        except Exception:
            return ""
        if isinstance(out, str):
            return out
        try:
            return out.decode("utf-8", errors="replace")
        except Exception:
            return ""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("utf-8", errors="replace")


def split_group_body(raw: str) -> tuple[str, str]:
    text = raw or ""
    cut = text.find(":\n")
    if 0 < cut < 80:
        who = text[:cut].strip()
        if who and ("@" in who or who.startswith("wxid_") or re.match(r"^[\w.\-]{2,40}$", who)):
            return who, text[cut + 2 :]
    return "", text


def map_msg_type(raw_type: int, content: str) -> str:
    return history_map.map_msg_type(raw_type, content)


def resolve_dump_root(path: Path) -> Path:
    path = Path(path)
    nested = path / path.name
    if (nested / "DB").is_dir():
        return nested
    if (path / "DB").is_dir():
        return path
    raise FileNotFoundError(f"no DB/ under {path}")


def load_zstd_decompressor(dict_path: Path | None):
    if dict_path is None:
        return None
    dict_path = Path(dict_path)
    if not dict_path.is_file():
        return None
    try:
        import zstandard
    except ImportError:
        print("import_ais_dump: zstandard not installed; compressed XML skipped", flush=True)
        return None
    try:
        ddict = zstandard.ZstdCompressionDict(dict_path.read_bytes())
        return zstandard.ZstdDecompressor(dict_data=ddict)
    except Exception as exc:
        print(f"import_ais_dump: zstd dict load failed: {exc}", flush=True)
        return None


def load_contacts(dump: Path) -> tuple[dict[str, dict[str, str]], dict[str, str]]:
    """Return (username->info, alias/username/md5 -> username)."""
    contacts: dict[str, dict[str, str]] = {}
    lookup: dict[str, str] = {}
    db = dump / "DB" / "WCDB_Contact.sqlite"
    if not db.is_file():
        raise FileNotFoundError(db)

    def ingest(user: str, remark, room, kind_hint: str = "") -> None:
        info = parse_remark(remark)
        info["username"] = user
        members: dict[str, str] = {}
        if room:
            xml = ""
            for _n, text in proto_strings(room):
                if "<RoomData" in text or "<Member" in text:
                    xml = text
                    break
            for m in _MEMBER.finditer(xml or ""):
                wxid = m.group(1)
                disp = _DISPLAY.search(m.group(2) or "")
                members[wxid] = (disp.group(1).strip() if disp else "")
        info["members"] = members  # type: ignore[assignment]
        if user.endswith("@chatroom"):
            info["kind"] = "group"
        elif user.startswith("gh_"):
            info["kind"] = "official"
        else:
            info["kind"] = kind_hint or "dm"
        contacts[user] = info
        lookup[user] = user
        lookup[hashlib.md5(user.encode("utf-8")).hexdigest()] = user
        if info.get("alias"):
            lookup[info["alias"]] = user

    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        for table in ("Friend", "OpenIMContact"):
            exists = con.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
            ).fetchone()
            if not exists:
                continue
            for user, remark, room in con.execute(
                f"SELECT userName, dbContactRemark, dbContactChatRoom FROM {table}"
            ):
                if not user:
                    continue
                ingest(str(user), remark, room)
    finally:
        con.close()

    session = dump / "session" / "session.db"
    if session.is_file():
        scon = sqlite3.connect(f"file:{session}?mode=ro", uri=True)
        try:
            for (user,) in scon.execute("SELECT UsrName FROM SessionAbstract"):
                if not user:
                    continue
                user = str(user)
                lookup.setdefault(user, user)
                lookup.setdefault(hashlib.md5(user.encode("utf-8")).hexdigest(), user)
                if user not in contacts:
                    contacts[user] = {
                        "username": user,
                        "nickname": "",
                        "alias": "",
                        "remark": "",
                        "kind": "group" if user.endswith("@chatroom") else ("official" if user.startswith("gh_") else "dm"),
                        "members": {},
                    }
        finally:
            scon.close()

    contacts.setdefault(
        SELF_WXID,
        {
            "username": SELF_WXID,
            "nickname": SELF_NAME,
            "alias": "",
            "remark": SELF_NAME,
            "kind": "dm",
            "members": {},
        },
    )
    lookup[SELF_WXID] = SELF_WXID
    lookup[hashlib.md5(SELF_WXID.encode("utf-8")).hexdigest()] = SELF_WXID
    lookup[SELF_NAME] = SELF_WXID
    return contacts, lookup


def sender_display(sender: str, contacts: dict, lookup: dict, chat_info: dict | None) -> str:
    if not sender:
        return ""
    if sender == SELF_WXID or sender == SELF_NAME:
        return SELF_NAME
    members = (chat_info or {}).get("members") or {}
    if sender in members and members[sender]:
        return members[sender]
    user = lookup.get(sender, sender)
    info = contacts.get(user)
    if info:
        return display_name(info)
    return sender


def infer_kind(chat_id: str, sample_bodies: list[str]) -> str:
    if chat_id.endswith("@chatroom"):
        return "group"
    if chat_id.startswith("gh_"):
        return "official"
    hits = 0
    for body in sample_bodies:
        who, _ = split_group_body(body)
        if who:
            hits += 1
    if hits >= 3:
        return "group"
    return "dm"


def build_event(
    *,
    chat_id: str,
    chat_kind: str,
    chat_name: str,
    row_lid,
    row_ts,
    row_des,
    row_type,
    content: str,
    contacts: dict,
    lookup: dict,
    chat_info: dict | None,
) -> dict:
    try:
        raw_type = int(row_type or 0)
    except (TypeError, ValueError):
        raw_type = 0
    try:
        ts = int(row_ts or 0)
    except (TypeError, ValueError):
        ts = 0
    try:
        des = int(row_des or 0)
    except (TypeError, ValueError):
        des = 0
    lid = str(row_lid)
    msg_type = map_msg_type(raw_type, content)
    is_self = des == 0
    sender = ""
    body = content
    if is_self:
        sender = SELF_WXID
        if chat_kind == "group":
            who, rest = split_group_body(content)
            if who and who not in {SELF_WXID, SELF_NAME} and not who.endswith("@chatroom"):
                # rare: mis-tagged, keep prefix if it is clearly someone else
                pass
            else:
                body = content
    else:
        if chat_kind == "group":
            sender, body = split_group_body(content)
        else:
            sender = chat_id
            body = content
    if msg_type == "text":
        text = body
    elif msg_type == "file":
        title = history_map.xml_tag(content, "title")
        text = title or "[file]"
    elif msg_type in {"image", "voice", "video", "emoji", "redpacket"}:
        text = f"[{msg_type}]"
    else:
        text = body or f"[{msg_type}]"

    extra: dict = {"full_export": True, "ais_dump": True, "raw_type": raw_type}
    if msg_type in {"file", "raw", "emoji", "redpacket"} and content:
        extra["xml"] = content[:8000]
        filename = history_map.xml_tag(content, "title")
        ext = history_map.xml_tag(content, "fileext")
        if filename:
            extra["filename"] = filename
        if ext:
            extra["fileext"] = ext
    sname = sender_display(sender, contacts, lookup, chat_info)
    return {
        "chat_id": chat_id,
        "chat_kind": "dm" if chat_kind == "official" else chat_kind,
        "chat_name": chat_name,
        "msg_id": lid,
        "msg_type": msg_type,
        "sender": sender,
        "sender_name": sname,
        "ts": ts,
        "text": text,
        "media_path": None,
        "extra_json": json.dumps(extra, ensure_ascii=False),
        "is_self": is_self,
    }


def place_media(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        return
    try:
        os.link(src, dest)
    except OSError:
        shutil.copy2(src, dest)


def sanitize_folder(name: str) -> str:
    return consumer._sanitize_folder_name(name) or ""


def chat_folder_name(chat_id: str, chat_name: str, used: set[str]) -> str:
    wanted = sanitize_folder(chat_name) or sanitize_folder(chat_id) or chat_id
    if wanted not in used:
        used.add(wanted)
        return wanted
    suffix = chat_id[:12]
    alt = f"{wanted}_{suffix}"
    n = 2
    while alt in used:
        alt = f"{wanted}_{suffix}_{n}"
        n += 1
    used.add(alt)
    return alt


def wipe_store(root: Path) -> None:
    consumer.wipe_imported(root)
    for extra in ("总览.md", "index.sqlite", "chats.json"):
        path = root / extra
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    inbox = root / consumer.DIR_INBOX
    if inbox.is_dir():
        for p in inbox.glob("*.json"):
            try:
                p.unlink()
            except OSError:
                pass
        shutil.rmtree(inbox / ".processing", ignore_errors=True)
        shutil.rmtree(inbox / consumer.DIR_FAILED, ignore_errors=True)
        shutil.rmtree(inbox / "failed", ignore_errors=True)


def list_chat_tables(db_path: Path) -> list[str]:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        return [
            r[0]
            for r in con.execute(
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name LIKE 'Chat_%' AND name NOT LIKE 'ChatExt%'"
            )
        ]
    finally:
        con.close()


def import_dump(
    root: Path,
    dump: Path,
    *,
    wipe: bool = True,
    dict_path: Path | None = None,
    refresh_md: bool = True,
) -> dict:
    root = Path(root)
    dump = resolve_dump_root(dump)
    db_dir = dump / "DB"
    if wipe:
        print("import_ais_dump: wiping 群聊/私聊/公众号/索引", flush=True)
        wipe_store(root)
    root.mkdir(parents=True, exist_ok=True)
    for name in (consumer.DIR_GROUPS, consumer.DIR_DMS, consumer.DIR_OFFICIAL):
        (root / name).mkdir(parents=True, exist_ok=True)

    print("import_ais_dump: loading contacts", flush=True)
    contacts, lookup = load_contacts(dump)
    decompressor = load_zstd_decompressor(dict_path)
    print(
        f"import_ais_dump: contacts={len(contacts)} zstd_dict={'yes' if decompressor else 'no'}",
        flush=True,
    )

    mapping: dict = {}
    used_folders = {consumer.DIR_GROUPS: set(), consumer.DIR_DMS: set(), consumer.DIR_OFFICIAL: set()}
    stats = {
        "chats": 0,
        "messages": 0,
        "media": 0,
        "compressed_empty": 0,
        "skipped_empty": 0,
        "unmapped": 0,
    }

    conn = consumer.init_db(root)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=OFF")
        conn.execute("PRAGMA temp_store=MEMORY")
        for db_name in ("message_1.sqlite", "message_2.sqlite", "message_3.sqlite", "message_4.sqlite"):
            db_path = db_dir / db_name
            if not db_path.is_file():
                continue
            tables = list_chat_tables(db_path)
            print(f"import_ais_dump: {db_name} chats={len(tables)}", flush=True)
            src = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
            src.text_factory = bytes
            try:
                for table in tables:
                    chat_md5 = table[5:]
                    username = lookup.get(chat_md5)
                    if not username:
                        stats["unmapped"] += 1
                        username = chat_md5
                    info = contacts.get(username) or {"username": username, "members": {}}
                    kind_hint = info.get("kind") or (
                        "group" if username.endswith("@chatroom") else ("official" if username.startswith("gh_") else "dm")
                    )
                    chat_name = display_name(info) if username in contacts else ""
                    if not chat_name or chat_name == username:
                        chat_name = username if not username.endswith("@chatroom") else username
                    if username == SELF_WXID:
                        chat_name = "我"
                    rows = src.execute(
                        f"SELECT MesLocalID, CreateTime, Des, Type, Message FROM {table} ORDER BY MesLocalID"
                    )
                    events: list[dict] = []
                    sample_bodies: list[str] = []
                    for lid, ts, des, typ, raw in rows:
                        content = decode_message(raw, decompressor)
                        if isinstance(raw, (bytes, bytearray)) and raw.startswith(ZSTD_MAGIC) and not content:
                            stats["compressed_empty"] += 1
                        if content and len(sample_bodies) < 12:
                            sample_bodies.append(content)
                        events.append((lid, ts, des, typ, content))
                    if not events:
                        stats["skipped_empty"] += 1
                        continue
                    chat_kind = infer_kind(username, sample_bodies) if username == chat_md5 else kind_hint
                    if chat_kind == "official":
                        kind_dir = consumer.DIR_OFFICIAL
                        store_kind = "dm"
                    elif chat_kind == "group":
                        kind_dir = consumer.DIR_GROUPS
                        store_kind = "group"
                    else:
                        kind_dir = consumer.DIR_DMS
                        store_kind = "dm"
                    folder = chat_folder_name(username, chat_name, used_folders[kind_dir])
                    chat_dir = root / kind_dir / folder
                    chat_dir.mkdir(parents=True, exist_ok=True)
                    media_idx = index_chat_media(dump, chat_md5)
                    mapped: list[dict] = []
                    for lid, ts, des, typ, content in events:
                        ev = build_event(
                            chat_id=username,
                            chat_kind=store_kind,
                            chat_name=chat_name if chat_name != username or not username.endswith("@chatroom") else folder,
                            row_lid=lid.decode() if isinstance(lid, bytes) else lid,
                            row_ts=ts.decode() if isinstance(ts, bytes) else ts,
                            row_des=des.decode() if isinstance(des, bytes) else des,
                            row_type=typ.decode() if isinstance(typ, bytes) else typ,
                            content=content,
                            contacts=contacts,
                            lookup=lookup,
                            chat_info=info,
                        )
                        ev["chat_kind"] = store_kind
                        src_media = media_idx.get(str(ev["msg_id"]))
                        if src_media is not None:
                            filename = src_media.name
                            extra_name = ""
                            try:
                                extra_obj = json.loads(ev["extra_json"] or "{}")
                                extra_name = str(extra_obj.get("filename") or "")
                                ext = str(extra_obj.get("fileext") or "")
                            except (json.JSONDecodeError, TypeError):
                                extra_name, ext = "", ""
                            if extra_name:
                                safe = sanitize_folder(extra_name) or filename
                                if ext and not safe.lower().endswith("." + ext.lower()):
                                    safe = f"{safe}.{ext}"
                                filename = f"{ev['msg_id']}_{safe}"
                            ext = Path(filename).suffix.lower()
                            if ext in {".xlsx", ".xls", ".docx", ".doc", ".pptx", ".ppt", ".pdf", ".txt", ".md", ".csv"}:
                                ev["msg_type"] = "file"
                                if not ev.get("text") or ev.get("text") in {"[raw]", "[file]"}:
                                    ev["text"] = extra_name or filename
                            sub = media.media_folder(str(ev["msg_type"]), filename)
                            dest = chat_dir / sub / filename
                            place_media(src_media, dest)
                            ev["media_path"] = f"{kind_dir}/{folder}/{sub}/{filename}"
                            ev["text"] = media.media_text(ev["msg_type"], ev.get("text"))
                            stats["media"] += 1
                        mapped.append(ev)
                    log = chat_dir / consumer.FILE_EVENTS
                    with log.open("w", encoding="utf-8") as fh:
                        for ev in mapped:
                            fh.write(json.dumps(ev, ensure_ascii=False) + "\n")
                    conn.executemany(
                        consumer.INSERT_SQL,
                        [
                            {
                                "chat_id": ev["chat_id"],
                                "chat_kind": ev["chat_kind"],
                                "msg_id": ev["msg_id"],
                                "msg_type": ev["msg_type"],
                                "sender": ev["sender"],
                                "ts": ev["ts"],
                                "text": ev.get("text"),
                                "media_path": ev.get("media_path"),
                                "extra_json": ev.get("extra_json"),
                            }
                            for ev in mapped
                        ],
                    )
                    mapping[f"{store_kind}:{username}"] = {
                        "chat_id": username,
                        "chat_kind": store_kind,
                        "chat_name": chat_name,
                        "folder": folder,
                    }
                    stats["chats"] += 1
                    stats["messages"] += len(mapped)
                    if len(mapped) >= 1000 or stats["chats"] % 20 == 0:
                        conn.commit()
                        print(
                            f"import_ais_dump: progress chats={stats['chats']} msgs={stats['messages']} media={stats['media']} last={folder} n={len(mapped)}",
                            flush=True,
                        )
            finally:
                src.close()
        conn.commit()
    finally:
        conn.close()

    consumer._save_chats_map(root, mapping)
    if refresh_md:
        print("import_ais_dump: rendering 聊天记录.md", flush=True)
        try:
            readable.refresh(root)
        except Exception as exc:
            print(f"import_ais_dump: readable.refresh failed: {exc}", flush=True)
    print(f"import_ais_dump: done {json.dumps(stats, ensure_ascii=False)}", flush=True)
    return stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Import 爱思 iOS WeChat dump into fnOS store")
    parser.add_argument("--root", default=str(consumer.default_root()))
    parser.add_argument(
        "--dump",
        default=os.environ.get("WECHAT_AIS_DUMP", ""),
    )
    parser.add_argument("--dict", dest="dict_path", default="")
    parser.add_argument("--no-wipe", action="store_true")
    parser.add_argument("--no-md", action="store_true")
    args = parser.parse_args(argv)
    started = time.time()
    import_dump(
        Path(args.root),
        Path(args.dump),
        wipe=not args.no_wipe,
        dict_path=Path(args.dict_path) if args.dict_path else None,
        refresh_md=not args.no_md,
    )
    print(f"import_ais_dump: elapsed={time.time() - started:.1f}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
