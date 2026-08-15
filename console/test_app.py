from __future__ import annotations

import json
from pathlib import Path

import app as console_app


def test_safe_media_rejects_traversal(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    (tmp_path / "群聊" / "值班群" / "媒体").mkdir(parents=True)
    good = tmp_path / "群聊" / "值班群" / "媒体" / "a.jpg"
    good.write_bytes(b"abc")
    assert console_app.safe_media("群聊/值班群/媒体/a.jpg") == good.resolve()
    assert console_app.safe_media("../etc/passwd") is None
    assert console_app.safe_media("群聊/../../etc/passwd") is None


def test_read_events_sorts_by_timestamp(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    chat = tmp_path / "群聊" / "小群"
    chat.mkdir(parents=True)
    later = {
        "chat_id": "r", "chat_kind": "group", "msg_id": "2",
        "msg_type": "text", "sender": "a", "ts": 200, "text": "后",
    }
    earlier = {
        "chat_id": "r", "chat_kind": "group", "msg_id": "1",
        "msg_type": "text", "sender": "a", "ts": 100, "text": "先",
    }
    (chat / "消息.jsonl").write_text(
        json.dumps(later, ensure_ascii=False) + "\n" + json.dumps(earlier, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    events = console_app._read_events(chat, 50)
    assert [e["msg_id"] for e in events] == ["1", "2"]


def test_read_events_dedups_msg_id(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    chat = tmp_path / "群聊" / "值班群"
    chat.mkdir(parents=True)
    first = {
        "chat_id": "r", "chat_kind": "group", "msg_id": "9",
        "msg_type": "image", "sender": "me", "ts": 100, "text": "[image]",
        "media_path": None,
    }
    second = dict(first)
    second["media_path"] = "群聊/值班群/图片/a.pic"
    (chat / "消息.jsonl").write_text(
        json.dumps(first, ensure_ascii=False) + "\n" + json.dumps(second, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    events = console_app._read_events(chat, 50)
    assert len(events) == 1
    assert events[0]["media_path"] == "群聊/值班群/图片/a.pic"


def test_last_event_reads_file_tail(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    chat = tmp_path / "群聊" / "大群"
    chat.mkdir(parents=True)
    lines = []
    for i in range(80):
        lines.append(json.dumps({
            "chat_id": "r", "chat_kind": "group", "msg_id": str(i),
            "msg_type": "text", "sender": "a", "ts": i, "text": "x" * 40,
        }, ensure_ascii=False))
    lines.append(json.dumps({
        "chat_id": "r", "chat_kind": "group", "msg_id": "tail",
        "msg_type": "text", "sender": "a", "ts": 999, "text": "最后",
    }, ensure_ascii=False))
    (chat / "消息.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    last = console_app._last_event(chat)
    assert last["text"] == "最后"
    events = console_app._read_events(chat, 10)
    assert events[-1]["msg_id"] == "tail"
    assert len(events) <= 10


def test_read_events_before_ts_pages_backward(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    chat = tmp_path / "群聊" / "翻页群"
    chat.mkdir(parents=True)
    lines = [
        json.dumps({
            "chat_id": "r", "chat_kind": "group", "msg_id": str(i),
            "msg_type": "text", "sender": "a", "ts": i, "text": f"m{i}",
        }, ensure_ascii=False)
        for i in range(1, 31)
    ]
    (chat / "消息.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    latest = console_app._read_events(chat, 10)
    assert [e["msg_id"] for e in latest] == [str(i) for i in range(21, 31)]
    older = console_app._read_events(chat, 10, before_ts=21, before_id="21")
    assert [e["msg_id"] for e in older] == [str(i) for i in range(11, 21)]
    oldest = console_app._read_events(chat, 10, before_ts=11, before_id="11")
    assert [e["msg_id"] for e in oldest] == [str(i) for i in range(1, 11)]


def test_read_events_expands_tail_for_fat_lines(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    chat = tmp_path / "群聊" / "大行"
    chat.mkdir(parents=True)
    pad = "卡" * 800
    lines = [
        json.dumps({
            "chat_id": "r", "chat_kind": "group", "msg_id": str(i),
            "msg_type": "text", "sender": "a", "ts": i, "text": pad,
        }, ensure_ascii=False)
        for i in range(1, 81)
    ]
    (chat / "消息.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    events = console_app._read_events(chat, 50)
    assert len(events) == 50
    assert events[0]["msg_id"] == "31"
    assert events[-1]["msg_id"] == "80"


def test_list_chats_reads_jsonl(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    chat = tmp_path / "群聊" / "值班群"
    chat.mkdir(parents=True)
    (tmp_path / "会话对照.json").write_text(json.dumps({
        "group:57342508437@chatroom": {
            "chat_id": "57342508437@chatroom",
            "chat_kind": "group",
            "chat_name": "值班群",
            "folder": "值班群",
        }
    }, ensure_ascii=False), encoding="utf-8")
    (chat / "消息.jsonl").write_text(
        json.dumps({
            "chat_id": "57342508437@chatroom",
            "chat_kind": "group",
            "msg_id": "1",
            "msg_type": "text",
            "sender": "wxid_a",
            "ts": 1786681275,
            "text": "测试",
        }, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    chats = console_app.list_chats()
    assert chats[0]["name"] == "值班群"
    assert chats[0]["preview"] == "测试"


def test_polish_message_pulls_group_nickname():
    ev = {
        "sender": "wxid_7786337863012",
        "sender_name": "风",
        "is_self": True,
        "text": "saarjoye:\n确实，都是几把人",
    }
    out = console_app.polish_message(ev)
    assert out["sender_name"] == "saarjoye"
    assert out["text"] == "确实，都是几把人"
    assert out["is_self"] is False


def test_polish_message_chatroom_sender_not_shown_as_id():
    ev = {"sender": "18725461928@chatroom", "text": "确实，都是几把人", "is_self": False}
    out = console_app.polish_message(ev)
    assert out["sender_name"] == ""
    assert not str(out.get("sender_name") or "").endswith("@chatroom")


def test_write_server_status(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    (tmp_path / "待入库").mkdir(parents=True)
    status = console_app.write_server_status()
    assert status["role"] == "console"
    assert (tmp_path / "status" / "server.json").is_file()
    assert status["inbox_pending"] == 0


def test_session_cookie_roundtrip(monkeypatch) -> None:
    monkeypatch.setattr(console_app, "CONSOLE_USER", "zkx")
    monkeypatch.setattr(console_app, "CONSOLE_PASSWORD", "secret")
    monkeypatch.setattr(console_app, "CONSOLE_SECRET", "unit-test-secret")
    cookie = console_app.make_session_cookie("zkx")
    assert console_app.parse_session_cookie(cookie) == "zkx"
    assert console_app.parse_session_cookie("AAAA" + cookie[4:]) is None
    assert console_app.parse_session_cookie(None) is None


def test_credentials_constant_time(monkeypatch) -> None:
    monkeypatch.setattr(console_app, "CONSOLE_USER", "zkx")
    monkeypatch.setattr(console_app, "CONSOLE_PASSWORD", "secret")
    assert console_app.credentials_ok("zkx", "secret") is True
    assert console_app.credentials_ok("zkx", "wrong") is False
    assert console_app.credentials_ok("admin", "secret") is False


def test_wav_duration_skips_list_chunk(tmp_path: Path) -> None:
    import struct
    # 1s of silence @ 24kHz mono s16 + a LIST chunk before data
    pcm = b"\x00\x00" * 24000
    fmt = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 1, 24000, 48000, 2, 16)
    lst = struct.pack("<4sI", b"LIST", 4) + b"INFO"
    data = struct.pack("<4sI", b"data", len(pcm)) + pcm
    body = b"WAVE" + fmt + lst + data
    wav = tmp_path / "a.wav"
    wav.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
    assert console_app.wav_duration_sec(wav) == 1


def test_sniff_magic_images_and_wxgf() -> None:
    assert console_app.sniff_magic(b"\xff\xd8\xff\xe0xxxx")[0] == "image"
    assert console_app.sniff_magic(b"\x89PNG\r\n\x1a\nxxxx") == ("image", "image/png")
    assert console_app.sniff_magic(b"wxgf\x13\x00\x02\x05")[0] == "wximage"
    assert console_app.sniff_magic(b"\x02#!SILK_V3xxxx")[0] == "voice"


def test_pcm16_to_wav_header() -> None:
    wav = console_app.pcm16_to_wav(b"\x00\x01" * 8, 24000)
    assert wav.startswith(b"RIFF")
    assert wav[8:12] == b"WAVE"
    assert wav[36:40] == b"data"


def test_extract_hevc_from_wxgf() -> None:
    payload = b"wxgf\x00\x00header" + b"\x00\x00\x00\x01\x26payload"
    assert console_app.extract_hevc_from_wxgf(payload) == b"\x00\x00\x00\x01\x26payload"
    assert console_app.extract_hevc_from_wxgf(b"not-wx") is None


def test_basic_auth_parse() -> None:
    import base64
    token = base64.b64encode(b"zkx:secret").decode("ascii")
    assert console_app.parse_basic_auth(f"Basic {token}") == ("zkx", "secret")
    assert console_app.parse_basic_auth(None) is None


def test_debug_log_list_and_filter(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    (tmp_path / "status").mkdir(parents=True)
    (tmp_path / "status" / "debug.log").write_text(
        "2026-08-14 18:00:01 capture image\n2026-08-14 19:00:02 media miss\n",
        encoding="utf-8",
    )
    files = console_app.list_debug_logs()
    assert files[0]["name"] == "debug.log"
    assert any(item["name"].startswith("debug-") for item in files)
    assert console_app.resolve_debug_log("../etc/passwd") is None
    import time
    text = (tmp_path / "status" / "debug.log").read_text(encoding="utf-8")
    start = int(time.mktime(time.strptime("2026-08-14 17:50:00", "%Y-%m-%d %H:%M:%S")))
    end = int(time.mktime(time.strptime("2026-08-14 18:30:00", "%Y-%m-%d %H:%M:%S")))
    kept = console_app.filter_log_text(text, start, end)
    assert "18:00:01" in kept
    assert "19:00:02" not in kept


def test_settings_override_public_url(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(console_app, "ROOT", tmp_path)
    monkeypatch.setattr(console_app, "PUBLIC_URL", "http://example.invalid:31632")
    monkeypatch.setattr(console_app, "LAN_URL", "http://192.168.1.10:18791")
    saved = console_app.save_settings({"public_url": "http://example.invalid:31632"})
    assert saved["public_url"] == "http://example.invalid:31632"
    status = console_app.write_server_status()
    assert status["public_url"] == "http://example.invalid:31632"
    assert status["url"] == "http://example.invalid:31632"


def test_classify_raw_voip_and_card() -> None:
    voip = console_app.classify_raw({
        "msg_type": "raw",
        "text": "[raw]",
        "extra_json": json.dumps({"raw_type": 50}),
    })
    assert voip["text"] == "[语音通话]"
    assert voip["card_kind"] == "语音通话"
    assert voip["msg_type"] == "raw"
    card = console_app.classify_raw({
        "msg_type": "raw",
        "text": "[raw]",
        "extra_json": json.dumps({"raw_type": 49, "ais_dump": True}),
    })
    assert card["text"] == "[卡片消息]"
    assert "[raw]" not in card["text"]


def test_classify_raw_audio_becomes_voice() -> None:
    ev = console_app.classify_raw({
        "msg_type": "raw",
        "text": "[raw]",
        "media_path": "私聊/妈/文件/1237.mp3",
        "extra_json": json.dumps({"raw_type": 49}),
    })
    assert ev["msg_type"] == "voice"
    assert ev["text"] == "[语音]"


def test_classify_raw_video_file() -> None:
    ev = console_app.classify_raw({
        "msg_type": "raw",
        "text": "[raw]",
        "media_path": "群聊/测试/视频/72468.mp4",
        "extra_json": json.dumps({"raw_type": 49}),
    })
    assert ev["msg_type"] == "video"


def test_estimate_voice_sec_silk_size(tmp_path: Path) -> None:
    p = tmp_path / "a.aud"
    p.write_bytes(b"\x02#!SILK_V3" + b"\x00" * 8400)
    assert console_app.estimate_voice_sec(p) == 3
