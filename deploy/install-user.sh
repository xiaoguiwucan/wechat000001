#!/usr/bin/env bash
# Install ingest as user zkx — no root required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${WECHAT_INGEST_ROOT:-$HOME/wechat-ingest/data}"
UNIT_DIR="${HOME}/.config/systemd/user"

mkdir -p "$DATA"/{groups,dms,inbox,inbox/failed,digests,media}
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/wechat-ingest.service" <<EOF
[Unit]
Description=WeChat ingest inbox consumer (user)

[Service]
Type=oneshot
Environment=WECHAT_INGEST_ROOT=$DATA
WorkingDirectory=$ROOT/store
ExecStart=/usr/bin/python3 $ROOT/store/consumer.py
EOF

cat > "$UNIT_DIR/wechat-ingest.path" <<EOF
[Unit]
Description=Watch WeChat ingest inbox

[Path]
PathChanged=$DATA/inbox
Unit=wechat-ingest.service

[Install]
WantedBy=default.target
EOF

cat > "$UNIT_DIR/wechat-digest.service" <<EOF
[Unit]
Description=WeChat daily digest

[Service]
Type=oneshot
Environment=WECHAT_INGEST_ROOT=$DATA
ExecStart=/usr/bin/python3 $ROOT/store/digest_daily.py
EOF

cat > "$UNIT_DIR/wechat-digest.timer" <<EOF
[Unit]
Description=WeChat daily digest at 00:30 CST

[Timer]
OnCalendar=*-*-* 00:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now wechat-ingest.path
systemctl --user enable --now wechat-digest.timer
# Drain once now
systemctl --user start wechat-ingest.service || true

# Cron fallback if user lingering is off
CRON_LINE="* * * * * WECHAT_INGEST_ROOT=$DATA /usr/bin/python3 $ROOT/store/consumer.py >/tmp/wechat-ingest.cron.log 2>&1"
(crontab -l 2>/dev/null | grep -v wechat-ingest/store/consumer.py; echo "$CRON_LINE") | crontab -

echo "data: $DATA"
echo "units: $UNIT_DIR"
echo "ok"
