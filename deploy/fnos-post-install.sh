#!/usr/bin/env bash
set -euo pipefail
chmod 711 /root
mkdir -p /root/.openclaw/wechat-ingest/groups
mkdir -p /root/.openclaw/wechat-ingest/dms
mkdir -p /root/.openclaw/wechat-ingest/inbox
mkdir -p /root/.openclaw/wechat-ingest/inbox/failed
chown -R zkx:Users /root/.openclaw/wechat-ingest
chmod -R u+rwX,g+rwX /root/.openclaw/wechat-ingest
systemctl daemon-reload
systemctl enable --now wechat-ingest.path
echo "path_enabled=$(systemctl is-enabled wechat-ingest.path)"
echo "path_active=$(systemctl is-active wechat-ingest.path)"
ls -ld /root /root/.openclaw /root/.openclaw/wechat-ingest /root/.openclaw/wechat-ingest/inbox
ls -la /opt/wechat-ingest/store/
echo '--- python smoke ---'
cd /opt/wechat-ingest/store
WECHAT_INGEST_ROOT=/root/.openclaw/wechat-ingest /usr/bin/python3 consumer.py
python3 - <<'PY'
import json, uuid
from pathlib import Path
root = Path("/root/.openclaw/wechat-ingest")
ev = {
    "chat_id": "smoke@chatroom",
    "chat_kind": "group",
    "msg_id": "smoke-1",
    "msg_type": "text",
    "sender": "wxid_smoke",
    "ts": 1720000001,
    "text": "fnos ingest smoke",
    "media_path": None,
    "extra_json": None,
}
p = root / "inbox" / (uuid.uuid4().hex + ".json")
p.write_text(json.dumps(ev), encoding="utf-8")
print("wrote", p)
PY
systemctl start wechat-ingest.service || true
sleep 1
WECHAT_INGEST_ROOT=/root/.openclaw/wechat-ingest /usr/bin/python3 /opt/wechat-ingest/store/consumer.py
echo '--- result ---'
ls -la /root/.openclaw/wechat-ingest/groups/smoke@chatroom/ || true
ls /root/.openclaw/wechat-ingest/inbox/ || true
python3 - <<'PY'
import sqlite3
from pathlib import Path
db = Path("/root/.openclaw/wechat-ingest/index.sqlite")
print("db_exists", db.exists(), "size", db.stat().st_size if db.exists() else 0)
if db.exists():
    con = sqlite3.connect(db)
    print(con.execute("select chat_id, msg_id, text from events").fetchall())
PY
systemctl --no-pager --full status wechat-ingest.path | head -20
systemctl --no-pager --full status wechat-ingest.service | tail -25
