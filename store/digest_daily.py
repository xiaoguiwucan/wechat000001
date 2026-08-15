#!/usr/bin/env python3
"""Write a daily WeChat digest markdown under memory/ if possible."""

from __future__ import annotations

import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(os.environ.get("WECHAT_INGEST_ROOT", "/data/wechat-ingest"))
CLI = Path(__file__).resolve().parent / "cli.py"
CST = timezone(timedelta(hours=8))


def main() -> int:
    day = (datetime.now(tz=CST) - timedelta(days=1)).date().isoformat()
    if len(sys.argv) > 1:
        day = sys.argv[1]
    env = os.environ.copy()
    env["WECHAT_INGEST_ROOT"] = str(ROOT)
    text = subprocess.check_output(
        [sys.executable, str(CLI), "digest", "--date", day, "--kind", "group"],
        env=env,
        text=True,
    )
    out_dir = ROOT / "日报"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{day}.md"
    path.write_text(text, encoding="utf-8")

    memory_candidates = [
        Path("/root/.openclaw/workspace/memory"),
        Path.home() / ".openclaw/workspace/memory",
        ROOT / "memory",
    ]
    for memory in memory_candidates:
        if memory.parent.is_dir() or os.access(memory.parent, os.W_OK):
            try:
                memory.mkdir(parents=True, exist_ok=True)
                memo = memory / f"{day}.md"
                existing = memo.read_text(encoding="utf-8") if memo.is_file() else ""
                block = f"\n\n## 微信群日报\n\n{text}\n"
                if "## 微信群日报" not in existing:
                    memo.write_text(existing + block, encoding="utf-8")
                break
            except OSError:
                continue
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
