-- wechat-ingest SQLite index schema (fnOS: /root/.openclaw/wechat-ingest/index.sqlite)
--
-- One row per ingested WeChat message.  Plain TEXT columns mirror the
-- per-chat JSONL events (groups/<chatroom_id>/events.jsonl,
-- dms/<wxid>/events.jsonl).  extra_json carries payloads the fixed
-- columns do not model (raw WeChat type, red-packet amount, reply flag, ...).
--
-- Enforced here: chat_kind is only 'group'|'dm', and a (chat_id, msg_id)
-- pair is unique so replayed inbox files are idempotent.

CREATE TABLE IF NOT EXISTS events (
    chat_id    TEXT,
    chat_kind  TEXT CHECK (chat_kind IN ('group', 'dm')),
    msg_id     TEXT,
    msg_type   TEXT,
    sender     TEXT,
    ts         INTEGER,
    text       TEXT,
    media_path TEXT,
    extra_json TEXT,
    UNIQUE (chat_id, msg_id)
);
