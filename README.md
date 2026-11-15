# Nextcloud Deployment with Ansible

Ansible playbooks that deploy a self-hosted Nextcloud stack with Docker Compose on the `myhost` host, served publicly at `https://nextcloud.example.com`.

## Stack

| Service | Container | Image | Exposed ports |
|---|---|---|---|
| Nextcloud (Apache) | `nextcloud-app` | `nextcloud:32.0.6-apache` | — (behind proxy) |
| MariaDB | `nextcloud-mariadb` | `mariadb:11.8.6` | — |
| Redis | `nextcloud-redis` | `redis:8.2.4-alpine` | — |
| Nginx Proxy Manager | `nextcloud-proxy` | `jc21/nginx-proxy-manager:2.14.0` | 80, 443, 81 (admin UI) |
| Netdata | `nextcloud-netdata` | `netdata/netdata:v2.9.0` | 19999 |

All containers share the `nextcloud-network` bridge network. Nextcloud waits for MariaDB and Redis to pass their healthchecks before starting. Nginx Proxy Manager handles TLS and proxies to `nextcloud-app:80`. It stores its own config in the same MariaDB database.

## Prerequisites

- Ansible on the control machine
- SSH access to `myhost.local` as `myuser` with `~/.ssh/id_ed25519`, with sudo rights
- Ubuntu/Debian on the target. The playbook installs `docker.io` and `docker-compose`.

## Configuration

### Inventory

```ini
[nextcloud]
myhost ansible_host=myhost.local ansible_user=myuser ansible_private_key=~/.ssh/id_ed25519
```

### Credentials

`setup.yml` reads secrets from environment variables. If one is unset, it falls back to a `changeme_*` default.

| Variable | Used for |
|---|---|
| `MYSQL_ROOT_PASSWORD` | MariaDB root |
| `MYSQL_PASSWORD` | MariaDB `nextcloud` user (also used as the Redis password) |
| `NEXTCLOUD_ADMIN_PASSWORD` | Nextcloud `admin` user |
| `NGINX_ADMIN_EMAIL` | Nginx Proxy Manager initial admin |
| `NGINX_ADMIN_PASSWORD` | Nginx Proxy Manager initial admin |

`run.sh` exports these variables and then runs the playbook you pass to it.

### Playbook variables

The `vars:` block in `setup.yml` sets these:

- `nextcloud_domain`: `nextcloud.example.com`
- `clean_install`: `false` keeps data and only refreshes configs and containers. `true` **deletes `/opt/nextcloud` and all data** before reinstalling.
- Data directories under `/opt/nextcloud`:
  - `app/`: Nextcloud `/var/www/html`
  - `db/`: MariaDB
  - `redis/`
  - `nginx-proxy-manager/`: `data/` and `letsencrypt/`
  - `netdata/`: `config/`, `lib/` and `cache/`

Setting values flow like this: `setup.yml` vars → `.env.j2` (rendered to `/opt/nextcloud/.env`, mode 0600) → `${VAR}` references in `docker-compose.yml.j2`.

## Playbooks

```bash
./run.sh setup.yml       # deploy or update the stack
./run.sh shutdown.yml    # stop the stack gracefully and power off the host
```

You can also run them directly:

```bash
ansible-playbook -i inventory.ini setup.yml
ansible-playbook -i inventory.ini setup.yml --check --diff   # dry run
ansible-playbook -i inventory.ini setup.yml -e clean_install=true   # full wipe and reinstall
```

### What `setup.yml` does

1. Installs Docker and docker-compose, and adds the SSH user to the `docker` group.
2. Stops any existing stack. If `clean_install` is set, it also removes the volumes and `/opt/nextcloud`.
3. Creates the data directories and renders `.env`, `docker-compose.yml` and `apache-hsts.conf`.
4. Installs and starts the `nextcloud-stack` systemd service, which starts the stack at boot and stops it cleanly on shutdown.
5. Installs the `/usr/local/bin/nextcloud-occ` helper.
6. Waits until `nextcloud-app` is healthy and Nextcloud reports itself as installed.
7. Runs post-install `occ` tasks:
   - repair with expensive checks
   - add missing database indices
   - set the maintenance window to start at 01:00
   - turn off the demo files given to new users
   - set `overwrite.cli.url`
   - turn off the first-run wizard
8. Enables the HSTS header in Apache.

## HTTPS / Nginx Proxy Manager

The proxy host and certificate are set up by hand in the Nginx Proxy Manager admin UI at `http://myhost.local:81`:

1. Log in with `NGINX_ADMIN_EMAIL` / `NGINX_ADMIN_PASSWORD`.
2. Add a proxy host for `nextcloud.example.com` that forwards to `nextcloud-app`, port `80`.
3. Request a Let's Encrypt certificate using the **OVH DNS challenge**. See [doc/ovh.md](doc/ovh.md) to create the OVH API credentials.

## Accessing

- Nextcloud: `https://nextcloud.example.com` (user `admin`)
- Nginx Proxy Manager: `http://myhost.local:81`
- Netdata: `http://myhost.local:19999`

## Managing the stack

On the target host:

```bash
sudo systemctl status nextcloud-stack
sudo systemctl restart nextcloud-stack
sudo systemctl stop nextcloud-stack

cd /opt/nextcloud
docker-compose ps
docker-compose logs -f nextcloud

nextcloud-occ status
nextcloud-occ maintenance:mode --on
```

## Updating

Image versions are pinned in `docker-compose.yml.j2`. To update:

1. Bump the tags in `docker-compose.yml.j2`.
2. Run `./run.sh setup.yml`. It keeps your data unless `clean_install` is set.

## Security notes

- `/opt/nextcloud/.env` contains every secret and has mode 0600.
- Set real values for the credential variables. Don't rely on the `changeme_*` defaults.
- Ports 81 (proxy admin) and 19999 (Netdata) are published on the host. Restrict them with a firewall if the host is reachable from untrusted networks.
- For production, consider Ansible Vault instead of plain environment variables.
