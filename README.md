# Homelab

Ansible playbooks for a self-hosted homelab. Currently they deploy a Nextcloud stack (Nextcloud, MariaDB, Redis and Nginx Proxy Manager) with Docker Compose on a single Debian/Ubuntu host, each application served on its own subdomain over HTTPS.

## Stack

| Service | Container | Image | Exposed ports |
|---|---|---|---|
| Nextcloud (Apache) | `nextcloud-app` | `nextcloud:32.0.6-apache` | — (behind proxy) |
| MariaDB | `nextcloud-mariadb` | `mariadb:11.8.6` | — |
| Redis | `nextcloud-redis` | `redis:8.2.4-alpine` | — |
| Nginx Proxy Manager | `nextcloud-proxy` | `jc21/nginx-proxy-manager:2.14.0` | 80, 443, 81 (admin UI) |

Monitoring (see [Monitoring](#monitoring)): every environment also runs `nextcloud-node-exporter` (`prom/node-exporter`, port 9100 on the host network), and the hub environment adds `nextcloud-victoria-metrics`, `nextcloud-vmalert`, `nextcloud-alertmanager` and `nextcloud-grafana` (behind the proxy).

All containers share the `nextcloud-network` bridge network. Nextcloud waits for MariaDB and Redis to pass their healthchecks before starting. Nginx Proxy Manager handles TLS and proxies to `nextcloud-app:80`. It stores its own config in the same MariaDB database.

## Repository layout

```
ansible.cfg              Ansible settings
run.sh                   runs a playbook on an environment: ./run.sh deploy.yml prod
playbooks/
  deploy.yml backup.yml restore.yml reboot.yml shutdown.yml maintenance_on.yml maintenance_off.yml
  templates/             env.j2, docker-compose.yml.j2, apache-hsts.conf.j2
  tasks/                 steps shared by several playbooks
  group_vars/all/        defaults.yml: project defaults
inventory.example/       templates for your site settings: prod/ and dev/ (copy them to inventory/, which is gitignored)
renovate.json, renovate.sh, .github/workflows/   dependency updates
doc/                     extra documentation; doc/architecture/ has the C4 diagrams (Structurizr)
trivy.sh                 vulnerability scan (Trivy) of the images and the e2e dependencies
architecture.sh          serve | check | export the architecture diagrams
```

## Vulnerability scan

[Trivy](https://trivy.dev) scans the container images in the compose template and the `e2e/` npm lockfile, in CI (`.github/workflows/trivy.yml`: pull requests, pushes to main, weekly) and locally with `./trivy.sh` (needs Docker). All findings go to the repository's Security tab; the check fails only on CRITICAL vulnerabilities that have a fix. Accepted findings: `.trivyignore`.

## Architecture

C4 diagrams (context, containers, deploy flow, per-environment deployment, backup): [doc/architecture/](doc/architecture/README.md), rendered in [diagrams.md](doc/architecture/diagrams.md).

## Prerequisites

- Ansible 2.19+ on the control machine
- [SecretSpec](https://secretspec.dev) on the control machine: all credentials (users, passwords, the NPM admin email) live in it, not in the repo
- SSH access to the target host with sudo rights
- Ubuntu/Debian on the target. The playbook installs `docker.io` and `docker-compose`.
- A domain at a DNS provider, with a subdomain per application (Nextcloud, Nginx Proxy Manager) created beforehand and pointing at the host. See [HTTPS / Nginx Proxy Manager](#https--nginx-proxy-manager). Certificates are obtained via a DNS challenge.

## Setup (once)

The repository contains no site-specific values. Your hosts and domains live in an `inventory/` directory that is gitignored, and your credentials in SecretSpec (see [Secrets](#secrets-secretspec)). The inventory has, one subdirectory per environment (see [Environments](#environments-prod-and-dev)). Start with prod:

```bash
mkdir inventory && cp -r inventory.example/prod inventory/prod
$EDITOR inventory/prod/hosts.ini                          # host, address, SSH user and key
$EDITOR inventory/prod/group_vars/nextcloud/main.yml      # domain, timezone
secretspec config global init --provider 'kdbx:/path/to/homelab.kdbx'   # once: where SecretSpec keeps the values (here a KeePass file; see Secrets)
secretspec check --profile prod                           # asks for every missing secret (passwords: openssl rand -base64 24 | tr -dc 'A-Za-z0-9')
```

Then deploy with `./run.sh deploy.yml prod`. Before touching the host, the playbook checks that the environment is set, that the domain and all credentials are set and are not placeholders, and that the passwords only use characters that are safe in `.env`, Redis and the session URL.

To keep your configuration outside this repository, put the same layout anywhere (for example in a private repo) and run `INVENTORY=~/infra/mysite/prod ./run.sh deploy.yml`.

### Settings

Defaults are in `playbooks/group_vars/all/defaults.yml`. Override any of them in `inventory/<environment>/group_vars/nextcloud/main.yml`. Use that group, not `group_vars/all`: Ansible gives the group precedence over `all`.

| Variable | Default | Notes |
|---|---|---|
| `stack_env` | **required** | the environment this inventory is: `prod`, `dev`, ... (see below) |
| `nextcloud_domain` | **required** | public domain, used for trusted domains and `overwrite.cli.url` |
| `timezone` | `UTC` | e.g. `Europe/Madrid` |
| `nextcloud_base_dir` | `/opt/<stack name>` (prod: `/opt/nextcloud`) | data directories are created under it: `app/`, `db/`, `redis/`, `nginx-proxy-manager/` |
| `clean_install` | `false` | `true` **deletes the base directory and all data** before reinstalling |
| `run_repair` | `false` | also run the slow repair and index steps on a run that doesn't restart the stack |

### Secrets (SecretSpec)

Credentials are declared in `secretspec.toml` (names and descriptions only) and stored by your SecretSpec provider, one set per profile: the profile is the environment (`prod`, `dev`). `./run.sh` runs Ansible inside `secretspec run --profile <environment> --`, which passes them as environment variables, and `playbooks/group_vars/all/defaults.yml` maps them to the Ansible variables.

| Secret | Ansible variable | Used for |
|---|---|---|
| `MYSQL_USER` | `mysql_user` | MariaDB user for Nextcloud and NPM |
| `MYSQL_PASSWORD` | `mysql_password` | that MariaDB user (also the Redis password: letters and digits only) |
| `MYSQL_ROOT_PASSWORD` | `mysql_root_password` | MariaDB root |
| `NEXTCLOUD_ADMIN_USER` | `nextcloud_admin_user` | Nextcloud admin user |
| `NEXTCLOUD_ADMIN_PASSWORD` | `nextcloud_admin_password` | Nextcloud admin password |
| `NGINX_ADMIN_EMAIL` | `nginx_admin_email` | Nginx Proxy Manager initial admin login |
| `NGINX_ADMIN_PASSWORD` | `nginx_admin_password` | Nginx Proxy Manager initial admin password |

```bash
secretspec check --profile dev                      # lists what is missing and asks for it
secretspec set MYSQL_PASSWORD --profile dev         # set or change one (prompts, nothing in your shell history)
secretspec get NGINX_ADMIN_EMAIL --profile prod     # read one
```

**KeePass (kdbx) provider.** The provider is per user, not per repo, so the file path never goes in `secretspec.toml`. Set it once in your user-global config:

```bash
secretspec config global init --provider 'kdbx:/home/you/secrets/homelab.kdbx'
# with a key file as well as (or instead of) the master password:
secretspec config global init --provider 'kdbx:/home/you/secrets/homelab.kdbx?keyfile=/home/you/secrets/homelab.key'
secretspec config global show                        # check what was saved
```

The master password is read from the `SECRETSPEC_KDBX_PASSWORD` environment variable (export it for the session, never put it in a file in the repo). To use another provider for one command, `--provider` or `SECRETSPEC_PROVIDER` overrides the global one.

Use different values in `dev` and `prod`. Run plain `ansible-playbook` the same way: `secretspec run --profile dev -- ansible-playbook -i inventory/dev playbooks/deploy.yml`.

Setting values flow like this: Ansible variables → `playbooks/templates/env.j2` (rendered to `<base dir>/.env`, mode 0600) → `${VAR}` references in `playbooks/templates/docker-compose.yml.j2`.

## Environments (prod and dev)

Environments (`prod`, `dev`, ...) let you try a change (a Nextcloud major upgrade, a new image, a branch) in `dev` before touching `prod`. Each environment is a directory of `inventory/` with its own host, settings and passwords, and every playbook runs against exactly one of them. **Every environment deploys the full stack** (Nextcloud, MariaDB, Redis and Nginx Proxy Manager) and is meant to run on **its own host**: ports 80, 443 and 81 can only be bound once per machine, so do not point two environments at the same host.

```bash
./run.sh deploy.yml dev       # deploy to dev
./run.sh deploy.yml prod      # deploy to prod
./run.sh deploy.yml           # without the environment you pick one (fzf), or get an error if there is no terminal
```

### Add a dev environment

1. `mkdir -p inventory && cp -r inventory.example/dev inventory/dev`, then edit it: the dev host in `hosts.ini`, `stack_env: dev`, its own domain (for example `dev.<your domain>`), then run `secretspec check --profile dev` and enter **different credentials from prod** (a new password for each secret, including the NPM admin email and password).
2. Create the DNS record for the dev domain, as for the prod subdomains.
3. `./run.sh deploy.yml dev`
4. Configure the dev Nginx Proxy Manager as described in [HTTPS](#https--nginx-proxy-manager).

### Test a branch in dev first

```bash
git checkout my-branch          # for example the Renovate branch with a Nextcloud major upgrade
./run.sh deploy.yml dev         # deploy it to dev and try it at https://<dev domain>
# happy? merge the branch, then:
git checkout main && git pull
./run.sh deploy.yml prod
```

Dev starts empty. To rehearse an **upgrade**, first deploy the version prod runs now (check out `main`, `deploy.yml dev`), put some data into dev, and then deploy the branch. Restoring a prod backup into dev is not supported yet: `restore.yml` refuses a backup made in another environment.

### Good to know

- **`clean_install`, backups, maintenance mode and restores** apply to the one environment you run them on.
- **`reboot.yml` and `shutdown.yml`** act on the whole machine of the environment you pick.

## Playbooks

```bash
./run.sh deploy.yml prod       # deploy or update the stack of an environment
./run.sh reboot.yml prod       # stop the stack, reboot the host, wait until Nextcloud is serving again
./run.sh shutdown.yml prod     # stop the stack gracefully and power off the host
./run.sh maintenance_on.yml dev    # put Nextcloud in maintenance mode (users see a maintenance page)
./run.sh maintenance_off.yml dev   # take it out of maintenance mode
./run.sh e2e.yml dev           # only run the end-to-end test against an already deployed environment
```

You can also run them directly, naming the inventory of the environment:

```bash
secretspec run --profile prod -- ansible-playbook -i inventory/prod playbooks/deploy.yml               # deploy prod
secretspec run --profile dev -- ansible-playbook -i inventory/dev playbooks/deploy.yml --check --diff   # dry run on dev
secretspec run --profile dev -- ansible-playbook -i inventory/dev playbooks/deploy.yml -e clean_install=true   # wipe dev and reinstall
secretspec run --profile prod -- ansible-playbook -i inventory/prod playbooks/deploy.yml -e run_repair=true     # also run the slow repair/index steps
```

`./run.sh` also accepts extra arguments after the environment, e.g. `./run.sh deploy.yml dev -e run_repair=true`. Run it without a playbook (`./run.sh`, or just options like `./run.sh --check --diff`) and, if [fzf](https://github.com/junegunn/fzf) and [yq](https://github.com/mikefarah/yq) are installed, you pick the playbook from a list that shows each playbook's name and description (the `name:` of its first play, e.g. `deploy - Deploy Nextcloud stack`), and then the environment. You can type to filter.

### End-to-end test

`deploy.yml` ends by checking that the deployment really works as a user would use it. It logs in to Nextcloud with a real browser ([Playwright](https://playwright.dev), Chromium only), uploads a small file through the Files app, checks over WebDAV that it arrived, and deletes it again. A failed test **fails the run** (the deployment is already done, nothing is rolled back) and prints the failing step and where the screenshot and page snapshot are.

- **Account:** the test logs in with a dedicated, non-admin account that `deploy.yml` creates (quota 100 MB). Its credentials are two secrets, per environment: `NEXTCLOUD_TEST_USER` (letters, digits, `.` `_` `-`) and `NEXTCLOUD_TEST_PASSWORD` (12+ characters, the same character rules as the other passwords). An existing account keeps its password unless you run with `-e e2e_reset_password=true`.
- **Where it runs:** on the machine you deploy from, not on the host: Chromium does not belong on a Raspberry Pi, and going through `https://<nextcloud_domain>` also tests DNS, the NPM certificate and the proxy host. That machine needs Node (`mise install`, or any recent Node) and must reach the domain. The first run installs the npm packages and Chromium; on a Linux machine missing the browser's system libraries run once `cd e2e && npx playwright install --with-deps chromium`.
- **Watch it:** it is headless by default. Add `-e e2e_headed=true` to see the browser, for example `./run.sh e2e.yml dev -e e2e_headed=true`; it needs a display on the machine you run it from. Each action then pauses 400 ms; change that with `-e e2e_slow_mo=1000`.
- **Run or skip it:** `./run.sh e2e.yml <env>` runs only the test; `./run.sh deploy.yml <env> --skip-tags e2e` deploys without it. It is skipped with `--check`.
- **The test** is `e2e/tests/nextcloud.spec.ts`. The selectors follow Nextcloud's Files app, so a Nextcloud major upgrade (that is what the dev environment is for) may need them adjusted.

### What `deploy.yml` does

The playbook is idempotent. A rerun with no changes causes no downtime and reports almost nothing as changed.

1. Checks that the required settings are provided.
2. Installs Docker and docker-compose, and adds the SSH user to the `docker` group.
3. Only if `clean_install` is set: stops the stack and deletes its volumes and the environment's base directory.
4. Creates the data directories and renders `.env`, `docker-compose.yml`, `apache-hsts.conf` and the stack's systemd service (`nextcloud-stack` in prod).
5. Restarts the stack **only if one of those files changed**. It then makes sure the service is enabled and running, so the stack starts at boot and stops cleanly on shutdown.
6. Installs the occ helper (`/usr/local/bin/nextcloud-occ` in prod).
7. Waits until Nextcloud is really serving requests, which can take several minutes after an image upgrade: the image first copies the new code and runs `occ upgrade`, and starts Apache only afterwards. The wait polls `status.php` (up to 15 minutes) instead of trusting `occ status`, which already answers while the upgrade is still running.
8. After a restart, or when run with `-e run_repair=true`, runs `maintenance:repair --include-expensive` and `db:add-missing-indices`.
9. Applies Nextcloud settings, changing each one only if it differs from the current value:
   - `config:system` settings from the `nextcloud_system_config` variable (override it in your inventory to change them): maintenance window starting at 01:00, no demo files for new users, and `overwrite.cli.url`
   - turns off the first-run wizard

The HSTS header comes from `apache-hsts.conf`, which is mounted read-only into the container's `conf-enabled/`. It stays active when the container is recreated.

## HTTPS / Nginx Proxy Manager

Each application is served on its own subdomain, over HTTPS only. Nginx Proxy Manager (NPM) terminates TLS and forwards to the containers over the internal `nextcloud-network`. `deploy.yml` sets up the certificate and the proxy hosts for you through NPM's API (see below); you only create the DNS records and the OVH API credentials.

### 1. Create the subdomains

Create the DNS records at your domain provider **before** requesting certificates. Each subdomain needs an `A` record (or a `CNAME`) pointing at the host's public IP address. The examples below use `example.com`:

| Application | Subdomain | Forwards to |
|---|---|---|
| Nextcloud | `cloud.example.com` (must equal `nextcloud_domain`) | `nextcloud-app`, port `80` |
| Nginx Proxy Manager (admin UI) | `proxy.example.com` | `nextcloud-proxy`, port `81` |

The subdomain names are your choice, except the Nextcloud one: it has to be the `nextcloud_domain` from your inventory, because Nextcloud only accepts requests for that domain.

### 2. Settings and secrets

In `inventory/<environment>/group_vars/nextcloud/main.yml` (see `inventory.example/`):

| Variable | Example | Notes |
|---|---|---|
| `npm_certificate_domains` | `dev.example.com,*.dev.example.com` | comma separated: **one** Let's Encrypt certificate for all of them. A wildcard covers the three subdomains below |
| `nextcloud_domain` | `cloud.dev.example.com` | proxy host to `nextcloud-app:80` |
| `proxy_domain` | `proxy.dev.example.com` | proxy host to `nextcloud-proxy:81` (NPM's own admin UI) |

The three domains must be covered by `npm_certificate_domains`. `ovh_endpoint` (default `ovh-eu`) and `npm_dns_propagation_seconds` (default: NPM's own) are optional.

The OVH API credentials are three secrets in SecretSpec, per environment: `OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET` and `OVH_CONSUMER_KEY`. See [doc/ovh.md](doc/ovh.md) to create them.

### 3. What `deploy.yml` does in NPM

After the stack is up, `playbooks/tasks/npm.yml` logs in to NPM's API (`http://127.0.0.1:81/api` on the host) with `nginx_admin_email` / `nginx_admin_password` and then:

1. Requests the Let's Encrypt certificate with the **DNS challenge against OVH**, unless one exists for exactly those domains. NPM renews it by itself. The first request can take a few minutes while the DNS record propagates.
2. Creates each proxy host (or updates it if it differs), all with that certificate, **Force SSL**, **HTTP/2** and **Websockets** on.

It is idempotent, and it only touches the hosts and the certificate listed above: whatever else you add by hand in the NPM UI stays. It is skipped with `--check`. Once the proxy host for NPM exists, you can administer NPM at `https://<proxy_domain>` instead of `http://<host>:81`.

Things to know:

- **Admin login:** NPM only applies `nginx_admin_email` / `nginx_admin_password` on its **first start**. If you change that admin in the UI, put the same email and password into SecretSpec, or the API login fails.
- **Failures:** a refused request stops the run with NPM's own message. The tasks hide the request details because they contain tokens and the OVH credentials; add `-e npm_debug=true` to see them (and then do not share the output). NPM's own log is `docker logs nextcloud-proxy`.
- **Let's Encrypt limits:** a repeatedly failing request counts toward its rate limits, so get it working in dev first.
- **NPM updates:** the API is not a stable public contract, so try NPM upgrades in dev before prod.

## Monitoring

Every environment exposes its host's metrics (`node_exporter`, port 9100). **One** environment is the hub (here `dev`, `with_monitoring_hub: true`): it scrapes all the hosts, stores 30 days of history, shows them in a Grafana dashboard (**Pi hosts**: current values on top, trends below, host selector) and sends alerts to Telegram. Everything is lightweight and open source (VictoriaMetrics, vmalert, Alertmanager, Grafana; about 300-400 MB of RAM on the hub, about 15 MB on the other hosts), works offline and writes little to the SD card.

1. In the hub's `inventory/<env>/group_vars/nextcloud/main.yml` (see `inventory.example/dev`): `with_monitoring_hub: true`, `grafana_domain` (covered by the NPM certificate, and its DNS record pointing at the hub) and `monitoring_targets`, one `{ name, address }` per host including the hub itself. Use **IP addresses** (containers cannot resolve `*.local`).
2. Secrets for the hub's profile: `GRAFANA_ADMIN_PASSWORD`, `TELEGRAM_BOT_TOKEN` (create a bot with @BotFather) and `TELEGRAM_CHAT_ID` (message the bot, then open `https://api.telegram.org/bot<token>/getUpdates` and copy `chat.id`; negative for groups). `secretspec set <NAME> --profile dev`.
3. Deploy every environment (`./run.sh deploy.yml prod`, then `dev`). Open `https://<grafana_domain>`, user `admin`.

Alert rules are in `playbooks/files/monitoring/alerts.yml`: host down, rebooted, CPU, load, memory, swap, disk full / filling up, read-only filesystem (SD card errors), SoC temperature. Change thresholds there and redeploy the hub (only the monitoring containers restart). The dashboard is `playbooks/files/monitoring/pi-hosts.json`; it is provisioned read-only, so edit a copy in Grafana and export it to the repo.

Limits: the hub cannot alert about its own death (nothing is left to send it), so keep an eye on it from outside (for example Uptime Kuma on another machine). Port 9100 has no authentication: only allow it from the hub with a firewall, or set `node_exporter_listen` to the LAN address. The dashboard and alerts only use node metrics; per-container metrics and Nextcloud-level checks are not included.

## Accessing

Everything is reached over HTTPS through its own subdomain:

| Application | URL | Login |
|---|---|---|
| Nextcloud | `https://cloud.example.com` | `nextcloud_admin_user` / `nextcloud_admin_password` |
| Nginx Proxy Manager | `https://proxy.example.com` | `nginx_admin_email` / `nginx_admin_password` |

Replace the example subdomains with the ones you created.

## Managing the stack

On the target host:

```bash
sudo systemctl status nextcloud-stack
sudo systemctl restart nextcloud-stack
sudo systemctl stop nextcloud-stack

# docker-compose needs sudo: /opt/nextcloud/.env (all the secrets) is readable only by root
cd /opt/nextcloud
sudo docker-compose ps
sudo docker-compose logs -f nextcloud
sudo docker-compose pull

nextcloud-occ status
nextcloud-occ maintenance:mode --on
```

## Backups

`backup.yml` takes a backup on the host and `restore.yml` puts one back. Nothing runs automatically: you start them when you want, for example before an upgrade.

```bash
./run.sh backup.yml prod                       # new backup, then remove the oldest ones beyond backup_keep
./run.sh backup.yml prod -e backup_keep=5      # keep 5 instead of the default 3
./run.sh restore.yml prod                      # list the available backups
./run.sh restore.yml prod -e backup=latest     # restore the newest (or -e backup=20261116T180000Z)
```

**What a backup contains** (in `/var/backups/nextcloud/<UTC timestamp>/`, readable by root only):

| File | Content |
|---|---|
| `db.sql.gz` | the database (Nextcloud and Nginx Proxy Manager share it) |
| `nextcloud-app.tar.gz` | Nextcloud code, `config.php` and apps (not user files, see below) |
| `nginx-proxy-manager.tar.gz` | proxy hosts and certificates |
| `config/` | the `.env`, `docker-compose.yml` and HSTS config of that moment, i.e. the image versions and passwords that go with the data |
| `manifest.yml` | what the backup contains and when it was made |

- **Downtime:** Nextcloud is in maintenance mode while the backup runs (a few minutes), so the database and files agree. The other services keep running. The playbook turns maintenance mode off again even if the backup fails, unless it was already on.
- **Retention:** after each successful backup, only the newest `backup_keep` (default 3, minimum 1) are kept. A backup that fails is deleted and never counts. Change the defaults in `inventory/<environment>/group_vars/nextcloud/main.yml` or with `-e`.
- **User files** (`app/data`) are **not** included by default: they can be many GB and an upgrade doesn't touch them. Add `-e backup_include_data=true` to include them. If the backup lacks them, a restore leaves your current files in place, so run `nextcloud-occ files:scan --all` afterwards if files changed since the backup (or restore with `-e restore_files_scan=true`).
- **Where it lives:** `backup_dir` (`/var/backups/nextcloud` by default) is outside the base directory, so `clean_install` doesn't delete it. It is still on the same disk as the data, so it protects against a bad upgrade or a mistake, **not** against the disk dying. Copy the backups elsewhere, for example `rsync -a --rsync-path="sudo rsync" <user>@<host>:/var/backups/nextcloud/ /somewhere/safe/`.
- **Scheduling:** to run it daily from the machine you deploy from, add a cron line such as `0 3 * * * cd /path/to/homelab && ./run.sh backup.yml prod` (SecretSpec must be able to unlock its provider without you, which a keyring usually cannot in cron).

**Restoring** replaces the current database, Nextcloud code and config, and proxy data with the backup, **and** the `.env` and `docker-compose.yml` of that moment, so the image versions match the data. It asks you to type the backup name to confirm (skip with `-e confirm_restore=true`). Before replacing anything it takes a safety backup of the current state, named `<timestamp>-pre-restore`, which is never deleted automatically (skip with `-e pre_restore_backup=false`, for example if the stack is too broken to back up).

- The stack is down during the restore. The database is re-created from the dump, then Nextcloud starts, maintenance mode is turned off and sync clients are told the data was restored.
- **Passwords** come back as they were at the time of the backup (they are in the `.env` and `config.php`). If you changed a password since, update the value in SecretSpec to match, or change it again afterwards.
- **On a new host:** run `./run.sh deploy.yml prod` first (it installs Docker and the service), copy the backup into `/var/backups/nextcloud/`, then run `restore.yml`. A backup can only be restored into the environment it was made in.

## Updating

Image versions are pinned in `playbooks/templates/docker-compose.yml.j2`. [Renovate](https://docs.renovatebot.com/) watches them and opens pull requests when new versions come out. Merging a PR only changes the pinned tag in the repository. **Nothing is deployed until you run `./run.sh deploy.yml`** (try it in `dev` first), which recreates the containers with the new images.

You can also update by hand: bump the tags in `playbooks/templates/docker-compose.yml.j2` and run `./run.sh deploy.yml prod`. It keeps your data unless `clean_install` is set.

### Dependency updates with Renovate

Configuration is in `renovate.json`:

- Minor, patch and digest updates of the container images arrive together in one PR named "container images".
- **Major updates are not proposed until you approve them** by ticking the box in the *Dependency Dashboard* issue. This matters here: Nextcloud supports upgrading one major version at a time, and major MariaDB or Redis upgrades can need data migrations. Read the release notes and back up before approving one. Nextcloud majors are offered one at a time (for example 33, then 34), so approve them in order and deploy after each.
- Nothing is merged automatically.

**Where to see it on GitHub**

| What | Where |
|---|---|
| Pipeline runs and logs | repository → **Actions** → **Renovate** |
| Update PRs | **Pull requests** |
| Pending and held-back updates, approval checkboxes | **Issues** → *Dependency Dashboard* |

`.github/workflows/renovate.yml` runs Renovate (in its Docker container) every Monday at 05:00 UTC. To run it right away, open **Actions → Renovate → Run workflow**. The scheduled run and that button only work once the workflow file is on the default branch.

**One-time setup:** the workflow needs a token that can open PRs.

1. Create a fine-grained personal access token (GitHub → Settings → Developer settings), limited to this repository, with *Read and write* for **Contents**, **Pull requests**, **Issues** and **Workflows**, and *Read* for **Metadata**.
2. Save it as a repository secret named `RENOVATE_TOKEN` (repository → Settings → Secrets and variables → Actions).

**Commit author:** Renovate's commits are authored as `Renovate Bot <your-github-user>@users.noreply.github.com` instead of Renovate's default, a Mend-owned address that triggers a warning. To use another author, set the repository variable `RENOVATE_GIT_AUTHOR` (Settings → Secrets and variables → Actions → **Variables**), for example `Renovate Bot <you@example.com>`. Renovate doesn't sign its commits, so GitHub shows them as *Unverified* either way.

**Running it yourself** (needs Docker):

```bash
./renovate.sh --local          # dry run: lists the updates found, changes nothing, no token needed
RENOVATE_TOKEN=... ./renovate.sh   # open/update the PRs on GitHub from your machine
```

## Security notes

- `<base dir>/.env` on the host contains every secret and has mode 0600.
- Secrets live only in your SecretSpec provider (`secretspec.toml` holds names, never values). `inventory/` is gitignored and holds no credentials.
- Passwords set in SecretSpec only take effect when MariaDB, Nextcloud and Nginx Proxy Manager first initialise. Changing one later does not change the live account. Change it in the service as well (`ALTER USER`, `nextcloud-occ user:resetpassword`, the NPM UI).
- Port 9100 (node_exporter, every host) serves metrics without a login; only the hub needs it (see Monitoring).
- Port 81 (proxy admin) is also published directly on the host over plain HTTP. It is needed for the first login, before any proxy host exists. Once the subdomains work, block it with a firewall so the applications are only reachable over HTTPS.
