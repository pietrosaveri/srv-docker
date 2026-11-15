#!/usr/bin/env bash
# One-time server setup: system deps for headed Chrome under Xvfb and npm
# dependencies.
#
# Run this ON THE SERVER (Debian/Ubuntu assumed), from inside SnapchatBot/:
#   ./setup-server.sh

set -euo pipefail
cd "$(dirname "$0")"

echo "==> Installing system packages (Xvfb + Puppeteer's bundled Chrome runtime libs, curl)..."
# NB: we deliberately don't install the 'chromium' apt package — on modern
# Ubuntu that's just a snap wrapper (sandboxing headaches for headless use).
# Puppeteer downloads and manages its own real Chrome binary via npm
# install; these are the shared libraries THAT binary needs to run.
sudo apt update
sudo apt install -y \
  xvfb curl ca-certificates wget lsb-release xdg-utils \
  fonts-liberation libnss3 libnspr4 libatk-bridge2.0-0 libatk1.0-0 \
  libcups2 libdrm2 libgbm1 libasound2t64 libxkbcommon0 libxcomposite1 \
  libxdamage1 libxrandr2 libxfixes3 libxrender1 libxi6 libxtst6 \
  libxext6 libx11-6 libx11-xcb1 libxcb1 libexpat1 libdbus-1-3 \
  libglib2.0-0 libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libgtk-3-0

echo "==> Installing Node.js (LTS via NodeSource)..."
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt install -y nodejs
else
  echo "Node already installed ($(node --version))."
fi

echo "==> Installing npm dependencies..."
npm install
mkdir -p logs

echo
echo "Setup done. Remaining manual steps:"
echo "  1. Get a logged-in session into chrome-profile/ — either copy it over"
echo "     from your local machine, or run 'node login.js' here (needs a way"
echo "     to see the browser once, e.g. VNC into the Xvfb display)."
echo "  2. Test without sending: DRY_RUN=1 ./run-server.sh"
echo "  3. Daily cron, e.g.: 0 18 * * * $(pwd)/run-server.sh >> $(pwd)/logs/cron.log 2>&1"
