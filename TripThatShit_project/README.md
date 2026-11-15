# TripThatShit

iOS trip planner (flights, trains, buses, ferries on a map, with tickets, photos and links)
plus a tiny sync server so friends can share a trip and all edit it.

```
TripThatShit/   SwiftUI app (Xcode project), installed from Xcode — not on the App Store
backend/        Go sync server, standard library only
compose.yaml    the server stack → https://trip.pietroserver.duckdns.org
design.md       design tokens the UI follows
```

## How sharing works

- The app stays **local-first**: every trip lives on the phone and works offline.
- A shared trip also syncs with the server. Edits are queued, sent when there is a
  connection, and friends' edits are pulled every 15 s while the trip is open, when the
  app comes back to the foreground, and on pull-to-refresh in the trip list.
- Changes merge **per leg**: two people editing different legs never overwrite each other.
  If both edit the *same* leg, the last save wins.
- Tickets, PDFs and photos are uploaded with their leg and downloaded on every member's
  phone, so they are available offline too.
- **Transport colours are per phone** (Impostazioni → Colori dei mezzi). They are never synced.
- There are no passwords. A phone gets a random token (kept in the Keychain) when it
  registers with the server key or joins with an invite code.

## Server

```sh
cd TripThatShit_project
cp .env.example .env                       # TRIP_APP_KEY=$(openssl rand -base64 24)
mkdir -p data && sudo chown 1000:1000 data
docker compose up -d --build               # or ../up-all.sh -b TripThatShit_project
curl https://trip.pietroserver.duckdns.org/healthz   # → ok
```

Caddy picks it up from the labels (public `trip.pietroserver.duckdns.org`, LAN
`trip.home.arpa`). All state is in `./data` (gitignored): `users.json`, `invites.json`
and `trips/<id>/{trip.json,files/}`. Back that folder up and you have backed up everything.

Tests: `cd backend && go test ./...`

## Using it

1. **You**: open a trip → tap the person icon (top right) → enter your name and the
   `TRIP_APP_KEY` (needed once) → **Condividi viaggio** → **Invia** the invite code.
2. **Friend**: in the trip list tap **···** → **Unisciti con codice** (or the button on
   the empty screen), paste the message or type the code, enter a name. No key needed.
3. Codes last 14 days and work for several people. Deleting a shared trip from the list
   means **leaving** it. The last member to leave deletes it from the server.

## Installing on the phones

Open `TripThatShit/TripThatShit.xcodeproj`, plug in the iPhone, pick it as the run
destination and press Run. The first time: turn on Developer Mode on the iPhone
(Settings → Privacy & Security), and trust the developer certificate
(Settings → General → VPN & Device Management).

> With a **free** Apple ID, an app installed this way stops opening after **7 days**.
> Reinstall from Xcode shortly before you leave (your data stays). A paid developer
> account lasts a year.

To point a debug build at another (HTTPS) server, set the `TRIP_SERVER` environment
variable in the Xcode scheme.
