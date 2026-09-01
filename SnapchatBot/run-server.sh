#!/usr/bin/env bash
# Runs aiSendSnap.js headed (not --headless) inside a virtual display, so it
# works on a Linux server with no monitor attached while still looking like
# a real browser to Snapchat's fingerprinting.
#
# One-time setup on the server (Debian/Ubuntu):
#   sudo apt update
#   sudo apt install -y xvfb chromium \
#     fonts-liberation libnss3 libatk-bridge2.0-0 libatk1.0-0 libcups2 \
#     libdrm2 libgbm1 libasound2 libxkbcommon0 libxcomposite1 libxdamage1 \
#     libxrandr2 libxfixes3
#   npm install
#   node login.js     # log in once; make sure DISPLAY is reachable, e.g. via VNC/ssh -X
#
# Then run this script directly, or from cron.

set -euo pipefail
cd "$(dirname "$0")"

# xvfb-run spawns a non-interactive shell that doesn't source ~/.bashrc, so
# an nvm-installed node (whose PATH entry lives there) would otherwise be
# invisible to it. Pick it up explicitly if present.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
fi

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  echo "node not found in PATH. Run 'which node' in your normal shell and either" >&2
  echo "install Node.js system-wide, or add its directory to PATH above." >&2
  exit 1
fi

if command -v xvfb-run >/dev/null 2>&1; then
  exec xvfb-run --auto-servernum --server-args="-screen 0 1920x1080x24" "$NODE_BIN" aiSendSnap.js
else
  echo "xvfb-run not found — install the 'xvfb' package first." >&2
  exit 1
fi
