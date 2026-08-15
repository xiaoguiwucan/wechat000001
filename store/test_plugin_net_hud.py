"""Contract checks for plugin LAN/WAN switch, stats, and HUD."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TWEAK = ROOT / "tweak"


def test_new_modules_exist():
    for name in ("hooks/NetworkPath.m", "hooks/UploadStats.m", "hooks/UploadHUD.m"):
        assert (TWEAK / name).is_file()


def test_settings_keys_declared():
    header = (TWEAK / "Settings.h").read_text(encoding="utf-8")
    impl = (TWEAK / "Settings.m").read_text(encoding="utf-8")
    for key in (
        "ingest.net.auto",
        "ingest.net.lan_host",
        "ingest.net.wan_host",
        "ingest.net.wan_port",
        "ingest.hud.enabled",
    ):
        assert key in impl
    assert "autoSwitchNetwork" in header
    assert "hj.wwszxc.tax" in impl
    assert "31631" in impl


def test_effective_host_uses_wifi_or_wan():
    impl = (TWEAK / "Settings.m").read_text(encoding="utf-8")
    assert "[self usingLAN] ? [self lanHost] : [self wanHost]" in impl
    net = (TWEAK / "hooks/NetworkPath.m").read_text(encoding="utf-8")
    assert "pdp_ip" in net
    assert "en0" in net
    assert "markLANFailed" in net
    assert "1.6" in net
    sftp = (TWEAK / "hooks/SftpInboxClient.m").read_text(encoding="utf-8")
    assert "applyCurrentEndpoint" in sftp
    assert "reconnectOnQueue" in sftp


def test_stats_track_types_and_periods():
    stats = (TWEAK / "hooks/UploadStats.m").read_text(encoding="utf-8")
    for token in ("text", "image", "voice", "video", "file", "emoji", "wifi", "wwan", "week", "year"):
        assert token in stats


def test_hud_is_draggable_and_hideable():
    hud = (TWEAK / "hooks/UploadHUD.m").read_text(encoding="utf-8")
    assert "UIPanGestureRecognizer" in hud
    assert "UIPinchGestureRecognizer" in hud
    assert "setHudHidden" in hud
    assert "局域网" in hud
    assert "chatLab" not in hud
    ui = (TWEAK / "hooks/SettingsUI.m").read_text(encoding="utf-8")
    assert "showHud" in ui
    assert "1.5.31" in ui
    assert "mangaRed" in (TWEAK / "hooks/UploadHUD.m").read_text(encoding="utf-8")
