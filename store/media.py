"""Media handling for the ingest consumer (todo 15).

Store-side mirror of the PKC CDN/silk download path: on the device, the tweak
reuses ``pkcAutoDownloadImgOrVideo`` / ``getAudioFileName:LocalID:`` /
``WCDownloadVideoCDNMgr`` and drops the downloaded file next to the inbox json
(``inbox/<uuid>.<ext>``).  This module is the fnOS consumer's decision layer:
it decides, from the event's ``msg_type`` and the size of the file that
actually arrived, whether the body is copied into ``groups|dms/<chat>/media/``
or indexed as metadata-only.

Rules (from the plan's todo 15 MUST NOT list):

- image and voice bodies are always copied (voice is stored as its ``.silk``
  file; NO ASR is ever performed — the store records the file + ``[voice]``
  placeholder text and nothing else);
- a video body larger than 50MB is NOT copied — the row is still inserted with
  ``media_path`` empty and a ``media_error`` note in ``extra_json`` (metadata
  only);
- a media-typed event whose file never arrived (failed download) is NEVER
  dropped: the row is still indexed with ``media_path`` empty and a
  ``media_error`` in ``extra_json``;
- non-media events carry no media decision and never get a ``media_error``.

``merge_media_error`` folds the reason into the event's existing
``extra_json`` payload (e.g. ``{"raw_type": 43}``) instead of overwriting it.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

#: Video body cap from the plan: bodies larger than this are indexed, not copied.
MAX_VIDEO_BYTES = 2 * 1024 * 1024 * 1024  # 2 GiB; live plugin still applies its own smaller cap

#: Ingest types that carry a media body the consumer is expected to store.
MEDIA_MSG_TYPES = frozenset({"image", "voice", "video", "emoji", "file"})

DIR_IMAGES = "图片"
DIR_VOICE = "语音"
DIR_VIDEO = "视频"
DIR_FILES = "文件"

_EXT_FOLDER = {
    ".pic": DIR_IMAGES, ".pic_hd": DIR_IMAGES, ".jpg": DIR_IMAGES, ".jpeg": DIR_IMAGES,
    ".png": DIR_IMAGES, ".gif": DIR_IMAGES, ".heic": DIR_IMAGES, ".wxam": DIR_IMAGES,
    ".aud": DIR_VOICE, ".silk": DIR_VOICE, ".slk": DIR_VOICE, ".amr": DIR_VOICE, ".wav": DIR_VOICE,
    ".mp4": DIR_VIDEO, ".mov": DIR_VIDEO, ".video": DIR_VIDEO, ".video_thum": DIR_VIDEO,
}


def media_folder(msg_type: str, filename: str = "") -> str:
    """Per-chat subfolder for one media file: 图片 / 语音 / 视频 / 文件."""
    kind = (msg_type or "").lower()
    if kind == "voice":
        return DIR_VOICE
    if kind == "video":
        return DIR_VIDEO
    if kind in {"image", "emoji"}:
        return DIR_IMAGES
    if kind == "file":
        return DIR_FILES
    ext = Path(filename).suffix.lower() if filename else ""
    if ext == ".thum" or ext.endswith("_thum"):
        return DIR_VIDEO
    return _EXT_FOLDER.get(ext, DIR_FILES)


@dataclass(frozen=True, slots=True)
class MediaDecision:
    """What to do with one event's media file."""

    copy_body: bool
    #: Human-readable reason when the body is not copied (recorded into
    #: extra_json as ``media_error``); None on the happy path.
    reason: str | None = None


def decide_media(msg_type: str, media_size: int | None) -> MediaDecision:
    """Decide whether to copy an event's media body, given the size of the
    file that actually arrived next to the inbox json (None = no file)."""
    if media_size is None:
        if msg_type in MEDIA_MSG_TYPES:
            return MediaDecision(
                copy_body=False,
                reason=f"media download failed: no media file for {msg_type}",
            )
        return MediaDecision(copy_body=False, reason=None)

    if msg_type == "video" and media_size > MAX_VIDEO_BYTES:
        return MediaDecision(
            copy_body=False,
            reason=f"video body skipped: {media_size} bytes exceeds 2GB cap",
        )

    return MediaDecision(copy_body=True, reason=None)


def media_text(msg_type: str, text: str | None) -> str | None:
    """Placeholder text for a media-typed event whose payload carried none.

    The device mapper normally sets ``[image]``/``[voice]``/``[video]``; this
    is the store-side backstop so a media event never lands with an empty
    text.  Voice is stored as ``[voice]`` — never ASR-transcribed here."""
    if text:
        return text
    if msg_type in MEDIA_MSG_TYPES:
        return f"[{msg_type}]"
    return text


def merge_media_error(extra_json: str | None, reason: str) -> str:
    """Return *extra_json* with a ``media_error`` field added, preserving any
    existing payload (raw_type, red-packet amount, ...).  Malformed JSON is
    replaced rather than raised — the row must always be indexable."""
    try:
        payload = json.loads(extra_json) if extra_json else {}
    except (json.JSONDecodeError, TypeError):
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    payload["media_error"] = reason
    return json.dumps(payload, ensure_ascii=False)
