# Runtime for BandiRadar (scraper + MCP server). The code itself is NOT copied in:
# compose mounts ./BandiRadar at /app, so `git pull` on the submodule updates the
# code without a rebuild. Rebuild only when requirements.txt changes.
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    TZ=Europe/Rome

RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY BandiRadar/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt uvicorn \
 && playwright install --with-deps chromium \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
