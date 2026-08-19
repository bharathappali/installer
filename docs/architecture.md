# Architecture

How the Causa RCA Installer works internally.
For installation steps, see the [Installation Guide](installation.md).

## Overview

The installer is a modular Bash project. A single entry point orchestrates the deployment by delegating each component to its own dedicated script. No component script is aware of the others — all coordination happens in the main orchestrator.

```
install.sh                              ← entry point, orchestrates everything
lib/
  images.env                            ← default image tags, sourced at startup
  logging.sh                            ← logging utilities and spinner
  install_utils.sh                      ← shared helpers, exit codes, error handling
  validator.sh                          ← pre-flight checks (tools, cluster, RBAC)
  install_kind_cluster.sh               ← Kind cluster + local registry
  install_prometheus.sh                 ← kube-prometheus-stack + Alertmanager webhook
  install_k8s_mcp.sh                    ← Kubernetes MCP Server
  install_causa.sh                      ← Causa Backend
  install_async_profiler.sh             ← Async Profiler
  install_async_profiler_mcp.sh         ← Async Profiler MCP Server
  install_quarkus_mcp.sh                ← Quarkus MCP Server
  install_causa_mcp.sh                  ← Causa MCP Server
manifests/
  prometheus/prometheusrule.yaml        ← workload-agnostic alert rules
  k8s_mcp_server.yaml                   ← Kubernetes MCP Server (NodePort 30000)
  causa/deployment.yaml                 ← Causa Backend (NodePort 30001)
  async_profiler/deployment.yaml        ← Async Profiler (NodePort 30002)
  async_profiler_mcp/deployment.yaml    ← Async Profiler MCP Server (NodePort 30003)
  quarkus_mcp/deployment.yaml           ← Quarkus MCP Server (NodePort 30004)
  causa_mcp/deployment.yaml             ← Causa MCP Server (NodePort 30005)
```

## Startup sequence

When `install.sh` is run:

1. Loads default images from `lib/images.env`
2. Parses CLI arguments — flags override env vars which override `lib/images.env`
3. Initialises the log file
4. Runs pre-flight validation (tools, Docker, cluster access, RBAC)
5. Deploys components in sequence (see [Installation order](installation.md#installation-order))
6. Runs post-installation health check and prints the access summary

## Image resolution

Every component image is resolved in this priority order:

```
CLI flag  >  exported env var  >  lib/images.env
```

`lib/images.env` uses `${VAR:-value}` syntax, so any value already exported in the environment before the script runs is preserved. There are no hardcoded image fallbacks in the component scripts — `lib/images.env` is the single source of truth.

## Target platforms

The installer selects which infrastructure steps to run based on `--target`:

| Target | Kind cluster | Prometheus stack |
|---|---|---|
| `kind` (default) | ✅ Provisioned | ✅ Installed |

Additional targets (e.g. `openshift`, `vm`) are planned for future releases.

## Alert flow

On the `kind` target, Alertmanager is configured to POST to Causa Backend when any alert fires:

```
Pod OOMKill / CrashLoop / CPU throttle
  → Prometheus evaluates PrometheusRule
  → Alertmanager fires
  → POST http://causa-backend.<namespace>.svc.cluster.local:8080/api/v1/alerts
  → Causa Backend starts RCA
  → AI agent calls list_diagnostics / get_diagnostic via Causa MCP Server
```

## Manifest substitution

Each manifest contains `PLACEHOLDER_NAMESPACE` as the namespace value. The `apply_manifest` helper in `lib/install_utils.sh` substitutes this with `INSTALL_NAMESPACE` at apply time using `sed` before piping to `kubectl apply`.
