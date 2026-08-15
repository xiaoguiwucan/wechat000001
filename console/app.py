#!/usr/bin/env python3
"""WeChat-style console for wechat-ingest. Stdlib only — no pip required."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import sqlite3
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse

ROOT = Path(os.environ.get("WECHAT_INGEST_ROOT", "/vol1/1000/iphone微信蒸馏上传数据"))
PORT = int(os.environ.get("CONSOLE_PORT", "18791"))
LAN_URL = os.environ.get("CONSOLE_LAN_URL", f"http://192.168.1.10:{PORT}")
PUBLIC_URL = os.environ.get("CONSOLE_PUBLIC_URL", "http://hj.wwszxc.tax:31632")
SILK_DECODER = os.environ.get("SILK_DECODER", "/home/zkx/wechat-ingest/tools/silk-decoder")
STATIC_DIR = Path(__file__).resolve().parent / "static"
SELF_WXID = os.environ.get("WECHAT_SELF_WXID", "wxid_7786337863012")
VERSION = "1.5.11"
SELF_NAME = os.environ.get("WECHAT_SELF_NAME", "风")
SETTINGS_NAME = "console.json"
CONSOLE_USER = os.environ.get("CONSOLE_USER", "zkx")
CONSOLE_PASSWORD = os.environ.get("CONSOLE_PASSWORD", "")
CONSOLE_SECRET = os.environ.get("CONSOLE_SECRET") or secrets.token_hex(32)
SESSION_COOKIE = "wx_console_sess"
SESSION_TTL = 12 * 3600
_login_fails: dict[str, list[float]] = {}
_login_lock = threading.Lock()

LOGIN_HTML = """<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<meta name="robots" content="noindex,nofollow"/>
<title>登录 · 微信记忆</title>
<style>
html,body{height:100%;margin:0}
body{min-height:100vh;display:flex;align-items:center;justify-content:center;
background:#f4ebe6;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Helvetica Neue",sans-serif;color:#2c1814}
.wrap{width:min(300px,88vw);text-align:center}
.logo{width:72px;height:36px;margin:0 auto 14px;border-radius:18px;overflow:hidden;border:1.6px solid #2c1814;
display:flex;font-size:15px;font-weight:800}
.logo i{flex:1;display:grid;place-items:center;background:#ee524c;color:#fff8f4}
.logo b{flex:1;display:grid;place-items:center;background:#fffdf9;color:#2c1814}
h1{margin:0 0 4px;font-size:20px;color:#2c1814;font-weight:800}
p{margin:0 0 18px;color:#7a4a42;font-size:13px}
form{background:#fffdf9;border-radius:16px;padding:18px 16px 14px;text-align:left;border:1.6px solid #2c1814}
label{display:block;font-size:11px;color:#ee524c;font-weight:800;margin:8px 0 4px}
input{width:100%;box-sizing:border-box;height:36px;border:1.2px solid #2c181428;
padding:0 10px;font-size:15px;background:#f7f1ee;border-radius:999px}
input:focus{outline:none;border-color:#ee524c}
button{width:100%;height:38px;margin-top:16px;border:1.6px solid #2c1814;border-radius:999px;background:#ee524c;color:#fff8f4;font-size:15px;font-weight:800}
button:hover{filter:brightness(1.04)}
.err{color:#ee524c;font-size:12px;min-height:16px;margin-top:8px;text-align:center}
</style></head><body>
<div class="wrap">
<div class="logo"><i>记</i><b>忆</b></div>
<h1>微信记忆</h1>
<p>本地账号登录</p>
<form method="post" action="/login" autocomplete="current-password">
<label>账号</label>
<input name="username" autocomplete="username" required/>
<label>密码</label>
<input name="password" type="password" autocomplete="current-password" required/>
<div class="err">__ERR__</div>
<button type="submit">登录</button>
</form>
</div></body></html>
"""


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _unb64(text: str) -> bytes:
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def _sign(payload: str) -> str:
    return hmac.new(CONSOLE_SECRET.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).hexdigest()


def make_session_cookie(username: str) -> str:
    exp = int(time.time()) + SESSION_TTL
    payload = f"{username}|{exp}"
    return _b64(f"{payload}|{_sign(payload)}".encode("utf-8"))


def parse_session_cookie(raw: str | None) -> str | None:
    if not raw:
        return None
    try:
        decoded = _unb64(raw).decode("utf-8")
        user, exp_s, sig = decoded.rsplit("|", 2)
        payload = f"{user}|{exp_s}"
        if not hmac.compare_digest(sig, _sign(payload)):
            return None
        if int(exp_s) < int(time.time()):
            return None
        if not hmac.compare_digest(user, CONSOLE_USER):
            return None
        return user
    except (ValueError, UnicodeDecodeError, TypeError):
        return None


def auth_configured() -> bool:
    return bool(CONSOLE_USER and CONSOLE_PASSWORD)


def credentials_ok(username: str, password: str) -> bool:
    if not auth_configured():
        return False
    user_ok = hmac.compare_digest(username or "", CONSOLE_USER)
    pass_ok = hmac.compare_digest(password or "", CONSOLE_PASSWORD)
    return bool(user_ok and pass_ok)


def login_allowed(ip: str) -> bool:
    now = time.time()
    with _login_lock:
        hits = [t for t in _login_fails.get(ip, []) if now - t < 600]
        _login_fails[ip] = hits
        return len(hits) < 8


def note_login_fail(ip: str) -> None:
    with _login_lock:
        _login_fails.setdefault(ip, []).append(time.time())


def parse_basic_auth(header: str | None) -> tuple[str, str] | None:
    if not header or not header.startswith("Basic "):
        return None
    try:
        raw = base64.b64decode(header[6:].strip()).decode("utf-8")
        user, password = raw.split(":", 1)
        return user, password
    except (ValueError, UnicodeDecodeError):
        return None


def parse_cookie_map(header: str | None) -> dict[str, str]:
    out: dict[str, str] = {}
    if not header:
        return out
    for part in header.split(";"):
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        out[key.strip()] = value.strip()
    return out

DIR_GROUPS = "群聊"
DIR_DMS = "私聊"
DIR_OFFICIAL = "公众号"
DIR_INBOX = "待入库"
FILE_EVENTS = "消息.jsonl"
FILE_CHATS = "会话对照.json"
FILE_INDEX = "索引.sqlite"


def _settings_path() -> Path:
    return ROOT / "status" / SETTINGS_NAME


def default_settings() -> dict:
    return {
        "lan_url": LAN_URL,
        "public_url": PUBLIC_URL,
        "token": "",
    }


def load_settings() -> dict:
    data = _load_json(_settings_path(), {})
    merged = default_settings()
    if isinstance(data, dict):
        for key in ("lan_url", "public_url", "token"):
            value = data.get(key)
            if isinstance(value, str) and value.strip():
                merged[key] = value.strip()
    return merged


def save_settings(update: dict) -> dict:
    current = load_settings()
    for key in ("lan_url", "public_url", "token"):
        if key in update and isinstance(update[key], str):
            current[key] = update[key].strip()
    path = _settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(current, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)
    return current


def public_settings() -> dict:
    s = load_settings()
    return {
        "lan_url": s["lan_url"],
        "public_url": s["public_url"],
        "has_token": bool(s["token"]),
        "frp_hint": "公网地址只影响展示；开隧道要改 frpc.ini",
    }


def _inbox_dir() -> Path:
    inbox = ROOT / DIR_INBOX
    if not inbox.is_dir() and (ROOT / "inbox").is_dir():
        return ROOT / "inbox"
    return inbox


def _load_json(path: Path, default):
    if not path.is_file():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


def _event_log(chat_dir: Path) -> Path | None:
    log = chat_dir / FILE_EVENTS
    if log.is_file():
        return log
    legacy = chat_dir / "events.jsonl"
    return legacy if legacy.is_file() else None


def _tail_text(path: Path, max_bytes: int) -> str:
    try:
        size = path.stat().st_size
    except OSError:
        return ""
    with path.open("rb") as fh:
        if size <= max_bytes:
            raw = fh.read()
        else:
            fh.seek(-max_bytes, os.SEEK_END)
            raw = fh.read()
    text = raw.decode("utf-8", errors="replace")
    if size > max_bytes:
        cut = text.find("\n")
        if cut >= 0:
            text = text[cut + 1 :]
    return text


def _last_event(chat_dir: Path) -> dict | None:
    log = _event_log(chat_dir)
    if log is None:
        return None
    text = _tail_text(log, 24576)
    last = None
    for line in text.splitlines():
        line = line.strip()
        if line:
            last = line
    if not last:
        return None
    try:
        ev = json.loads(last)
        return ev if isinstance(ev, dict) else None
    except json.JSONDecodeError:
        return None


def _msg_id_key(mid: object) -> tuple:
    text = str(mid or "")
    try:
        return (0, int(text))
    except (TypeError, ValueError):
        return (1, text)


def _event_sort_key(ev: dict) -> tuple:
    try:
        ts = int(ev.get("ts") or 0)
    except (TypeError, ValueError):
        ts = 0
    return (ts, _msg_id_key(ev.get("msg_id")))


def _events_from_text(text: str) -> list[dict]:
    rows: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(ev, dict):
            rows.append(ev)
    by_id: dict[str, dict] = {}
    order: list[str] = []
    for ev in rows:
        mid = str(ev.get("msg_id") or "")
        prev = by_id.get(mid)
        if prev is None:
            by_id[mid] = ev
            order.append(mid)
            continue
        if ev.get("media_path") and not prev.get("media_path"):
            by_id[mid] = ev
        elif ev.get("sender_name") and not prev.get("sender_name"):
            by_id[mid] = ev
    rows = [by_id[mid] for mid in order]
    book = _nickbook_from_events(rows)
    rows = [polish_message(ev, book) for ev in rows]
    rows.sort(key=_event_sort_key)
    return rows


def _read_events(
    chat_dir: Path,
    limit: int,
    before_ts: int | None = None,
    before_id: str | None = None,
) -> list[dict]:
    log = _event_log(chat_dir)
    if log is None:
        return []
    want = limit if limit > 0 else 80
    try:
        size = log.stat().st_size
    except OSError:
        return []
    if size <= 0:
        return []
    cursor = None
    if before_ts is not None:
        cursor = (int(before_ts), _msg_id_key(before_id or ""))
    chunk = min(size, max(96_000, want * 2500))
    max_chunk = min(size, 24 * 1024 * 1024)
    rows: list[dict] = []
    while True:
        parsed = _events_from_text(_tail_text(log, chunk))
        if cursor is None:
            rows = parsed
        else:
            rows = [ev for ev in parsed if _event_sort_key(ev) < cursor]
        if len(rows) >= want or chunk >= size or chunk >= max_chunk:
            break
        chunk = min(size, max_chunk, max(chunk * 2, chunk + 256_000))
    if want > 0:
        rows = rows[-want:]
    return rows


def _index_counts() -> tuple[int, int] | None:
    db = ROOT / FILE_INDEX
    if not db.is_file():
        db = ROOT / "index.sqlite"
    if not db.is_file():
        return None
    try:
        conn = sqlite3.connect(f"file:{quote(str(db))}?mode=ro", uri=True, timeout=0.8)
        try:
            messages = conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
            media = conn.execute(
                "SELECT COUNT(*) FROM events WHERE media_path IS NOT NULL AND media_path != ''"
            ).fetchone()[0]
        finally:
            conn.close()
        return int(messages), int(media)
    except sqlite3.Error:
        return None


def _count_messages() -> int:
    counts = _index_counts()
    if counts is not None:
        return counts[0]
    total = 0
    for kind in (DIR_GROUPS, DIR_DMS, DIR_OFFICIAL, "groups", "dms"):
        base = ROOT / kind
        if not base.is_dir():
            continue
        for folder in base.iterdir():
            if not folder.is_dir():
                continue
            log = _event_log(folder)
            if log is None:
                continue
            try:
                total += max(0, log.stat().st_size // 180)
            except OSError:
                continue
    return total


def _count_media() -> int:
    counts = _index_counts()
    if counts is not None:
        return counts[1]
    return 0


def _plugin_status() -> dict:
    return _load_json(ROOT / "status" / "plugin.json", {})


def _build_server_status() -> dict:
    inbox = _inbox_dir()
    pending = 0
    if inbox.is_dir():
        pending = len([p for p in inbox.glob("*.json") if not p.name.startswith("names")])
    plugin = _plugin_status()
    plugin_ts = int(plugin.get("ts") or 0)
    plugin_age = time.time() - plugin_ts if plugin_ts else 10**9
    chats_map = _load_json(ROOT / FILE_CHATS, {})
    settings = load_settings()
    return {
        "role": "console",
        "version": VERSION,
        "ts": int(time.time()),
        "status": "ok",
        "url": settings["public_url"] or settings["lan_url"],
        "lan_url": settings["lan_url"],
        "public_url": settings["public_url"],
        "data_root": str(ROOT),
        "inbox_pending": pending,
        "chats": len(chats_map) if isinstance(chats_map, dict) else 0,
        "messages": _count_messages(),
        "media_files": _count_media(),
        "plugin_online": bool(plugin) and plugin_age < 60,
        "plugin": plugin,
        "consumer_ok": True,
    }


def write_server_status() -> dict:
    status = _build_server_status()
    path = ROOT / "status" / "server.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(status, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)
    return status


def list_chats() -> list[dict]:
    mapping = _load_json(ROOT / FILE_CHATS, {})
    folder_meta: dict[tuple[str, str], dict] = {}
    if isinstance(mapping, dict):
        for rec in mapping.values():
            if not isinstance(rec, dict):
                continue
            folder = rec.get("folder") or rec.get("chat_id") or ""
            kind = rec.get("chat_kind") or ("group" if str(rec.get("chat_id", "")).endswith("@chatroom") else "dm")
            folder_meta[(kind, folder)] = rec

    chats: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for kind_dir, kind in ((DIR_GROUPS, "group"), (DIR_DMS, "dm"), (DIR_OFFICIAL, "official")):
        base = ROOT / kind_dir
        if not base.is_dir():
            continue
        for folder in sorted(base.iterdir(), key=lambda p: p.name):
            if not folder.is_dir():
                continue
            rec = folder_meta.get((kind if kind != "official" else "dm", folder.name), {})
            chat_id = str(rec.get("chat_id") or folder.name)
            if chat_id == SELF_WXID:
                continue
            last = _last_event(folder)
            if last:
                last = polish_message(dict(last))
            preview = ""
            ts = 0
            if last:
                preview = str(last.get("text") or f"[{last.get('msg_type')}]")
                preview = {
                    "[image]": "[图片]",
                    "[voice]": "[语音]",
                    "[video]": "[视频]",
                    "[emoji]": "[动画表情]",
                    "[redpacket]": "[红包]",
                    "[raw]": "[卡片]",
                    "[卡片消息]": "[卡片]",
                    "[语音通话]": "[语音通话]",
                    "[位置]": "[位置]",
                    "[名片]": "[名片]",
                }.get(preview, preview)
                ts = int(last.get("ts") or 0)
            else:
                continue
            chats.append({
                "kind": kind,
                "folder": folder.name,
                "chat_id": rec.get("chat_id") or folder.name,
                "name": rec.get("chat_name") or (last.get("chat_name") if last else None) or folder.name,
                "preview": preview[:80],
                "ts": ts,
            })
            seen.add((kind if kind != "official" else "dm", folder.name))
    chats.sort(key=lambda c: c["ts"], reverse=True)
    return chats


def chat_dir(kind: str, folder: str) -> Path | None:
    if "/" in folder or "\\" in folder or folder in {".", ".."}:
        return None
    if kind == "group":
        base = ROOT / DIR_GROUPS
    elif kind == "official":
        base = ROOT / DIR_OFFICIAL
    else:
        base = ROOT / DIR_DMS
    path = (base / folder).resolve()
    try:
        path.relative_to(base.resolve())
    except ValueError:
        return None
    return path if path.is_dir() else None


def safe_media(rel: str) -> Path | None:
    rel = rel.lstrip("/")
    if not rel or ".." in Path(rel).parts:
        return None
    path = (ROOT / rel).resolve()
    try:
        path.relative_to(ROOT.resolve())
    except ValueError:
        return None
    return path if path.is_file() else None


def debug_log_dir() -> Path:
    path = ROOT / "status" / "logs"
    path.mkdir(parents=True, exist_ok=True)
    return path


def archive_current_debug_log() -> Path | None:
    src = ROOT / "status" / "debug.log"
    if not src.is_file():
        return None
    dest_dir = debug_log_dir()
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(src.stat().st_mtime))
    dest = dest_dir / f"debug-{stamp}.log"
    for existing in dest_dir.glob("debug-*.log"):
        try:
            if existing.stat().st_size == src.stat().st_size and abs(existing.stat().st_mtime - src.stat().st_mtime) < 2:
                return existing
        except OSError:
            continue
    if not dest.exists():
        dest.write_bytes(src.read_bytes())
    return dest


def list_debug_logs() -> list[dict]:
    archive_current_debug_log()
    items: list[dict] = []
    latest = ROOT / "status" / "debug.log"
    if latest.is_file():
        items.append({
            "name": "debug.log",
            "label": "当前最新",
            "ts": int(latest.stat().st_mtime),
            "size": latest.stat().st_size,
            "current": True,
        })
    for path in sorted(debug_log_dir().glob("debug-*.log"), key=lambda p: p.stat().st_mtime, reverse=True):
        items.append({
            "name": path.name,
            "label": path.name,
            "ts": int(path.stat().st_mtime),
            "size": path.stat().st_size,
            "current": False,
        })
    return items


def resolve_debug_log(name: str | None) -> Path | None:
    if not name or name in {"debug.log", "latest", "current"}:
        path = ROOT / "status" / "debug.log"
        return path if path.is_file() else None
    if "/" in name or "\\" in name or name in {".", ".."} or ".." in Path(name).parts:
        return None
    if not name.startswith("debug-") or not name.endswith(".log"):
        return None
    path = (debug_log_dir() / name).resolve()
    try:
        path.relative_to(debug_log_dir().resolve())
    except ValueError:
        return None
    return path if path.is_file() else None


def parse_log_line_ts(line: str) -> int | None:
    raw = line.strip()
    for fmt, width in (("%Y-%m-%d %H:%M:%S", 19), ("%H:%M:%S", 8)):
        if len(raw) < width:
            continue
        try:
            parsed = time.strptime(raw[:width], fmt)
            if fmt == "%H:%M:%S":
                today = time.localtime()
                parsed = time.struct_time((
                    today.tm_year, today.tm_mon, today.tm_mday,
                    parsed.tm_hour, parsed.tm_min, parsed.tm_sec,
                    today.tm_wday, today.tm_yday, today.tm_isdst,
                ))
            return int(time.mktime(parsed))
        except ValueError:
            continue
    return None


def filter_log_text(text: str, from_ts: int | None, to_ts: int | None) -> str:
    if from_ts is None and to_ts is None:
        return text
    kept: list[str] = []
    last_ts: int | None = None
    for line in text.splitlines():
        parsed = parse_log_line_ts(line)
        if parsed is not None:
            last_ts = parsed
        use = last_ts
        if use is None:
            continue
        if from_ts is not None and use < from_ts:
            continue
        if to_ts is not None and use > to_ts:
            continue
        kept.append(line)
    return "\n".join(kept)


def extract_hevc_from_wxgf(data: bytes) -> bytes | None:
    if not data.startswith((b"wxgf", b"wxam")):
        return None
    start = data.find(b"\x00\x00\x00\x01")
    if start < 0:
        start = data.find(b"\x00\x00\x01")
    if start < 0:
        return None
    return data[start:]


def decode_wxgf_bytes(data: bytes) -> tuple[bytes, str] | None:
    """Decode WeChat wxgf/wxam into PNG or GIF using ffmpeg."""
    hevc = extract_hevc_from_wxgf(data)
    if hevc is None:
        return None
    try:
        first = subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-f", "hevc", "-i", "pipe:0",
                "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-",
            ],
            input=hevc,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if first.returncode == 0 and first.stdout.startswith(b"\x89PNG"):
        return first.stdout, "image/png"
    return None


def decode_wxgf_file(src: Path) -> Path | None:
    cache = src.with_name(src.name + ".preview.png")
    try:
        if cache.is_file() and cache.stat().st_mtime >= src.stat().st_mtime and cache.stat().st_size > 32:
            return cache
    except OSError:
        pass
    try:
        raw = src.read_bytes()
    except OSError:
        return None
    decoded = decode_wxgf_bytes(raw)
    if decoded is None:
        return None
    body, _ctype = decoded
    tmp = cache.with_suffix(".png.tmp")
    try:
        tmp.write_bytes(body)
        tmp.replace(cache)
    except OSError:
        return None
    return cache if cache.is_file() else None


def sniff_magic(data: bytes) -> tuple[str, str]:
    """Return (kind, content_type) from file bytes."""
    if len(data) >= 3 and data[0] == 0xFF and data[1] == 0xD8:
        return "image", "image/jpeg"
    if len(data) >= 8 and data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image", "image/png"
    if len(data) >= 6 and data.startswith((b"GIF87a", b"GIF89a")):
        return "image", "image/gif"
    if len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "image", "image/webp"
    if len(data) >= 12 and data[4:8] == b"ftyp":
        return "video", "video/mp4"
    if len(data) >= 12 and data.startswith(b"\x00\x00\x00") and b"ftyp" in data[:16]:
        return "video", "video/mp4"
    if data.startswith(b"wxgf") or data.startswith(b"wxam"):
        return "wximage", "application/octet-stream"
    if data[:1] == b"\x02" and data[1:10] == b"#!SILK_V3":
        return "voice", "audio/silk"
    if data.startswith(b"#!SILK_V3"):
        return "voice", "audio/silk"
    if data.startswith(b"RIFF") and data[8:12] == b"WAVE":
        return "voice", "audio/wav"
    return "unknown", "application/octet-stream"


def sniff_path(path: Path) -> tuple[str, str]:
    try:
        data = path.read_bytes()[:64]
    except OSError:
        return "unknown", "application/octet-stream"
    kind, ctype = sniff_magic(data)
    if kind != "unknown":
        return kind, ctype
    guessed = mimetypes.guess_type(path.name)[0]
    if guessed and guessed.startswith("image/"):
        return "image", guessed
    if guessed and guessed.startswith("video/"):
        return "video", guessed
    if guessed and guessed.startswith("audio/"):
        return "voice", guessed
    suffix = path.suffix.lower()
    if suffix in {".mp4", ".mov", ".m4v"}:
        return "video", "video/mp4"
    if suffix in {".jpg", ".jpeg", ".png", ".gif", ".webp", ".pic", ".pic_hd"}:
        return "image", guessed or "image/jpeg"
    if suffix in {".aud", ".silk", ".slk", ".wav", ".mp3"}:
        return "voice", guessed or "audio/mpeg"
    return "unknown", guessed or "application/octet-stream"


def wav_duration_sec(path: Path) -> int:
    """Seconds from a PCM WAV; walks chunks so a LIST tag before data is fine."""
    import struct
    try:
        raw = path.read_bytes()
    except OSError:
        return 0
    if len(raw) < 44 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        return 0
    byte_rate = struct.unpack_from("<I", raw, 28)[0]
    pos = 12
    data_size = 0
    while pos + 8 <= len(raw):
        kind = raw[pos:pos + 4]
        size = struct.unpack_from("<I", raw, pos + 4)[0]
        if kind == b"data":
            data_size = size
            break
        pos += 8 + size + (size & 1)
    if byte_rate <= 0:
        return 0
    if data_size <= 0:
        data_size = max(0, len(raw) - 44)
    return max(1, round(data_size / byte_rate))


_PREFIX = re.compile(r"^([^\n:]{1,80}):\n(.*)$", re.S)


def _looks_id(value: str) -> bool:
    return (not value) or value.endswith("@chatroom") or value.startswith("wxid_") or value == "群系统"


AUDIO_SUFFIX = {".mp3", ".m4a", ".wav", ".aac", ".ogg", ".aud", ".silk", ".slk"}
VIDEO_SUFFIX = {".mp4", ".mov", ".m4v"}
RAW_TYPE_LABEL = {
    42: "名片",
    48: "位置",
    50: "语音通话",
    66: "名片",
}


def _extra(ev: dict) -> dict:
    raw = ev.get("extra_json")
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, str) or not raw:
        return {}
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def classify_raw(ev: dict) -> dict:
    """Turn imported ``[raw]`` stubs into a playable type or a Chinese label.

    爱思 dump type 49/50/48/42 blobs are zstd-compressed, so they land as
    ``msg_type=raw`` / ``text=[raw]``. If a file was attached by MesLocalID,
    promote it to voice/video/file so the console can play it. Otherwise
    show 名片/位置/语音通话/卡片消息 — never the literal ``[raw]``.
    """
    if not isinstance(ev, dict):
        return ev
    kind = ev.get("msg_type")
    path = ev.get("media_path") if isinstance(ev.get("media_path"), str) else ""
    suffix = Path(path).suffix.lower() if path else ""
    extra = _extra(ev)
    raw_type = extra.get("raw_type")
    try:
        raw_type = int(raw_type)
    except (TypeError, ValueError):
        raw_type = None

    if kind == "raw" or (isinstance(ev.get("text"), str) and ev["text"].strip() == "[raw]"):
        if suffix in AUDIO_SUFFIX or ev.get("media_kind") == "voice":
            ev["msg_type"] = "voice"
            if not ev.get("text") or ev.get("text") in {"[raw]", "[file]"}:
                ev["text"] = "[语音]"
        elif suffix in VIDEO_SUFFIX or ev.get("media_kind") == "video":
            ev["msg_type"] = "video"
            if not ev.get("text") or ev.get("text") in {"[raw]", "[file]"}:
                ev["text"] = "[视频]"
        elif path:
            ev["msg_type"] = "file"
            name = str(extra.get("filename") or Path(path).name)
            ev["text"] = name
        else:
            label = RAW_TYPE_LABEL.get(raw_type, "卡片消息")
            ev["msg_type"] = "raw"
            ev["card_kind"] = label
            ev["text"] = f"[{label}]"
    return ev


def estimate_voice_sec(path: Path) -> int:
    try:
        size = path.stat().st_size
    except OSError:
        return 1
    suffix = path.suffix.lower()
    if suffix == ".wav":
        return max(1, wav_duration_sec(path) or 1)
    if suffix in {".mp3", ".m4a", ".aac", ".ogg"}:
        return max(1, min(600, size // 16000 or 1))
    return max(1, min(60, size // 2800 or 1))


def polish_message(ev: dict, nickbook: dict[str, str] | None = None) -> dict:
    """Show 群员备注/昵称. Never show a chatroom id as a person."""
    if not isinstance(ev, dict):
        return ev
    book = nickbook or {}
    text = ev.get("text") if isinstance(ev.get("text"), str) else ""
    sender = str(ev.get("sender") or "")
    name = ev.get("sender_name") if isinstance(ev.get("sender_name"), str) else ""
    match = _PREFIX.match(text)
    if match:
        who, body = match.group(1).strip(), match.group(2)
        if who and not who.endswith("@chatroom"):
            ev["text"] = body
            if who.startswith("wxid_"):
                ev["sender"] = who
                pretty = book.get(who) or name
                if pretty and not _looks_id(pretty):
                    ev["sender_name"] = pretty
            else:
                ev["sender_name"] = book.get(who, who)
                ev["is_self"] = who in {SELF_WXID, SELF_NAME}
    sender = str(ev.get("sender") or "")
    if sender in book and (not ev.get("sender_name") or _looks_id(str(ev.get("sender_name")))):
        ev["sender_name"] = book[sender]
    name = ev.get("sender_name") if isinstance(ev.get("sender_name"), str) else ""
    if _looks_id(name):
        ev["sender_name"] = book.get(sender, "")
    if str(ev.get("sender") or "").endswith("@chatroom"):
        ev["is_self"] = False
        if _looks_id(str(ev.get("sender_name") or "")):
            ev["sender_name"] = ""
    if ev.get("is_self") and ev.get("sender_name") and ev["sender_name"] not in {SELF_NAME, SELF_WXID, sender}:
        if not _looks_id(str(ev.get("sender_name"))):
            ev["is_self"] = False
    return classify_raw(ev)


def _nickbook_from_events(events: list[dict]) -> dict[str, str]:
    book: dict[str, str] = {}
    mapping = _load_json(ROOT / FILE_CHATS, {})
    if isinstance(mapping, dict):
        for rec in mapping.values():
            if not isinstance(rec, dict):
                continue
            cid = str(rec.get("chat_id") or "")
            cname = str(rec.get("chat_name") or "")
            if cid and cname and not cid.endswith("@chatroom") and not _looks_id(cname):
                book[cid] = cname
    for ev in events:
        if not isinstance(ev, dict):
            continue
        sid = str(ev.get("sender") or "")
        sname = ev.get("sender_name") if isinstance(ev.get("sender_name"), str) else ""
        if sid and sname and not _looks_id(sname) and not sid.endswith("@chatroom"):
            book[sid] = sname
        text = ev.get("text") if isinstance(ev.get("text"), str) else ""
        match = _PREFIX.match(text)
        if match:
            who = match.group(1).strip()
            if who and not _looks_id(who):
                book[who] = who
    return book


def enrich_event(ev: dict) -> dict:
    path = ev.get("media_path")
    ev["play_url"] = ""
    ev["voice_sec"] = int(ev.get("voice_sec") or 0)
    if isinstance(path, str) and path:
        media = safe_media(path)
        if media is not None:
            kind, _ctype = sniff_path(media)
            ev["media_kind"] = kind
            ev["media_playable"] = kind in {"image", "video", "voice", "wximage"}
            if ev.get("msg_type") == "voice" or kind == "voice":
                wav = media.with_suffix(".wav")
                if wav.is_file() and wav.stat().st_size > 16:
                    try:
                        ev["play_url"] = "/media/" + str(wav.relative_to(ROOT))
                    except ValueError:
                        ev["play_url"] = "/media/" + path
                    ev["voice_sec"] = wav_duration_sec(wav) or estimate_voice_sec(wav)
                else:
                    ev["play_url"] = "/media/" + path
                    if not ev.get("voice_sec"):
                        ev["voice_sec"] = estimate_voice_sec(media)
        else:
            ev["media_kind"] = "missing"
            ev["media_playable"] = False
    else:
        ev["media_kind"] = ""
        ev["media_playable"] = False
    return ev


def pcm16_to_wav(pcm: bytes, sample_rate: int = 24000) -> bytes:
    import struct
    data_size = len(pcm)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + data_size,
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        sample_rate,
        sample_rate * 2,
        2,
        16,
        b"data",
        data_size,
    )
    return header + pcm


def transcode_silk(src: Path) -> Path | None:
    wav = src.with_suffix(".wav")
    try:
        if wav.is_file() and wav.stat().st_mtime >= src.stat().st_mtime and wav.read_bytes()[:4] == b"RIFF":
            return wav
    except OSError:
        pass
    decoder = Path(SILK_DECODER)
    if not decoder.is_file():
        return None
    raw = src.read_bytes()
    silk = src.with_suffix(".silk")
    silk.write_bytes(raw[1:] if raw[:1] == b"\x02" and raw[1:10] == b"#!SILK_V3" else raw)
    pcm = src.with_suffix(".pcm")
    try:
        subprocess.run(
            [str(decoder), str(silk), str(pcm), "-quiet"],
            check=False,
            timeout=20,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not pcm.is_file() or pcm.stat().st_size < 16:
        return None
    wav.write_bytes(pcm16_to_wav(pcm.read_bytes()))
    try:
        pcm.unlink()
    except OSError:
        pass
    return wav if wav.is_file() and wav.read_bytes()[:4] == b"RIFF" else None


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        print(f"[console] {self.address_string()} {fmt % args}")

    def _security_headers(self) -> None:
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Robots-Tag", "noindex, nofollow")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; img-src 'self' data: https:; media-src 'self' blob:; "
            "style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'",
        )

    def _session_user(self) -> str | None:
        cookies = parse_cookie_map(self.headers.get("Cookie"))
        user = parse_session_cookie(cookies.get(SESSION_COOKIE))
        if user:
            return user
        basic = parse_basic_auth(self.headers.get("Authorization"))
        if basic and credentials_ok(basic[0], basic[1]):
            return basic[0]
        return None

    def _wants_html(self) -> bool:
        accept = (self.headers.get("Accept") or "").lower()
        return "text/html" in accept

    def _deny(self) -> None:
        if self._wants_html() or self.path in {"/", "/index.html", "/login"}:
            self.send_response(302)
            self._security_headers()
            self.send_header("Location", "/login")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(401)
        self._security_headers()
        self.send_header("WWW-Authenticate", 'Basic realm="wechat-memory"')
        body = b'{"error":"unauthorized"}'
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _login_page(self, error: str = "") -> None:
        html = LOGIN_HTML.replace("__ERR__", error)
        data = html.encode("utf-8")
        self.send_response(200)
        self._security_headers()
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _set_session(self, username: str) -> None:
        cookie = make_session_cookie(username)
        self.send_header(
            "Set-Cookie",
            f"{SESSION_COOKIE}={cookie}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}",
        )

    def _clear_session(self) -> None:
        self.send_header(
            "Set-Cookie",
            f"{SESSION_COOKIE}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0",
        )

    def _authorized(self) -> bool:
        if not auth_configured():
            return False
        return self._session_user() is not None

    def _json(self, payload, code: int = 200) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self._security_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _bytes(self, data: bytes, content_type: str, filename: str | None = None) -> None:
        self.send_response(200)
        self._security_headers()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if filename:
            self.send_header("Content-Disposition", f'inline; filename="{filename}"')
        self.end_headers()
        self.wfile.write(data)

    def _file(self, path: Path, content_type: str | None = None) -> None:
        data = path.read_bytes()
        kind, sniffed = sniff_magic(data[:64] if len(data) > 64 else data)
        if path.suffix.lower() in {".aud", ".silk", ".slk"} or (kind == "voice" and sniffed == "audio/silk"):
            wav = transcode_silk(path)
            if wav is not None:
                self._bytes(wav.read_bytes(), "audio/wav", wav.name)
                return
        if kind == "wximage" or path.suffix.lower() in {".pic", ".pic_hd", ".wxgf", ".wxam"}:
            if kind == "wximage" or data.startswith((b"wxgf", b"wxam")):
                preview = decode_wxgf_file(path)
                if preview is not None:
                    self._bytes(preview.read_bytes(), "image/png", preview.name)
                    return
        ctype = content_type or sniffed
        if kind == "unknown":
            ctype = content_type or mimetypes.guess_type(path.name)[0] or sniffed
        if kind == "wximage":
            ctype = "application/octet-stream"
        self._bytes(data, ctype, path.name)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        if path == "/login":
            if self._authorized():
                self.send_response(302)
                self._security_headers()
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self._login_page()
            return
        if path == "/logout":
            self.send_response(302)
            self._security_headers()
            self._clear_session()
            self.send_header("Location", "/login")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self._authorized():
            self._deny()
            return
        if path == "/" or path == "/index.html":
            self._file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
            return
        if path.startswith("/static/"):
            rel = path[len("/static/") :]
            target = (STATIC_DIR / rel).resolve()
            try:
                target.relative_to(STATIC_DIR.resolve())
            except ValueError:
                self.send_error(404)
                return
            if target.is_file():
                self._file(target)
                return
            self.send_error(404)
            return
        if path == "/api/health":
            self._json({"ok": True, "version": VERSION})
            return
        if path == "/api/status":
            self._json(write_server_status())
            return
        if path == "/logs" or path == "/logs.html":
            self._file(STATIC_DIR / "logs.html", "text/html; charset=utf-8")
            return
        if path == "/api/debug-logs":
            self._json({"files": list_debug_logs()})
            return
        if path == "/api/debug-log" or path == "/api/debug-log.md":
            qs = parse_qs(parsed.query)
            name = (qs.get("name") or ["debug.log"])[0]
            from_raw = (qs.get("from") or [""])[0]
            to_raw = (qs.get("to") or [""])[0]
            from_ts = int(from_raw) if from_raw.isdigit() else None
            to_ts = int(to_raw) if to_raw.isdigit() else None
            archive_current_debug_log()
            log_path = resolve_debug_log(name)
            if log_path is None:
                if path.endswith(".md"):
                    body = "# 微信记忆调试日志\n\n还没有插件日志。请在手机打开 微信记忆 → 上传调试日志。\n"
                    self._bytes(body.encode("utf-8"), "text/markdown; charset=utf-8", "wechat-ingest-debug.md")
                    return
                self._json({"text": "", "ts": 0, "size": 0, "name": name,
                            "hint": "还没有插件日志。打开微信记忆 → 上传调试日志。"})
                return
            text = log_path.read_text(encoding="utf-8", errors="replace")
            filtered = filter_log_text(text, from_ts, to_ts)
            if path.endswith(".md"):
                stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(log_path.stat().st_mtime))
                md = (
                    f"# 微信记忆调试日志\n\n"
                    f"- 文件：{log_path.name}\n"
                    f"- 更新时间：{stamp}\n"
                    f"- 原始大小：{log_path.stat().st_size} 字节\n"
                    f"- 筛选后：{len(filtered.encode('utf-8'))} 字节\n\n"
                    f"```\n{filtered}\n```\n"
                )
                self._bytes(md.encode("utf-8"), "text/markdown; charset=utf-8", f"{log_path.stem}.md")
                return
            if len(filtered) > 400000:
                filtered = filtered[-400000:]
            self._json({
                "text": filtered,
                "ts": int(log_path.stat().st_mtime),
                "size": log_path.stat().st_size,
                "name": log_path.name,
                "filtered": bool(from_ts or to_ts),
            })
            return
        if path == "/api/settings":
            self._json(public_settings())
            return
        if path == "/api/chats":
            self._json({"chats": list_chats()})
            return
        if path.startswith("/api/chats/") and path.endswith("/messages"):
            parts = path.strip("/").split("/")
            # api chats <kind> <folder> messages
            if len(parts) >= 5:
                kind = parts[2]
                folder = "/".join(parts[3:-1])
                qs = parse_qs(parsed.query)
                limit = min(200, max(1, int(qs.get("limit", ["80"])[0] or 80)))
                before_raw = (qs.get("before_ts") or [""])[0]
                before_id = (qs.get("before_id") or [""])[0] or None
                before_ts = None
                if before_raw:
                    try:
                        before_ts = int(before_raw)
                    except (TypeError, ValueError):
                        before_ts = None
                directory = chat_dir(kind, folder)
                if directory is None:
                    self._json({"error": "chat not found"}, 404)
                    return
                page = _read_events(directory, limit + 1, before_ts=before_ts, before_id=before_id)
                has_more = len(page) > limit
                events = page[-limit:] if has_more else page
                for ev in events:
                    polish_message(ev)
                    if ev.get("sender") == SELF_WXID or ev.get("sender_name") == SELF_NAME:
                        ev["is_self"] = True
                    if ev.get("sender", "").endswith("@chatroom"):
                        ev["is_self"] = False
                    if ev.get("is_self") and not ev.get("sender_name"):
                        ev["sender_name"] = SELF_NAME
                    enrich_event(ev)
                self._json({
                    "messages": events,
                    "has_more": has_more,
                    "self_wxid": SELF_WXID,
                    "self_name": SELF_NAME,
                })
                return
        if path.startswith("/media/"):
            rel = path[len("/media/") :]
            media = safe_media(rel)
            if media is None:
                self.send_error(404)
                return
            self._file(media)
            return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        if path == "/login":
            length = int(self.headers.get("Content-Length") or 0)
            if length > 4096:
                self._login_page("请求过大")
                return
            raw = self.rfile.read(length) if length > 0 else b""
            form = parse_qs(raw.decode("utf-8", errors="replace"))
            username = (form.get("username") or [""])[0]
            password = (form.get("password") or [""])[0]
            ip = self.client_address[0] if self.client_address else "0.0.0.0"
            if not login_allowed(ip):
                self._login_page("尝试次数过多，请稍后再试")
                return
            if credentials_ok(username, password):
                self.send_response(302)
                self._security_headers()
                self._set_session(username)
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            note_login_fail(ip)
            self._login_page("账号或密码错误")
            return
        if not self._authorized():
            self._deny()
            return
        if path != "/api/settings":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._json({"error": "invalid json"}, 400)
            return
        if not isinstance(body, dict):
            self._json({"error": "invalid json"}, 400)
            return
        save_settings(body)
        self._json({"ok": True, "settings": public_settings(), "status": write_server_status()})


def status_loop() -> None:
    while True:
        try:
            write_server_status()
        except Exception as exc:  # noqa: BLE001
            print(f"[console] status write failed: {exc}")
        time.sleep(20)


def main() -> None:
    if not auth_configured():
        raise SystemExit("CONSOLE_USER / CONSOLE_PASSWORD must be set")
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / "status").mkdir(parents=True, exist_ok=True)
    write_server_status()
    threading.Thread(target=status_loop, name="status", daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"wechat-ingest console {VERSION} on {PUBLIC_URL} root={ROOT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
