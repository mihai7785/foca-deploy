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
  a tunnel such as Cloudflare Tunnel — see § 11).

For production we recommend a **separate 100 GB data disk** mounted at
`/srv/foca/data` — see § 11 (real-client deviations) for the why.

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

## 4. Bootstrap commands

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

## 5. GHCR authentication

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

## 6. Configure .env

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

## 7. Start the instance

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
§ 12 (Troubleshooting).

---

## 8. Update procedure

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

## 9. Rollback procedure

1. Edit `/srv/foca/.env` and set `IMAGE_TAG` to a known-good prior
   version (e.g. `v2.25.2`).
2. `docker compose pull` — confirms the older image is still in GHCR.
3. `docker compose up -d` — recreates containers off the older image.

**Image rollback does not roll back data.** Database migrations
applied during the newer version's run remain applied. If a release
introduced a breaking schema change, you also need to:

* Stop the stack: `docker compose down`.
* Restore database files from backup (see § 10).
* Start with the older `IMAGE_TAG`.

For this reason, **take a backup of `/srv/foca/data/sqlite/`
immediately before any update.**

---

## 10. Backup

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

## 11. Real-client deviations

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
* **Snapshot SQLite before every update.** See § 10.

---

## 12. Troubleshooting

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
  § 6 "Auth cookies" for the matrix.
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

## 13. Where to get help

* For deployment / template issues: open an issue on
  https://github.com/mihai7785/foca-deploy/issues — public, no
  account required to read.
* For application bugs: the source repo is private; contact the
  maintainer (see your engagement agreement) and they will file the
  issue against the internal tracker.
* Email: hello@focalabs.ro for general inquiries.
