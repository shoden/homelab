# Homelab

Ansible playbooks for a self-hosted homelab. Currently they deploy a Nextcloud stack (Nextcloud, MariaDB, Redis, Nginx Proxy Manager and Netdata) with Docker Compose on a single Debian/Ubuntu host, each application served on its own subdomain over HTTPS.

## Stack

| Service | Container | Image | Exposed ports |
|---|---|---|---|
| Nextcloud (Apache) | `nextcloud-app` | `nextcloud:32.0.6-apache` | — (behind proxy) |
| MariaDB | `nextcloud-mariadb` | `mariadb:11.8.6` | — |
| Redis | `nextcloud-redis` | `redis:8.2.4-alpine` | — |
| Nginx Proxy Manager | `nextcloud-proxy` | `jc21/nginx-proxy-manager:2.14.0` | 80, 443, 81 (admin UI) |
| Netdata | `nextcloud-netdata` | `netdata/netdata:v2.9.0` | 19999 |

All containers share the `nextcloud-network` bridge network. Nextcloud waits for MariaDB and Redis to pass their healthchecks before starting. Nginx Proxy Manager handles TLS and proxies to `nextcloud-app:80`. It stores its own config in the same MariaDB database.

## Repository layout

```
ansible.cfg              Ansible settings (default inventory: ./inventory)
run.sh                   runs a playbook: ./run.sh setup.yml
playbooks/
  setup.yml backup.yml restore.yml reboot.yml shutdown.yml
  templates/             env.j2, docker-compose.yml.j2, apache-hsts.conf.j2
  group_vars/all/        defaults.yml: project defaults
inventory.example/       template for your site settings (copy it to inventory/, which is gitignored)
renovate.json, renovate.sh, .github/workflows/   dependency updates
doc/                     extra documentation
```

## Prerequisites

- Ansible 2.19+ on the control machine
- SSH access to the target host with sudo rights
- Ubuntu/Debian on the target. The playbook installs `docker.io` and `docker-compose`.
- A domain at a DNS provider, with a subdomain per application (Nextcloud, Nginx Proxy Manager, Netdata) created beforehand and pointing at the host. See [HTTPS / Nginx Proxy Manager](#https--nginx-proxy-manager). Certificates are obtained via a DNS challenge.

## Setup (once)

The repository contains no site-specific values. Your host, domain and passwords live in an `inventory/` directory that is gitignored:

```bash
cp -r inventory.example inventory
$EDITOR inventory/hosts.ini                          # host, address, SSH user and key
$EDITOR inventory/group_vars/nextcloud/main.yml      # domain, admin email, timezone
$EDITOR inventory/group_vars/nextcloud/vault.yml     # passwords, e.g. openssl rand -base64 24 | tr -d '/+='
ansible-vault encrypt inventory/group_vars/nextcloud/vault.yml
echo 'your vault password' > .vault_pass && chmod 600 .vault_pass   # optional, otherwise you are prompted
```

Then deploy with `./run.sh setup.yml`. Before touching the host, the playbook checks that the domain, the admin email and all four passwords are set and are not still the `CHANGE_ME` / `example.com` placeholders.

To keep your configuration outside this repository, put the same layout anywhere (for example in a private repo) and run `INVENTORY=~/infra/mysite ./run.sh setup.yml`.

### Settings

Defaults are in `playbooks/group_vars/all/defaults.yml`. Override any of them in `inventory/group_vars/nextcloud/main.yml`. Use that group, not `group_vars/all`: Ansible gives the group precedence over `all`.

| Variable | Default | Notes |
|---|---|---|
| `nextcloud_domain` | **required** | public domain, used for trusted domains and `overwrite.cli.url` |
| `nginx_admin_email` | **required** | initial Nginx Proxy Manager admin login |
| `timezone` | `UTC` | e.g. `Europe/Madrid` |
| `nextcloud_base_dir` | `/opt/nextcloud` | data directories are created under it: `app/`, `db/`, `redis/`, `nginx-proxy-manager/`, `netdata/` |
| `nextcloud_admin_user` | `admin` | |
| `clean_install` | `false` | `true` **deletes the base directory and all data** before reinstalling |
| `run_repair` | `false` | also run the slow repair and index steps on a run that doesn't restart the stack |

### Secrets (`vault.yml`)

| Variable | Used for |
|---|---|
| `mysql_root_password` | MariaDB root |
| `mysql_password` | MariaDB `nextcloud` user (also used as the Redis password) |
| `nextcloud_admin_password` | Nextcloud admin user |
| `nginx_admin_password` | Nginx Proxy Manager initial admin |

Setting values flow like this: Ansible variables → `playbooks/templates/env.j2` (rendered to `<base dir>/.env`, mode 0600) → `${VAR}` references in `playbooks/templates/docker-compose.yml.j2`.

## Playbooks

```bash
./run.sh setup.yml       # deploy or update the stack
./run.sh reboot.yml      # stop the stack, reboot the host, wait until Nextcloud is healthy again
./run.sh shutdown.yml    # stop the stack gracefully and power off the host
```

You can also run them directly:

```bash
ansible-playbook --ask-vault-pass playbooks/setup.yml               # uses ./inventory (see ansible.cfg)
ansible-playbook --ask-vault-pass playbooks/setup.yml --check --diff   # dry run
ansible-playbook --ask-vault-pass playbooks/setup.yml -e clean_install=true   # full wipe and reinstall
ansible-playbook --ask-vault-pass playbooks/setup.yml -e run_repair=true      # also run the slow repair/index steps
```

`./run.sh` also accepts extra arguments, e.g. `./run.sh setup.yml -e run_repair=true`. Run it without a playbook (`./run.sh`, or just options like `./run.sh --check --diff`) and, if [fzf](https://github.com/junegunn/fzf) is installed, you pick the playbook from a list that shows each playbook's name and description (the `name:` of its first play, e.g. `setup    - Deploy Nextcloud stack`). You can type to filter on either.

### What `setup.yml` does

The playbook is idempotent. A rerun with no changes causes no downtime and reports almost nothing as changed.

1. Checks that the required settings are provided.
2. Installs Docker and docker-compose, and adds the SSH user to the `docker` group.
3. Only if `clean_install` is set: stops the stack and deletes its volumes and `/opt/nextcloud`.
4. Creates the data directories and renders `.env`, `docker-compose.yml`, `apache-hsts.conf` and the `nextcloud-stack` systemd service.
5. Restarts the stack **only if one of those files changed**. It then makes sure the service is enabled and running, so the stack starts at boot and stops cleanly on shutdown.
6. Installs the `/usr/local/bin/nextcloud-occ` helper.
7. Waits until `nextcloud-app` is healthy and Nextcloud reports itself as installed.
8. After a restart, or when run with `-e run_repair=true`, runs `maintenance:repair --include-expensive` and `db:add-missing-indices`.
9. Applies Nextcloud settings, changing each one only if it differs from the current value:
   - `config:system` settings from the `nextcloud_system_config` variable (override it in your inventory to change them): maintenance window starting at 01:00, no demo files for new users, and `overwrite.cli.url`
   - turns off the first-run wizard

The HSTS header comes from `apache-hsts.conf`, which is mounted read-only into the container's `conf-enabled/`. It stays active when the container is recreated.

## HTTPS / Nginx Proxy Manager

Each application is served on its own subdomain, over HTTPS only. Nginx Proxy Manager (NPM) terminates TLS and forwards to the containers over the internal `nextcloud-network`. The proxy hosts and certificates are set up by hand in the NPM admin UI. Ansible does not manage them.

### 1. Create the subdomains

Create the DNS records at your domain provider **before** requesting certificates. Each subdomain needs an `A` record (or a `CNAME`) pointing at the host's public IP address. The examples below use `example.com`:

| Application | Subdomain | Forwards to |
|---|---|---|
| Nextcloud | `cloud.example.com` (must equal `nextcloud_domain`) | `nextcloud-app`, port `80` |
| Nginx Proxy Manager (admin UI) | `proxy.example.com` | `nextcloud-proxy`, port `81` |
| Netdata | `netdata.example.com` | `nextcloud-netdata`, port `19999` |

The subdomain names are your choice, except the Nextcloud one: it has to be the `nextcloud_domain` from your inventory, because Nextcloud only accepts requests for that domain.

### 2. Get a certificate

1. Open the NPM admin UI at `http://<host>:81` and log in with `nginx_admin_email` / `nginx_admin_password`. This direct port is the only way in until the proxy host for NPM itself exists.
2. Go to **Certificates → Add Certificate → Let's Encrypt via DNS**. Choose **OVH** as the DNS provider and paste the API credentials. See [doc/ovh.md](doc/ovh.md) to create them.
3. Request either one certificate per subdomain, or a single wildcard certificate (`*.example.com`) that all three proxy hosts can share. The DNS challenge supports wildcards.

### 3. Add a proxy host for each application

Under **Hosts → Proxy Hosts → Add Proxy Host**, create three entries with these settings:

| Setting | Nextcloud | Nginx Proxy Manager | Netdata |
|---|---|---|---|
| Domain Names | `cloud.example.com` | `proxy.example.com` | `netdata.example.com` |
| Scheme | `http` | `http` | `http` |
| Forward Hostname / IP | `nextcloud-app` | `nextcloud-proxy` | `nextcloud-netdata` |
| Forward Port | `80` | `81` | `19999` |
| Websockets Support | on | on | on |

On the **SSL** tab of each one, select the certificate and turn on **Force SSL** (redirects HTTP to HTTPS) and **HTTP/2 Support**.

Once the NPM entry works, you can administer NPM at `https://proxy.example.com` instead of the direct port.

## Accessing

Everything is reached over HTTPS through its own subdomain:

| Application | URL | Login |
|---|---|---|
| Nextcloud | `https://cloud.example.com` | `nextcloud_admin_user` / `nextcloud_admin_password` |
| Nginx Proxy Manager | `https://proxy.example.com` | `nginx_admin_email` / `nginx_admin_password` |
| Netdata | `https://netdata.example.com` | none (see the security notes) |

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
./run.sh backup.yml                       # new backup, then remove the oldest ones beyond backup_keep
./run.sh backup.yml -e backup_keep=5      # keep 5 instead of the default 3
./run.sh restore.yml                      # list the available backups
./run.sh restore.yml -e backup=latest     # restore the newest (or -e backup=20261116T180000Z)
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
- **Retention:** after each successful backup, only the newest `backup_keep` (default 3, minimum 1) are kept. A backup that fails is deleted and never counts. Change the defaults in `inventory/group_vars/nextcloud/main.yml` or with `-e`.
- **User files** (`app/data`) are **not** included by default: they can be many GB and an upgrade doesn't touch them. Add `-e backup_include_data=true` to include them. If the backup lacks them, a restore leaves your current files in place, so run `nextcloud-occ files:scan --all` afterwards if files changed since the backup (or restore with `-e restore_files_scan=true`).
- **Where it lives:** `backup_dir` is outside `/opt/nextcloud`, so `clean_install` doesn't delete it. It is still on the same disk as the data, so it protects against a bad upgrade or a mistake, **not** against the disk dying. Copy the backups elsewhere, for example `rsync -a --rsync-path="sudo rsync" <user>@<host>:/var/backups/nextcloud/ /somewhere/safe/`.
- **Scheduling:** to run it daily from the machine you deploy from, add a cron line such as `0 3 * * * cd /path/to/homelab && ./run.sh backup.yml` (it needs `.vault_pass`).

**Restoring** replaces the current database, Nextcloud code and config, and proxy data with the backup, **and** the `.env` and `docker-compose.yml` of that moment, so the image versions match the data. It asks you to type the backup name to confirm (skip with `-e confirm_restore=true`). Before replacing anything it takes a safety backup of the current state, named `<timestamp>-pre-restore`, which is never deleted automatically (skip with `-e pre_restore_backup=false`, for example if the stack is too broken to back up).

- The stack is down during the restore. The database is re-created from the dump, then Nextcloud starts, maintenance mode is turned off and sync clients are told the data was restored.
- **Passwords** come back as they were at the time of the backup (they are in the `.env` and `config.php`). If you changed a password since, update `vault.yml` to match, or change it again afterwards.
- **On a new host:** run `./run.sh setup.yml` first (it installs Docker and the service), copy the backup into `/var/backups/nextcloud/`, then run `restore.yml`.

## Updating

Image versions are pinned in `playbooks/templates/docker-compose.yml.j2`. [Renovate](https://docs.renovatebot.com/) watches them and opens pull requests when new versions come out. Merging a PR only changes the pinned tag in the repository. **Nothing is deployed until you run `./run.sh setup.yml`**, which recreates the containers with the new images.

You can also update by hand: bump the tags in `playbooks/templates/docker-compose.yml.j2` and run `./run.sh setup.yml`. It keeps your data unless `clean_install` is set.

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

**Running it yourself** (needs Docker):

```bash
./renovate.sh --local          # dry run: lists the updates found, changes nothing, no token needed
RENOVATE_TOKEN=... ./renovate.sh   # open/update the PRs on GitHub from your machine
```

## Security notes

- `<base dir>/.env` on the host contains every secret and has mode 0600.
- Secrets live only in the Vault-encrypted `inventory/group_vars/nextcloud/vault.yml`. `inventory/` and `.vault_pass` are gitignored, so never commit them unencrypted.
- Passwords set in `vault.yml` only take effect when MariaDB, Nextcloud and Nginx Proxy Manager first initialise. Changing one later does not change the live account. Change it in the service as well (`ALTER USER`, `nextcloud-occ user:resetpassword`, the NPM UI).
- Ports 81 (proxy admin) and 19999 (Netdata) are also published directly on the host over plain HTTP. Port 81 is needed for the first login, before any proxy host exists. Once the subdomains work, block both ports with a firewall so the applications are only reachable over HTTPS.
- Netdata has no login of its own. Anyone who can reach `https://netdata.example.com` can see your host's metrics. Restrict it with an **Access List** in NPM (Hosts → Access Lists) and attach it to the Netdata proxy host.
