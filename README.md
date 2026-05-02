# foca-deploy

Deployment templates for **Foca**, a Romanian SMB AI platform built by
[Focalabs](https://focalabs.ro).

## What's in this repo

* `docker-compose.deploy.yml` — Compose file referencing the published
  Foca container images.
* `.env.deploy.example` — Environment variable template, copied to
  `.env` and filled in per instance.
* `DEPLOY.md` — Operator runbook for a fresh-VM install.

## What's NOT in this repo

* Application source code (private — not redistributed).
* Container images (published privately to GitHub Container Registry).
* Secrets — the `.env.example` ships with `replace_me` placeholders.

## Tagging

Tags here mirror the matching application release. When app version
`vX.Y.Z` is built and pushed to GHCR, the deploy templates that go
with it are tagged `vX.Y.Z` here. Always pin to a specific tag in
production:

```bash
TAG=v2.25.2
curl -LO "https://raw.githubusercontent.com/mihai7785/foca-deploy/${TAG}/docker-compose.deploy.yml"
```

## Quick start

See [DEPLOY.md](DEPLOY.md) for the full operator guide.

## Public on purpose

This repo is intentionally public so fresh VMs can pull the templates
with anonymous `curl`. The templates contain no credentials.
