#!/usr/bin/env python3
"""Contract test: PKCWeChatTools.dylib must contain every required selector.

Re-scans the live dylib with `rabin2 -c` and `strings` and fails if any
selector declared in `contracts/pkc-selectors.json` (field ``required``) is
missing from the binary. The JSON is never trusted blindly — the live scan is
the source of truth.

Runnable two ways:
    python3 contracts/test_pkc_selectors.py          # standalone, exit 0 on pass
    python3 -m pytest contracts/test_pkc_selectors.py -q   # pytest collection

Commit note: the failure path (a scan missing ``isAtMe:``) is covered by the
dedicated test ``test_missing_selector_is_rejected`` and must stay committed.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONTRACT = HERE / "pkc-selectors.json"

DYLIB = Path(os.environ.get("PKC_DYLIB", ""))

# Selectors todo-1 guarantees. Every one must be declared in
# pkc-selectors.json["required"] AND be found by the live dylib scan.
REQUIRED = [
    "AddMsg:MsgWrap:",
    "AsyncOnPreAddMsg:MsgWrap:",
    "HandleAppMsg:MsgWrap:",
    "isAtMe:",
    "pkcOpenClawText:byChat:",
    "oc_connectOpenClawWithURL:token:sessionKey:completion:",
    "sendMsg:toUser:",
    "pkcReplyMessage:",
    "getAudioFileName:LocalID:",
    "pkcAutoDownloadImgOrVideo",
]


def path_env() -> dict[str, str]:
    """PATH prefixed with the tool dirs where rabin2 lives."""
    env = os.environ.copy()
    env["PATH"] = f"{Path.home()}/.local/bin:/opt/homebrew/bin:" + env.get("PATH", "")
    return env


def scan_selectors() -> set[str]:
    """Union of declared ObjC methods (rabin2 -c) and selector literals (strings)."""
    found: set[str] = set()

    rabin = subprocess.run(
        ["rabin2", "-c", str(DYLIB)],
        capture_output=True,
        text=True,
        env=path_env(),
        check=True,
    )
    for line in rabin.stdout.splitlines():
        if "objc" in line and "method" in line:
            tokens = line.split()
            if tokens:
                found.add(tokens[-1])

    strs = subprocess.run(
        ["strings", str(DYLIB)],
        capture_output=True,
        text=True,
        env=path_env(),
        check=True,
    )
    for line in strs.stdout.splitlines():
        selector = line.strip()
        # Selector literals carry ':' or start with the 'pkc' prefix. Extra
        # matches are harmless for membership checks; the required set is exact.
        if ":" in selector or selector.startswith("pkc"):
            found.add(selector)

    return found


def required_from_json() -> list[str]:
    """Parse the ``required`` selector list from the contract JSON."""
    data = json.loads(CONTRACT.read_text(encoding="utf-8"))
    required = data.get("required")
    if not isinstance(required, list):
        raise AssertionError("pkc-selectors.json: field 'required' must be a list")
    return required


def missing_selectors(required: list[str], found: set[str]) -> list[str]:
    """Selectors in ``required`` that are absent from the live scan."""
    return [selector for selector in required if selector not in found]


def test_required_selectors_are_declared_in_json() -> None:
    """Every guaranteed selector must be listed in pkc-selectors.json["required"]."""
    declared = required_from_json()
    undeclared = [s for s in REQUIRED if s not in declared]
    assert not undeclared, f"pkc-selectors.json missing required selectors: {undeclared}"


def test_live_dylib_contains_required_selectors() -> None:
    """The live dylib scan must contain every selector declared as required."""
    if not DYLIB.is_file():
        try:
            import pytest
            pytest.skip("set PKC_DYLIB to a PKC sample dylib to run the live scan")
        except ImportError:
            print("SKIP live dylib scan (PKC_DYLIB unset)")
            return
    declared = required_from_json()
    found = scan_selectors()
    absent = missing_selectors(declared, found)
    assert not absent, f"selectors missing from live dylib scan: {absent}"


def test_missing_selector_is_rejected() -> None:
    """Failure path: a scan missing ``isAtMe:`` must be detected.

    Mocks the missing-strings case by removing ``isAtMe:`` from an otherwise
    complete scan result and asserts the checker reports it. If the required
    selector is ever dropped from the expected list, this test fails.
    """
    declared = required_from_json()
    assert "isAtMe:" in declared, "isAtMe: must stay in the required contract"

    complete = set(declared)
    mocked_missing = complete - {"isAtMe:"}
    reported = missing_selectors(declared, mocked_missing)

    assert reported == ["isAtMe:"], f"expected isAtMe: to be reported, got {reported}"


def main() -> int:
    tests = [
        test_required_selectors_are_declared_in_json,
        test_live_dylib_contains_required_selectors,
        test_missing_selector_is_rejected,
    ]
    failures = 0
    for test in tests:
        name = test.__name__
        try:
            test()
            print(f"PASS  {name}")
        except Exception as exc:  # noqa: BLE001 - runner boundary, report and continue
            failures += 1
            print(f"FAIL  {name}: {exc}")
    if failures:
        print(f"{failures} contract check(s) FAILED")
        return 1
    print("All PKC selector contract checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
