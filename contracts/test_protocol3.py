#!/usr/bin/env python3
"""Protocol-3 hello identity fixture tests (fnOS OpenClaw whitelist).

Locks the client identity the reply pipe must present so the fnOS
OpenClaw whitelist keeps accepting the plugin:

    client     openclaw-control-ui
    mode       webchat
    version    1.0.0
    userAgent  pkc-openclaw-client/1.0.0
    role       operator
    protocol   3

Protocol 4 must never be introduced as valid; only protocol 3 is accepted.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

FIXTURE = Path(__file__).with_name("protocol3_hello.json")

EXPECTED: dict[str, object] = {
    "client": "openclaw-control-ui",
    "mode": "webchat",
    "version": "1.0.0",
    "userAgent": "pkc-openclaw-client/1.0.0",
    "role": "operator",
    "protocol": 3,
}


def load_fixture() -> dict[str, object]:
    with open(FIXTURE, encoding="utf-8") as fh:
        return json.load(fh)


def assert_hello_identity(hello: dict[str, object]) -> None:
    """Assert a hello dict is exactly the protocol-3 identity.

    Raises AssertionError on any mismatch, so both the happy path and the
    failure-path tests share one source of truth.
    """
    assert hello == EXPECTED, f"hello != protocol-3 identity: {hello!r}"
    assert isinstance(hello["protocol"], int), "protocol must be the integer 3"


def test_hello_matches_protocol3_identity() -> None:
    """happy: the fixture matches every required hello field."""
    hello = load_fixture()
    for field, expected in EXPECTED.items():
        assert hello[field] == expected, (
            f"field {field!r}: expected {expected!r}, got {hello.get(field)!r}"
        )
    assert_hello_identity(hello)


def test_mutating_user_agent_is_rejected() -> None:
    """failure: userAgent=other must fail the identity check."""
    hello = load_fixture()
    hello["userAgent"] = "other"
    try:
        assert_hello_identity(hello)
    except AssertionError:
        return
    raise AssertionError("userAgent='other' must be rejected by the identity check")


def test_protocol_4_is_rejected() -> None:
    """failure: protocol=4 must never be accepted; only protocol 3 is valid."""
    hello = load_fixture()
    hello["protocol"] = 4
    try:
        assert_hello_identity(hello)
    except AssertionError:
        return
    raise AssertionError("protocol=4 must be rejected by the identity check")


def main() -> int:
    test_hello_matches_protocol3_identity()
    test_mutating_user_agent_is_rejected()
    test_protocol_4_is_rejected()
    print("PASS: protocol-3 hello identity matches; userAgent=other and protocol=4 rejected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
