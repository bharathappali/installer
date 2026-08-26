# Causa RCA Installer

Deploys the full Causa RCA infrastructure stack onto a local [Kind](https://kind.sigs.k8s.io/) cluster in a single command.

> **Scope:** Infrastructure only — Causa Backend and MCP servers.

## What gets installed

| Component | NodePort |
|---|---|
| Kubernetes MCP Server | 30000 |
| Causa Backend | 30001 |
| Jafra MCP Server | 30003 (Kind node only — not mapped to localhost) |
| Quarkus MCP Server | 30004 |
| Causa MCP Server | 30005 |
| PostgreSQL (pgvector) | — (ClusterIP) |

## Prerequisites

- [`docker`](https://docs.docker.com/get-docker/) **or** [`podman`](https://podman.io/getting-started/installation) (rootful mode)
- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)
- `curl`, `grep`, `sed`, `awk` — pre-installed on macOS and most Linux distributions

> **Podman users:** the Podman machine must be started in rootful mode (`podman machine init --rootful`).

## Quickstart

```bash
git clone https://github.com/causaai/installer.git
cd installer

# Full install — provisions Kind cluster and all components
./install.sh

# Dry run — validate prerequisites without making changes
./install.sh --dry-run

# Uninstall everything
./install.sh --terminate

# View all CLI flags
./install.sh --help
```

## Repo layout

```
install.sh          # Entry point — orchestrates all components
lib/
  images.env        # Default image tags (single source of truth)
  logging.sh        # Logging helpers and spinner
  install_utils.sh  # Shared helpers, manifest apply/delete, exit codes
  validator.sh      # Pre-flight checks: CLI tools, container runtime, cluster
  install_kind_cluster.sh   # Kind cluster + local registry
  install_k8s_mcp.sh        # Kubernetes MCP Server
  install_jafra_mcp.sh      # Jafra MCP Server
  install_quarkus_mcp.sh    # Quarkus MCP Server
  install_postgres.sh       # PostgreSQL + pgvector + secrets
  install_causa.sh          # Causa Backend
  install_causa_mcp.sh      # Causa MCP Server
manifests/
  k8s_mcp_server.yaml       # Kubernetes MCP Server (NodePort 30000)
  causa/                    # Causa Backend (NodePort 30001)
  jafra_mcp/                # Jafra MCP Server (NodePort 30003, Kind node only)
  quarkus_mcp/              # Quarkus MCP Server (NodePort 30004)
  causa_mcp/                # Causa MCP Server (NodePort 30005)
  postgres/                 # PostgreSQL + pgvector (ClusterIP)
```

## Documentation

| Doc | What's in it |
|---|---|
| [Installation Guide](docs/installation.md) | Full install steps, prerequisites, uninstall, reinstall |
| [Configuration](docs/configuration.md) | All CLI flags, env vars, image overrides, and defaults |
| [Architecture](docs/architecture.md) | How the installer works internally, component wiring |
| [Troubleshooting](docs/troubleshooting.md) | Status checks, log locations, common errors |

## Support

Open an issue or raise a PR against the `mvp_demo` branch.
