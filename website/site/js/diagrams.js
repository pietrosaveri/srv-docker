// Diagram sources for the infrastructure page.
// Mermaid definitions mirror infrastructure.md; `info` holds per-node detail
// keyed by the node id used in the definition above it.
//
// Addresses are described by role rather than by value. This page is public,
// and a literal address written here is one more copy that goes stale.

window.DIAGRAMS = [

  {
    id: "physical",
    title: "Physical Architecture",
    kind: "flowchart",
    note: "Tailscale runs on the Ubuntu host itself, not inside a container. That placement does two separate jobs. Outbound: any container on the homeserver network can reach a remote tailnet peer, because traffic routes out through the host's tailscale0 interface. Inbound: the host advertises the home LAN as a Tailscale subnet route, so tailnet devices reach home addresses from anywhere. The second job is the one that actually carries day-to-day traffic.",
    src: `flowchart TB
    Internet((Internet))
    Router["Home Router<br/>NAT / port forwarding<br/>DHCP, with a reservation pinning the server"]
    Mini["Late 2014 Mac mini<br/>Ubuntu Server<br/>+ Tailscale client (tailscale0)<br/>+ subnet router for the home LAN"]
    Docker["Docker Engine"]
    SSD["Server Storage"]
    Clients["Client Devices<br/>Laptop · Phone · Tablet"]
    Tailnet(("Tailscale Tailnet<br/>WireGuard mesh"))
    Internet --> Router
    Router --> Mini
    Mini --> Docker
    Docker --> SSD
    Router --> Clients
    Mini -.->|encrypted WireGuard tunnel| Tailnet
    Clients -.->|same tunnel, from anywhere| Tailnet`,
    info: {
      Internet: { title: "Internet", body: "Everything public arrives here. Only ports 80 and 443 are ever forwarded inward." },
      Router: { title: "Home Router", body: "NAT plus two port forwards, 80 and 443, to the Mac mini. It also runs DHCP, and holds a reservation that pins the server to a fixed address so nothing downstream goes stale." },
      Mini: { title: "Late 2014 Mac mini", body: "4 GB RAM, 500 GB HDD, Ubuntu Server 26.04 LTS. Runs the Docker engine and the Tailscale client directly on the host, plus two systemd timers that keep DNS correct." },
      Docker: { title: "Docker Engine", body: "Hosts all 16 containers on a single external bridge network named homeserver." },
      SSD: { title: "Server Storage", body: "Bind mounts and named volumes under the host filesystem. Each service keeps its own data directory next to its compose file." },
      Clients: { title: "Client Devices", body: "Laptop, phone and tablet. They resolve private names through Tailscale MagicDNS, which forwards to AdGuard, and they reach the server either directly on the LAN or over the advertised subnet route from anywhere." },
      Tailnet: { title: "Tailscale Tailnet", body: "A WireGuard mesh. The host joins as a peer, which both gives containers a route to machines elsewhere and gives remote devices a route into this network." }
    }
  },

  {
    id: "network",
    title: "Network Architecture",
    kind: "flowchart",
    note: "AdGuard's DNS service (port 53) and Caddy's reverse proxy (ports 80/443) are two independent listeners on the same host. A DNS answer from AdGuard never touches Caddy, and Caddy never touches port 53, they only share an address. Note that client DNS does not arrive over the LAN: the router's own resolver refuses to forward .arpa queries, so every private name is resolved through MagicDNS instead.",
    src: `flowchart TB
    Internet((Internet))
    DuckDNS["DuckDNS Authoritative DNS<br/>apex → the current public IP<br/>*.apex → the same IP<br/>(implicit wildcard, no per-host record)<br/>kept current by duckdns-sync.timer"]
    Router["Router<br/>NAT port forward<br/>80 → server:80<br/>443 → server:443<br/>destination pinned by DHCP reservation<br/><br/>Its own resolver refuses .arpa,<br/>so it can never serve *.home.arpa"]
    Internet --> DuckDNS
    DuckDNS --> Router
    subgraph Ubuntu["Ubuntu Server (Mac mini)"]
        Caddy["Caddy Docker Proxy<br/>• Watches Docker socket for container labels<br/>• Routes by Host header / SNI<br/>• Let's Encrypt for public hosts<br/>• Internal CA for *.home.arpa hosts"]
        AdGuard["AdGuard Home<br/>• DNS :53 (tcp+udp), bound to the host<br/>• ONE wildcard rewrite: *.home.arpa<br/>• Web UI on host :3000 and via Caddy"]
        Tailscaled["tailscale0<br/>Host WireGuard interface<br/>Advertises the home LAN as a route<br/>Serves as the tailnet's DNS resolver"]
        DNSSync["dns-sync.timer<br/>Every 5 min: repairs the wildcard<br/>to the host's current LAN address"]
        Network["Docker network: homeserver<br/>external bridge network"]
        Router --> Caddy
        Caddy --> Network
        Caddy -.->|"reverse_proxy to a tailnet address"| Tailscaled
        AdGuard --> Network
        DNSSync -->|"AdGuard HTTP API"| AdGuard
    end
    Tailscaled -.->|encrypted tunnel| RemotePeer(["Remote tailnet peer"])
    subgraph Devices["Client devices — at home or away"]
        Laptop
        Phone
        Tablet
    end
    Laptop -->|"all DNS via MagicDNS"| Tailscaled
    Phone --> Tailscaled
    Tablet --> Tailscaled
    Tailscaled -->|"forwards to AdGuard"| AdGuard`,
    info: {
      DuckDNS: { title: "DuckDNS", body: "Authoritative DNS for the public zone. It answers an implicit wildcard, so every subdomain returns the same IP, there is no per-service record anywhere. A host timer refreshes the record every five minutes." },
      Router: { title: "Router", body: "Forwards 80 and 443 to the server. Both are needed: 80 for ACME HTTP-01 challenges, 443 for traffic and TLS-ALPN-01. Its resolver serves ordinary domains fine but refuses .arpa, which is why it can never answer for the private zone." },
      Caddy: { title: "Caddy Docker Proxy", body: "lucaslorentz/caddy-docker-proxy:2.9-alpine. Reads container labels off the Docker socket and rebuilds its routing table live. The single ingress point for HTTP and HTTPS." },
      AdGuard: { title: "AdGuard Home", body: "Binds port 53 tcp+udp directly to the host. The private zone is one wildcard rewrite rather than an entry per hostname, so a new service needs no DNS work. Its UI is published on host port 3000 as well as proxied by Caddy, deliberately: a DNS admin tool must not be reachable only through the DNS it serves." },
      Tailscaled: { title: "tailscale0", body: "The host's WireGuard interface. It owns the tailnet range, so any packet Caddy sends to such an address leaves via the host routing table rather than the bridge network. It also advertises the home LAN as a route and acts as the tailnet's DNS resolver." },
      DNSSync: { title: "dns-sync.timer", body: "A host systemd timer, not a container, because it repairs the DNS that containers depend on. It reads the address from the kernel's own outbound routing decision and refuses to act if that route would yield a non-LAN address, on the principle that writing a wrong value is worse than writing nothing." },
      Network: { title: "homeserver", body: "An external Docker bridge network created outside any single compose file, which is what lets every service join the same network independently." },
      RemotePeer: { title: "Remote tailnet peer", body: "A machine elsewhere, reachable only through the mesh. Caddy proxies one public hostname straight to it, so that request leaves this server entirely. The hostname and target are deliberately not published here." }
    }
  },

  {
    id: "dns",
    title: "DNS Resolution: Public vs Private",
    kind: "flowchart",
    note: "Because DNS never differentiates the public subdomains, Caddy is the only component on the whole path that knows share. should go to Pingvin Share and upload. to the Upload Portal, decided from the Host header and TLS SNI after every name has already resolved to the identical IP. The private side is frequently misremembered: clients do not query AdGuard over the LAN. The router hands out its own address for DNS and refuses to forward .arpa, so 'Use Tailscale DNS' must be enabled, at home as much as away.",
    src: `flowchart TB
    subgraph Public["Public resolution: the duckdns.org zone"]
        direction TB
        PubClient["Any Internet client"]
        PubQuery["Query: share.apex"]
        DuckAuth["DuckDNS authoritative nameservers"]
        PubAnswer["Answer: the home router's public IP<br/>Same IP for the apex AND every subdomain -<br/>DuckDNS answers an implicit wildcard,<br/>there is no per-service DNS record"]
        PubClient --> PubQuery --> DuckAuth --> PubAnswer
    end
    subgraph Local["Private resolution: *.home.arpa"]
        direction TB
        LocalClient["Client device (laptop / phone / tablet)"]
        MagicDNS["Tailscale MagicDNS<br/>'Use Tailscale DNS' must be on;<br/>the tailnet resolver is the host"]
        AdGuardRW["AdGuard Home rewrite table<br/>ONE wildcard entry: *.home.arpa<br/>kept current by dns-sync.timer"]
        LocalAnswer["Answer: the server's LAN address<br/>Reachable from anywhere on the tailnet,<br/>because the host advertises the<br/>home LAN as a subnet route"]
        LocalClient --> MagicDNS --> AdGuardRW --> LocalAnswer
    end`,
    info: {
      DuckAuth: { title: "DuckDNS nameservers", body: "Authoritative for the public zone. A single dynamic-DNS record keeps the apex pointed at the current public IP." },
      PubAnswer: { title: "The wildcard answer", body: "Identical for every subdomain. This is why adding a public service needs no DNS change at all, only a Caddy label." },
      MagicDNS: { title: "Tailscale MagicDNS", body: "The tailnet's resolver is the host itself, addressed by its tailnet address, which never changes. That is why remote resolution survived a LAN address change unscathed: the question was always delivered correctly, only the answer was stale. It is configured as a global nameserver, so all DNS from tailnet devices travels here, which buys AdGuard's filtering everywhere at the cost of a round trip." },
      AdGuardRW: { title: "The wildcard rewrite", body: "One entry covering every present and future name in the private zone. It replaced eleven hand-made per-host entries, which was the arrangement that turned a single DHCP lease change into a total outage of the private zone." },
      LocalAnswer: { title: "LAN address answer", body: "Traffic never reaches the router's WAN side and needs no port forward. From outside the house the same address is still reachable, via the subnet route the host advertises to the tailnet." }
    }
  },

  {
    id: "resilience",
    title: "How the Address Stays Correct",
    kind: "flowchart",
    note: "The same fact, 'the server is at this address', was once written down in five places by hand with nothing keeping them in agreement. One DHCP lease change invalidated all five at once and took down the private zone, the public zone, and the tool needed to diagnose either. Two layers now protect it: the reservation makes the address stop changing, and the timers make the copies repair themselves when it changes anyway, because a reservation is a promise made by one device and promises made by devices do not survive that device being reset or replaced.",
    src: `flowchart TB
    Fact["The fact<br/>'the server is at this LAN address'<br/>'the house is at this public IP'"]
    subgraph Pinned["Made stable"]
        Reservation["Router DHCP reservation<br/>MAC → fixed LAN address<br/>so the lease stops moving"]
        Forward["Router port forwards<br/>80 / 443 → that same address"]
    end
    subgraph Healing["Made self-correcting"]
        DNSSync["dns-sync.timer — every 5 min<br/>reads the host's own outbound route,<br/>rewrites AdGuard's *.home.arpa<br/>wildcard via the AdGuard HTTP API"]
        DuckSync["duckdns-sync.timer — every 5 min<br/>updates the DuckDNS record using the<br/>empty-ip form, so DuckDNS reads the<br/>source address off the request itself"]
    end
    subgraph Permanent["Stable by construction"]
        TSAddr["The host's tailnet address<br/>assigned by Tailscale, never changes;<br/>this is why the MagicDNS resolver<br/>setting survived the outage"]
        SubnetRoute["The advertised LAN subnet<br/>a /24, unaffected by which host<br/>address the server happens to hold"]
    end
    Fact --> Pinned
    Fact --> Healing
    Fact --> Permanent`,
    info: {
      Fact: { title: "One fact, many copies", body: "The failure mode is not that any single copy was wrong. It is that the same fact lived in several places with no mechanism keeping them in agreement, so the first change to one made liars of the rest." },
      Reservation: { title: "DHCP reservation", body: "Bound to the WiFi MAC on the router, rather than configured statically on the server. The router then remains the single authority on who holds what, so no address conflict can be created, and a typo cannot strand a headless machine reached over WiFi." },
      Forward: { title: "Port forwards", body: "Rules name a destination address, which makes them a silent copy of the same fact. Where the router allows selecting a device instead of typing an address, that is preferable: it follows the reservation automatically." },
      DNSSync: { title: "dns-sync.timer", body: "Idempotent: it compares before it writes and exits silently when nothing needs changing, which is what makes a five-minute interval free. It also adds the correct entry before deleting the stale one, so an interruption mid-change leaves a harmless duplicate rather than a name with no answer, and the next run cleans that up." },
      DuckSync: { title: "duckdns-sync.timer", body: "Sends the update with an empty ip parameter, so DuckDNS records the source address of the request itself. That removes the self-detection step entirely, and with it a whole class of failure. It also means the script must run on the home connection: run from anywhere else it would publish that network." },
      TSAddr: { title: "The tailnet address", body: "Assigned by Tailscale and stable for the life of the machine, with no relationship to the router, the WiFi, or DHCP. Depending on the most stable identity available rather than the most convenient one is the general lesson." },
      SubnetRoute: { title: "The advertised subnet", body: "A whole /24 rather than a single host, so it stays correct no matter which address inside it the server holds." }
    }
  },

  {
    id: "tls",
    title: "HTTPS / Certificate Architecture",
    kind: "flowchart",
    note: "This is why local devices see a browser warning the first time they hit a *.home.arpa site, self-signed, until the internal root CA is imported on that device, while every public host gets a normally trusted certificate automatically. Worth knowing: renewal depends on inbound port forwarding and fails silently. If a forwarding rule breaks, existing certificates stay valid and every page keeps loading for weeks, until one expires and the symptom becomes TLS errors with a cause that looks entirely unrelated.",
    src: `flowchart TB
    Request["Incoming TLS connection on :443"]
    Request --> SNI{"SNI hostname is *.home.arpa?"}
    SNI -->|"yes, label sets tls internal"| Internal["Caddy's Internal CA<br/>• Self-signed root, generated locally on first start<br/>• Issues a leaf cert per hostname<br/>• No external network call<br/>• Only trusted by clients that imported this root"]
    SNI -->|"no, public duckdns.org host"| ACME["Caddy's ACME client<br/>• Requests a cert from Let's Encrypt<br/>• Challenge via port 80 (HTTP-01)<br/>  or 443 (TLS-ALPN-01)<br/>• Auto-renews before expiry"]
    ACME --> LE[("Let's Encrypt CA")]
    Internal --> Serve["Serve the request over TLS"]
    LE --> Serve`,
    info: {
      SNI: { title: "The decision point", body: "Chosen per hostname by whether that container's label sets tls internal. One Caddy instance runs both issuance paths side by side." },
      Internal: { title: "Caddy's Internal CA", body: "A self-signed root generated locally the first time Caddy started. It never calls out, which is the point, *.home.arpa names don't exist publicly and could never pass an ACME challenge." },
      ACME: { title: "ACME client", body: "Both challenge types work here because the router forwards 80 and 443. Renewal is automatic and needs no cron job, but it is also the part that quietly stops working if a forward breaks, so it deserves a check after any router change." },
      LE: { title: "Let's Encrypt", body: "Issues the publicly trusted certificates. Rate limits apply per registered domain, which is worth knowing before adding many subdomains at once." },
      Serve: { title: "Serve over TLS", body: "From here both paths are identical, Caddy terminates TLS and reverse-proxies plain HTTP to the upstream." }
    }
  },

  {
    id: "docker",
    title: "Docker Architecture",
    kind: "flowchart",
    note: "Three things worth calling out. Docmost isn't one container but three, the app, its own Postgres 17 and its own Redis, the latter two carrying no Caddy label at all and therefore unreachable from outside the network. dashboard-proxy isn't a real service: it's an alpine image running sleep infinity whose only purpose is to hold Caddy labels. And only two containers publish host ports, caddy and adguard, everything else is reachable only through Caddy.",
    src: `flowchart LR
    subgraph Docker["Docker Engine: homeserver network (external bridge)"]
        Network[("homeserver")]
        Caddy["caddy (ingress)<br/>publishes :80 :443"]
        AdGuard["adguard<br/>publishes :53 :3000"]
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
      Caddy: { title: "caddy", body: "lucaslorentz/caddy-docker-proxy:2.9-alpine · publishes 80 and 443 · mounts the Docker socket read-only. The ingress point for all web traffic." },
      AdGuard: { title: "adguard", body: "adguard/adguardhome:latest · publishes 53 tcp+udp for DNS, and 3000 for its web UI. That second port is the out-of-band management door: reachable by address alone, so it keeps working when DNS does not. The UI is also proxied by Caddy at adguard.home.arpa." },
      Homepage: { title: "homepage", body: "ghcr.io/gethomepage/homepage:latest · :3000 · homepage.home.arpa. HOMEPAGE_ALLOWED_HOSTS must list every name it's reached on." },
      Website: { title: "website", body: "nginx:alpine serving this very page · :80 · the public apex. The only public host on the bare apex domain." },
      Pingvin: { title: "pingvin-share", body: "ghcr.io/smp46/pingvin-share-x · :3000 · dual-homed on share.home.arpa and the matching public host." },
      Upload: { title: "upload-portal", body: "Built from source in this repo, Go backend, embedded React frontend · :8080 · dual-homed. Runs as UID/GID 1000." },
      Etherpad: { title: "etherpad", body: "etherpad/etherpad:latest · :9001 · dual-homed. PUBLIC_URL is pinned to the public host so generated pad links use the public name." },
      Docmost: { title: "docmost (app)", body: "docmost/docmost:latest · :3000 · docmost.home.arpa. Depends on its own Postgres and Redis." },
      DocmostDB: { title: "docmost-db", body: "postgres:17. No Caddy label, so no route exists to it from outside. Reachable only as db:5432 within the network." },
      DocmostRedis: { title: "docmost-redis", body: "redis:8, appendonly yes, maxmemory-policy noeviction. Reachable only as redis:6379 within the network." },
      Portainer: { title: "portainer", body: "portainer/portainer-ce:latest · :9000 · portainer.home.arpa. Private on purpose, it holds the Docker socket." },
      FileBrowser: { title: "filebrowser", body: "filebrowser/filebrowser:latest · :80 · files.home.arpa. Runs as UID/GID 1000 over /srv." },
      Glances: { title: "glances", body: "nicolargo/glances:latest · :61208 · glances.home.arpa. Runs with pid: host so it sees the real process table." },
      ZenNotes: { title: "zennotes", body: "adibhanna/zennotes:latest · :7878 · zennotes.home.arpa. Its public label exists but is commented out. cap_drop ALL, requires an auth token." },
      Crumbs: { title: "crumbs", body: "ghcr.io/bretzel-app/crumbs:latest · :3000 · dual-homed. Uses a named volume rather than a bind mount." },
      DashboardProxy: { title: "dashboard-proxy", body: "alpine:latest running sleep infinity. Serves nothing and listens on nothing, it exists only to carry two Caddy labels that point at a tailnet address." },
      TailscaleHop: { title: "host tailscale0", body: "Where the traffic actually goes. Because the upstream is a tailnet address rather than a container name, the packet never uses the bridge network to reach its destination." }
    }
  },

  {
    id: "domains",
    title: "Domain Map",
    kind: "flowchart",
    note: "home.arpa is not a subdomain of duckdns.org, they're two unrelated zones resolved by two different resolvers along two different network paths, which is why they're drawn apart rather than as one tree. Note the symmetry now: the public wildcard lives in DuckDNS, the private wildcard lives in AdGuard, and either way a new service needs only a Caddy label. The manual per-host DNS step that used to be required on the private side no longer exists.",
    src: `flowchart TB
    subgraph PublicZone["Public zone: the duckdns.org apex (DuckDNS)"]
        PubRoot["the apex"] --> PubWebsite["→ website"]
        PubRoot -.->|implicit wildcard| PubShare["share.apex<br/>→ pingvin-share"]
        PubRoot -.->|implicit wildcard| PubUpload["upload.apex<br/>→ upload-portal"]
        PubRoot -.->|implicit wildcard| PubNotes["notes.apex<br/>→ etherpad"]
        PubRoot -.->|implicit wildcard| PubCrumbs["crumbs.apex<br/>→ crumbs"]
        PubRoot -.->|implicit wildcard| PubBridge["a bridged subdomain<br/>→ Tailscale bridge → remote peer"]
    end
    subgraph PrivateZone["Private zone: *.home.arpa (one AdGuard wildcard)"]
        Wildcard["*.home.arpa<br/>→ the server's LAN address<br/><br/>Any name matches.<br/>Adding a service needs no DNS change."]
        Wildcard --- HPHome["homepage"]
        Wildcard --- HPPortainer["portainer"]
        Wildcard --- HPGlances["glances"]
        Wildcard --- HPFiles["files"]
        Wildcard --- HPAdGuard["adguard"]
        Wildcard --- HPDocmost["docmost"]
        Wildcard --- HPShare["share (dual-homed)"]
        Wildcard --- HPUpload["upload (dual-homed)"]
        Wildcard --- HPNotes["notes (dual-homed)"]
        Wildcard --- HPCrumbs["crumbs (dual-homed)"]
        Wildcard --- HPZen["zennotes (public label commented out)"]
    end`,
    info: {
      PubRoot: { title: "The apex", body: "The only name with a real DNS record. Every subdomain below is answered by DuckDNS's implicit wildcard, not by a record of its own. A host timer keeps that one record pointed at the current public IP." },
      PubBridge: { title: "The bridged subdomain", body: "The odd one out: its upstream is not a container but a tailnet address, so the request ends up on a machine that is not this server at all. The hostname and target stay private." },
      Wildcard: { title: "The private wildcard", body: "One rewrite entry covering the whole zone, replacing eleven hand-made per-host entries. Those eleven were the reason a single DHCP lease change broke every private name at once, and fixing it by hand meant eleven edits." },
      HPShare: { title: "Dual-homed", body: "The same pingvin-share container carries two labels: share.home.arpa on the internal CA and the matching public host on Let's Encrypt. Both point at port 3000." },
      HPZen: { title: "zennotes", body: "The public label is written in the compose file but commented out, so this name currently resolves on the private zone only." },
      HPPortainer: { title: "Deliberately private", body: "Portainer, Glances, File Browser and AdGuard all mount the Docker socket or expose host internals, so none of them ever gets a public label." }
    }
  },

  {
    id: "flow-public",
    title: "Request Flow: Public Service",
    kind: "sequence",
    note: "The certificate step only runs when there's no valid cached cert. Every other request skips straight from the router to the label match. The DuckDNS record itself is refreshed every five minutes by a host timer, which is what keeps the first step answering correctly when the ISP changes the public IP.",
    src: `sequenceDiagram
    participant User
    participant DuckDNS
    participant Router
    participant Caddy
    participant LE as Let's Encrypt
    participant Docker
    participant Service
    Note over DuckDNS: duckdns-sync.timer on the host<br/>refreshes this record every 5 min
    User->>DuckDNS: Resolve share.apex
    Note right of DuckDNS: Wildcard answer, every subdomain<br/>resolves to the same public IP
    DuckDNS-->>User: Public IP (home router)
    User->>Router: TLS ClientHello, SNI = share.apex
    Router->>Caddy: Forward TCP 443
    alt No valid cached certificate
        Caddy->>LE: ACME order for share.apex
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
    note: "No router, no Let's Encrypt, no WAN hop, and a certificate signed by a CA that only exists on this machine. But the DNS hop does go through Tailscale, whether the device is at home or away, because the router refuses to forward .arpa queries and therefore cannot answer for this zone at all.",
    src: `sequenceDiagram
    participant Device as Client device
    participant Magic as Tailscale MagicDNS
    participant AdGuard
    participant Caddy
    participant Docker
    participant Service
    Device->>Magic: DNS query: share.home.arpa
    Note right of Magic: Requires 'Use Tailscale DNS'.<br/>The router cannot answer this -<br/>it refuses to forward .arpa
    Magic->>AdGuard: Forward to the tailnet resolver
    Note right of AdGuard: Matched by the single<br/>*.home.arpa wildcard rewrite
    AdGuard-->>Device: The server's LAN address
    Device->>Caddy: TLS ClientHello, SNI = share.home.arpa
    Note right of Device: Reachable on the LAN directly, or from<br/>anywhere via the advertised subnet route
    Caddy->>Caddy: tls internal → self-signed leaf<br/>from Caddy's local CA
    Caddy->>Docker: Match Host/SNI to container label
    Docker->>Service: Reverse proxy (HTTP)
    Service-->>Device: Response`,
    info: {}
  },

  {
    id: "flow-tailscale",
    title: "Request Flow: Tailscale Bridge",
    kind: "sequence",
    note: "Same Caddy instance and the same public hostname pattern as every other service. The only difference is that the upstream address is a tailnet IP instead of a Docker container name, so the last hop leaves the homeserver network and travels the WireGuard mesh instead.",
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
    Caddy->>Caddy: Match label → reverse_proxy to a tailnet address
    Caddy->>TS: Plain HTTP, routed via host's default gateway
    TS->>Peer: Encrypted inside the WireGuard tunnel
    Peer-->>User: Response relayed back through the same path`,
    info: {}
  }

];
