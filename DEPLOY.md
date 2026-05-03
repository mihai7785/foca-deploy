# Foca — Operator Deployment Guide

This guide takes you from a fresh Linux VM to a running Foca instance
in 15–30 minutes. It assumes Linux competence (Docker, shell, systemd
basics) but no familiarity with the Foca codebase.

---

## 1. What you're deploying

Foca is a Romanian SMB AI platform: business-intelligence chat,
document Q&A, automated reports, daily briefings, and (optionally) an
address-correction module for e-commerce. It runs as two Docker
containers (FastAPI backend + nginx proxy with the React UI baked in)
behind a reverse proxy on the host. State persists under
`/srv/foca/data/`.

This guide gets a fresh VM to a working web UI on `http://<host>/`.
TLS, public DNS, and tunnel/CDN setup are covered separately.

---

## 2. Prerequisites

* **OS**: Ubuntu 24.04 LTS or compatible. Other distros work but are
  not the documented path.
* **Docker**: engine ≥ 26 with the compose plugin (`docker compose`,
  not `docker-compose`).
* **RAM**: 4 GB minimum. 8 GB recommended (the sentence-transformer
  embedder + cross-encoder reranker run on CPU and benefit from
  headroom).
* **Disk**: 50 GB minimum.
* **Network**: outbound HTTPS access to `ghcr.io`,
  `raw.githubusercontent.com`, `api.anthropic.com`, `huggingface.co`
  (model cache primer on first run), and any IMAP/SMTP servers you
  configure.
* **Ingress**: ports 80 and 443 reachable from clients (or fronted by
  a tunnel such as Cloudflare Tunnel — see § 13).

For production we recommend a **separate 100 GB data disk** mounted at
`/srv/foca/data` — see § 13 (real-client deviations) for the why.

Install Docker on Ubuntu 24.04:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
docker --version
docker compose version
```

---

## 3. Nginx profiles

The nginx container picks one of two configs at start time, controlled
by `NGINX_PROFILE` in `.env`. The default is **`http-only`** because
it works on a fresh VM with no certificates; `prod-letsencrypt` is
opt-in and requires extra host setup.

### `http-only` (default)

* Listens on port 80 only, no HTTPS.
* `server_name _` — accepts any hostname.
* Same React SPA + `/api` proxy + SSE behavior + security headers as
  prod, minus HSTS (meaningless without HTTPS at the edge).
* No landing page server block (the platform is the only thing
  served; the landing assets remain baked in the image but unused).

Use this profile for:

* LAN-only deployments.
* Instances behind a TLS-terminating proxy where the proxy handles
  HTTPS and forwards plain HTTP to nginx — Cloudflare Tunnel, AWS
  ALB, Traefik, or another nginx on the host.

### `prod-letsencrypt` (opt-in)

* Listens on 80 (HTTP→HTTPS redirect plus
  `/.well-known/acme-challenge/` passthrough for ACME HTTP-01) and
  443 (HTTPS).
* Reads certs from `/etc/letsencrypt/live/${LETSENCRYPT_DOMAIN}/`.
* Serves the landing page on `${LANDING_DOMAIN}` (may be a
  comma-separated list — entrypoint converts to spaces) and the
  platform on `${APP_DOMAIN}`.

To use this profile:

1. Set `NGINX_PROFILE=prod-letsencrypt` in `.env` plus the four
   templated values: `APP_DOMAIN`, `LANDING_DOMAIN`,
   `LETSENCRYPT_DOMAIN`, `MAX_UPLOAD_SIZE`.
2. Uncomment the `volumes:` block on the `nginx` service in
   `docker-compose.yml` (the deploy template ships with the
   `/etc/letsencrypt` and `/var/www/certbot` mounts commented out so
   fresh non-prod VMs do not need those paths to exist).
3. Ensure certbot has issued certs for the configured domain on the
   host before starting nginx — otherwise nginx will restart-loop
   with `[emerg] cannot load certificate`.

### Picking the right profile

| Situation | Profile |
| --- | --- |
| Local LAN, no public DNS | `http-only` |
| Behind Cloudflare Tunnel | `http-only` |
| Behind AWS ALB / Traefik / host nginx | `http-only` |
| Direct internet exposure with certbot on the host | `prod-letsencrypt` |

If you set `NGINX_PROFILE` to anything else, the entrypoint exits
with a clear error before nginx starts.

---

## 4. Deployment patterns

Foca runs in one of two validated patterns. Pick before bootstrap —
the pattern determines `NGINX_PROFILE`, `JWT_COOKIE_SECURE`, the cert
story, and whether you need to touch your firewall.

### Pattern A — Direct public IP with Let's Encrypt

Use when the deploy host has a routable public IPv4 and you control
its inbound ports — VPS, cloud VM, colocation, dedicated server with
port-forward control. Production example: `app.focalabs.ro` on the
Contabo VPS.

Setup:

* Open ports 80 and 443 from the internet to the host.
* Run certbot on the host (or sidecar) to obtain and renew Let's
  Encrypt certs at `/etc/letsencrypt/live/${LETSENCRYPT_DOMAIN}/`.
* Uncomment the `/etc/letsencrypt` and `/var/www/certbot` volume
  mounts on the `nginx` service in `docker-compose.yml` (see § 3).
* In `.env`:
  * `NGINX_PROFILE=prod-letsencrypt`
  * `APP_DOMAIN`, `LANDING_DOMAIN`, `LETSENCRYPT_DOMAIN` filled in
  * `JWT_COOKIE_SECURE=true` (the platform is served over HTTPS only)
* Point the public DNS A record at the host's IP.

Tradeoffs:

* **Pros:** simple, single-layer, no third-party dependency, full
  control over TLS.
* **Cons:** requires a public IP, requires firewall/router work,
  exposes the origin IP to scanners and probes, you handle cert
  renewal and the renewal hook into the running container.

### Pattern B — Cloudflare Tunnel (NAT / office deployment)

Use when the deploy host is behind NAT, has no public IP, runs on
home or office-grade internet, or you want to hide the origin IP
from scanners. Production example: `afumati.focalabs.ro` on a
Proxmox VM behind a residential router.

Setup:

* The parent domain's DNS must already be on Cloudflare (changing
  authoritative DNS is a separate decision; if you can't move it,
  this pattern doesn't apply).
* Install `cloudflared` as a systemd service on the deploy host.
  The Cloudflare Zero Trust dashboard generates a token-based
  install command per tunnel; run it on the host once.
* Configure ingress in the Cloudflare dashboard:
  `<hostname>` → `http://localhost:80`. Cloudflare auto-creates a
  CNAME proxied through their edge.
* In `.env`:
  * `NGINX_PROFILE=http-only` — Cloudflare terminates TLS at the
    edge and `cloudflared` connects to `localhost:80` over plain
    HTTP, so nginx serves plain HTTP locally.
  * `JWT_COOKIE_SECURE=false` if you want simultaneous LAN access
    (LAN clients hit the same nginx over plain HTTP at the LAN IP).
    Set `true` if only the public hostname matters — Cloudflare
    presents HTTPS at the edge, so cookies sent from the browser
    are over HTTPS.
* No port forwarding on the router. Inbound traffic flows through
  the outbound `cloudflared` connection to Cloudflare's edge.

Tradeoffs:

* **Pros:** zero inbound exposure, works behind NAT, free auto-
  renewing TLS at the edge, origin IP hidden from public scans.
* **Cons:** third-party dependency on Cloudflare, free-tier
  request and timeout limits (see below).

#### Cloudflare free-tier considerations

Three concrete numbers worth knowing before relying on Pattern B
for anything large or long-running:

* **Maximum request body**: 100 MB on Free / Pro plans, 200 MB on
  Business, 500 MB+ on Enterprise. Set `MAX_UPLOAD_SIZE` in `.env`
  at or below the plan's ceiling. Afumati uses
  `MAX_UPLOAD_SIZE=50m` which is comfortable.
* **Edge timeout**: 120 seconds. Backend SSE / streaming endpoints
  must send data or a keepalive within this window or the edge
  drops the connection. Foca's chat-stream endpoint is
  well below this in practice.
* **SSE through the edge**: tested and working with Cloudflare
  defaults as of May 2026 (afumati). If a future Cloudflare change
  breaks it, the fix is a Configuration Rule that disables Browser
  Cache and any "Performance" optimizations for the `/api/` path.

### Mixing patterns on one instance

A single Foca instance uses one pattern at a time, but Pattern B
covers both public-internet and in-office LAN access for the same
deployment: Cloudflare handles HTTPS for remote users; LAN clients
hit the same nginx on plain HTTP at the LAN IP. Keep
`JWT_COOKIE_SECURE=false` so cookies survive both paths.

Pattern A does not naturally serve LAN clients — they would have to
either trust the public certificate over a LAN-resolved hostname or
use a separate hostname with a different cert. If you need LAN +
public on Pattern A, use Pattern B instead.

---

## 5. Bootstrap commands

Pin a specific deploy template version. Substitute the desired tag
into `TAG`. The matching container images must already exist in GHCR
under the same tag.

```bash
TAG=v2.25.2

sudo mkdir -p /srv/foca/data/{sqlite,chroma,uploads,logs,models,config}
sudo chown -R $USER:$USER /srv/foca

cd /srv/foca

curl -LO "https://raw.githubusercontent.com/mihai7785/foca-deploy/${TAG}/docker-compose.deploy.yml"
curl -LO "https://raw.githubusercontent.com/mihai7785/foca-deploy/${TAG}/.env.deploy.example"

mv docker-compose.deploy.yml docker-compose.yml
mv .env.deploy.example .env
```

After this, `/srv/foca/` contains `docker-compose.yml` (renamed from
the `.deploy` version), `.env` (about to be filled in), and the empty
`data/` subdirectories that the containers will bind-mount.

---

## 6. GHCR authentication

The container images are private. The deploy host needs a Personal
Access Token scoped only to read packages.

1. Sign in at https://github.com with an account that has access to
   the `mihai7785/foca-backend` and `mihai7785/foca-nginx` packages.
2. Open https://github.com/settings/tokens and click
   **"Generate new token (classic)"**.
3. Scope: check **`read:packages`** only. Uncheck everything else
   (especially `repo` and `workflow` — keep this token narrow so a
   leak has minimal blast radius).
4. Expiration: 1 year is the practical maximum. Add a calendar
   reminder to rotate.
5. Copy the token *once* (GitHub will not show it again).

Authenticate Docker without exposing the token in shell history:

```bash
read -s GHCR_PAT
# (paste token, press Enter — it won't echo)

echo "$GHCR_PAT" | docker login ghcr.io -u <your-github-username> --password-stdin
unset GHCR_PAT
```

The credential is cached in `~/.docker/config.json` and persists
across reboots. Re-run `docker login` only when the PAT expires.

---

## 7. Configure .env

Open `/srv/foca/.env` and fill in real values. The blocks that gate
startup or core features:

| Variable | What |
| --- | --- |
| `IMAGE_TAG` | Pin to `vX.Y.Z` for production. `latest` is fine for non-critical instances. |
| `ANTHROPIC_API_KEY` | Required. Anthropic API key for the cloud LLM path. |
| `JWT_SECRET` | Required. Random string used to sign session cookies. Generate with `openssl rand -hex 32`. |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | Used only on first run when `auth.db` is empty. Change the password in the Admin UI immediately after first login. |
| `PLATFORM_NAME`, `COMPANY_NAME`, `BOT_NAME`, `PLATFORM_TITLE` | Branding strings shown in the UI. Per-instance. |
| `SMTP_*` | Required if you want the platform to send email. |
| `IMAP_*` | Required if you want the platform to ingest a mailbox. |
| `DEBUG=false` | Gates `/api/v1/docs` (Swagger) and the OpenAPI schema. Leave `false` to avoid exposing API docs. |

The `LLM_ENCRYPTION_KEY` variable is **conditional**: required only if
you intend to manage LLM providers through the Admin UI (which
encrypts API keys at rest). If you only use `ANTHROPIC_API_KEY` from
`.env`, leave it as `replace_me` — startup is unaffected. Generate one
with `openssl rand -base64 32` when you need it.

Optional blocks (Ollama local LLM, per-user spend quota, LangFuse
tracing) can stay at defaults for a first deploy.

### Auth cookies

`JWT_COOKIE_SECURE` and `JWT_COOKIE_SAMESITE` control the `Secure` and
`SameSite` attributes on JWT auth cookies. Defaults work for prod
(HTTPS, strict). Override per deployment shape:

* **Plain-HTTP LAN** (e.g. `http://192.168.x.y/`): set
  `JWT_COOKIE_SECURE=false`. Browsers refuse to send `Secure` cookies
  over `http://` and login silently fails otherwise.
* **Behind Cloudflare Tunnel**: keep defaults. TLS terminates at
  Cloudflare; cookies are still served over HTTPS to the browser.
* **Cross-domain proxy setups**: may need `JWT_COOKIE_SAMESITE=lax`.
  `none` is rarely needed and requires `Secure=true` per spec
  (the backend logs a warning at first cookie set if you violate this).

---

## 8. Start the instance

```bash
cd /srv/foca
docker compose pull
docker compose up -d
docker compose ps
# Expected: foca-backend (healthy), foca-nginx (running)

curl http://localhost/api/v1/health
# Expected: {"status":"ok","version":"...","enabled_modules":[...]}
```

The backend `start_period` is 60 s. The very first start takes longer
than subsequent ones because the embedding and reranker models
download into `/srv/foca/data/models/` (~2 GB). After that, the cache
persists and restarts are fast.

If `docker compose ps` shows `foca-backend (unhealthy)`, jump to
§ 14 (Troubleshooting).

---

## 9. Update procedure

**Instance pinned to `:latest`** (non-production):

```bash
cd /srv/foca
docker compose pull
docker compose up -d
docker image prune -f
```

**Instance pinned to a specific version** (recommended for production):

```bash
cd /srv/foca
sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=v2.26.0/' .env
docker compose pull
docker compose up -d
```

`docker compose up -d` (not `restart`) is mandatory — `restart` does
not re-read `.env`, so an `IMAGE_TAG` change goes unnoticed.

---

## 10. Auto-update strategy (optional)

By default, Foca instances are updated by hand: edit `IMAGE_TAG` in
`.env`, `docker compose pull`, `docker compose up -d`. For instances
that prefer automation, this repo ships a small script + systemd
units. Read [§ Auto-update mechanism](#auto-update-mechanism) and
the [LIMITATION](#limitation) at the end of this section before
opting in.

### IMAGE_TAG strategy — three tiers

Pick one based on risk tolerance:

* **Pinned (recommended for production clients)** — `IMAGE_TAG=v2.25.4`
  or another exact version. Updates require operator action: edit
  `.env`, pull, restart. Most controlled, safest. This is the
  default in `.env.deploy.example`.
* **Mutable stable** — `IMAGE_TAG=stable`. The platform team moves
  the `stable` tag in GHCR when a release is approved for opt-in
  clients. Each release reaches stable-tag clients only after the
  tag move. *(Note: the `stable` tag is not yet implemented in the
  build pipeline; this is forward-looking documentation.)*
* **Latest (canary only)** — `IMAGE_TAG=latest`. Every push to main
  becomes the new `:latest`. Used by Focalabs internal canary
  instances (e.g., afumati) to validate releases before promoting.
  **Not recommended for production clients.**

### Auto-update mechanism

Optional. Typically only worth installing on canary instances on
`IMAGE_TAG=latest` (or future `IMAGE_TAG=stable`). Three template
files in this repo:

* `scripts/foca-update.sh` — pulls images and reconciles containers.
  Locks against concurrent invocations with `flock`.
* `systemd/foca-update.service` — oneshot service that runs the
  script. `After=docker.service` so docker is up first.
* `systemd/foca-update.timer` — fires the service every 10 minutes
  (`OnBootSec=2min` for first post-boot run, `OnUnitActiveSec=10min`
  thereafter).

To install on a deploy host (assuming the deploy user is `mihai`
and the deploy directory is `/srv/foca`):

```bash
# Copy script
sudo cp scripts/foca-update.sh /usr/local/bin/foca-update
sudo chmod +x /usr/local/bin/foca-update

# Copy systemd units (verify User= line in .service matches your deploy user)
sudo cp systemd/foca-update.service /etc/systemd/system/
sudo cp systemd/foca-update.timer /etc/systemd/system/

# Reload systemd, enable and start the timer
sudo systemctl daemon-reload
sudo systemctl enable --now foca-update.timer

# Verify
sudo systemctl list-timers foca-update.timer
journalctl -u foca-update.service -n 20
```

The timer runs the update every 10 minutes. Logs go to the journal
(`journalctl -u foca-update.service`). The script is idempotent —
when no new image is available, `docker compose up -d` is a no-op.

### LIMITATION

**Auto-update is safe only for image-compatible releases** —
releases where the new image runs against the existing `.env` and
`docker-compose.yml` without modification.

Releases that change the deployment contract require operator
intervention BEFORE the auto-update runs. Otherwise the new image
fails its healthcheck and the instance goes down until manually
fixed. Examples of contract-changing releases:

* New required environment variable in `.env`
* Changed `docker-compose.yml` (new services, new volumes, removed
  services, new bind-mount paths)
* Schema repair beyond what the platform's startup migration runner
  handles

Foca's track record on releases that required operator action:

* **v2.25.3** — required setting `NGINX_PROFILE` in `.env`.
* **v2.25.4** — required setting `JWT_COOKIE_SECURE` and
  `JWT_COOKIE_SAMESITE` in `.env`.

The platform's release notes flag the required operator action for
contract-changing releases. Until that action is applied, an
auto-updating instance pinned to `latest` will pull the new image,
fail to start, and stay broken until you intervene. **For real
client deployments, prefer pinned image tags and update manually.**

---

## 11. Rollback procedure

Three distinct recovery scenarios. Pick the right one for the
failure mode — image-tag rollback is fast and lossless when data
is intact; the other two involve data restore from PBS and should
be reserved for actual data damage.

### Scenario 1 — Bad release (image-tag rollback)

Use when a new version misbehaves but data is intact (UI broken,
backend errors, regression in a feature). No data restore needed.
This is the common case and takes under a minute.

```bash
# On the deploy host, in /srv/foca:
sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=vX.Y.Z/' .env  # previous known-good
docker compose pull
docker compose up -d
docker compose ps  # confirm healthy
```

If the previous tag's images are no longer in your local cache, the
pull fetches them from GHCR. As long as the tag still exists on GHCR
(release tags are kept indefinitely), this works.

Caveat: an image rollback does not roll back schema migrations
applied during the newer version's run. Forward-only migrations are
the project default. If a release introduced a breaking schema
change, also follow Scenario 2 to restore the affected database
files from a pre-update snapshot.

### Scenario 2 — Data corruption or accidental destruction (PBS file restore)

Use when data has been corrupted, wrongly modified, or deleted and
an image rollback alone will not help (a user erased a critical
record; a script ran against the wrong table; a migration broke
something the rollback image cannot read).

The procedure assumes Proxmox Backup Server is the backup target
(see § 12). If you use a different backup tool, the restore
mechanics differ but the file-level approach is the same.

1. In PBS, identify a snapshot from BEFORE the bad event. Use the
   PBS task log timestamps or the daily-schedule cadence to pick.
2. Open the snapshot in PBS UI → File Restore → wait for the mount
   to come up.
3. Browse to the affected path under `/srv/foca/data/` (typically
   `/srv/foca/data/sqlite/<dbname>.db` or files under
   `/srv/foca/data/uploads/`).
4. Download the recovered files to the deploy host (PBS UI provides
   a download button for selected files).
5. Stop containers, replace files in place, start containers:

```bash
cd /srv/foca
docker compose down
# replace the affected files in /srv/foca/data/...
docker compose up -d
docker compose ps
```

File-level restore is preferred over full-VM restore because it
preserves the current `IMAGE_TAG`, `.env`, and any post-snapshot
config changes. Full-VM restore overwrites everything; reserve it
for Scenario 3.

### Scenario 3 — Catastrophic loss (full VM restore)

Use when the VM is unreachable, the OS disk has failed, or the
entire instance has been destroyed. PBS performs a full VM restore;
the procedure is PBS-tool-specific and the operator running PBS
will already know it.

After the restore completes, on the recovered VM:

* Confirm `.env` values still match expected (`IMAGE_TAG`, JWT
  secrets, branding strings, mail credentials).
* `docker compose pull && docker compose up -d`.
* Verify login works and admin pages populate as expected.

For this reason — and for the Scenario 2 case — take a snapshot of
`/srv/foca/data/sqlite/` immediately before any update.

---

## 12. Backup

What to back up:

| Path | Contents | Frequency |
| --- | --- | --- |
| `/srv/foca/data/sqlite/` | All platform databases | Daily (or hourly if active) |
| `/srv/foca/data/uploads/` | User-uploaded documents, email attachments | Daily |
| `/srv/foca/data/chroma/` | ChromaDB vector store | Weekly (rebuildable from sources) |
| `/srv/foca/data/config/` | Connector configs (incl. encrypted secrets) | On change |
| `/srv/foca/data/models/` | HuggingFace cache | Skip — re-downloadable |

Recommended target for self-hosted instances: **Proxmox Backup
Server** on a separate physical host. PBS dedup makes hourly SQLite
snapshots cheap and gives point-in-time restore. For VPS deployments
without a PBS option, restic to S3-compatible storage works well.

For SQLite consistency under concurrent writes, prefer the SQLite
`.backup` command over plain `cp`:

```bash
for db in /srv/foca/data/sqlite/*.db; do
    name=$(basename "$db")
    docker compose exec -T backend sqlite3 "/data/sqlite/$name" \
        ".backup '/data/sqlite/${name}.bak'"
done
# Then move the *.bak files off-host with rsync / restic / your tool of choice.
```

Backups should be **off-host**. A local snapshot does not survive a
disk failure or a destructive `docker compose down -v`.

---

## 13. Real-client deviations

For paying-client deployments, deviate from the defaults as follows:

* **Pin `IMAGE_TAG=vX.Y.Z`.** Never use `:latest` in production.
  Auto-update on every upstream release is fine for personal/internal
  instances; it is a liability for instances under SLA.
* **Provision a separate 100 GB data disk in Proxmox** at VM creation
  and mount it at `/srv/foca/data`. This decouples backup granularity
  from the OS partition and allows a data-disk resize without
  touching the OS. PBS snapshots of the data disk are cheaper and
  faster than full-VM snapshots.
* **Use a DHCP reservation** for the VM IP so the address survives
  reboots without manual reconfiguration on the network side.
* **Plan for a tunnel** (Cloudflare Tunnel or equivalent) before
  exposing the instance to the public internet. Direct 80/443
  exposure works but burns a public IP and requires manual TLS cert
  management. A separate guide will cover the tunnel setup.
* **Rotate the GHCR PAT yearly.** Calendar reminder, not a TODO.
* **Snapshot SQLite before every update.** See § 12.

---

## 14. Troubleshooting

**`docker login ghcr.io` returns `denied: denied`.**
The PAT lacks the `read:packages` scope. Re-create the token at
https://github.com/settings/tokens with that scope checked, then run
`docker login` again.

**`docker compose pull` fails with `manifest unknown`.**
The `IMAGE_TAG` in `.env` does not exist in GHCR. Common cause:
typo, or pinning to a tag that was never published (the deploy
template tag exists in this repo but the matching container image
was never built upstream). Check the available tags at
https://github.com/mihai7785?tab=packages.

**`docker compose ps` shows `foca-backend (unhealthy)`.**
Look at the logs:

```bash
docker compose logs backend --tail 80
```

Common causes:

* Missing or wrong `ANTHROPIC_API_KEY` — the backend logs an LLM
  init error on first chat call but starts otherwise.
* Cookie attributes wrong for the deployment shape — e.g. plain-HTTP
  LAN with default `JWT_COOKIE_SECURE=true` causes the browser to
  silently drop the cookie and every authenticated request returns
  401. Set `JWT_COOKIE_SECURE=false` and `docker compose up -d`. See
  § 7 "Auth cookies" for the matrix.
* HuggingFace download in progress on first start — wait 2–3 minutes
  and re-check.

**Backend starts but chat returns "LLM error".**
Check `ANTHROPIC_API_KEY` value (no quotes, no trailing whitespace).
If the key is correct, check outbound network access from the
container: `docker compose exec backend curl -fsS https://api.anthropic.com/v1/messages` should return a `401` (key required), not a connection error.

**Permissions errors on `/srv/foca/data/`.**
Ensure ownership matches the user that runs `docker compose` (usually
the user invoking the command, since the bind-mount uses host UIDs):

```bash
sudo chown -R $USER:$USER /srv/foca
```

The containers run as their own internal user but bind-mounts inherit
host ownership.

---

## 15. Where to get help

* For deployment / template issues: open an issue on
  https://github.com/mihai7785/foca-deploy/issues — public, no
  account required to read.
* For application bugs: the source repo is private; contact the
  maintainer (see your engagement agreement) and they will file the
  issue against the internal tracker.
* Email: hello@focalabs.ro for general inquiries.
