# Nextcloud Docker Compose Deployment with Ansible

## Objective
Create an Ansible playbook to deploy Nextcloud with MariaDB and Redis using Docker Compose on the myhost.local host.

## Requirements

### Infrastructure
- **Target Host**: myhost.local
- **Ansible Host Configuration**:
  ```ini
  myhost ansible_host=myhost.local ansible_user=myuser ansible_private_key=~/.ssh/id_ed25519
  ```

### Services to Deploy
1. **Nextcloud** - Latest stable version
2. **MariaDB** - Database backend for Nextcloud
3. **Redis** - Caching layer for improved performance

### Implementation Details

#### Docker Compose Setup
- Create a `docker-compose.yml` file with all three services
- Use environment variables from `.env` file for:
  - Database credentials (MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD, MYSQL_DATABASE, MYSQL_USER)
  - Nextcloud admin credentials (NEXTCLOUD_ADMIN_USER, NEXTCLOUD_ADMIN_PASSWORD)
  - Volume paths for persistent storage
  - Redis configuration

#### Ansible Playbook Structure
- Create inventory file with myhost host configuration
- Main playbook should:
  - Ensure Docker and Docker Compose are installed
  - Create necessary directories for volumes
  - Template the `.env` file with credentials
  - Deploy the `docker-compose.yml` file
  - Start the Docker Compose stack
  - Verify services are running

#### Environment Variables (.env template)
The playbook should template an `.env` file with variables for:
- MariaDB root password
- MariaDB database name
- MariaDB user and password
- Nextcloud admin username and password
- Volume paths (nextcloud_data, mariadb_data, redis_data)
- Host paths for persistent storage

#### Volume Management
- Define persistent volumes for:
  - Nextcloud data and config
  - MariaDB data
  - Redis data
- Volumes should be configurable via `.env` file

#### Networking
- All services should be on the same Docker network
- Expose Nextcloud web interface on port 8080 (or configurable)

## Deliverables
1. Ansible inventory file (`inventory.ini`)
2. Ansible playbook (`nextcloud.yml`)
3. Docker Compose file template (`docker-compose.yml.j2`)
4. Environment file template (`.env.j2`)
5. README with deployment instructions
