# Built with the vampere repo (./vampere) as context; see compose.yaml.

# 1. Pipeline: offline run → output/*.json for the frontend + greenops.duckdb for the chat.
#    --offline reuses the committed advisor answers, so the build never calls OpenAI.
FROM python:3.13-slim AS pipeline
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt requirements-assistant.txt ./
RUN pip install --no-cache-dir -r requirements.txt -r requirements-assistant.txt
COPY . .
RUN test -f data/case/README.md || { echo "data/case is empty: run 'git submodule update --init --recursive' first" >&2; exit 1; }
RUN python -m pipeline.run --offline

# 2. Frontend: Vite build; prebuild copies ../output into public/data/real.
FROM node:24-alpine AS web
WORKDIR /app/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
COPY --from=pipeline /app/output /app/output
RUN npm run build

# 3a. Static site.
FROM nginx:alpine AS site
COPY --from=web /app/web/dist /usr/share/nginx/html

# 3b. Chat assistant (FastAPI). Reads output/ and the DuckDB; appends its token log to output/assistant/.
FROM pipeline AS api
RUN useradd -u 1000 -m app && chown -R app /app/output
USER app
EXPOSE 8787
CMD ["uvicorn", "assistant.server:create_app", "--factory", "--host", "0.0.0.0", "--port", "8787"]
