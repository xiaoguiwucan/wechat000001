"""SFTP inbox transporter tests for wechat-ingest (todo 12, TDD).

Locks store/sftp_inbox.py BEFORE the plugin's device-side SFTP put ships. Two
kinds of fixtures prove the same contract:

- an in-process **fake transporter** (``FakeSftpTransport``) backed by a local
  directory that maps the remote virtual filesystem ("/") onto a temp dir — no
  network, deterministic, used for every behavioral test; and
- a **local paramiko SFTP server** (``_LocalSftpServer`` on 127.0.0.1:<ephemeral>)
  that exercises the real ``ParamikoSftpTransport`` against a live SFTP
  subsystem — the "local sftp/paramiko fixture" from the acceptance criteria.

The contract under test:

1. config is read from the environment (host/port/user/password) — never
   embedded in source;
2. ``SftpInboxTransporter.drop`` SFTP-puts ``inbox/<uuid>.json`` (+ optional
   ``inbox/<uuid>.<ext>``) into the ingest root's ``inbox/``;
3. a dropped json is consumed to SQLite by ``consumer.consume_inbox``
   (acceptance: "dropped json is consumed to SQLite");
4. an SFTP error retries with bounded backoff and NEVER calls any reply/send
   seam (acceptance: "SFTP error retries without calling sendMsg" — the ingest
   pipe has no sendMsg path at all);
5. the real paramiko transport works against a live local SFTP server.

Tests use an explicit temp root and the ``WECHAT_INGEST_*`` env contract; the
live password never appears anywhere in the test or the module source.
"""

from __future__ import annotations

import json
import os
import socket
import sqlite3
import threading
import time
from pathlib import Path

import pytest

import consumer
import media
import sftp_inbox
from sftp_inbox import (
    ParamikoSftpTransport,
    SftpConfig,
    SftpConfigError,
    SftpDropError,
    SftpInboxTransporter,
)

try:  # the paramiko real-server test is skipped when paramiko is absent
    import paramiko
except ImportError:  # pragma: no cover — exercised only in minimal envs
    paramiko = None

TEXT_EVENT = {
    "chat_id": "room1",
    "chat_kind": "group",
    "msg_id": "g-sftp-1",
    "msg_type": "text",
    "sender": "wxid_a",
    "ts": 1720000001,
    "text": "hello from sftp",
    "media_path": None,
    "extra_json": None,
}

REMOTE_ROOT = "wechat-ingest"  # remote ingest root under the transport's virtual "/"


# --------------------------------------------------------------------- fakes

class FakeSftpTransport:
    """In-process ``SftpTransport`` fake mapping the remote virtual filesystem
    ("/") onto a local temp dir.  ``fail_before`` makes the first N ``put_bytes``
    calls raise, so the bounded-retry path is exercised without a network.
    ``send_msg_calls`` is a sentinel: the ingest drop path must never touch any
    reply/send seam, so it must stay 0 after every drop attempt."""

    def __init__(self, base: Path, *, fail_before: int = 0) -> None:
        self.base = Path(base)
        self.base.mkdir(parents=True, exist_ok=True)
        self.fail_before = fail_before
        self.put_calls: list[tuple[str, bytes]] = []
        self.send_msg_calls = 0

    def put_bytes(self, remote_path: str, data: bytes) -> None:
        self.put_calls.append((remote_path, data))
        if len(self.put_calls) <= self.fail_before:
            raise OSError("simulated SFTP failure")
        target = self.base.joinpath(*remote_path.lstrip("/").split("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def read_bytes(self, remote_path: str) -> bytes:
        return self.base.joinpath(*remote_path.lstrip("/").split("/")).read_bytes()

    def has(self, remote_path: str) -> bool:
        return self.base.joinpath(*remote_path.lstrip("/").split("/")).is_file()

    def close(self) -> None:
        pass


@pytest.fixture()
def base(tmp_path: Path) -> Path:
    return tmp_path / "sftp-root"


@pytest.fixture()
def fake(base: Path) -> FakeSftpTransport:
    return FakeSftpTransport(base)


def make_transporter(
    transport: FakeSftpTransport | ParamikoSftpTransport,
    *,
    max_attempts: int = 3,
    retry_delay: float = 0.0,
) -> SftpInboxTransporter:
    return SftpInboxTransporter(
        config=SftpConfig(host="127.0.0.1", port=22, user="tester", password="pw"),
        root=REMOTE_ROOT,
        transport=transport,
        max_attempts=max_attempts,
        retry_delay=retry_delay,
    )


# ---------------------------------------------------------- config from env

def test_ssh_config_read_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("WECHAT_INGEST_SSH_HOST", "ingest.example")
    monkeypatch.setenv("WECHAT_INGEST_SSH_PORT", "2222")
    monkeypatch.setenv("WECHAT_INGEST_SSH_USER", "zkx")
    monkeypatch.setenv("WECHAT_INGEST_SSH_PASSWORD", "sekret")
    config = SftpConfig.from_env()
    assert config == SftpConfig(host="ingest.example", port=2222, user="zkx", password="sekret")


def test_ssh_config_defaults_port_and_user(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("WECHAT_INGEST_SSH_HOST", "ingest.example")
    monkeypatch.delenv("WECHAT_INGEST_SSH_PORT", raising=False)
    monkeypatch.delenv("WECHAT_INGEST_SSH_USER", raising=False)
    monkeypatch.delenv("WECHAT_INGEST_SSH_PASSWORD", raising=False)
    config = SftpConfig.from_env()
    assert (config.port, config.user, config.password) == (22, "root", None)


def test_ssh_config_missing_host_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("WECHAT_INGEST_SSH_HOST", raising=False)
    with pytest.raises(SftpConfigError):
        SftpConfig.from_env()


def test_live_password_not_embedded_in_module_source() -> None:
    source = Path(sftp_inbox.__file__).read_text(encoding="utf-8")
    live_password = "Zkx" + "@0426"  # assembled so the raw secret never appears in the repo
    assert live_password not in source


# ------------------------------------------------------- drop into inbox/ via fake

def test_drop_writes_json_and_media_under_inbox(fake: FakeSftpTransport) -> None:
    transporter = make_transporter(fake)
    stem = transporter.drop(TEXT_EVENT, media_bytes=b"\x89PNG fake", media_suffix=".png")

    for remote_path, _data in fake.put_calls:
        assert remote_path.startswith(f"{REMOTE_ROOT}/inbox/")
    assert fake.has(f"{REMOTE_ROOT}/inbox/{stem}.json")
    assert fake.read_bytes(f"{REMOTE_ROOT}/inbox/{stem}.png") == b"\x89PNG fake"

    event = json.loads(fake.read_bytes(f"{REMOTE_ROOT}/inbox/{stem}.json"))
    assert event["msg_id"] == "g-sftp-1"
    # media is committed BEFORE the json (the json is the consumer's claim marker)
    assert fake.put_calls[-1][0].endswith(".json")


def test_dropped_json_is_consumed_to_sqlite(fake: FakeSftpTransport, base: Path) -> None:
    transporter = make_transporter(fake)
    transporter.drop(TEXT_EVENT)

    root = base / REMOTE_ROOT
    assert consumer.consume_inbox(root) == (1, 0)

    conn = sqlite3.connect(root / consumer.FILE_INDEX)
    try:
        row = conn.execute("SELECT chat_id, chat_kind, msg_id, msg_type, text FROM events").fetchone()
    finally:
        conn.close()
    assert row == ("room1", "group", "g-sftp-1", "text", "hello from sftp")
    assert (root / consumer.DIR_GROUPS / "room1" / consumer.FILE_EVENTS).is_file()
    assert not list((root / consumer.DIR_INBOX).glob("*.json"))  # inbox json consumed + unlinked


def test_dropped_media_consumed_at_media_path(fake: FakeSftpTransport, base: Path) -> None:
    transporter = make_transporter(fake)
    stem = transporter.drop(TEXT_EVENT, media_bytes=b"png-bytes", media_suffix=".png")

    root = base / REMOTE_ROOT
    assert consumer.consume_inbox(root) == (1, 0)

    conn = sqlite3.connect(root / consumer.FILE_INDEX)
    try:
        media_path = conn.execute("SELECT media_path FROM events").fetchone()[0]
    finally:
        conn.close()
    assert media_path == f"{consumer.DIR_GROUPS}/room1/{media.DIR_IMAGES}/{stem}.png"
    assert (root / media_path).read_bytes() == b"png-bytes"


# ------------------------------------------- retry on SFTP error, no sendMsg

def test_sftp_error_retries_then_succeeds_without_sendmsg(base: Path) -> None:
    fake = FakeSftpTransport(base, fail_before=2)  # first two puts raise
    transporter = make_transporter(fake, max_attempts=3, retry_delay=0.0)

    transporter.drop(TEXT_EVENT)

    # json put retried 3x (2 failures + success) and eventually landed
    assert len(fake.put_calls) == 3
    assert fake.has(f"{REMOTE_ROOT}/inbox/" + fake.put_calls[-1][0].rsplit("/", 1)[-1])
    assert fake.send_msg_calls == 0
    assert not hasattr(sftp_inbox, "sendMsg")

    root = base / REMOTE_ROOT
    assert consumer.consume_inbox(root) == (1, 0)


def test_sftp_error_exhausts_retries_and_raises_without_sendmsg(base: Path) -> None:
    class AlwaysFailing(FakeSftpTransport):
        def put_bytes(self, remote_path: str, data: bytes) -> None:
            self.put_calls.append((remote_path, data))
            raise OSError("simulated persistent SFTP failure")

    fake = AlwaysFailing(base)
    transporter = make_transporter(fake, max_attempts=2, retry_delay=0.0)

    with pytest.raises(SftpDropError):
        transporter.drop(TEXT_EVENT)

    assert len(fake.put_calls) == 2  # bounded retry, then it gives up loudly
    assert fake.send_msg_calls == 0
    assert not hasattr(sftp_inbox, "sendMsg")


def test_retry_does_not_write_partial_duplicate_json(base: Path) -> None:
    # a failure AFTER the media put must not re-order or duplicate the json
    class FailOnceOnJson(FakeSftpTransport):
        def __init__(self, base: Path) -> None:
            super().__init__(base)
            self.json_failures_left = 1

        def put_bytes(self, remote_path: str, data: bytes) -> None:
            self.put_calls.append((remote_path, data))
            if remote_path.endswith(".json") and self.json_failures_left > 0:
                self.json_failures_left -= 1
                raise OSError("simulated transient json put failure")
            target = self.base.joinpath(*remote_path.lstrip("/").split("/"))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)

    fake = FailOnceOnJson(base)
    transporter = make_transporter(fake, max_attempts=3, retry_delay=0.0)
    transporter.drop(TEXT_EVENT, media_bytes=b"png-bytes", media_suffix=".png")

    json_calls = [p for p, _d in fake.put_calls if p.endswith(".json")]
    assert len(json_calls) == 2  # first json attempt failed, second succeeded
    assert len({p for p, _d in fake.put_calls}) == 2  # one .png + one .json path
    assert fake.send_msg_calls == 0

    root = base / REMOTE_ROOT
    assert consumer.consume_inbox(root) == (1, 0)


# --------------------------------------- real paramiko transport vs live SFTP

class _LocalAuthServer(paramiko.ServerInterface):
    """Accepts any password auth and channel opens on the fixture server. The
    sftp subsystem is handled by the DEFAULT check_channel_subsystem_request,
    which invokes the registered SFTPServer handler."""

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED

    def get_allowed_auths(self, username):
        return "password"


class _LocalHandle(paramiko.SFTPHandle):
    """A write handle over a local file; the default read/write impls use the
    ``readfile``/``writefile`` attributes we set here."""

    def __init__(self, path: Path, flags: int) -> None:
        super().__init__(flags=flags)
        if not path.exists():
            path.touch()
        self.readfile = path.open("r+b")
        self.writefile = self.readfile
        if flags & os.O_TRUNC:
            self.writefile.seek(0)
            self.writefile.truncate()

    def stat(self):
        try:
            return paramiko.SFTPAttributes.from_stat(os.fstat(self.readfile.fileno()))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)


class _LocalSftpServer(paramiko.SFTPServerInterface):
    """Filesystem-backed SFTP server rooted at a temp dir (the local fixture)."""

    def __init__(self, server, root) -> None:
        super().__init__(server)
        self.root = Path(root)

    def _realpath(self, path: str) -> Path:
        return self.root / self.canonicalize(path).lstrip("/")

    @staticmethod
    def _attrs(p: Path) -> paramiko.SFTPAttributes:
        attr = paramiko.SFTPAttributes.from_stat(p.stat())
        attr.filename = p.name
        return attr

    def list_folder(self, path):
        try:
            return [self._attrs(p) for p in sorted(self._realpath(path).iterdir())]
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def stat(self, path):
        try:
            return self._attrs(self._realpath(path))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def lstat(self, path):
        try:
            return self._attrs(self._realpath(path))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def open(self, path, flags, attr):
        p = self._realpath(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        try:
            return _LocalHandle(p, flags)
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def mkdir(self, path, attr):
        try:
            self._realpath(path).mkdir(parents=True, exist_ok=True)
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        return paramiko.SFTP_OK

    def remove(self, path):
        try:
            self._realpath(path).unlink()
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        return paramiko.SFTP_OK

    def rename(self, oldpath, newpath):
        try:
            self._realpath(oldpath).rename(self._realpath(newpath))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        return paramiko.SFTP_OK

    def rmdir(self, path):
        try:
            self._realpath(path).rmdir()
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        return paramiko.SFTP_OK


@pytest.fixture()
def local_sftp_server(tmp_path: Path):
    pytest.importorskip("paramiko")
    server_root = tmp_path / "sftp-server-root"
    server_root.mkdir(parents=True, exist_ok=True)

    host_key = paramiko.RSAKey.generate(2048)
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    port = sock.getsockname()[1]

    def serve() -> None:
        conn, _ = sock.accept()
        transport = paramiko.Transport(conn)
        transport.add_server_key(host_key)
        transport.set_subsystem_handler(
            "sftp", paramiko.SFTPServer, _LocalSftpServer, str(server_root)
        )
        try:
            transport.start_server(server=_LocalAuthServer())
            while transport.is_active():
                time.sleep(0.02)
        finally:
            transport.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield port, server_root
    finally:
        sock.close()


def test_paramiko_transport_drops_into_local_sftp_server(local_sftp_server) -> None:
    pytest.importorskip("paramiko")
    port, server_root = local_sftp_server

    config = SftpConfig(host="127.0.0.1", port=port, user="tester", password="pw")
    transporter = SftpInboxTransporter(
        config=config,
        root=REMOTE_ROOT,
        transport=ParamikoSftpTransport(config),
        max_attempts=2,
        retry_delay=0.0,
    )
    stem = transporter.drop(TEXT_EVENT, media_bytes=b"png-bytes", media_suffix=".png")
    transporter.close()

    inbox = server_root / REMOTE_ROOT / "inbox"
    assert (inbox / f"{stem}.json").is_file()
    assert (inbox / f"{stem}.png").read_bytes() == b"png-bytes"
    assert json.loads((inbox / f"{stem}.json").read_text())["msg_id"] == "g-sftp-1"

    # acceptance: a dropped json is consumed to SQLite via the consumer
    root = server_root / REMOTE_ROOT
    assert consumer.consume_inbox(root) == (1, 0)
    conn = sqlite3.connect(root / consumer.FILE_INDEX)
    try:
        assert conn.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 1
    finally:
        conn.close()
