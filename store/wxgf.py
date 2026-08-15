"""Decode WeChat wxgf/wxam stills on fnOS with ffmpeg. Phone stays untouched."""

from __future__ import annotations

import subprocess
from pathlib import Path

WXGF_HEADERS = (b"wxgf", b"wxam")


def extract_hevc(data: bytes) -> bytes | None:
    if not data.startswith(WXGF_HEADERS):
        return None
    start = data.find(b"\x00\x00\x00\x01")
    if start < 0:
        start = data.find(b"\x00\x00\x01")
    if start < 0:
        return None
    return data[start:]


def is_wxgf(path: Path) -> bool:
    try:
        return path.read_bytes()[:4] in WXGF_HEADERS
    except OSError:
        return False


def preview_path(src: Path) -> Path:
    return src.with_name(src.name + ".preview.png")


def decode_bytes(data: bytes) -> bytes | None:
    hevc = extract_hevc(data)
    if hevc is None:
        return None
    try:
        proc = subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-f", "hevc", "-i", "pipe:0",
                "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-",
            ],
            input=hevc,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode == 0 and proc.stdout.startswith(b"\x89PNG"):
        return proc.stdout
    return None


def ensure_preview(src: Path) -> Path | None:
    src = Path(src)
    if not src.is_file():
        return None
    cache = preview_path(src)
    try:
        if cache.is_file() and cache.stat().st_mtime >= src.stat().st_mtime and cache.stat().st_size > 32:
            return cache
    except OSError:
        pass
    if not is_wxgf(src):
        return None
    png = decode_bytes(src.read_bytes())
    if not png:
        return None
    tmp = cache.with_suffix(".png.tmp")
    tmp.write_bytes(png)
    tmp.replace(cache)
    return cache


def backfill(root: Path) -> int:
    n = 0
    root = Path(root)
    for folder in ("图片", "媒体", "media"):
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            if path.suffix.lower() not in {".pic", ".pic_hd", ".wxgf", ".wxam", ".dat"}:
                continue
            if ensure_preview(path) is not None:
                n += 1
    return n
