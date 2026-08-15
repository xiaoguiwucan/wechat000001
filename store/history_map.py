"""Map a raw WeChat Chat_* row (dumped by the phone) into a store event.

The phone does not classify types or decode media. fnOS does that here so
export is just sqlite + file copy.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

TYPE_MAP = {
    1: "text",
    3: "image",
    34: "voice",
    43: "video",
    44: "video",
    47: "emoji",
    49: "redpacket",
    62: "video",
}
SYSMSG_TYPES = {10000, 10002}
_MEDIA = {"image", "voice", "video", "emoji", "file", "redpacket"}
_XML_TAG = re.compile(r"<(?P<tag>[A-Za-z0-9_]+)>(?P<val>.*?)</(?P=tag)>", re.I | re.S)


def map_msg_type(raw_type, content: str) -> str:
    if raw_type in SYSMSG_TYPES:
        lowered = (content or "").lower()
        if "revokemsg" in lowered or "撤回" in (content or ""):
            return "revoke"
        if "announcement" in lowered or "群公告" in (content or ""):
            return "announcement"
        return "revoke" if raw_type == 10002 else "announcement"
    if raw_type == 49:
        lowered = (content or "").lower()
        if "<type>6</type>" in lowered or "<appattach" in lowered or "<fileext>" in lowered:
            return "file"
        if "<type>2001</type>" in lowered or "hongbao" in lowered or "wxpay" in lowered or "红包" in (content or ""):
            return "redpacket"
        if "<type>4</type>" in lowered or "<videomsg" in lowered:
            return "video"
        return "raw"
    return TYPE_MAP.get(raw_type, "raw")


def xml_tag(xml: str, tag: str) -> str:
    if not xml or not tag:
        return ""
    open_ = f"<{tag}>"
    start = xml.lower().find(open_.lower())
    if start < 0:
        return ""
    from_ = start + len(open_)
    close = f"</{tag}>"
    end = xml.lower().find(close.lower(), from_)
    if end < 0:
        return ""
    return xml[from_:end].strip()


def split_group_body(raw: str) -> tuple[str, str]:
    text = raw or ""
    cut = text.find(":\n")
    if 0 < cut < 80:
        who = text[:cut]
        if who.startswith("wxid_") or "@" in who or len(who) < 40:
            return who, text[cut + 2 :]
    return "", text


def map_history_row(
    *,
    chat_id: str,
    chat_kind: str,
    self_wxid: str,
    row: dict,
) -> dict:
    lid = row.get("lid")
    if lid is None:
        raise ValueError("row missing lid")
    raw_type = row.get("type")
    try:
        raw_type = int(raw_type)
    except (TypeError, ValueError):
        raw_type = 0
    content = row.get("msg") or ""
    if not isinstance(content, str):
        content = str(content)
    try:
        ts = int(row.get("ts") or 0)
    except (TypeError, ValueError):
        ts = 0
    try:
        des = int(row.get("des") or 0)
    except (TypeError, ValueError):
        des = 0

    msg_type = map_msg_type(raw_type, content)
    sender = ""
    body = content
    if chat_kind == "group":
        if des == 0:
            sender, body = split_group_body(content)
            if not sender:
                sender = chat_id
        else:
            sender = self_wxid or "self"
    elif des == 0:
        sender = chat_id
    else:
        sender = self_wxid or "self"

    if msg_type == "text":
        text = body
    elif msg_type in _MEDIA:
        title = xml_tag(content, "title")
        text = title if msg_type == "file" and title else f"[{msg_type}]"
    else:
        text = body

    extra: dict = {"full_export": True}
    if msg_type == "raw":
        extra["raw_type"] = raw_type
    if msg_type in ("file", "raw", "emoji", "redpacket") and content:
        extra["xml"] = content
        filename = xml_tag(content, "title")
        ext = xml_tag(content, "fileext")
        if filename:
            extra["filename"] = filename
        if ext:
            extra["fileext"] = ext

    return {
        "chat_id": chat_id,
        "chat_kind": chat_kind,
        "msg_id": str(lid),
        "msg_type": msg_type,
        "sender": sender,
        "ts": ts,
        "text": text,
        "media_path": None,
        "extra_json": json.dumps(extra, ensure_ascii=False) if extra else None,
        "is_self": bool(self_wxid) and sender == self_wxid,
    }


def _looks_thumb(path: Path) -> bool:
    name = path.name.lower()
    return "thum" in name or "thumb" in name


def find_hist_media(media_root: Path, lid: str, extra_xml: str = "") -> Path | None:
    """Pick the best already-uploaded file for this local id (or attach md5)."""
    if not media_root.is_dir() or not lid:
        return None
    cands: list[Path] = []
    prefix = f"{lid}."
    needles = {lid}
    if extra_xml:
        for tag in ("md5", "attachid", "fileid", "aeskey"):
            val = xml_tag(extra_xml, tag)
            if val and len(val) >= 8:
                needles.add(val)
    for path in media_root.rglob("*"):
        if not path.is_file():
            continue
        name = path.name
        if name.startswith(prefix) or name == lid:
            cands.append(path)
            continue
        for needle in needles:
            if needle != lid and needle in name:
                cands.append(path)
                break
    if not cands:
        return None
    full = [p for p in cands if not _looks_thumb(p)]
    if full:
        full.sort(key=lambda p: -p.stat().st_size)
        return full[0]
    return None
