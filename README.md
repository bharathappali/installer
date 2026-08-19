# Causa RCA Installer

Deploys the full Causa RCA infrastructure stack onto a local [Kind](https://kind.sigs.k8s.io/) cluster in a single command.

> **Scope:** Infrastructure only — Prometheus, Causa Backend, and MCP servers. End-to-end demo setup (workload + LLM config) lives in [`causa-demos`](https://github.com/causaai/causa-demos).

## What gets installed

| Component | NodePort |
|---|---|
| Prometheus Stack (kube-prometheus-stack) | — |
| Kubernetes MCP Server | 30000 |
| Causa Backend | 30001 |
| Async Profiler | 30002 |
| Async Profiler MCP Server | 30003 |
| Quarkus MCP Server | 30004 |
| Causa MCP Server | 30005 |

## Prerequisites

- [`docker`](https://docs.docker.com/get-docker/)
- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)
- [`helm`](https://helm.sh/docs/intro/install/) v3+
- `curl`, `sed`, `awk` — pre-installed on macOS and most Linux distributions

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
lib/                # One install script per component
  images.env        # Default image tags (single source of truth)
  validator.sh      # Pre-flight checks: CLI tools, cluster, RBAC
manifests/          # Kubernetes resource definitions
  prometheus/       # Alert rules
  causa/            # Causa Backend
  async_profiler/   # Async Profiler
  async_profiler_mcp/  # Async Profiler MCP Server
  quarkus_mcp/      # Quarkus MCP Server
  causa_mcp/        # Causa MCP Server
```

## Documentation

| Doc | What's in it |
|---|---|
| [Installation Guide](docs/installation.md) | Full install steps, prerequisites, uninstall, reinstall |
| [Configuration](docs/configuration.md) | All CLI flags, env vars, image overrides, and defaults |
| [Architecture](docs/architecture.md) | How the installer works internally, component wiring, alert flow |
| [Troubleshooting](docs/troubleshooting.md) | Status checks, log locations, common errors |

## Support

Open an issue or raise a PR against the `mvp_demo` branch.
