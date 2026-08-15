"""Unit-file safety + bootstrap tests for the wechat-ingest systemd units (todo 6).

Runnable two ways (both documented in the evidence file):

    python3 deploy/test_units.py           # standalone wrapper -> pytest
    python3 -m pytest deploy/test_units.py -q

Locks the plan acceptance criteria for todo 6:

  * no new public TCP listen anywhere in the units
      -> a unit that would Listen on ``0.0.0.0:18791`` is REJECTED
  * ``User=`` is documented (root is expected: fnOS runs OpenClaw as root)
  * ``WECHAT_INGEST_ROOT=/root/.openclaw/wechat-ingest`` is set
  * ``ExecStart`` runs the inbox consumer (store/consumer.py), never a
    second OpenClaw instance

``systemd-analyze verify`` is invoked when the binary exists (real fnOS);
on hosts without systemd (e.g. the dev Mac) the path/schema checks above are
the gate, which the plan explicitly allows.
"""

from __future__ import annotations

import configparser
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

DEPLOY_DIR = Path(__file__).resolve().parent
SERVICE = DEPLOY_DIR / "wechat-ingest.service"
PATH_UNIT = DEPLOY_DIR / "wechat-ingest.path"
INSTALL_SH = DEPLOY_DIR / "install-ingest.sh"

INGEST_ROOT = "/root/.openclaw/wechat-ingest"
FORBIDDEN_PUBLIC_LISTEN = ("0.0.0.0", "18791", "ListenStream", "ListenDatagram")


# --------------------------------------------------------------------------- helpers

def parse_unit(path: Path) -> configparser.ConfigParser:
    """Parse a systemd unit as INI.  systemd accepts both '=' and ' : ' as
    key separators; configparser covers the '=' form used by these units."""
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    # systemd directive names keep their written casing (ExecStart, not
    # execstart): make option lookups case-preserving.
    parser.optionxform = str
    with path.open(encoding="utf-8") as fh:
        parser.read_file(fh)
    return parser


def directive_lines(path: Path, name: str) -> list[str]:
    """Return the raw RHS of every ``Name=value`` line in a unit, in order."""
    return re.findall(
        rf"^{re.escape(name)}\s*=\s*(.+)$",
        path.read_text(encoding="utf-8"),
        flags=re.MULTILINE,
    )


def network_violations(text: str) -> list[str]:
    """Return a list of reasons why ``text`` would open or reference a new
    public TCP listener.  Empty list == safe (the acceptance gate)."""
    problems: list[str] = []
    for needle in FORBIDDEN_PUBLIC_LISTEN:
        if needle in text:
            problems.append(f"contains forbidden token {needle!r}")
    if re.search(r"^\[Socket\]\s*$", text, flags=re.MULTILINE):
        problems.append("contains a [Socket] section")
    if re.search(r"\bListen[A-Za-z]*\s*=", text):
        problems.append("contains a Listen*= directive")
    return problems


# ------------------------------------------------------------------ unit schema

def test_service_unit_parses() -> None:
    parser = parse_unit(SERVICE)
    assert parser.has_section("Unit")
    assert parser.has_section("Service")
    assert parser.has_section("Install")


def test_path_unit_parses() -> None:
    parser = parse_unit(PATH_UNIT)
    assert parser.has_section("Unit")
    assert parser.has_section("Path")
    assert parser.has_section("Install")


def test_both_units_wanted_by_multi_user() -> None:
    assert parse_unit(SERVICE).get("Install", "WantedBy") == "multi-user.target"
    assert parse_unit(PATH_UNIT).get("Install", "WantedBy") == "multi-user.target"


# ------------------------------------------------------- no public TCP listen

def test_service_has_no_public_listen() -> None:
    assert network_violations(SERVICE.read_text(encoding="utf-8")) == []


def test_path_unit_has_no_listener() -> None:
    assert network_violations(PATH_UNIT.read_text(encoding="utf-8")) == []


def test_no_forbidden_token_in_any_deploy_unit() -> None:
    for unit in (SERVICE, PATH_UNIT):
        assert network_violations(unit.read_text(encoding="utf-8")) == []


def test_unit_listening_on_0000_18791_is_rejected() -> None:
    # QA failure case from the plan: a unit that listens on 0.0.0.0:18791
    # must be rejected by the checker.
    evil = (
        "[Service]\n"
        "ExecStart=/usr/bin/something\n"
        "[Socket]\n"
        "ListenStream=0.0.0.0:18791\n"
    )
    violations = network_violations(evil)
    assert violations, "checker must flag 0.0.0.0:18791"
    assert any("18791" in v for v in violations)


# ------------------------------------------------------------------ User + env

def test_service_user_is_documented_root() -> None:
    """User= must be present and documented.  root is expected because fnOS
    runs the existing OpenClaw as root and the store lives under /root."""
    text = SERVICE.read_text(encoding="utf-8")
    assert "User=root" in text, "service must declare User=root"
    assert "Group=root" in text
    # The unit body must justify the root choice in a comment (documented).
    assert re.search(r"^# .*root", text, flags=re.MULTILINE | re.IGNORECASE)


def test_service_sets_ingest_root_env() -> None:
    text = SERVICE.read_text(encoding="utf-8")
    assert f"WECHAT_INGEST_ROOT={INGEST_ROOT}" in text


def test_path_unit_watches_the_same_inbox() -> None:
    parser = parse_unit(PATH_UNIT)
    assert parser.get("Path", "Unit") == "wechat-ingest.service"
    assert parser.get("Path", "PathChanged") == f"{INGEST_ROOT}/inbox/"


# -------------------------------------------- consumer, not a second OpenClaw

def test_service_execs_consumer_never_openclaw() -> None:
    text = SERVICE.read_text(encoding="utf-8")
    exec_start = parse_unit(SERVICE).get("Service", "ExecStart")
    assert "python3" in exec_start
    assert "store/consumer.py" in exec_start
    # No second OpenClaw: the exec line must not invoke the openclaw binary.
    assert "openclaw" not in exec_start


def test_service_recreates_store_skeleton_at_boot() -> None:
    pre = directive_lines(SERVICE, "ExecStartPre")
    assert pre, "service must mkdir the store skeleton before consuming"
    for sub in ("groups", "dms", "inbox", "inbox/failed"):
        assert any(sub in cmd for cmd in pre), f"skeleton dir missing: {sub}"


# ---------------------------------------------------------------- install script

def test_install_script_is_executable() -> None:
    assert INSTALL_SH.exists()
    assert INSTALL_SH.stat().st_mode & 0o111, "install-ingest.sh must be executable"


def test_install_script_bootstraps_required_dirs() -> None:
    text = INSTALL_SH.read_text(encoding="utf-8")
    for sub in ("groups", "dms", "inbox", "inbox/failed"):
        assert sub in text, f"install script must create {sub}/"


def test_install_script_contains_no_device_credentials() -> None:
    text = INSTALL_SH.read_text(encoding="utf-8")
    assert "CONSOLE_PASSWORD" not in text
    assert "a7430375" not in text


def test_install_script_never_execs_openclaw() -> None:
    # No *command* in the script may launch the openclaw binary (the
    # ".openclaw" directory path is fine).  Commands are lines whose first
    # token is an executable; a comment or an argument never starts a line.
    text = INSTALL_SH.read_text(encoding="utf-8")
    commands = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" in line and not line.startswith("if"):
            continue  # assignment / function call, not an exec
        commands.append(line)
    assert commands
    for cmd in commands:
        first = cmd.split()[0]
        assert not first.endswith("/openclaw") and first != "openclaw", \
            f"command would launch a second OpenClaw: {cmd!r}"


# ------------------------------------- systemd-analyze (only where systemd lives)

def test_systemd_analyze_verify_if_available() -> None:
    """On fnOS, real verification: systemd-analyze verify both units.

    On hosts without systemd (dev Mac) this is skipped - the schema/safety
    tests above are the gate, which the plan explicitly allows.  When systemd
    DOES exist but the consumer script has not shipped yet (todo 5), the
    resulting 'executable does not exist' error is expected and not a unit
    defect, so it is downgraded to a warning rather than a failure.
    """
    analyzer = shutil.which("systemd-analyze")
    if analyzer is None:
        pytest.skip("systemd-analyze not available on this host; schema tests are the gate")
    proc = subprocess.run(
        [analyzer, "verify", str(SERVICE), str(PATH_UNIT)],
        capture_output=True, text=True, check=False,
    )
    tolerable = ("does not exist", "No such file or directory",
                 "not found", "may not be accessible")
    real_errors = [line for line in proc.stderr.splitlines()
                   if not any(msg in line for msg in tolerable)]
    assert not real_errors, "systemd-analyze verify failed:\n" + "\n".join(real_errors)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
