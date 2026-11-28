/*
 * C4 model of the homelab (Structurizr DSL). Render with ../../architecture.sh (see README.md here).
 *
 * Host/domain agnostic on purpose: no IPs, domains or credentials. Container names are the ones of prod
 * (derived from `stack_name` in playbooks/group_vars/all/defaults.yml). Update this file when you add a
 * service or a `with_*` flag.
 */
workspace "Homelab" "Self-hosted Nextcloud stack with monitoring and logging, deployed with Ansible." {

    !identifiers hierarchical

    model {
        operator = person "Operator" "Runs the playbooks from the control machine."
        user = person "User" "Uses Nextcloud from a browser, the desktop or the mobile app (web and WebDAV)."

        # --- External systems -----------------------------------------------------------------
        letsencrypt = softwareSystem "Let's Encrypt" "Issues the TLS certificate (DNS-01 challenge)." "External"
        ovh = softwareSystem "OVH DNS" "Holds the domain's DNS zone; receives the DNS-01 challenge records." "External"
        telegram = softwareSystem "Telegram" "Receives deploy audit messages and monitoring alerts." "External"
        github = softwareSystem "GitHub / Renovate" "Hosts the repository; Renovate proposes container image updates." "External"
        secretspec = softwareSystem "SecretSpec" "Credential store on the control machine, one profile per environment." "External"

        # --- The Nextcloud stack: one per environment, each on its own host ---------------------
        stack = softwareSystem "Nextcloud stack" "Nextcloud with its database, cache and TLS proxy, plus the host's monitoring and log agents. One instance per environment." {
            proxy = container "nextcloud-proxy" "TLS-terminating reverse proxy (80/443, admin UI on 81). Configured through its REST API by deploy.yml." "Nginx Proxy Manager" "Optional,Proxy"
            app = container "nextcloud-app" "Nextcloud; readiness is status.php." "Nextcloud (Apache)"
            db = container "nextcloud-mariadb" "Nextcloud's database; also holds the proxy's configuration." "MariaDB" "Database"
            redis = container "nextcloud-redis" "File locking and sessions." "Redis" "Database"
            nodeExporter = container "nextcloud-node-exporter" "Host metrics on port 9100 (host network)." "node-exporter" "Optional"
            vector = container "nextcloud-vector" "Ships journald and container logs; disk buffer, HTTPS + basic auth." "Vector" "Optional"
            dockerProxy = container "nextcloud-docker-proxy" "Read-only Docker socket proxy (CONTAINERS=1) on an internal network, so Vector can read container logs." "tecnativa/docker-socket-proxy" "Optional"
            unit = container "nextcloud-stack.service" "systemd oneshot unit: docker-compose up -d at boot, down at shutdown. Restarted by a deploy only if its config changed." "systemd, docker-compose" "Lifecycle"

            user -> proxy "Browses and syncs" "HTTPS 443"
            proxy -> app "Proxies to" "HTTP 80"
            app -> db "Reads and writes" "SQL"
            app -> redis "Locks and sessions" "Redis"
            proxy -> db "Stores its config" "SQL"
            vector -> dockerProxy "Reads container logs" "HTTP, logs-network"
        }

        # --- Monitoring hub: only the hub environment (dev), with_monitoring_hub -----------------
        hub = softwareSystem "Monitoring hub" "Metrics, logs, alerting and dashboards for all environments. Runs only on the hub environment (with_monitoring_hub)." {
            metrics = container "nextcloud-victoria-metrics" "Scrapes the node-exporters and Vector, and VictoriaLogs' own metrics." "VictoriaMetrics" "Database"
            logs = container "nextcloud-victoria-logs" "Stores the shipped logs (retention and disk cap configurable). TLS (self-signed) + basic auth on 9428 (LAN only)." "VictoriaLogs" "Database"
            vmalert = container "nextcloud-vmalert" "Evaluates the alert rules (alerts.yml, including log alerts derived from metrics)." "vmalert"
            alertmanager = container "nextcloud-alertmanager" "Routes alerts to Telegram." "Alertmanager"
            grafana = container "nextcloud-grafana" "Dashboards (provisioned, read-only) over metrics and logs; behind the proxy at its own domain." "Grafana"

            vmalert -> metrics "Queries rules"
            vmalert -> alertmanager "Fires alerts"
            grafana -> metrics "Queries" "HTTP"
            grafana -> logs "Queries" "HTTPS, basic auth"
            metrics -> logs "Scrapes metrics" "HTTPS, basic auth"
        }

        # --- Deployment tooling: the control machine -----------------------------------------------
        tooling = softwareSystem "Deployment tooling" "Ansible project that deploys and operates the stacks over SSH." {
            runsh = container "run.sh" "Picks the playbook and environment (fzf), runs it inside `secretspec run`. release_branch: deploys a branch to dev, merges it into main, deploys prod." "Bash"
            playbooks = container "Ansible playbooks" "deploy, backup, restore, reboot, shutdown, maintenance_on/off, e2e. Flat project, no roles." "Ansible" {
                checks = component "Preflight checks" "Asserts stack_env, domains, passwords (and their allowed characters) are set and not placeholders." "deploy.yml pre_tasks"
                render = component "Config rendering" "env.j2, docker-compose.yml.j2, HSTS conf, vector/monitoring config; flags a restart only if a file changed." "Jinja2 templates"
                lifecycle = component "Stack lifecycle" "Pulls images, (re)starts the systemd unit, waits for Nextcloud (status.php)." "systemd, wait_nextcloud.yml"
                npmTasks = component "Proxy and certificate" "Idempotently creates the Let's Encrypt certificate and proxy hosts through NPM's REST API." "npm.yml, npm_proxy_host.yml"
                settings = component "Nextcloud settings" "config:system read-then-write, test account, optional repair and index jobs." "occ, repair_nextcloud.yml"
                e2e = component "End-to-end test" "Playwright (Chromium): log in, upload, check over WebDAV, delete. Runs only if something relevant changed." "e2e.yml"
                audit = component "Deploy audit" "Keeps the deployed commit on the host. Sends deploy OK / FAILED (commit linked to GitHub, branch if not main, new commits, failed task) to Telegram. Only main can be deployed to prod." "audit_deploy.yml, telegram_notify.yml"
            }
            e2eTests = container "Playwright project" "Browser test of the deployed environment (e2e/)." "Playwright, Chromium"
            logsTls = container "Logs certificate" "Self-signed certificate for VictoriaLogs, created in certs/ and copied to the hub and each shipper." "OpenSSL" "Optional"
            backups = container "Backups" "On each host in backup_dir (outside the base dir): DB dump, Nextcloud volume (no user files), proxy data, config. Pruned to backup_keep." "Directory" "Database"

            operator -> runsh "Runs" "./run.sh deploy.yml prod"
            runsh -> playbooks "Starts, with credentials as environment variables"
            playbooks.checks -> playbooks.render "Then"
            playbooks.render -> playbooks.lifecycle "Then"
            playbooks.lifecycle -> playbooks.npmTasks "Then"
            playbooks.npmTasks -> playbooks.settings "Then"
            playbooks.settings -> playbooks.e2e "Then"
            playbooks.e2e -> playbooks.audit "Then"
            playbooks.e2e -> e2eTests "Runs on the control machine"
            playbooks.render -> logsTls "Generates"
            runsh -> secretspec "Gets credentials" "secretspec run --profile"
        }

        # --- Relationships across systems ---------------------------------------------------------
        tooling.playbooks -> stack.unit "Installs, restarts, stops" "SSH, sudo"
        tooling.playbooks -> stack.app "occ commands, maintenance mode, backup, restore" "docker exec over SSH"
        tooling.playbooks -> stack.db "Dumps and restores" "docker exec over SSH"
        tooling.playbooks -> stack.proxy "Creates certificate and proxy hosts" "REST API"
        tooling.playbooks -> tooling.backups "Writes and prunes" "SSH"
        tooling.playbooks -> hub.grafana "Provisions dashboards and data sources" "Files over SSH"
        tooling.playbooks -> hub.alertmanager "Provisions configuration" "Files over SSH"
        tooling.playbooks -> telegram "Deploy OK / FAILED" "HTTPS"
        tooling.e2eTests -> stack.proxy "Logs in, uploads, checks WebDAV, deletes" "HTTPS"

        stack.proxy -> letsencrypt "Requests certificate" "ACME"
        stack.proxy -> ovh "DNS-01 challenge records" "HTTPS API"
        stack.proxy -> hub.grafana "Proxies to" "HTTP"
        user -> hub.grafana "Browses dashboards" "HTTPS"

        hub.metrics -> stack.nodeExporter "Scrapes, per environment" "HTTP 9100"
        stack.vector -> hub.logs "Ships logs, per environment" "HTTPS 9428, basic auth"
        hub.metrics -> stack.vector "Scrapes Vector's metrics" "HTTP 9598"
        hub.alertmanager -> telegram "Sends alerts" "HTTPS"

        github -> tooling "Renovate opens pull requests for image tags" "Pull request"

        # --- Deployment: one environment per host -------------------------------------------------
        prod = deploymentEnvironment "prod" {
            deploymentNode "Prod host" "One machine. Debian/Ubuntu, Docker, docker-compose." "Linux" {
                deploymentNode "Docker" "All containers on the nextcloud-network bridge (logs-network for the socket proxy)." "docker-compose" {
                    containerInstance stack.proxy
                    containerInstance stack.app
                    containerInstance stack.db
                    containerInstance stack.redis
                    containerInstance stack.nodeExporter
                    containerInstance stack.vector
                    containerInstance stack.dockerProxy
                }
                infrastructureNode "nextcloud-stack.service" "Starts the stack at boot." "systemd"
            }
            deploymentNode "Monitoring hub host" "The dev host. Receives this host's metrics and logs." "Linux" {
                infrastructureNode "Monitoring hub" "Victoria-metrics scrapes this host; Vector ships logs to victoria-logs." "see the dev environment"
            }
        }

        dev = deploymentEnvironment "dev" {
            deploymentNode "Dev host (monitoring hub)" "One machine. Runs the full stack and the monitoring hub." "Linux" {
                deploymentNode "Docker" "All containers on the nextcloud-network bridge (logs-network for the socket proxy)." "docker-compose" {
                    containerInstance stack.proxy
                    containerInstance stack.app
                    containerInstance stack.db
                    containerInstance stack.redis
                    containerInstance stack.nodeExporter
                    containerInstance stack.vector
                    containerInstance stack.dockerProxy
                    containerInstance hub.metrics
                    containerInstance hub.logs
                    containerInstance hub.vmalert
                    containerInstance hub.alertmanager
                    containerInstance hub.grafana
                }
                infrastructureNode "nextcloud-stack.service" "Starts the stack and the hub at boot." "systemd"
            }
        }
    }

    views {
        systemContext stack "SystemContext" "Who and what the homelab talks to." {
            include *
            exclude hub
            autoLayout lr
        }

        container stack "NextcloudStack" "The Nextcloud stack of one environment, and how the outside reaches it." {
            include *
            exclude hub
            autoLayout lr
        }

        container hub "MonitoringAndLogs" "Metrics, logs and alerts across environments." {
            include *
            include stack.nodeExporter stack.vector
            autoLayout lr
        }

        container tooling "DeploymentTooling" "What runs on the control machine and what it touches." {
            include *
            autoLayout lr
        }

        component tooling.playbooks "DeployFlow" "The steps of deploy.yml, in order. All of it runs inside one block with an audit in its rescue." {
            include *
            autoLayout tb
        }

        deployment * prod "DeploymentProd" "Prod: one host with the full stack; metrics and logs go to the hub." {
            include *
            autoLayout lr
        }

        deployment * dev "DeploymentDev" "Dev: one host with the full stack and the monitoring hub." {
            include *
            autoLayout lr
        }

        dynamic tooling "BackupFlow" "backup.yml: a verified backup of one environment (restore.yml takes a pre-restore snapshot the same way)." {
            operator -> tooling.runsh "./run.sh backup.yml prod"
            tooling.runsh -> tooling.playbooks "Runs backup.yml"
            tooling.playbooks -> stack.app "Maintenance mode on"
            tooling.playbooks -> stack.db "Dump (MYSQL_PWD read inside the container)"
            tooling.playbooks -> tooling.backups "Archive volume, proxy data, config into <ts>.partial"
            tooling.playbooks -> tooling.backups "Rename to <ts>, prune to backup_keep"
            tooling.playbooks -> stack.app "Maintenance mode off (always, if it turned it on)"
            autoLayout lr
        }

        styles {
            element "Person" {
                shape Person
                background #1f4e79
                color #ffffff
            }
            element "Software System" {
                background #2b6cb0
                color #ffffff
            }
            element "External" {
                background #8a8f98
                color #ffffff
            }
            element "Container" {
                background #3f84c6
                color #ffffff
            }
            element "Component" {
                background #7fb2e5
                color #0b2239
            }
            element "Database" {
                shape Cylinder
            }
            element "Optional" {
                border dashed
            }
            element "Infrastructure Node" {
                background #ffffff
                color #333333
            }
            relationship "Relationship" {
                thickness 2
            }
        }
    }

}
