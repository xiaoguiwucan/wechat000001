#!/usr/bin/env bash
# Install the WeChat-style console. Prefers Docker compose on fnOS;
# falls back to a user systemd service when docker.sock is not writable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${WECHAT_INGEST_ROOT:-$HOME/wechat-ingest/data}"
UNIT_DIR="${HOME}/.config/systemd/user"
DOCKER_DIR="${WECHAT_CONSOLE_DOCKER_DIR:-$HOME/wechat-ingest/console}"
PORT="${CONSOLE_PORT:-18791}"

mkdir -p "$DATA/status" "$UNIT_DIR"

if [ -n "${WECHAT_CONSOLE_DOCKER_DIR:-}" ]; then
  mkdir -p "$DOCKER_DIR"
  cp -a "$ROOT/console/." "$DOCKER_DIR/"
  echo "compose copied to $DOCKER_DIR"
fi

cat > "$UNIT_DIR/wechat-console.service" <<EOF
[Unit]
Description=WeChat ingest console (WeChat-style viewer)
After=network.target

[Service]
Type=simple
Environment=WECHAT_INGEST_ROOT=$DATA
Environment=CONSOLE_PORT=$PORT
Environment=CONSOLE_PUBLIC_URL=http://127.0.0.1:$PORT
Environment=SILK_DECODER=${SILK_DECODER:-/usr/local/bin/silk-decoder}
Environment=WECHAT_SELF_WXID=${WECHAT_SELF_WXID:-}
WorkingDirectory=$ROOT/console
ExecStart=/usr/bin/python3 -u $ROOT/console/app.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now wechat-console.service

if docker info >/dev/null 2>&1; then
  (cd "$ROOT/console" && docker compose up -d --build)
  echo "docker console up on :$PORT"
else
  echo "docker.sock not writable for $(whoami); console running as user systemd on :$PORT"
  echo "start the compose later from 飞牛 Docker: $DOCKER_DIR"
fi

echo "open http://127.0.0.1:$PORT"
