# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Homelab: a flat (no roles) Ansible project for self-hosted services. It currently deploys one stack, Nextcloud with its supporting services, via Docker Compose to a single host. The `nextcloud` inventory group, `nextcloud-*` container names and `/opt/nextcloud` paths refer to that stack, not to the project name. The repo is host/domain agnostic: all site-specific values (host, domain, email, passwords) live in the gitignored `inventory/` directory (copy of `inventory.example/`), never in tracked files. There is no build, lint or test suite.

## Commands

```bash
./run.sh setup.yml       # deploy/update the stack (idempotent). Extra args pass through, e.g. -e run_repair=true
./run.sh backup.yml       # back up DB, Nextcloud volume (no user files), proxy data and config to backup_dir; prunes to backup_keep
./run.sh restore.yml -e backup=latest    # restore a backup (without -e backup it lists them); asks for confirmation
./run.sh reboot.yml      # stop the stack, reboot the host and wait for Nextcloud to be healthy (stack starts at boot via systemd)
./run.sh shutdown.yml    # stop the stack via systemd and power off the host
./run.sh setup.yml --check --diff    # dry run
./renovate.sh --local     # dry run of Renovate in Docker: shows which image updates it would propose
ansible-playbook playbooks/setup.yml --syntax-check
./run.sh setup.yml -e clean_install=true   # WIPES the base dir and all volumes
```

`run.sh` uses `./inventory` (or `$INVENTORY`) and `./.vault_pass` if present, otherwise prompts for the vault password. Plain `ansible-playbook` also finds `./inventory` via `ansible.cfg`; add `--vault-password-file .vault_pass` or `--ask-vault-pass`.

On the target host, `nextcloud-occ <args>` (installed by `setup.yml`) wraps `docker exec -u www-data nextcloud-app php occ`.

## Architecture

- **Layout**: playbooks live in `playbooks/`, with their `templates/` and `group_vars/all/defaults.yml` next to them (Ansible resolves both relative to the playbook's directory, so they must stay there). `run.sh` accepts `setup.yml`, `setup` or a path and finds the file in `playbooks/`. Run plain `ansible-playbook` from the repo root so `ansible.cfg` and `./inventory` are picked up.
- **`setup.yml`** is the main playbook and contains no site values. Project defaults are in `playbooks/group_vars/all/defaults.yml`; the site's values are in `inventory/group_vars/nextcloud/main.yml` (plain) and `vault.yml` (Ansible Vault: `mysql_root_password`, `mysql_password`, `nextcloud_admin_password`, `nginx_admin_password`). `inventory.example/` is the committed template. Overrides must go in `group_vars/nextcloud` (the inventory group), because it beats `group_vars/all`; and never define an overridable setting in the play's `vars:`, which would beat inventory vars. A `pre_tasks` assert fails the run if `nextcloud_domain`, `nginx_admin_email` or a password is missing or still a `CHANGE_ME`/`example.com` placeholder.
- **Variable flow is two-stage**: Ansible vars → `playbooks/templates/env.j2` (rendered to `/opt/nextcloud/.env`, mode 0600) → `${VAR}` substitution inside `playbooks/templates/docker-compose.yml.j2`. The compose template uses almost no Jinja itself, so adding a new setting usually means editing `playbooks/group_vars/all/defaults.yml` (or the assert list if required), `playbooks/templates/env.j2`, and `playbooks/templates/docker-compose.yml.j2` together.
- **Stack** (`playbooks/templates/docker-compose.yml.j2`, pinned image versions): `mariadb`, `redis`, `nextcloud` (apache image, waits on DB/Redis healthchecks), `nginx` (Nginx Proxy Manager, the TLS-terminating reverse proxy on 80/443, admin UI on 81, stores its config in the same MariaDB DB), and `netdata` (monitoring on 19999). Container names are `nextcloud-*`; playbooks reference them by name (e.g. `nextcloud-app`). Proxy hosts/certificates in NPM are configured manually through its UI (Let's Encrypt via OVH DNS-01 challenge — see `doc/ovh.md`), not by Ansible.
- **Lifecycle / idempotency**: the stack runs as the systemd unit `nextcloud-stack.service` (oneshot, `RemainAfterExit=yes`, `docker-compose up -d` / `down`), so it starts at boot and stops cleanly on shutdown. `setup.yml` registers the `.env`, compose, HSTS-conf and unit-file tasks and restarts the unit **only if one changed** (`stack_config_changed`); otherwise it just ensures `state: started`. Don't add an unconditional `docker-compose down` before that — the oneshot unit stays "active", so `started` would then not bring containers back. New template files that require a restart must be registered and added to the `stack_config_changed` list. When that flag is set, `docker-compose pull` runs first (task `timeout: 1800`) so new image tags download while the old stack is still up and the unit's 300s `TimeoutStartSec` is not spent on downloads. Image upgrades are driven only by a changed tag in `playbooks/templates/docker-compose.yml.j2` (tags are pinned, nothing is pulled otherwise), so a merged Renovate PR must be `git pull`ed before `./run.sh setup.yml`.
- **Nextcloud settings** are applied read-then-write: `config:system` keys live in the `nextcloud_system_config` var (get, then set only if different). The slow `maintenance:repair --include-expensive` / `db:add-missing-indices` run only after a restart or with `-e run_repair=true`.
- **HSTS** comes from `playbooks/templates/apache-hsts.conf.j2`, bind-mounted read-only into the container's `/etc/apache2/conf-enabled/` (not enabled via `a2enconf`, which would be lost when `docker-compose down` recreates the container).
- **Backups** (`backup.yml`, `restore.yml`, settings `backup_*` / `restore_*` in `playbooks/group_vars/all/defaults.yml`): backups go to `backup_dir` (default `/var/backups/nextcloud`, deliberately outside `nextcloud_base_dir` because `clean_install` deletes that). Each is built in `<ts>.partial` and renamed when verified, so pruning (regex on `^\d{8}T\d{6}Z$`) only ever sees complete ones; `-pre-restore` snapshots don't match it and are never pruned. Nextcloud is in maintenance mode during a backup (turned off in `always`, only if the playbook turned it on). The DB is dumped with `MYSQL_PWD` read from the container's own env, never from the host command line. `restore.yml` wipes the MariaDB data dir and lets the container re-initialise it from the restored `.env` before importing the dump, so the DB users come from `.env`, not the dump. It restores the backup's `docker-compose.yml`/`.env` so image tags match the restored Nextcloud code (Nextcloud cannot be downgraded). `restore.yml` `import_playbook`s `backup.yml` for its safety snapshot.
- **Dependency updates**: Renovate (`renovate.json`, run by `.github/workflows/renovate.yml` or `./renovate.sh`) updates the image tags in `playbooks/templates/docker-compose.yml.j2`. Majors need approval in the Dependency Dashboard issue and nothing is automerged; the image manager is pointed at the `.j2` file via `managerFilePatterns`. Merging only changes the repo, deploying is still `./run.sh setup.yml`.
- Uses legacy `docker-compose` (v1 binary from apt `docker-compose` package), not `docker compose`.

## Known quirks

- `REDIS_PASSWORD` in `playbooks/templates/env.j2` reuses `mysql_password`.
- NPM's `INITIAL_ADMIN_EMAIL`/`INITIAL_ADMIN_PASSWORD` only apply on NPM's first start (empty DB); changing them later has no effect.
- `nextcloud_port` is written to `.env` but not used by the compose file.
