# Architecture diagrams

C4 model of the homelab in the [Structurizr DSL](https://docs.structurizr.com/dsl): one source,
[`workspace.dsl`](workspace.dsl). Everything runs in Docker through `../../architecture.sh`.

```bash
./architecture.sh serve     # edit and browse live at http://localhost:8080 (PORT=... to change)
./architecture.sh check     # validate the DSL (CI does this)
./architecture.sh export    # regenerate diagrams/ and diagrams.md
./architecture.sh site      # self-contained interactive site in site/ (gitignored): open site/index.html, works offline
```

Generated output is committed, so GitHub shows it without tooling: [diagrams.md](diagrams.md) (Mermaid, rendered by
GitHub) and [diagrams/](diagrams/) (`.svg` via PlantUML, `.mmd` Mermaid sources). Never edit them by hand: change
the DSL and run `export`. CI fails if they are out of date.

| View | C4 level | Shows |
|---|---|---|
| SystemContext | 1 | Operator, user and the external services |
| NextcloudStack | 2 | Proxy, Nextcloud, MariaDB, Redis, agents of one environment |
| MonitoringAndLogs | 2 | The hub (metrics, logs, alerts, Grafana) and what feeds it |
| DeploymentTooling | 2 | `run.sh`, the playbooks, Playwright, backups, SecretSpec |
| DeployFlow | 3 | The steps of `deploy.yml` and its audit |
| DeploymentProd, DeploymentDev | deployment | Which containers run on which host |
| BackupFlow | dynamic | The sequence of `backup.yml` |

## Conventions

- Host/domain agnostic, like the rest of the repo: no IPs, domains or credentials in the DSL.
- Container names are prod's (derived from `stack_name`).
- Dashed border = optional (`with_proxy`, `with_node_exporter`, `with_log_shipper`, ...). Grey = external system.
- When you add a service or a `with_*` flag, update `workspace.dsl` and run `./architecture.sh export`.
- The image tags in `architecture.sh` can be overridden with `STRUCTURIZR_IMAGE` and `PLANTUML_IMAGE`.
