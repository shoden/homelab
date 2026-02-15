# Nextcloud Deployment with Ansible

This Ansible playbook deploys Nextcloud with MariaDB and Redis using Docker Compose on the myhost.local host.

## Prerequisites

- Ansible installed on your control machine
- SSH access to myhost.local with the configured private key
- Target host running Ubuntu/Debian

## Configuration

### Host Configuration

The inventory file (`inventory.ini`) contains:
```ini
[nextcloud]
myhost ansible_host=myhost.local ansible_user=myuser ansible_private_key=~/.ssh/id_ed25519
```

### Credentials Configuration

You can customize credentials in two ways:

1. **Environment Variables** (Recommended for production):
   ```bash
   export MYSQL_ROOT_PASSWORD='your_secure_root_password'
   export MYSQL_PASSWORD='your_secure_mysql_password'
   export NEXTCLOUD_ADMIN_PASSWORD='your_secure_admin_password'
   ```

2. **Edit playbook.yml** (For testing):
   Modify the `vars` section in `playbook.yml` to set custom values:
   ```yaml
   vars:
     mysql_root_password: "your_secure_root_password"
     mysql_password: "your_secure_mysql_password"
     nextcloud_admin_password: "your_secure_admin_password"
   ```

### Volume Paths

Default volume paths (can be customized in `playbook.yml`):
- Nextcloud data: `/opt/nextcloud/data`
- MariaDB data: `/opt/nextcloud/mariadb`
- Redis data: `/opt/nextcloud/redis`

## Deployment

### Run the Playbook

```bash
ansible-playbook -i inventory.ini playbook.yml
```

### With Custom Credentials

```bash
export MYSQL_ROOT_PASSWORD='your_root_pass'
export MYSQL_PASSWORD='your_mysql_pass'
export NEXTCLOUD_ADMIN_PASSWORD='your_admin_pass'

ansible-playbook -i inventory.ini playbook.yml
```

### Check Deployment

```bash
ansible-playbook -i inventory.ini playbook.yml --check
```

## Accessing Nextcloud

After successful deployment:
- URL: `http://myhost.local:8080`
- Admin username: `admin`
- Admin password: (the one you configured)

## Services

The deployment includes:
- **Nextcloud**: Latest stable version (port 8080)
- **MariaDB**: Database backend
- **Redis**: Caching layer

## Managing the Stack

SSH to the target host and navigate to `/opt/nextcloud`:

```bash
# View logs
docker-compose logs -f

# Stop services
docker-compose down

# Start services
docker-compose up -d

# Restart services
docker-compose restart

# View running containers
docker-compose ps
```

## Updating

To update Nextcloud and services:

```bash
cd /opt/nextcloud
docker-compose pull
docker-compose up -d
```

## Troubleshooting

### Check service status
```bash
ssh myuser@myhost.local
cd /opt/nextcloud
docker-compose ps
docker-compose logs
```

### Check environment file
```bash
sudo cat /opt/nextcloud/.env
```

### Restart services
```bash
cd /opt/nextcloud
docker-compose restart
```

## Security Notes

- Change default passwords before deployment
- The `.env` file contains sensitive credentials (mode 0600)
- Consider using Ansible Vault for production deployments
- Set up HTTPS/SSL for production use
- Configure firewall rules as needed

## Customization

Edit `playbook.yml` to customize:
- Port number (default: 8080)
- Volume paths
- Service versions
- Network configuration
