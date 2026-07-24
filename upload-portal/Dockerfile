# --- frontend build ---
FROM node:22-alpine AS frontend
WORKDIR /app
COPY frontend/package.json ./
RUN npm install
COPY frontend/ .
RUN npm run build

# --- backend build ---
FROM golang:1.23-alpine AS backend
RUN apk add --no-cache git
WORKDIR /app
COPY backend/go.mod ./
COPY backend/ .
COPY --from=frontend /app/dist ./web/dist
RUN go mod tidy && CGO_ENABLED=0 go build -o /out/upload-portal ./cmd/server

# --- runtime ---
FROM alpine:3.20
RUN apk add --no-cache ffmpeg poppler-utils ca-certificates && \
    addgroup -g 1000 app && adduser -D -u 1000 -G app app
COPY --from=backend /out/upload-portal /usr/local/bin/upload-portal
USER app
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/upload-portal"]
