"""SFTP inbox transporter for wechat-ingest (todo 12).

Drops one ingest event (JSON + optional media) into
``<root>/inbox/<uuid>.json`` / ``<root>/inbox/<uuid>.<ext>`` over the EXISTING
SSH session — the libssh2 ``SSHForwarder`` *pattern* PKC uses, shaped the same
way (``initWithSSHHost:sshPort:username:password:`` on the ObjC side, this
module on the host side): one SSH connection can multiplex the SFTP channel
(ingest) with the 18790 local forward (todo-13 reply pipe).  NO new public port
is ever opened here, and this path NEVER calls ``sendMsg`` / any reply
mechanism — ingest is strictly a one-way SFTP put.

Config contract (env, never embedded in source):

- ``WECHAT_INGEST_SSH_HOST``   — required
- ``WECHAT_INGEST_SSH_PORT``   — default 22
- ``WECHAT_INGEST_SSH_USER``   — default "root"
- ``WECHAT_INGEST_SSH_PASSWORD`` — optional (None = key/agent auth)

The ingest root defaults to ``WECHAT_INGEST_ROOT`` (same env contract as
``consumer.default_root``), so the remote drop lands in the same tree the
consumer reads.

Transport seam: ``SftpInboxTransporter`` talks to an ``SftpTransport``
(``put_bytes`` / ``close``).  ``ParamikoSftpTransport`` implements it over a
real paramiko SFTP subsystem (the local test suite also runs it against an
in-process paramiko SFTP server); tests inject a fake to exercise ordering and
the bounded-retry path without a network.

Retry policy: a failed SFTP put is retried up to ``max_attempts`` with
``retry_delay`` backoff; after the last attempt ``SftpDropError`` is raised so
the caller keeps the event (never silently dropped, never routed to a reply).
Media is written BEFORE the json: the json is the consumer's atomic claim
marker, so a racing consumer can never see a media-less commit.
"""

from __future__ import annotations

import json
import os
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from consumer import default_root


class SftpError(Exception):
    """Base error for the ingest SFTP transporter."""


class SftpConfigError(SftpError):
    """Bad or missing SSH configuration."""


class SftpDropError(SftpError):
    """An inbox file could not be SFTP-put after all retry attempts."""


@dataclass(frozen=True, slots=True)
class SftpConfig:
    """SSH connection parameters for the ingest drop (from env, not source)."""

    host: str
    port: int = 22
    user: str = "root"
    password: str | None = None

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "SftpConfig":
        env = os.environ if env is None else env
        host = env.get("WECHAT_INGEST_SSH_HOST", "")
        if not host:
            raise SftpConfigError("WECHAT_INGEST_SSH_HOST is not set")
        port = int(env.get("WECHAT_INGEST_SSH_PORT", "22"))
        return cls(
            host=host,
            port=port,
            user=env.get("WECHAT_INGEST_SSH_USER", "root"),
            password=env.get("WECHAT_INGEST_SSH_PASSWORD") or None,
        )


class SftpTransport(Protocol):
    """One SFTP channel over the existing SSH session (put-only for ingest)."""

    def put_bytes(self, remote_path: str, data: bytes) -> None: ...

    def close(self) -> None: ...


class ParamikoSftpTransport:
    """``SftpTransport`` over a real paramiko SSH+SFTP connection.

    Mirrors the PKC ``SSHForwarder`` shape: one SSH client; the SFTP channel
    serves the ingest inbox.  The same client can later multiplex the 18790
    local forward (todo-13 reply pipe) via :attr:`client` — no new public port
    is opened anywhere in this module.
    """

    def __init__(self, config: SftpConfig) -> None:
        import paramiko  # lazy: the module imports and the fake-based tests run without it

        self._client = paramiko.SSHClient()
        self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self._client.connect(
            hostname=config.host,
            port=config.port,
            username=config.user,
            password=config.password,
            timeout=10,
        )
        self._sftp = self._client.open_sftp()

    @property
    def client(self):
        """The underlying SSH client — the seam for a future 18790 local
        forward multiplexed on this same connection (never opened here)."""
        return self._client

    def _mkdir_p(self, remote_dir: str) -> None:
        path = ""
        for part in remote_dir.split("/"):
            if not part:
                continue
            path = f"{path}/{part}"
            try:
                self._sftp.stat(path)
            except FileNotFoundError:
                self._sftp.mkdir(path)

    def put_bytes(self, remote_path: str, data: bytes) -> None:
        self._mkdir_p(remote_path.rsplit("/", 1)[0])
        with self._sftp.open(remote_path, "wb") as fh:
            fh.write(data)

    def close(self) -> None:
        try:
            self._sftp.close()
        finally:
            self._client.close()


class SftpInboxTransporter:
    """Drops serialized events into ``<root>/inbox/`` via an ``SftpTransport``.

    ``transport`` defaults to ``ParamikoSftpTransport`` (paramiko must be
    installed); tests inject a fake.  ``root`` is the REMOTE ingest root
    (``WECHAT_INGEST_ROOT`` by default); drops go under ``<root>/inbox/``.
    """

    def __init__(
        self,
        *,
        config: SftpConfig | None = None,
        root: str | Path | None = None,
        transport: SftpTransport | None = None,
        max_attempts: int = 3,
        retry_delay: float = 0.5,
    ) -> None:
        self._config = config or SftpConfig.from_env()
        self._root = str(root if root is not None else default_root()).rstrip("/")
        self._transport = transport or ParamikoSftpTransport(self._config)
        self._max_attempts = max(1, int(max_attempts))
        self._retry_delay = max(0.0, float(retry_delay))

    def __enter__(self) -> "SftpInboxTransporter":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def close(self) -> None:
        self._transport.close()

    def _remote_path(self, stem: str, suffix: str) -> str:
        return f"{self._root}/inbox/{stem}{suffix}"

    def _put_with_retry(self, remote_path: str, data: bytes) -> None:
        """Bounded retry on transport failure.  This is the ONLY retry boundary:
        every SFTP error class retries; after the last attempt the event is kept
        by the caller (SftpDropError) rather than silently dropped or routed to
        a reply path."""
        last_error: Exception | None = None
        for attempt in range(1, self._max_attempts + 1):
            try:
                self._transport.put_bytes(remote_path, data)
                return
            except Exception as exc:  # transport-level failure — retry with backoff
                last_error = exc
                if attempt < self._max_attempts:
                    time.sleep(self._retry_delay)
        raise SftpDropError(
            f"SFTP put to {remote_path} failed after {self._max_attempts} attempts"
        ) from last_error

    def drop(
        self,
        event: dict,
        *,
        media_bytes: bytes | None = None,
        media_suffix: str = ".bin",
    ) -> str:
        """SFTP-put one event as ``inbox/<uuid>.json`` (+ optional media) into
        the ingest root's ``inbox/``; returns the uuid stem.

        Media is committed BEFORE the json (the consumer atomically claims the
        json, so a racing consumer never sees a media-less commit).  The ingest
        path never calls ``sendMsg`` / any reply mechanism.
        """
        stem = uuid.uuid4().hex
        if media_bytes is not None:
            self._put_with_retry(self._remote_path(stem, media_suffix), media_bytes)
        payload = json.dumps(event, ensure_ascii=False).encode("utf-8")
        self._put_with_retry(self._remote_path(stem, ".json"), payload)
        return stem
