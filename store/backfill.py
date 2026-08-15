#!/usr/bin/env python3
"""Import historical events from a JSONL file into the inbox (phase 5).

Each line must be a store event object. Used for selected-group backfill
after you export history; the iOS dylib records live traffic going forward.
"""

from __future__ import annotations

import json
import sys
import uuid
from pathlib import Path

from consumer import consume_inbox, default_root


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: backfill.py events.jsonl", file=sys.stderr)
        return 2
    src = Path(sys.argv[1])
    root = default_root()
    inbox = root / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    count = 0
    for line in src.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        (inbox / f"{uuid.uuid4()}.json").write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
        count += 1
    consumed, failed = consume_inbox(root)
    print(f"queued={count} consumed={consumed} failed={failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
