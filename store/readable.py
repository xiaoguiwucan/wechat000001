#!/usr/bin/env python3
"""Turn stored JSONL into Chinese, human-readable files. No phone plugin needed."""

from __future__ import annotations

import json
import re
import shutil
from datetime import datetime, timedelta, timezone
from html import unescape
from pathlib import Path
from xml.etree import ElementTree as ET

import consumer

CST = timezone(timedelta(hours=8))
SELF_WXID = "wxid_7786337863012"

TYPE_CN = {
    "text": "文字",
    "image": "图片",
    "voice": "语音",
    "video": "视频",
    "emoji": "表情",
    "redpacket": "红包",
    "revoke": "撤回",
    "announcement": "群公告",
    "raw": "卡片/其他",
}

README = """微信蒸馏数据说明

这个文件夹是手机微信勾选会话后自动上传、再整理好的知识库。只收开启采集后的新消息，不会整机导历史。

【你会看的】
- 群聊/          群消息，每个群一个文件夹
- 私聊/          好友一对一
- 公众号/        公众号推送（不是好友）
- 日报/          以后自动生成的每日摘要
- 总览.md        所有会话的中文目录
- 使用说明.txt    本文件

【每个会话文件夹里】
- 聊天记录.md     给人看的中文记录（推荐打开这个）
- 消息.jsonl     给程序用的原始数据，一般不用点
- 图片/ 语音/ 视频/ 文件/   按类型分开的原文件

【先不用管的】
- 待入库/        手机刚传上来、正在整理
- 索引.sqlite    搜索数据库
- 会话对照.json  群id和中文名对照
- inbox、index.sqlite  兼容旧路径的快捷方式

群名/好友备注要等下次更新手机插件并点「同步群名和好友备注」后才会全部变成中文。
当前没同步到名称的，文件夹仍是微信内部编号。
"""


def _xml_text(blob: str) -> str | None:
    raw = blob.strip()
    if "<" not in raw:
        return None
    # sender prefix used by some group raw messages: wxid_xxx:\n<xml>
    prefix = ""
    if raw.startswith("wxid_") or "@chatroom" in raw[:40]:
        head, _, rest = raw.partition(":")
        if "<" in rest:
            prefix = head.strip()
            raw = rest.lstrip()
    start = raw.find("<")
    end = raw.rfind(">")
    if start < 0 or end <= start:
        return None
    xml = raw[start : end + 1]
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        title = re.search(r"<title>(.*?)</title>", xml, re.S)
        des = re.search(r"<des>(.*?)</des>", xml, re.S)
        bits = []
        if title:
            bits.append(unescape(re.sub("<[^>]+>", "", title.group(1))).strip())
        if des:
            bits.append(unescape(re.sub("<[^>]+>", "", des.group(1))).strip())
        text = " / ".join(x for x in bits if x)
        return f"{prefix}: {text}" if prefix and text else (text or None)
    title = "".join(root.itertext()) if False else None
    t = root.find(".//title")
    d = root.find(".//des")
    src = root.find(".//sourcedisplayname")
    emoji = root.find(".//emoji")
    bits = []
    if t is not None and (t.text or "").strip():
        bits.append(t.text.strip())
    if d is not None and (d.text or "").strip():
        bits.append(d.text.strip())
    if src is not None and (src.text or "").strip():
        bits.append(f"来源:{src.text.strip()}")
    if emoji is not None:
        bits.append("[表情]")
    text = " / ".join(bits)
    if prefix and text:
        return f"{prefix}: {text}"
    return text or None


def human_text(event: dict) -> str:
    text = event.get("text") or ""
    pretty = _xml_text(text)
    extra = event.get("extra_json")
    if extra:
        try:
            obj = json.loads(extra)
            asr = obj.get("asr")
            if asr:
                return f"[语音] {asr}"
        except (json.JSONDecodeError, TypeError):
            pass
    if pretty:
        return pretty
    m = re.match(r"^([^\n:]{1,80}):\n(.*)$", text, re.S)
    if m and m.group(1).strip() and not m.group(1).endswith("@chatroom"):
        text = m.group(2)
    if text in {"[image]", "[voice]", "[video]", "[redpacket]", "[revoke]"}:
        return {
            "[image]": "[图片]",
            "[voice]": "[语音]",
            "[video]": "[视频]",
            "[redpacket]": "[红包]",
            "[revoke]": "[撤回]",
        }[text]
    return text.replace("\r\n", "\n").strip()


def fmt_time(ts: int | None) -> str:
    try:
        return datetime.fromtimestamp(int(ts or 0), tz=CST).strftime("%Y-%m-%d %H:%M")
    except (OverflowError, OSError, ValueError):
        return "-"


def sender_label(event: dict, chat_kind: str) -> str:
    text = event.get("text") or ""
    m = re.match(r"^([^\n:]{1,80}):\n", text)
    if m:
        who = m.group(1).strip()
        if who and not who.endswith("@chatroom") and not who.startswith("wxid_"):
            return who
        if who.startswith("wxid_"):
            name = event.get("sender_name") or ""
            return str(name) if name and name != who else who
    name = event.get("sender_name") or ""
    if name and name != event.get("sender") and not str(name).endswith("@chatroom"):
        return str(name)
    sid = event.get("sender") or ""
    if sid == SELF_WXID:
        return "我"
    if chat_kind == "group" and sid.endswith("@chatroom"):
        return name if name and not name.endswith("@chatroom") else "群成员"
    return sid or "未知"


def render_chat(chat_dir: Path, chat_kind: str, title: str) -> int:
    src = chat_dir / consumer.FILE_EVENTS
    if not src.is_file():
        src = chat_dir / "events.jsonl"
    if not src.is_file():
        return 0
    lines = []
    seen = set()
    for raw in src.read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        key = (event.get("msg_id"), event.get("ts"), event.get("text"))
        if key in seen:
            continue
        seen.add(key)
        kind = TYPE_CN.get(str(event.get("msg_type")), str(event.get("msg_type")))
        body = human_text(event)
        who = sender_label(event, chat_kind)
        media = event.get("media_path")
        extra = f"\n  文件: {media}" if media else ""
        lines.append(f"### {fmt_time(event.get('ts'))} · {who} · {kind}\n\n{body}{extra}\n")
    out = chat_dir / "聊天记录.md"
    header = f"# {title}\n\n共 {len(lines)} 条（已去重）\n\n微信内部编号：`{chat_dir.name}`\n\n"
    out.write_text(header + "\n".join(lines), encoding="utf-8")
    return len(lines)


def move_officials(root: Path) -> int:
    src = root / consumer.DIR_DMS
    dst = root / consumer.DIR_OFFICIAL
    if not src.is_dir():
        return 0
    dst.mkdir(parents=True, exist_ok=True)
    n = 0
    for chat in list(src.iterdir()):
        if chat.is_dir() and chat.name.startswith("gh_"):
            target = dst / chat.name
            if target.exists():
                continue
            shutil.move(str(chat), str(target))
            n += 1
    return n


def maybe_rename_self(root: Path) -> None:
    src = root / consumer.DIR_DMS / SELF_WXID
    dst = root / consumer.DIR_DMS / "我"
    if src.is_dir() and not dst.exists():
        src.rename(dst)


def build_index(root: Path) -> None:
    rows = ["# 微信蒸馏总览\n", "刷新这个文件可看每个会话最新在聊什么。\n"]
    sections = [
        ("群聊", consumer.DIR_GROUPS, "group"),
        ("私聊", consumer.DIR_DMS, "dm"),
        ("公众号", consumer.DIR_OFFICIAL, "dm"),
    ]
    for title, folder, kind in sections:
        base = root / folder
        rows.append(f"\n## {title}\n")
        if not base.is_dir():
            rows.append("（空）\n")
            continue
        chats = sorted([p for p in base.iterdir() if p.is_dir()], key=lambda p: p.stat().st_mtime, reverse=True)
        for chat in chats:
            md = chat / "聊天记录.md"
            last = ""
            count = 0
            ev = chat / consumer.FILE_EVENTS
            if ev.is_file():
                raw_lines = ev.read_text(encoding="utf-8").splitlines()
                count = len(raw_lines)
                if raw_lines:
                    try:
                        last = human_text(json.loads(raw_lines[-1])).replace("\n", " ")[:60]
                    except json.JSONDecodeError:
                        last = ""
            rows.append(f"- [{chat.name}]({folder}/{chat.name}/聊天记录.md) · {count} 条 · {last}\n")
    (root / "总览.md").write_text("".join(rows), encoding="utf-8")
    (root / "使用说明.txt").write_text(README, encoding="utf-8")


def refresh(root: Path | None = None) -> None:
    root = Path(root) if root is not None else consumer.default_root()
    moved = move_officials(root)
    maybe_rename_self(root)
    total = 0
    for kind_name, folder, kind in (
        ("group", consumer.DIR_GROUPS, "group"),
        ("dm", consumer.DIR_DMS, "dm"),
        ("official", consumer.DIR_OFFICIAL, "dm"),
    ):
        base = root / folder
        if not base.is_dir():
            continue
        for chat in base.iterdir():
            if chat.is_dir():
                total += render_chat(chat, kind, chat.name)
    build_index(root)
    if __name__ == "__main__":
        print(f"readable: chats_rendered_messages={total} officials_moved={moved}")


if __name__ == "__main__":
    refresh()
