#!/usr/bin/env bash
# foca-update.sh — pull the latest Foca images for the configured
# IMAGE_TAG and reconcile the running containers.
#
# Intended for invocation by systemd timer (see foca-update.timer).
# Logs to stdout/stderr; systemd captures them into the journal.
# View logs with: journalctl -u foca-update.service
#
# Behavior:
#   - Acquires an exclusive flock so an overlapping timer fire cannot
#     collide with a still-running update from the previous tick.
#   - `docker compose pull` fetches new images for whatever IMAGE_TAG
#     is configured in .env. If the tag is mutable (`latest` / future
#     `stable`) and a new push has landed, this picks it up.
#   - `docker compose up -d` recreates containers only when the image
#     SHA changed; otherwise it is a no-op. Safe to run repeatedly.
#
# Configuration:
#   FOCA_DEPLOY_DIR   Override the deploy directory. Default: /srv/foca.
#
# Exit codes:
#   0 — completed (no update needed, or update succeeded, or another
#       invocation already holds the lock)
#   1 — fatal error (deploy dir or compose file missing, docker error)

set -euo pipefail

DEPLOY_DIR="${FOCA_DEPLOY_DIR:-/srv/foca}"
LOCK_FILE="/var/lock/foca-update.lock"

if [ ! -d "$DEPLOY_DIR" ]; then
    echo "[foca-update] ERROR: deploy directory not found: $DEPLOY_DIR" >&2
    exit 1
fi

if [ ! -f "$DEPLOY_DIR/docker-compose.yml" ]; then
    echo "[foca-update] ERROR: docker-compose.yml not found in $DEPLOY_DIR" >&2
    exit 1
fi

cd "$DEPLOY_DIR"

# Acquire an exclusive lock. If another invocation holds it, exit
# cleanly so the systemd timer does not pile up failed runs.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[foca-update] another invocation holds the lock; skipping"
    exit 0
fi

echo "[foca-update] pulling images from GHCR"
docker compose pull

echo "[foca-update] reconciling containers (no-op if image unchanged)"
docker compose up -d

echo "[foca-update] done"
