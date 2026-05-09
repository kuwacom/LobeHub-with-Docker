# LobeHub Self-Hosting

[日本語](./README.md) | English

A `docker-compose` configuration for self-hosting LobeHub.  
This repository is based on the official LobeHub `deploy` / `production` configurations, with authentication, monitoring, search, and object storage externalized for easier operation.

This README is organized to achieve both:

- Help newcomers understand "what to start and how" without confusion
- Allow experienced users to quickly jump to "required settings and operational commands"

## Table of Contents

- [Where to Start](#where-to-start)
- [What This Configuration Runs](#what-this-configuration-runs)
- [Get Started in 5 Minutes](#get-started-in-5-minutes)
- [Setup Modes](#setup-modes)
- [Startup Patterns](#startup-patterns)
- [Common Verification Commands](#common-verification-commands)
- [Script Reference](#script-reference)
- [Usage by Scenario](#usage-by-scenario)
- [Key Files and Directories](#key-files-and-directories)
- [Key Environment Variables](#key-environment-variables)
- [Authentication and User Management](#authentication-and-user-management)
- [Monitoring Configuration](#monitoring-configuration)
- [Persistence and Data Storage](#persistence-and-data-storage)
- [Reset Policy](#reset-policy)
- [Known Caveats](#known-caveats)

## Where to Start

If you want to get up to speed quickly, just read these:

1. Start with [Get Started in 5 Minutes](#get-started-in-5-minutes)
2. To choose how to use SearXNG, see [Startup Patterns](#startup-patterns)
3. To find operational scripts, see [Script Reference](#script-reference)
4. For user management, see [Authentication and User Management](#authentication-and-user-management)
5. To check what data can be safely deleted, see [Reset Policy](#reset-policy)

## What This Configuration Runs

The components in this repository are as follows:

| Component | Technology | Role |
| --- | --- | --- |
| Application | LobeHub | Chat UI / Model invocation |
| Authentication | Casdoor | SSO / User authentication |
| Database | PostgreSQL | Persistent data for LobeHub / Casdoor |
| Cache | Redis | Sessions / Cache |
| Object Storage | RustFS | S3-compatible storage |
| Search | SearXNG | Search backend for Online Search |
| Monitoring | Grafana / Prometheus / Tempo / OTel Collector | Metrics / Trace visualization |
| Public Access | Cloudflared | Public access via Cloudflare Tunnel |

Key characteristics of this configuration:

- LobeHub email/password registration is disabled; Casdoor is used as the authentication platform
- RustFS is used instead of MinIO
- Persistence uses host-side bind mounts rather than Docker named volumes
- The `with-searxng` profile allows switching between built-in and external SearXNG

## Get Started in 5 Minutes

### Prerequisites

At minimum, you need:

- `docker` and `docker compose`
- `bash`
- `python3` or `python`
- `openssl`

`setup.sh` will automatically generate from [`.env.example`](./.env.example) if `.env` doesn't exist.

### Quickstart Steps

1. Run initial setup

```bash
bash ./setup.sh
```

2. Verify configuration

```bash
docker compose config
```

3. Pull images

```bash
docker compose pull
```

4. Start base services

```bash
docker compose up -d network-service postgresql redis rustfs rustfs-init tempo prometheus otel-collector casdoor
docker compose up -d searxng
docker compose up -d lobe grafana
```

5. Check status

```bash
docker compose ps
docker compose logs -f lobe casdoor rustfs grafana tempo prometheus --tail 200
```

### URLs After Startup

| URL | Purpose |
| --- | --- |
| `http://localhost:3210` | LobeHub |
| `http://localhost:8000` | Casdoor Admin UI / Auth UI |
| `http://localhost:9001` | RustFS Console |
| `http://localhost:3000` | Grafana |

### Exposed Ports

| Port | Purpose |
| --- | --- |
| `3210` | LobeHub |
| `8000` | Casdoor |
| `9000` | RustFS API |
| `9001` | RustFS Console |
| `3000` | Grafana |
| `4317` | OTel Collector gRPC |
| `4318` | OTel Collector HTTP |
| `5432` | PostgreSQL |
| `6379` | Redis |

## Setup Modes

[`setup.sh`](./setup.sh) is a script that configures URLs according to your deployment style.

### Common Usage Examples

```bash
bash ./setup.sh
```

```bash
bash ./setup.sh --mode port --host 192.168.1.10 --yes
```

```bash
bash ./setup.sh --mode domain --protocol https --app-domain lobe.example.com --casdoor-domain auth.example.com --rustfs-domain s3.example.com
```

### Mode Overview

| Mode | Use Case | What It Determines |
| --- | --- | --- |
| `local` | Development or standalone testing | `localhost`-based URLs |
| `port` | LAN access or direct IP | `http://<host>:port` format URLs |
| `domain` | Production or reverse proxy | Custom domain URLs |

### What `setup.sh` Does

- Generates from [`.env.example`](./.env.example) if `.env` doesn't exist
- Generates secrets like `AUTH_SECRET` as needed
- Generates [`casdoor/init_data.json`](./casdoor/init_data.json) from [`casdoor/init_data.json.exmaple`](./casdoor/init_data.json.exmaple)
- Updates URLs like `AUTH_CASDOOR_ISSUER` and `S3_ENDPOINT` to match the configuration
- Validates configuration using `docker compose config`

## Startup Patterns

### 1. Using Built-in SearXNG

Include `with-searxng` in `COMPOSE_PROFILES` in `.env`.

```env
COMPOSE_PROFILES=with-searxng
SEARXNG_URL=http://searxng:8080
```

Startup:

```bash
docker compose up -d network-service postgresql redis rustfs rustfs-init tempo prometheus otel-collector casdoor
docker compose up -d searxng
docker compose up -d lobe grafana
```

### 2. Using External SearXNG

Remove `with-searxng` from `COMPOSE_PROFILES` in `.env` and change `SEARXNG_URL` to the external URL.

```env
COMPOSE_PROFILES=
SEARXNG_URL=https://searx.example.com
```

Startup:

```bash
docker compose up -d network-service postgresql redis rustfs rustfs-init tempo prometheus otel-collector casdoor
docker compose up -d lobe grafana
```

Notes:

- Enable `json` format on the external SearXNG side
- `SEARXNG_BASE_URL` only needs adjustment if you're separately exposing the SearXNG UI

## Common Verification Commands

### Configuration Check

```bash
docker compose config
docker compose ps
```

### Log Check

```bash
docker compose logs -f lobe casdoor rustfs grafana tempo prometheus --tail 200
```

### Connectivity Check

```bash
curl http://localhost:9000/health
curl http://localhost:8000/.well-known/openid-configuration
```

### SearXNG Settings Check

```bash
docker compose exec searxng sed -n '1,120p' /etc/searxng/settings.yml
```

## Script Reference

Operational scripts are in [`scripts/`](./scripts/).  
They are organized by purpose so you can quickly determine what each one does.

| Script | Role | When to Use | Main Input | Example |
| --- | --- | --- | --- | --- |
| [`setup.sh`](./setup.sh) | Setup `.env` and Casdoor initial data | Initial build, URL change, reconfiguration | `--mode`, `--host`, `--app-domain`, etc. | `bash ./setup.sh --yes` |
| [`original-setup.sh`](./original-setup.sh) | Original deploy setup script | When referencing upstream behavior | Interactive input | `bash ./original-setup.sh` |
| [`scripts/export-master-model-settings.sh`](./scripts/export-master-model-settings.sh) | Extract master user's provider/model settings via SQL | Settings inventory, ENV candidate generation | `SOURCE_EMAIL` | `SOURCE_EMAIL='0_0@kuwa.dev' bash scripts/export-master-model-settings.sh > scripts/out.jsonl` |
| [`scripts/copy-master-model-settings.sh`](./scripts/copy-master-model-settings.sh) | Copy master user's provider/model settings to new users | Right after adding a new user | `SOURCE_EMAIL`, `HOURS_BACK` | `SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/copy-master-model-settings.sh` |
| [`scripts/apply-generated-model-settings.sh`](./scripts/apply-generated-model-settings.sh) | DB copy plus re-apply OpenAI `key_vaults` using generated ENV | When aligning new user with production settings | `SOURCE_EMAIL`, `HOURS_BACK` | `SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/apply-generated-model-settings.sh` |
| [`scripts/backup-user-data.sh`](./scripts/backup-user-data.sh) | Backup specified user's core data to JSON | Before migration, deletion, or recovery | `SOURCE_EMAIL` or `SOURCE_USER_ID` | `SOURCE_EMAIL='user@example.com' OUTPUT_FILE=./scripts/user-backup.json bash scripts/backup-user-data.sh` |
| [`scripts/restore-user-data.sh`](./scripts/restore-user-data.sh) | Restore backup JSON to an existing user | User recovery, duplication, migration | `TARGET_EMAIL` or `TARGET_USER_ID`, `BACKUP_FILE` | `TARGET_EMAIL='user@example.com' BACKUP_FILE=./scripts/user-backup.json bash scripts/restore-user-data.sh` |
| [`scripts/delete-user.sh`](./scripts/delete-user.sh) | Completely delete a specified user from PostgreSQL | Account removal, erroneous account cleanup | `TARGET_EMAIL` or `TARGET_USER_ID`, `--confirm-delete` | `TARGET_EMAIL='user@example.com' bash scripts/delete-user.sh --dry-run` |
| [`scripts/lib-lobehub-db.sh`](./scripts/lib-lobehub-db.sh) | Shared functions for DB scripts | Not executed directly | None | None |

### Script Auxiliary Outputs

| File | Role |
| --- | --- |
| [`scripts/out.jsonl`](./scripts/out.jsonl) | Example output from `export-master-model-settings.sh` |
| `scripts/generated-model-provider.env` | ENV candidate file organized from `out.jsonl` |

### Notes on Script Usage

- Most scripts read `.env` and connect to PostgreSQL via `docker compose exec`
- `copy-master-model-settings.sh` and `apply-generated-model-settings.sh` overwrite the target user's provider/model settings
- `delete-user.sh` is designed to be run with `--dry-run` first
- `restore-user-data.sh` requires the target user to already exist in LobeHub

## Usage by Scenario

### Distributing Model Settings After Adding a New User

1. Create a user in the Casdoor admin panel
2. Have the user log in to LobeHub once
3. Copy master settings

```bash
SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/copy-master-model-settings.sh
```

If you also need to align OpenAI `key_vaults`:

```bash
SOURCE_EMAIL='0_0@kuwa.dev' HOURS_BACK=6 bash scripts/apply-generated-model-settings.sh
```

### Inventorying Master User Settings

```bash
SOURCE_EMAIL='0_0@kuwa.dev' bash scripts/export-master-model-settings.sh > scripts/out.jsonl
```

### Backing Up and Restoring a User

Backup:

```bash
SOURCE_EMAIL='user@example.com' OUTPUT_FILE=./scripts/user-backup.json bash scripts/backup-user-data.sh
```

Restore:

```bash
TARGET_EMAIL='user@example.com' BACKUP_FILE=./scripts/user-backup.json bash scripts/restore-user-data.sh
```

### Completely Deleting a User

Dry run first:

```bash
TARGET_EMAIL='user@example.com' bash scripts/delete-user.sh --dry-run
```

If everything looks good, execute:

```bash
TARGET_EMAIL='user@example.com' bash scripts/delete-user.sh --no-dry-run --confirm-delete
```

## Key Files and Directories

| Path | Description |
| --- | --- |
| [`docker-compose.yml`](./docker-compose.yml) | Production Compose definition |
| [`.env.example`](./.env.example) | Environment variable template |
| [`.env`](./.env) | Production environment variables |
| [`setup.sh`](./setup.sh) | Setup for current merged configuration |
| [`original-setup.sh`](./original-setup.sh) | Original deploy setup |
| [`casdoor/init_data.json.exmaple`](./casdoor/init_data.json.exmaple) | Casdoor initial data template |
| [`casdoor/init_data.json`](./casdoor/init_data.json) | Initial data loaded into Casdoor |
| [`bucket.config.json`](./bucket.config.json) | RustFS bucket public access settings |
| [`searxng/settings.yml`](./searxng/settings.yml) | SearXNG settings |
| [`grafana/`](./grafana) | Grafana datasource / dashboard / data |
| [`prometheus/`](./prometheus) | Prometheus settings / data |
| [`tempo/`](./tempo)| Tempo settings / data |
| [`otel-collector/`](./otel-collector) | OTel Collector settings |
| [`postgresql/data`](./postgresql/data) | PostgreSQL data |
| [`redis/data`](./redis/data) | Redis data |
| [`rustfs/data`](./rustfs/data) | RustFS data |
| [`rustfs/logs`](./rustfs/logs) | RustFS logs |
| [`scripts/`](./scripts/) | Operational script collection |

## Key Environment Variables

You don't need to read all of them. Start with these key items for smooth operation:

| Key | Purpose | Notes |
| --- | --- | --- |
| `APP_URL` | LobeHub public URL | The URL reachable from browsers |
| `INTERNAL_APP_URL` | Internal container communication URL | Important for Compose configuration |
| `AUTH_SSO_PROVIDERS` | SSO provider specification | Currently assumes `casdoor` |
| `AUTH_DISABLE_EMAIL_PASSWORD` | Disable LobeHub direct registration | `1` to disable |
| `AUTH_CASDOOR_ISSUER` | Casdoor issuer URL | Core of OIDC |
| `AUTH_CASDOOR_ID` | Casdoor client ID | Populated by `setup.sh` from template |
| `AUTH_CASDOOR_SECRET` | Casdoor client secret | Same as above |
| `S3_ENDPOINT` | RustFS API endpoint | LobeHub storage destination |
| `RUSTFS_ACCESS_KEY` | RustFS access key | Usually `admin` |
| `RUSTFS_SECRET_KEY` | RustFS secret | Must be reviewed on first setup |
| `COMPOSE_PROFILES` | Compose profile switching | `with-searxng` for built-in SearXNG |
| `SEARXNG_URL` | Search backend URL | Used for both built-in and external |
| `GF_SECURITY_ADMIN_PASSWORD` | Grafana admin password | Don't run with default value |
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflared startup token | Only needed when using Tunnel |

Model / Provider notes:

- Values shared across the entire server go in `.env`
- Per-user provider / model / keyVaults are stored in the database
- Custom providers are difficult to fully reproduce with `.env` alone; DB / UI / SQL-based management is more suitable

## Authentication and User Management

### Basic Policy

In this configuration, users do not register directly in LobeHub.

- LobeHub signup is disabled
- Casdoor is used as the Identity Provider
- User creation is done on the Casdoor side

### Flow for Enabling a New User

1. Create a user in the Casdoor admin panel
2. Have the user log in to LobeHub
3. If needed, apply model settings using `copy-master-model-settings.sh`

### About Casdoor Initial Data

[`casdoor/init_data.json.exmaple`](./casdoor/init_data.json.exmaple) contains the initial configuration template.  
[`setup.sh`](./setup.sh) generates [`casdoor/init_data.json`](./casdoor/init_data.json) from this template.

Important:

- Always review seed information before production deployment
- If `postgresql/data` already exists, changes to `init_data.json` will not be automatically reflected in the Casdoor DB

## Monitoring Configuration

### Role Distribution

| Component | Role |
| --- | --- |
| `network-service` | Shared network namespace and port exposure aggregation |
| `otel-collector` | OTLP receiver from LobeHub |
| `tempo` | Trace storage |
| `prometheus` | Metrics storage |
| `grafana` | Metrics / Trace visualization |

### Monitoring Visibility

- Grafana comes with Prometheus / Tempo datasources pre-registered
- Dashboards are minimal in the initial state; use Explore as a starting point
- The `otel-tracing-test` profile can be used for trace connectivity testing

## Persistence and Data Storage

### Storage Locations

| Service | Storage Path |
| --- | --- |
| PostgreSQL | [`postgresql/data`](./postgresql/data) |
| Redis | [`redis/data`](./redis/data) |
| RustFS Data | [`rustfs/data`](./rustfs/data) |
| RustFS Logs | [`rustfs/logs`](./rustfs/logs) |
| Grafana | [`grafana/data`](./grafana/data) |
| Tempo | [`tempo/data`](./tempo/data) |
| Prometheus | [`prometheus/data`](./prometheus/data) |

### Permission Notes

When bind-mounting RustFS on Ubuntu, you may get `Permission denied` unless the owner is set to `10001:10001`.

```bash
sudo mkdir -p rustfs/data rustfs/logs
sudo chown -R 10001:10001 rustfs
sudo chmod -R 755 rustfs
```

Additional notes:

- Grafana / Prometheus / Tempo specify `user: "0"` in compose to avoid permission errors

## Reset Policy

### Full Reset

Deleting the following directories will reset each respective service:

- `postgresql/data`
- `redis/data`
- `rustfs/data`
- `rustfs/logs`
- `grafana/data`
- `tempo/data`
- `prometheus/data`

### Resetting Only LobeHub While Keeping Casdoor

Important notes:

- Casdoor also uses PostgreSQL
- Therefore, deleting `postgresql/data` entirely will also delete Casdoor data

This means:

- For a full reset, delete `postgresql/data` entirely
- To keep Casdoor, do not delete all of PostgreSQL
- To reset only LobeHub, initialize at the `lobechat` database level

## Known Caveats

- Be careful when writing actual keys in `.env` or `scripts/generated-model-provider.env`
- Always change seed information and initial secrets before production use
- Custom providers are difficult to fully reproduce with `.env` alone; DB / UI / SQL-based management is more suitable
- RustFS API currently assumes port `9000` in some places
- Cloudflared is designed to be started separately after setting `CLOUDFLARE_TUNNEL_TOKEN`

## Pre-Production Checklist

At minimum, verify the following before going to production:

- Changed Casdoor seed users and initial passwords
- Replaced secrets in `.env` with secure values
- `APP_URL` / `AUTH_CASDOOR_ISSUER` / `S3_ENDPOINT` match your actual public configuration
- Decided whether to use built-in or external SearXNG
- Added initial Grafana dashboards if needed
