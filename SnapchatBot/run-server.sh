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

if command -v xvfb-run >/dev/null 2>&1; then
  exec xvfb-run --auto-servernum --server-args="-screen 0 1920x1080x24" node aiSendSnap.js
else
  echo "xvfb-run not found — install the 'xvfb' package first." >&2
  exit 1
fi
