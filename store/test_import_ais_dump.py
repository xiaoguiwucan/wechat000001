from __future__ import annotations

import hashlib
import json
import sqlite3
from pathlib import Path

import consumer
import import_ais_dump as ais


def test_parse_remark_nickname_and_remark():
    # field1=小风 field6=xiaofeng  (real blob from dump)
    blob = bytes.fromhex("0a06e5b08fe9a38e1a00")
    # simpler handmade: field1=小风
    blob = b"\x0a\x06" + "小风".encode()
    got = ais.parse_remark(blob)
    assert got["nickname"] == "小风"
    # field1 nick, field3 remark
    blob = (
        b"\x0a\x09"
        + "张艳文".encode()
        + b"\x1a\x03"
        + "妈".encode()
    )
    got = ais.parse_remark(blob)
    assert got["nickname"] == "张艳文"
    assert got["remark"] == "妈"
    assert ais.display_name({**got, "username": "wxid_x"}) == "妈"


def test_split_group_and_des_mapping():
    who, body = ais.split_group_body("saarjoye:\n等SKILL出来了")
    assert who == "saarjoye"
    assert body == "等SKILL出来了"
    ev = ais.build_event(
        chat_id="18725461928@chatroom",
        chat_kind="group",
        chat_name="PC站看片狂魔小群",
        row_lid=1,
        row_ts=10,
        row_des=1,
        row_type=1,
        content="saarjoye:\n等SKILL出来了",
        contacts={},
        lookup={},
        chat_info={},
    )
    assert ev["is_self"] is False
    assert ev["sender"] == "saarjoye"
    assert ev["sender_name"] == "saarjoye"
    assert ev["text"] == "等SKILL出来了"
    self_ev = ais.build_event(
        chat_id="18725461928@chatroom",
        chat_kind="group",
        chat_name="PC站看片狂魔小群",
        row_lid=5,
        row_ts=11,
        row_des=0,
        row_type=1,
        content="确实，都是几把人",
        contacts={},
        lookup={},
        chat_info={},
    )
    assert self_ev["is_self"] is True
    assert self_ev["sender"] == ais.SELF_WXID
    assert self_ev["sender_name"] == ais.SELF_NAME


def test_file_and_image_types():
    xml = "pllynn:\n<appmsg><type>6</type><title>表.xlsx</title><fileext>xlsx</fileext></appmsg>"
    ev = ais.build_event(
        chat_id="room@chatroom",
        chat_kind="group",
        chat_name="g",
        row_lid=9,
        row_ts=1,
        row_des=1,
        row_type=49,
        content=xml,
        contacts={},
        lookup={},
        chat_info={},
    )
    assert ev["msg_type"] == "file"
    assert ev["text"] == "表.xlsx"
    assert ev["sender"] == "pllynn"
    img = ais.build_event(
        chat_id="wxid_friend",
        chat_kind="dm",
        chat_name="Jane",
        row_lid=2,
        row_ts=1,
        row_des=1,
        row_type=3,
        content="",
        contacts={"wxid_friend": {"username": "wxid_friend", "nickname": "Jane", "alias": "", "remark": ""}},
        lookup={"wxid_friend": "wxid_friend"},
        chat_info={},
    )
    assert img["msg_type"] == "image"
    assert img["sender"] == "wxid_friend"
    assert img["sender_name"] == "Jane"


def test_media_index_skips_thumb_prefers_hd(tmp_path: Path):
    chat = "abc123"
    img = tmp_path / "Img" / chat
    img.mkdir(parents=True)
    (img / "12.pic_thum").write_bytes(b"tiny")
    (img / "12.pic").write_bytes(b"full")
    (img / "12.pic_hd").write_bytes(b"hd-image-bytes")
    (tmp_path / "Audio" / chat).mkdir(parents=True)
    (tmp_path / "Audio" / chat / "3.aud").write_bytes(b"silk")
    got = ais.index_chat_media(tmp_path, chat)
    assert got["12"].name == "12.pic_hd"
    assert got["3"].name == "3.aud"
    assert "99" not in got


def _make_contact_db(path: Path) -> None:
    con = sqlite3.connect(path)
    con.execute(
        "CREATE TABLE Friend (userName TEXT, dbContactRemark BLOB, dbContactChatRoom BLOB)"
    )
    nick = b"\x0a" + bytes([len("小风".encode())]) + "小风".encode()
    room = "PC站看片狂魔小群".encode()
    room_name = b"\x0a" + bytes([len(room)]) + room
    con.execute("INSERT INTO Friend VALUES (?,?,?)", ("wxid_w0sohqqbi4m822", nick, None))
    con.execute("INSERT INTO Friend VALUES (?,?,?)", ("18725461928@chatroom", room_name, None))
    con.commit()
    con.close()


def _make_message_db(path: Path, chat_id: str, rows: list[tuple]) -> None:
    md5 = hashlib.md5(chat_id.encode()).hexdigest()
    table = "Chat_" + md5
    con = sqlite3.connect(path)
    con.execute(
        f"CREATE TABLE {table} (CreateTime INTEGER, Des INTEGER, ImgStatus INTEGER, "
        "MesLocalID INTEGER PRIMARY KEY, Message TEXT, MesSvrID INTEGER, Status INTEGER, "
        "TableVer INTEGER, Type INTEGER, WCDB_CT_Message INTEGER)"
    )
    for lid, ts, des, typ, msg in rows:
        con.execute(
            f"INSERT INTO {table} (MesLocalID, CreateTime, Des, Type, Message) VALUES (?,?,?,?,?)",
            (lid, ts, des, typ, msg),
        )
    con.commit()
    con.close()
    return md5


def test_import_mini_dump_wipes_and_splits(tmp_path: Path):
    dump = tmp_path / "dump" / "deadbeef"
    (dump / "DB").mkdir(parents=True)
    (dump / "session").mkdir()
    _make_contact_db(dump / "DB" / "WCDB_Contact.sqlite")
    group = "18725461928@chatroom"
    dm = "wxid_w0sohqqbi4m822"
    gmd5 = hashlib.md5(group.encode()).hexdigest()
    dmd5 = hashlib.md5(dm.encode()).hexdigest()
    _make_message_db(
        dump / "DB" / "message_1.sqlite",
        group,
        [
            (1, 100, 1, 1, "小风:\n啊"),
            (2, 101, 0, 1, "回你了"),
            (3, 102, 1, 3, ""),
        ],
    )
    _make_message_db(
        dump / "DB" / "message_2.sqlite",
        dm,
        [
            (1, 200, 1, 1, "在吗"),
            (2, 201, 0, 1, "在"),
        ],
    )
    img = dump / "Img" / gmd5
    img.mkdir(parents=True)
    (img / "3.pic").write_bytes(b"hello-pic")
    (img / "3.pic_thum").write_bytes(b"t")

    root = tmp_path / "store"
    leftover = root / consumer.DIR_GROUPS / "旧群"
    leftover.mkdir(parents=True)
    (leftover / "消息.jsonl").write_text("{}\n", encoding="utf-8")
    (root / consumer.FILE_INDEX).write_bytes(b"x")

    stats = ais.import_dump(root, dump, wipe=True, refresh_md=True)
    assert stats["chats"] == 2
    assert stats["messages"] == 5
    assert stats["media"] == 1
    assert not leftover.exists()
    gdir = root / consumer.DIR_GROUPS / "PC站看片狂魔小群"
    assert (gdir / consumer.FILE_EVENTS).is_file()
    lines = [json.loads(x) for x in (gdir / consumer.FILE_EVENTS).read_text(encoding="utf-8").splitlines()]
    assert lines[0]["sender"] == "小风"
    assert lines[0]["text"] == "啊"
    assert lines[1]["is_self"] is True
    assert lines[1]["sender_name"] == (ais.SELF_NAME or ais.SELF_WXID or lines[1]["sender"])
    assert lines[2]["msg_type"] == "image"
    assert lines[2]["media_path"].endswith("3.pic")
    assert (gdir / "图片" / "3.pic").is_file()
    ddir = root / consumer.DIR_DMS / "小风"
    dlines = [json.loads(x) for x in (ddir / consumer.FILE_EVENTS).read_text(encoding="utf-8").splitlines()]
    assert dlines[0]["sender"] == dm
    assert dlines[0]["sender_name"] == "小风"
    assert dlines[1]["is_self"] is True
    assert (gdir / "聊天记录.md").is_file()
    conn = sqlite3.connect(root / consumer.FILE_INDEX)
    try:
        n = conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    finally:
        conn.close()
    assert n == 5
