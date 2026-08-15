"""Pure ingest/reply policy engine for the WeChat plugin.

Single source of truth for the decision matrix used by both the iOS tweak
and the fnOS consumer. No network, no I/O, no OpenClaw — pure functions.

Decision rules (in precedence order):

1. ``ts < enabled_at`` → drop (no backfill of pre-enable history).
2. Chat is in the matching exclude list → drop.
3. ``record_all_groups`` / ``record_all_dms`` → ingest that kind.
4. Otherwise the chat must be on its kind whitelist. Both whitelists empty
   and both record-all flags off → drop (fail closed).
5. Reply is only True for an ingested *group* message that is not self
   and that either @'s the bot or starts with the command prefix.
   The iOS dylib never sends; PKC owns group replies. DMs never reply.

The ingest gate (``decide_ingest``) is rules 1–4 only. It deliberately never
reads ``is_at_me`` / ``command_prefix``, so a whitelisted chat's message is
ingested silently even when nothing triggers a reply (todo-11: no trigger
gate for ingest; reply stays a separate decision, todos 13/14).
"""

from __future__ import annotations


def has_command_prefix(text: str | None, prefix: str | None) -> bool:
    """True when *text* starts with *prefix* (ignoring leading whitespace).

    Returns False when either is missing or empty.
    """
    if not text or not prefix:
        return False
    return text.lstrip().startswith(prefix)


def decide(event: dict, config: dict) -> dict:
    """Return ``{"ingest": bool, "reply": bool}`` for one chat event."""
    # Rule 1: no backfill — anything before the enable timestamp is dropped.
    if event.get("ts", 0) < config.get("enabled_at", 0):
        return {"ingest": False, "reply": False}

    chat_kind = event.get("chat_kind")
    chat_id = event.get("chat_id")

    group_whitelist = config.get("group_whitelist") or []
    dm_whitelist = config.get("dm_whitelist") or []
    group_exclude = config.get("group_exclude") or []
    dm_exclude = config.get("dm_exclude") or []
    record_all_groups = bool(config.get("record_all_groups"))
    record_all_dms = bool(config.get("record_all_dms"))

    if chat_kind == "group":
        if chat_id in group_exclude:
            return {"ingest": False, "reply": False}
        allowed = record_all_groups or chat_id in group_whitelist
    elif chat_kind == "dm":
        if chat_id in dm_exclude:
            return {"ingest": False, "reply": False}
        allowed = record_all_dms or chat_id in dm_whitelist
    else:
        return {"ingest": False, "reply": False}

    if not allowed:
        return {"ingest": False, "reply": False}

    reply = False
    if chat_kind == "group" and not event.get("is_self"):
        reply = event.get("is_at_me", False) or has_command_prefix(
            event.get("text"), config.get("command_prefix")
        )
    return {"ingest": True, "reply": reply}


def decide_ingest(event: dict, config: dict) -> bool:
    """Whether *event* should be enqueued for ingest (the ingest gate).

    Applies rules 1–4 of :func:`decide` — no backfill + whitelist — and
    nothing else. It deliberately does NOT require ``is_at_me`` or the
    command prefix: those only feed the *reply* decision (todos 13/14), so a
    whitelisted chat's message is ingested silently even when it triggers no
    reply. Returns True exactly when ``decide(event, config)["ingest"]`` is
    True.
    """
    return decide(event, config)["ingest"]
