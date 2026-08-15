"""Test-path bootstrap: make the store/ and policy/ modules importable.

The repo modules are flat (``consumer`` / ``sftp_inbox`` / ``media`` in
``store/``; ``ingest_policy`` / ``reply_routing`` / ``send_gate`` and the
``test_msgwrap_map`` mapping contract in ``policy/``) with no ``__init__.py``,
so each suite relies on its own directory being on ``sys.path``. ``tests/``
sits at the repo root, so this conftest prepends the two module directories
before any test imports them.
"""

from __future__ import annotations

import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent

for _dir in ("store", "policy"):
    _path = str(_REPO_ROOT / _dir)
    if _path not in sys.path:
        sys.path.insert(0, _path)
