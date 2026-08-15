#!/usr/bin/env python3
"""Decode WeChat silk/amr voice and transcribe on fnOS."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(os.environ.get("WECHAT_INGEST_ROOT", "/data/wechat-ingest"))
FFMPEG = shutil.which("ffmpeg") or "/usr/bin/ffmpeg"


def _silk_header(data: bytes) -> bool:
    return data.startswith(b"#!SILK_V3") or data[1:10] == b"#!SILK_V3"


def to_wav(src: Path, wav: Path) -> bool:
    raw = src.read_bytes()
    tmp = src
    if _silk_header(raw) or src.suffix.lower() in {".aud", ".silk", ".slk"}:
        decoder = (
            shutil.which("decoder")
            or shutil.which("silk-decoder")
            or next((str(p) for p in (
                Path("/home/zkx/wechat-ingest/tools/silk-decoder"),
                Path("/usr/local/bin/silk-decoder"),
            ) if p.is_file()), None)
        )
        if decoder:
            pcm = wav.with_suffix(".pcm")
            cmd = [decoder, str(src), str(pcm), "-Fs_API", "24000"]
            if subprocess.run(cmd, capture_output=True).returncode == 0 and pcm.is_file():
                ff = [
                    FFMPEG, "-y", "-f", "s16le", "-ar", "24000", "-ac", "1",
                    "-i", str(pcm), str(wav),
                ]
                ok = subprocess.run(ff, capture_output=True).returncode == 0
                pcm.unlink(missing_ok=True)
                return ok and wav.is_file()
        # strip WeChat 1-byte prefix and retry ffmpeg (sometimes amr/mp3)
        if raw[:1] in (b"\x02", b"\x01") and raw[1:10] == b"#!SILK_V3":
            stripped = src.with_suffix(".silk")
            stripped.write_bytes(raw[1:])
            tmp = stripped
    if not FFMPEG:
        return False
    cmd = [FFMPEG, "-y", "-i", str(tmp), "-ac", "1", "-ar", "16000", str(wav)]
    return subprocess.run(cmd, capture_output=True).returncode == 0 and wav.is_file()


def transcribe_wav(wav: Path) -> str:
    base = os.environ.get("OPENAI_BASE_URL") or os.environ.get("WECHAT_ASR_BASE") or ""
    key = os.environ.get("OPENAI_API_KEY") or os.environ.get("WECHAT_ASR_KEY") or ""
    if base and key:
        import urllib.request
        boundary = "----weclaw"
        data = (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nzh\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n"
            f"Content-Type: audio/wav\r\n\r\n"
        ).encode() + wav.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
        url = base.rstrip("/") + "/audio/transcriptions"
        req = urllib.request.Request(url, data=data, method="POST")
        req.add_header("Authorization", f"Bearer {key}")
        req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                payload = json.loads(resp.read().decode())
            return (payload.get("text") or "").strip()
        except Exception:
            pass
    venv_py = Path("/home/zkx/wechat-ingest/venv/bin/python")
    if venv_py.is_file():
        try:
            out = subprocess.run(
                [str(venv_py), "-c",
                 "from faster_whisper import WhisperModel; import sys; "
                 "m=WhisperModel('tiny', device='cpu', compute_type='int8'); "
                 "segs,_=m.transcribe(sys.argv[1], language='zh'); "
                 "print(''.join(s.text for s in segs))",
                 str(wav)],
                capture_output=True, text=True, timeout=180,
            )
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except Exception:
            pass
    whisper = shutil.which("whisper")
    if whisper:
        out = subprocess.run(
            [whisper, str(wav), "--language", "zh", "--model", "tiny", "--output_format", "txt", "--output_dir", str(wav.parent)],
            capture_output=True, text=True,
        )
        txt = wav.with_suffix(".txt")
        if txt.is_file():
            return txt.read_text(encoding="utf-8").strip()
        return (out.stdout or "").strip()
    return ""


def transcribe_file(src: Path) -> str:
    with tempfile.TemporaryDirectory() as td:
        wav = Path(td) / "a.wav"
        if not to_wav(src, wav):
            return ""
        return transcribe_wav(wav)


def attach_to_event(event: dict, text: str) -> dict:
    extra = {}
    if event.get("extra_json"):
        try:
            extra = json.loads(event["extra_json"])
        except json.JSONDecodeError:
            extra = {}
    extra["asr"] = text
    event["extra_json"] = json.dumps(extra, ensure_ascii=False)
    if text and (not event.get("text") or event["text"] in {"[voice]", "[语音]"}):
        event["text"] = f"[语音] {text}"
    return event


if __name__ == "__main__":
    import sys
    print(transcribe_file(Path(sys.argv[1])) if len(sys.argv) > 1 else "usage: transcribe.py file")
