# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A flat (no roles) Ansible project that deploys a self-hosted Nextcloud stack via Docker Compose to a single host, `myhost` (`myhost.local`, user `myuser`, see `inventory.ini`). Public domain is `nextcloud.example.com`. There is no build, lint or test suite.

## Commands

```bash
./run.sh setup.yml       # deploy/update the stack (idempotent; add -e run_repair=true via ansible-playbook for repair steps) (exports credential env vars, then ansible-playbook -i inventory.ini <playbook>)
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
- **Lifecycle / idempotency**: the stack runs as the systemd unit `nextcloud-stack.service` (oneshot, `RemainAfterExit=yes`, `docker-compose up -d` / `down`), so it starts at boot and stops cleanly on shutdown. `setup.yml` registers the `.env`, compose, HSTS-conf and unit-file tasks and restarts the unit **only if one changed** (`stack_config_changed`); otherwise it just ensures `state: started`. Don't add an unconditional `docker-compose down` before that — the oneshot unit stays "active", so `started` would then not bring containers back. New template files that require a restart must be registered and added to the `stack_config_changed` list.
- **Nextcloud settings** are applied read-then-write: `config:system` keys live in the `nextcloud_system_config` var (get, then set only if different). The slow `maintenance:repair --include-expensive` / `db:add-missing-indices` run only after a restart or with `-e run_repair=true`.
- **HSTS** comes from `apache-hsts.conf.j2`, bind-mounted read-only into the container's `/etc/apache2/conf-enabled/` (not enabled via `a2enconf`, which would be lost when `docker-compose down` recreates the container).
- Uses legacy `docker-compose` (v1 binary from apt `docker-compose` package), not `docker compose`.

## Stale / legacy files

- `.github/prompts/nextcloud-deployment.md` is the original prompt and describes an older design (`playbook.yml`, port 8080 exposed directly, no proxy).

## Known quirks

- `REDIS_PASSWORD` in `.env.j2` reuses `mysql_password`.
- NPM's `INITIAL_ADMIN_EMAIL`/`INITIAL_ADMIN_PASSWORD` only apply on NPM's first start (empty DB); changing them later has no effect.
- `nextcloud_port` is written to `.env` but not used by the compose file.
