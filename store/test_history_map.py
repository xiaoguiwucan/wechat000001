from pathlib import Path

import history_map


def test_text_group_incoming_strips_sender():
    ev = history_map.map_history_row(
        chat_id="room@chatroom",
        chat_kind="group",
        self_wxid="wxid_me",
        row={"lid": 9, "type": 1, "msg": "wxid_a:\nhello", "ts": 10, "des": 0},
    )
    assert ev["msg_type"] == "text"
    assert ev["sender"] == "wxid_a"
    assert ev["text"] == "hello"
    assert ev["msg_id"] == "9"
    assert ev["is_self"] is False


def test_file_appmsg_type_6():
    xml = "<appmsg><type>6</type><title>合同.pdf</title><fileext>pdf</fileext></appmsg>"
    ev = history_map.map_history_row(
        chat_id="room@chatroom",
        chat_kind="group",
        self_wxid="wxid_me",
        row={"lid": 3, "type": 49, "msg": xml, "ts": 1, "des": 1},
    )
    assert ev["msg_type"] == "file"
    assert ev["text"] == "合同.pdf"
    assert ev["sender"] == "wxid_me"
    assert ev["is_self"] is True
    assert "合同.pdf" in (ev["extra_json"] or "")


def test_image_placeholder():
    ev = history_map.map_history_row(
        chat_id="wxid_friend",
        chat_kind="dm",
        self_wxid="wxid_me",
        row={"lid": 2, "type": 3, "msg": "", "ts": 1, "des": 0},
    )
    assert ev["msg_type"] == "image"
    assert ev["text"] == "[image]"
    assert ev["sender"] == "wxid_friend"


def test_find_hist_media_prefers_full_over_thumb(tmp_path: Path):
    root = tmp_path / "hist-media" / "abc"
    img = root / "Img"
    img.mkdir(parents=True)
    (img / "12.pic_thum").write_bytes(b"tiny")
    (img / "12.pic").write_bytes(b"full-image-bytes-here")
    got = history_map.find_hist_media(root, "12")
    assert got is not None
    assert got.name == "12.pic"


def test_find_hist_media_ignores_thumb_only(tmp_path: Path):
    root = tmp_path / "hist-media" / "abc"
    img = root / "Img"
    img.mkdir(parents=True)
    (img / "12.pic_thum").write_bytes(b"tiny")
    assert history_map.find_hist_media(root, "12") is None
