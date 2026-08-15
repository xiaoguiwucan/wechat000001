#!/usr/bin/env bash
#
# install-ingest.sh - bootstrap /root/.openclaw/wechat-ingest and install the
# systemd units that drive the inbox consumer (plan todo 6).
#
# Scope:
#   * create the store skeleton (groups/, dms/, inbox/, inbox/failed/)
#   * copy the python store code to /opt/wechat-ingest
#   * install wechat-ingest.service + wechat-ingest.path into /etc/systemd/system
#   * enable + start the .path trigger
#
# Must NOT:
#   * open any TCP listener (units have no Listen*/Socket options)
#   * run a second OpenClaw (nothing here execs the openclaw binary)
#   * embed device credentials (password / gateway token are never written)
#
# Idempotent: safe to re-run after a reboot or partial install.
#
# Usage: sudo deploy/install-ingest.sh [--root-dir /root/.openclaw/wechat-ingest]

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "error: install-ingest.sh must run as root (systemd units + /root store)" >&2
    exit 1
fi

# ---- inputs ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INGEST_ROOT="${1:-/root/.openclaw/wechat-ingest}"      # WECHAT_INGEST_ROOT
CODE_ROOT="/opt/wechat-ingest"                          # installed python
SYSTEMD_DIR="/etc/systemd/system"

# ---- store skeleton ---------------------------------------------------------
install -d -m 0755 "${INGEST_ROOT}"
for sub in groups dms inbox inbox/failed; do
    install -d -m 0755 "${INGEST_ROOT}/${sub}"
done
echo "store skeleton ready: ${INGEST_ROOT}/"

# ---- code -------------------------------------------------------------------
install -d -m 0755 "${CODE_ROOT}"
if [[ -d "${REPO_DIR}/store" ]]; then
    cp -r "${REPO_DIR}/store" "${CODE_ROOT}/"
    chmod -R a+rX "${CODE_ROOT}/store"
fi
if [[ -d "${REPO_DIR}/policy" ]]; then
    cp -r "${REPO_DIR}/policy" "${CODE_ROOT}/"
    chmod -R a+rX "${CODE_ROOT}/policy"
fi
if [[ ! -f "${CODE_ROOT}/store/consumer.py" ]]; then
    echo "warning: ${CODE_ROOT}/store/consumer.py not present yet " \
         "(todo 5 will ship it); unit stays installed and will fail " \
         "cleanly until then" >&2
fi

# ---- units ------------------------------------------------------------------
install -m 0644 "${SCRIPT_DIR}/wechat-ingest.service" "${SYSTEMD_DIR}/"
install -m 0644 "${SCRIPT_DIR}/wechat-ingest.path"    "${SYSTEMD_DIR}/"

systemctl daemon-reload
systemctl enable --now wechat-ingest.path

echo "installed:"
echo "  ${SYSTEMD_DIR}/wechat-ingest.service"
echo "  ${SYSTEMD_DIR}/wechat-ingest.path"
echo "  enabled:  systemctl list-units --all 'wechat-ingest.*'"
echo "  status:   systemctl status wechat-ingest.path wechat-ingest.service"
