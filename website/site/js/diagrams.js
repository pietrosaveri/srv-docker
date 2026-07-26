// Diagram sources for the infrastructure page.
// Mermaid definitions mirror infrstucture.md; `info` holds per-node detail
// keyed by the node id used in the definition above it.

window.DIAGRAMS = [

  {
    id: "physical",
    title: "Physical Architecture",
    kind: "flowchart",
    note: "Tailscale runs on the Ubuntu host itself, not inside a container. That placement is what makes the bridge trick possible: any container on the homeserver network can reach a remote tailnet peer, because traffic routes out through the host's tailscale0 interface.",
    src: `flowchart TB
    Internet((Internet))
    Router["Home Router<br/>NAT / Port Forwarding"]
    Mini["Late 2014 Mac mini<br/>Ubuntu Server<br/>+ Tailscale client (tailscale0)"]
    Docker["Docker Engine"]
    SSD["Server Storage"]
    Clients["Local Devices<br/>Laptop · Phone · Tablet"]
    Tailnet(("Tailscale Tailnet<br/>WireGuard mesh"))
    Internet --> Router
    Router --> Mini
    Mini --> Docker
    Docker --> SSD
    Router --> Clients
    Mini -.->|encrypted WireGuard tunnel| Tailnet`,
    info: {
      Internet: { title: "Internet", body: "Everything public arrives here. Only ports 80 and 443 are ever forwarded inward." },
      Router: { title: "Home Router", body: "NAT plus two port forwards: 80 and 443 to the Mac mini. Nothing else is exposed to the outside." },
      Mini: { title: "Late 2014 Mac mini", body: "4 GB RAM, 500 GB HDD, Ubuntu Server 26.04 LTS. Runs the Docker engine and the Tailscale client directly on the host." },
      Docker: { title: "Docker Engine", body: "Hosts all 16 containers on a single external bridge network named homeserver." },
      SSD: { title: "Server Storage", body: "Bind mounts and named volumes under the host filesystem. Each service keeps its own data directory next to its compose file." },
      Clients: { title: "Local Devices", body: "Laptop, phone and tablet on the LAN. They point at AdGuard for DNS, which is what makes *.home.arpa resolve." },
      Tailnet: { title: "Tailscale Tailnet", body: "A WireGuard mesh. The host joins it as a peer, giving containers a route to machines that aren't on this network at all." }
    }
  },

  {
    id: "network",
    title: "Network Architecture",
    kind: "flowchart",
    note: "AdGuard's DNS service (port 53) and Caddy's reverse proxy (ports 80/443) are two independent listeners on the same host. A DNS answer from AdGuard never touches Caddy, and Caddy never touches port 53, they only share a LAN IP.",
    src: `flowchart TB
    Internet((Internet))
    DuckDNS["DuckDNS Authoritative DNS<br/>pietroserver.duckdns.org → Public IP<br/>*.pietroserver.duckdns.org → same IP<br/>(implicit wildcard, no per-host record)"]
    Router["Router<br/>NAT Port Forward<br/>80 → Ubuntu:80<br/>443 → Ubuntu:443"]
    Internet --> DuckDNS
    DuckDNS --> Router
    subgraph Ubuntu["Ubuntu Server (Mac mini)"]
        Caddy["Caddy Docker Proxy<br/>• Watches Docker socket for container labels<br/>• Routes by Host header / SNI<br/>• Let's Encrypt for public hosts<br/>• Internal CA for *.home.arpa hosts"]
        AdGuard["AdGuard Home<br/>• DNS :53 (tcp+udp), bound directly to host<br/>• One explicit DNS Rewrite per hostname<br/>• Own web UI also reverse-proxied by Caddy"]
        Tailscaled["tailscale0<br/>Host-level WireGuard interface"]
        Network["Docker Network: homeserver<br/>external bridge network"]
        Router --> Caddy
        Caddy --> Network
        Caddy -.->|"reverse_proxy to a 100.64.0.0/10 address"| Tailscaled
        AdGuard --> Network
    end
    Tailscaled -.->|encrypted tunnel| RemotePeer(["Remote tailnet peer"])
    subgraph LAN["Local LAN"]
        Laptop
        Phone
        Tablet
    end
    Laptop -->|"DNS query *.home.arpa"| AdGuard
    Phone --> AdGuard
    Tablet --> AdGuard`,
    info: {
      DuckDNS: { title: "DuckDNS", body: "Authoritative DNS for the public zone. It answers an implicit wildcard, so every subdomain returns the same IP, there is no per-service record anywhere." },
      Router: { title: "Router", body: "Forwards 80 and 443 to the Mac mini. Both are needed: 80 for ACME HTTP-01 challenges, 443 for actual traffic and TLS-ALPN-01." },
      Caddy: { title: "Caddy Docker Proxy", body: "lucaslorentz/caddy-docker-proxy:2.9-alpine. Reads container labels off the Docker socket and rebuilds its routing table live. The only container publishing ports to the host." },
      AdGuard: { title: "AdGuard Home", body: "Binds port 53 tcp+udp directly to the host. Every *.home.arpa name is one hand-made DNS Rewrite entry, no wildcard. Its own web UI is proxied by Caddy at adguard.home.arpa." },
      Tailscaled: { title: "tailscale0", body: "The host's WireGuard interface. It owns the 100.64.0.0/10 range, so any packet Caddy sends to such an address leaves via the host routing table rather than the bridge network." },
      Network: { title: "homeserver", body: "An external Docker bridge network created outside any single compose file, which is what lets every service join the same network independently." },
      RemotePeer: { title: "Remote tailnet peer", body: "A machine elsewhere, reachable only through the mesh. Caddy proxies one public hostname straight to it, so that request leaves this server entirely. The hostname and target are deliberately not published here." }
    }
  },

  {
    id: "dns",
    title: "DNS Resolution: Public vs Private",
    kind: "flowchart",
    note: "Because DNS never differentiates the public subdomains, Caddy is the only component on the whole path that knows share. should go to Pingvin Share and upload. to the Upload Portal, decided from the Host header and TLS SNI, after every name has already resolved to the identical IP. Locally it's the opposite: no wildcard exists, so a new *.home.arpa service resolves for nobody until its rewrite entry is added by hand.",
    src: `flowchart TB
    subgraph Public["Public resolution: pietroserver.duckdns.org"]
        direction TB
        PubClient["Any Internet client"]
        PubQuery["Query: share.pietroserver.duckdns.org"]
        DuckAuth["DuckDNS authoritative nameservers"]
        PubAnswer["Answer: home router's public IP<br/>Same IP for the root domain AND every subdomain -<br/>DuckDNS answers an implicit wildcard,<br/>there is no per-service DNS record"]
        PubClient --> PubQuery --> DuckAuth --> PubAnswer
    end
    subgraph Local["Local resolution: *.home.arpa"]
        direction TB
        LocalClient["LAN client (laptop / phone / tablet)"]
        LocalQuery["Query: share.home.arpa"]
        AdGuardRW["AdGuard Home DNS Rewrite table<br/>One manually-created entry per hostname -<br/>no wildcard rule"]
        LocalAnswer["Answer: Mac mini's LAN IP"]
        LocalClient --> LocalQuery --> AdGuardRW --> LocalAnswer
    end`,
    info: {
      DuckAuth: { title: "DuckDNS nameservers", body: "Authoritative for pietroserver.duckdns.org. A single dynamic-DNS record keeps the apex pointed at the current public IP." },
      PubAnswer: { title: "The wildcard answer", body: "Identical for every subdomain. This is why adding a public service needs no DNS change at all, only a Caddy label." },
      AdGuardRW: { title: "DNS Rewrite table", body: "Explicit entries, one per hostname, added through the AdGuard web UI. Forgetting one is the usual reason a new local service doesn't resolve." },
      LocalAnswer: { title: "LAN IP answer", body: "Traffic stays entirely inside the network, it never reaches the router's WAN side and needs no port forward." }
    }
  },

  {
    id: "tls",
    title: "HTTPS / Certificate Architecture",
    kind: "flowchart",
    note: "This is why local devices see a browser warning the first time they hit a *.home.arpa site, self-signed, until the internal root CA is imported on that device, while every public host gets a normally trusted certificate automatically.",
    src: `flowchart TB
    Request["Incoming TLS connection on :443"]
    Request --> SNI{"SNI hostname is *.home.arpa?"}
    SNI -->|"yes, label sets tls internal"| Internal["Caddy's Internal CA<br/>• Self-signed root, generated locally on first start<br/>• Issues a leaf cert per hostname<br/>• No external network call<br/>• Only trusted by clients that imported this root"]
    SNI -->|"no, public *.duckdns.org host"| ACME["Caddy's ACME client<br/>• Requests a cert from Let's Encrypt<br/>• Challenge via port 80 (HTTP-01)<br/>  or 443 (TLS-ALPN-01)<br/>• Auto-renews before expiry"]
    ACME --> LE[("Let's Encrypt CA")]
    Internal --> Serve["Serve the request over TLS"]
    LE --> Serve`,
    info: {
      SNI: { title: "The decision point", body: "Chosen per hostname by whether that container's label sets tls internal. One Caddy instance runs both issuance paths side by side." },
      Internal: { title: "Caddy's Internal CA", body: "A self-signed root generated locally the first time Caddy started. It never calls out, which is the point, *.home.arpa names don't exist publicly and could never pass an ACME challenge." },
      ACME: { title: "ACME client", body: "Both challenge types work here because the router already forwards 80 and 443. Renewal is automatic and needs no cron job." },
      LE: { title: "Let's Encrypt", body: "Issues the publicly trusted certificates. Rate limits apply per registered domain, which is worth knowing before adding many subdomains at once." },
      Serve: { title: "Serve over TLS", body: "From here both paths are identical, Caddy terminates TLS and reverse-proxies plain HTTP to the upstream." }
    }
  },

  {
    id: "docker",
    title: "Docker Architecture",
    kind: "flowchart",
    note: "Two things worth calling out. Docmost isn't one container but three, the app, its own Postgres 17 and its own Redis, the latter two carrying no Caddy label at all and therefore unreachable from outside the network. And dashboard-proxy isn't a real service: it's an alpine image running sleep infinity whose only purpose is to hold Caddy labels.",
    src: `flowchart LR
    subgraph Docker["Docker Engine: homeserver network (external bridge)"]
        Network[("homeserver")]
        Caddy["caddy (ingress)"]
        AdGuard["adguard"]
        Homepage["homepage"]
        Website["website (nginx)"]
        Pingvin["pingvin-share"]
        Upload["upload-portal"]
        Etherpad["etherpad"]
        Docmost["docmost (app)"]
        DocmostDB[("docmost-db<br/>postgres:17")]
        DocmostRedis[("docmost-redis<br/>redis:8")]
        Portainer["portainer"]
        FileBrowser["filebrowser"]
        Glances["glances"]
        ZenNotes["zennotes"]
        Crumbs["crumbs"]
        DashboardProxy["dashboard-proxy<br/>alpine, sleep infinity -<br/>label-carrier only, no real service"]
        Network --- Caddy
        Network --- AdGuard
        Network --- Homepage
        Network --- Website
        Network --- Pingvin
        Network --- Upload
        Network --- Etherpad
        Network --- Docmost
        Docmost --- DocmostDB
        Docmost --- DocmostRedis
        Network --- Portainer
        Network --- FileBrowser
        Network --- Glances
        Network --- ZenNotes
        Network --- Crumbs
        Network --- DashboardProxy
    end
    DashboardProxy -.->|"actual traffic bypasses the homeserver network entirely"| TailscaleHop(["host tailscale0<br/>→ remote peer"])`,
    info: {
      Network: { title: "homeserver", body: "External bridge network. Containers reach each other by container name; Caddy resolves upstreams the same way." },
      Caddy: { title: "caddy", body: "lucaslorentz/caddy-docker-proxy:2.9-alpine · publishes 80 and 443 · mounts the Docker socket read-only. The single ingress point." },
      AdGuard: { title: "adguard", body: "adguard/adguardhome:latest · publishes 53 tcp+udp · UI on :3000 at adguard.home.arpa." },
      Homepage: { title: "homepage", body: "ghcr.io/gethomepage/homepage:latest · :3000 · homepage.home.arpa. HOMEPAGE_ALLOWED_HOSTS must list every name it's reached on." },
      Website: { title: "website", body: "nginx:alpine serving this very page · :80 · pietroserver.duckdns.org. The only public host on the bare apex domain." },
      Pingvin: { title: "pingvin-share", body: "ghcr.io/smp46/pingvin-share-x · :3000 · dual-homed on share.home.arpa and share.pietroserver.duckdns.org." },
      Upload: { title: "upload-portal", body: "Built from source in this repo, Go backend, embedded React frontend · :8080 · dual-homed. Runs as UID/GID 1000." },
      Etherpad: { title: "etherpad", body: "etherpad/etherpad:latest · :9001 · dual-homed. PUBLIC_URL is pinned to the duckdns host so generated pad links use the public name." },
      Docmost: { title: "docmost (app)", body: "docmost/docmost:latest · :3000 · docmost.home.arpa. Depends on its own Postgres and Redis." },
      DocmostDB: { title: "docmost-db", body: "postgres:17. No Caddy label, so no route exists to it from outside. Reachable only as db:5432 within the network." },
      DocmostRedis: { title: "docmost-redis", body: "redis:8, appendonly yes, maxmemory-policy noeviction. Reachable only as redis:6379 within the network." },
      Portainer: { title: "portainer", body: "portainer/portainer-ce:latest · :9000 · portainer.home.arpa. LAN-only on purpose, it holds the Docker socket." },
      FileBrowser: { title: "filebrowser", body: "filebrowser/filebrowser:latest · :80 · files.home.arpa. Runs as UID/GID 1000 over /srv." },
      Glances: { title: "glances", body: "nicolargo/glances:latest · :61208 · glances.home.arpa. Runs with pid: host so it sees the real process table." },
      ZenNotes: { title: "zennotes", body: "adibhanna/zennotes:latest · :7878 · zennotes.home.arpa. Its public label exists but is commented out. cap_drop ALL, requires an auth token." },
      Crumbs: { title: "crumbs", body: "ghcr.io/bretzel-app/crumbs:latest · :3000 · crumbs.home.arpa. Uses a named volume rather than a bind mount." },
      DashboardProxy: { title: "dashboard-proxy", body: "alpine:latest running sleep infinity. Serves nothing and listens on nothing, it exists only to carry two Caddy labels that point at a Tailscale address." },
      TailscaleHop: { title: "host tailscale0", body: "Where the traffic actually goes. Because the upstream is a Tailscale IP rather than a container name, the packet never uses the bridge network to reach its destination." }
    }
  },

  {
    id: "domains",
    title: "Domain Map",
    kind: "flowchart",
    note: "home.arpa is not a subdomain of duckdns.org, they're two unrelated zones resolved by two different resolvers, which is why they're drawn apart rather than as one tree. Pingvin Share, Upload Portal and Etherpad are each dual-homed: one container, two labels, two certificate authorities, one upstream port.",
    src: `flowchart TB
    subgraph PublicZone["Public zone: pietroserver.duckdns.org (DuckDNS)"]
        PubRoot["pietroserver.duckdns.org"] --> PubWebsite["→ website"]
        PubRoot -.->|implicit wildcard| PubShare["share.pietroserver.duckdns.org<br/>→ pingvin-share"]
        PubRoot -.->|implicit wildcard| PubUpload["upload.pietroserver.duckdns.org<br/>→ upload-portal"]
        PubRoot -.->|implicit wildcard| PubNotes["notes.pietroserver.duckdns.org<br/>→ etherpad"]
        PubRoot -.->|implicit wildcard| PubBridge["a bridged subdomain<br/>→ Tailscale bridge → remote peer"]
    end
    subgraph PrivateZone["Private zone: *.home.arpa (AdGuard rewrites)"]
        HPHome["homepage.home.arpa"]
        HPPortainer["portainer.home.arpa"]
        HPGlances["glances.home.arpa"]
        HPFiles["files.home.arpa"]
        HPAdGuard["adguard.home.arpa"]
        HPDocmost["docmost.home.arpa"]
        HPShare["share.home.arpa<br/>(dual-homed w/ public)"]
        HPUpload["upload.home.arpa<br/>(dual-homed w/ public)"]
        HPNotes["notes.home.arpa<br/>(dual-homed w/ public)"]
        HPZen["zennotes.home.arpa<br/>(public label present but commented out)"]
        HPCrumbs["crumbs.home.arpa"]
    end`,
    info: {
      PubRoot: { title: "The apex", body: "The only name with a real DNS record. Every subdomain below is answered by DuckDNS's implicit wildcard, not by a record of its own." },
      PubBridge: { title: "The bridged subdomain", body: "The odd one out: its upstream is not a container but a Tailscale address, so the request ends up on a machine that is not this server at all. The hostname and target stay private." },
      HPShare: { title: "Dual-homed", body: "The same pingvin-share container carries two labels: share.home.arpa on the internal CA and share.pietroserver.duckdns.org on Let's Encrypt. Both point at port 3000." },
      HPZen: { title: "zennotes", body: "The public label is written in the compose file but commented out, so this name currently resolves on the private zone only." },
      HPPortainer: { title: "Deliberately private", body: "Portainer, Glances, File Browser and AdGuard all mount the Docker socket or expose host internals, so none of them ever gets a public label." }
    }
  },

  {
    id: "flow-public",
    title: "Request Flow: Public Service",
    kind: "sequence",
    note: "The certificate step only runs when there's no valid cached cert. Every other request skips straight from the router to the label match.",
    src: `sequenceDiagram
    participant User
    participant DuckDNS
    participant Router
    participant Caddy
    participant LE as Let's Encrypt
    participant Docker
    participant Service
    User->>DuckDNS: Resolve share.pietroserver.duckdns.org
    Note right of DuckDNS: Wildcard answer, every subdomain<br/>of pietroserver.duckdns.org resolves<br/>to the same public IP
    DuckDNS-->>User: Public IP (home router)
    User->>Router: TLS ClientHello, SNI = share.pietroserver.duckdns.org
    Router->>Caddy: Forward TCP 443
    alt No valid cached certificate
        Caddy->>LE: ACME order for share.pietroserver.duckdns.org
        LE-->>Caddy: Signed certificate
    end
    Caddy->>Caddy: Match Host/SNI to container label
    Caddy->>Docker: Route to matched container
    Docker->>Service: Reverse proxy (HTTP)
    Service-->>User: Response`,
    info: {}
  },

  {
    id: "flow-local",
    title: "Request Flow: Local-only Service",
    kind: "sequence",
    note: "No router, no Let's Encrypt, no WAN hop. The request goes laptop to Mac mini and back, with a certificate signed by a CA that only exists on this machine.",
    src: `sequenceDiagram
    participant Laptop
    participant AdGuard
    participant Caddy
    participant Docker
    participant Service
    Laptop->>AdGuard: DNS query: share.home.arpa
    Note right of AdGuard: Explicit per-host DNS Rewrite entry<br/>(no wildcard) configured in the web UI
    AdGuard-->>Laptop: Mac mini LAN IP
    Laptop->>Caddy: TLS ClientHello, SNI = share.home.arpa
    Caddy->>Caddy: tls internal → self-signed leaf<br/>from Caddy's local CA
    Caddy->>Docker: Match Host/SNI to container label
    Docker->>Service: Reverse proxy (HTTP)
    Service-->>Laptop: Response`,
    info: {}
  },

  {
    id: "flow-tailscale",
    title: "Request Flow: Tailscale Bridge",
    kind: "sequence",
    note: "Same Caddy instance and the same public hostname pattern as every other service. The only difference is that the upstream address is a Tailscale IP instead of a Docker container name, so the last hop leaves the homeserver network and travels the WireGuard mesh instead.",
    src: `sequenceDiagram
    participant User
    participant DuckDNS
    participant Router
    participant Caddy
    participant TS as Host tailscale0
    participant Peer as Remote tailnet peer
    User->>DuckDNS: Resolve the bridged subdomain
    DuckDNS-->>User: Public IP (same wildcard record)
    User->>Router: TLS ClientHello, SNI = the bridged subdomain
    Router->>Caddy: Forward TCP 443
    Caddy->>Caddy: Match label → reverse_proxy to a Tailscale address
    Caddy->>TS: Plain HTTP, routed via host's default gateway
    TS->>Peer: Encrypted inside the WireGuard tunnel
    Peer-->>User: Response relayed back through the same path`,
    info: {}
  }

];
