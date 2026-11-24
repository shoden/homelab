# Logs

Every environment can ship its logs to VictoriaLogs on the monitoring hub (dev); you browse them in Grafana
(Explore, data source "VictoriaLogs", LogsQL such as `host:prod AND container_name:nextcloud-app AND error`).

```
every host (with_log_shipper)                 hub (with_monitoring_hub)
vector ── journald (system)
       └─ docker-proxy ── containers  ──────►  victoria-logs :9428  ◄── Grafana (internal network)
          (disk buffer)    HTTPS + basic auth    90 days / 20 GB     (LAN, direct IP, TLS)
```

## Setup

1. Pick a password and store it in SecretSpec, **the same value in every profile**:
   `secretspec set LOGS_INGEST_PASSWORD --profile dev` and again for `prod`.
2. Hub inventory (`inventory/dev/group_vars/nextcloud/main.yml`): `with_log_shipper: true` and
   `logs_tls_hosts: ["<hub IP>"]` (the addresses the other hosts use; they go into the certificate).
3. Every other environment: `with_log_shipper: true` and `logs_hub_url: https://<hub IP>:9428` (no path, an IP).
4. Deploy the hub first (it creates the certificate and starts VictoriaLogs), then the others:
   `./run.sh deploy.yml dev`, `./run.sh deploy.yml prod`.

## Notes

- The hub publishes port 9428 on the LAN (`logs_listen`) with TLS (`logs_tls`, on by default) and basic auth. Never
  forward 9428 on the router. The port also serves VictoriaLogs' own UI (`/select/vmui`), behind the same login. To
  restrict it further, set `logs_listen` to the LAN address or add a firewall rule allowing only the other hosts.
- TLS has no domain, so it is a self-signed certificate (`tasks/logs_tls.yml`) made on the machine you deploy from,
  in `certs/` (gitignored, keep the key private), and copied to the hub and to every shipper. Vector trusts only that
  certificate and checks the address in `logs_hub_url` against it; Grafana gets it inline in its data source. It is
  valid 10 years (`logs_tls_days`) and is reissued when `logs_tls_hosts` changes; to renew it, delete `certs/logs.crt`
  and deploy the hub, then the others (VictoriaLogs and the shippers restart). If the address in `logs_hub_url` is not
  in `logs_tls_hosts`, the shipper logs a certificate error.
- `logs_tls: false` goes back to plain HTTP (then `logs_hub_url` starts with `http://`).
- Fields: `host` (the environment name, like the `host` label of the metrics), `source` (`journal` or `docker`),
  `container_name`, `unit` (systemd unit). Stream fields are those four.
- Vector reads the Docker API through `docker-proxy` (container list and logs only), on a network only Vector
  joins. Do not give other containers access to it: inspecting a container reveals its environment (passwords).
- If the hub or NPM is down, shippers keep up to `log_shipper_buffer_bytes` (1 GiB) on disk and send it later.
- Retention: `logs_retention` (90d) and `logs_max_disk` (20GB); whichever is reached first drops the oldest data.
- Only the journal of the current boot is read on a fresh start, and only directories that exist on the host are
  mounted (`/var/log/journal` and/or `/run/log/journal`).

## Dashboard

Grafana provisions a read-only **Logs** dashboard (`playbooks/files/monitoring/logs.json`, uid `homelab-logs`):
pipeline health (rows ingested, shippers up/down, rows dropped, disk used and % of the cap), ingest rate, events
sent per host, disk vs cap, shipper errors, and, from the VictoriaLogs data source, log volume per host, an
errors panel and the latest logs. The *Shipper host* variable comes from the metrics (host = `monitoring_targets`
name); *Environment* (`dev`, `prod`) filters the log panels by the `host` field of the logs (= `stack_env`).
The dashboard reloads by itself within a minute of a deploy; no restart is needed.

## Alerts (to the same Telegram chat)

They come from metrics, so the existing vmalert evaluates them (rules in `playbooks/files/monitoring/alerts.yml`, group
`logs`). The hub's VictoriaMetrics scrapes VictoriaLogs itself (job `victorialogs`, over the internal network, with
the logs login) and every shipper's Vector (job `vector`, port 9598 on the LAN like node_exporter, from
`monitoring_targets`; an entry with `shipper: false` is skipped).

| Alert | Fires when |
|---|---|
| `LogsNotIngested` | no rows ingested from any host in the last hour |
| `HostNotShippingLogs` | a host's Vector is up but delivered nothing to the hub in the last hour |
| `LogShipperErrors` | a shipper keeps failing to send (wrong password, certificate or address): events are lost |
| `LogShipperDown` / `LogsHubDown` | Vector or VictoriaLogs stop answering to the scrape |
| `LogVolumePeak` | a host logs over 5 times its daily average and over 20 lines per second, for 10 minutes |
| `LogsRowsDropped` | VictoriaLogs drops rows (bad timestamp, too many fields) |
| `LogsStorageReadOnly` | the disk is almost full and VictoriaLogs rejects new logs |
| `LogsNearDiskCap` | the logs use over 90% of `logs_max_disk`, so the oldest are already being dropped |

Tune the thresholds in `alerts.yml`; a deploy restarts vmalert and VictoriaMetrics when it changes. Alerts on the
content of the logs (for example "ssh login failures") would need a second vmalert pointed at VictoriaLogs.
