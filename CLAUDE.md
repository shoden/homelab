# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A flat (no roles) Ansible project that deploys a self-hosted Nextcloud stack via Docker Compose to a single host, `myhost` (`myhost.local`, user `myuser`, see `inventory.ini`). Public domain is `nextcloud.example.com`. There is no build, lint or test suite.

## Commands

```bash
./run.sh setup.yml       # deploy/update the stack (exports credential env vars, then ansible-playbook -i inventory.ini <playbook>)
./run.sh shutdown.yml    # stop the stack via systemd and power off the host
ansible-playbook -i inventory.ini setup.yml --check --diff   # dry run
ansible-playbook -i inventory.ini setup.yml --syntax-check
ansible-playbook -i inventory.ini setup.yml -e clean_install=true   # WIPES /opt/nextcloud and all volumes
```

On the target host, `nextcloud-occ <args>` (installed by `setup.yml`) wraps `docker exec -u www-data nextcloud-app php occ`.

## Architecture

- **`setup.yml`** is the main playbook. All configuration lives in its `vars:` block (paths under `/opt/nextcloud`, domain, `clean_install`). Secrets come from env vars (`MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD`, `NGINX_ADMIN_EMAIL`, `NGINX_ADMIN_PASSWORD`) via `lookup('env', ...)` with `changeme_*` fallbacks; `run.sh` sets them.
- **Variable flow is two-stage**: Ansible vars → `.env.j2` (rendered to `/opt/nextcloud/.env`, mode 0600) → `${VAR}` substitution inside `docker-compose.yml.j2`. The compose template uses almost no Jinja itself, so adding a new setting usually means editing `setup.yml` vars, `.env.j2`, and `docker-compose.yml.j2` together.
- **Stack** (`docker-compose.yml.j2`, pinned image versions): `mariadb`, `redis`, `nextcloud` (apache image, waits on DB/Redis healthchecks), `nginx` (Nginx Proxy Manager, the TLS-terminating reverse proxy on 80/443, admin UI on 81, stores its config in the same MariaDB DB), and `netdata` (monitoring on 19999). Container names are `nextcloud-*`; playbooks reference them by name (e.g. `nextcloud-app`). Proxy hosts/certificates in NPM are configured manually through its UI (Let's Encrypt via OVH DNS-01 challenge — see `doc/ovh.md`), not by Ansible.
- **Lifecycle**: the stack runs as the systemd unit `nextcloud-stack.service` (oneshot `docker-compose up -d` / `down`), so it starts at boot and stops cleanly on shutdown. `setup.yml` always runs `docker-compose down` first, then starts the unit, waits for `nextcloud-app` to be healthy and `occ status` to report installed, then applies post-install `occ` settings (repair, missing indices, maintenance window, no skeleton files, overwrite.cli.url, first-run wizard off) and enables the Apache HSTS conf (`apache-hsts.conf.j2`, bind-mounted into the container). These `occ` tasks use `failed_when: false` / `changed_when: false` so reruns are idempotent-ish.
- Uses legacy `docker-compose` (v1 binary from apt `docker-compose` package), not `docker compose`.

## Stale / legacy files

- `.github/prompts/nextcloud-deployment.md` is the original prompt and describes an older design (`playbook.yml`, port 8080 exposed directly, no proxy).

## Known quirks

- `REDIS_PASSWORD` in `.env.j2` reuses `mysql_password`.
- NPM's `INITIAL_ADMIN_EMAIL`/`INITIAL_ADMIN_PASSWORD` only apply on NPM's first start (empty DB); changing them later has no effect.
- `nextcloud_port` is written to `.env` but not used by the compose file.
