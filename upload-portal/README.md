# Upload Portal

## Purpose
Inbound file-drop service — the "Others → Me" counterpart to Pingvin Share.
Generate a link from the admin dashboard, send it to someone, they drag files
(or whole folders) onto a plain drop page with no login required.

## URL
- Admin: https://upload.home.arpa (also reachable at the public hostname below)
- Public base for generated links: https://upload.pietroserver.duckdns.org/u/:token

## First run
Before the first `docker compose up`, make sure `./data` is owned by the
container's user (it runs as UID/GID 1000, not root) — otherwise it'll
crash-loop with `mkdir /data/files: permission denied`:
```
mkdir -p data && sudo chown -R 1000:1000 data
```

Then open the admin URL — you'll be prompted to set an admin password before
the dashboard unlocks. There's no default password.

## Ports
8080 (internal, proxied by Caddy)

## Volumes
`./data` — SQLite database, uploaded files, and generated thumbnails:
```
data/
├── db/upload.db
├── files/<link_token>/<relative_path>
└── thumbnails/<upload_id>.jpg
```

## Notes
- Runs as UID/GID 1000, matching File Browser's convention for the shared
  `/srv`-adjacent bind mounts.
- Single Go binary with the React frontend embedded via `go:embed`; no
  separate frontend container or database service.
- Requires `ffmpeg` and `poppler-utils` at runtime (already baked into the
  image) for video-frame and PDF thumbnails.
