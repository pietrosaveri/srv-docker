#!/usr/bin/env bash
# One-time server setup: system deps for headed Chrome under Xvfb, Ollama,
# the cloud model, and npm dependencies.
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

echo "==> Installing Ollama..."
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "Ollama already installed ($(ollama --version))."
fi

echo "==> Ensuring Ollama daemon is up (needed for signin/pull below)..."
STARTED_OLLAMA=0
if ! curl -s -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
  nohup ollama serve > /tmp/ollama.log 2>&1 &
  disown
  STARTED_OLLAMA=1
  sleep 2
else
  echo "Ollama daemon already running."
fi

echo "==> Sign in for cloud models (interactive — follow the printed link)..."
ollama signin || echo "Skipped/failed sign-in — run 'ollama signin' manually if the cloud model fails to pull."

echo "==> Pulling gemma4:31b-cloud..."
ollama pull gemma4:31b-cloud

echo "==> Installing npm dependencies..."
npm install

if [ "$STARTED_OLLAMA" -eq 1 ]; then
  echo "==> Stopping the Ollama daemon we started for setup..."
  echo "    (aiSendSnap.js starts/stops it itself on each run)"
  pkill -f "ollama serve" || true
fi

echo
echo "Setup done. Remaining manual steps:"
echo "  1. Get a logged-in session into chrome-profile/ — either copy it over"
echo "     from your local machine, or run 'node login.js' here (needs a way"
echo "     to see the browser once, e.g. VNC into the Xvfb display)."
echo "  2. Test with: ./run-server.sh"
