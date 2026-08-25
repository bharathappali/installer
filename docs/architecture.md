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
  validator.sh                          ← pre-flight checks (tools, container runtime, cluster)
  install_kind_cluster.sh               ← Kind cluster + local registry
  install_k8s_mcp.sh                    ← Kubernetes MCP Server
  install_jafra_mcp.sh                  ← Jafra MCP Server
  install_quarkus_mcp.sh                ← Quarkus MCP Server
  install_postgres.sh                   ← PostgreSQL + pgvector + Kubernetes secrets
  install_causa.sh                      ← Causa Backend
  install_causa_mcp.sh                  ← Causa MCP Server
manifests/
  k8s_mcp_server.yaml                   ← Kubernetes MCP Server (NodePort 30000)
  causa/deployment.yaml                 ← Causa Backend (NodePort 30001)
  jafra_mcp/deployment.yaml             ← Jafra MCP Server (NodePort 30003)
  quarkus_mcp/deployment.yaml           ← Quarkus MCP Server (NodePort 30004)
  causa_mcp/deployment.yaml             ← Causa MCP Server (NodePort 30005)
  postgres/deployment.yaml              ← PostgreSQL + pgvector (ClusterIP)
```

## Startup sequence

When `install.sh` is run:

1. Loads default images from `lib/images.env`
2. Parses CLI arguments — flags override env vars which override `lib/images.env`
3. Initialises the log file
4. Runs pre-flight validation (container runtime, tools, cluster access)
5. Deploys components in sequence (see [Installation order](installation.md#installation-order))
6. Runs post-installation health check and prints the access summary

## Image resolution

Every component image is resolved in this priority order:

```
CLI flag  >  exported env var  >  lib/images.env
```

`lib/images.env` uses `${VAR:-value}` syntax, so any value already exported in the environment before the script runs is preserved. There are no hardcoded image fallbacks in the component scripts — `lib/images.env` is the single source of truth.

## Container runtime detection

The validator detects the available container runtime automatically:

1. Prefers **Podman** if `podman` is available and responding
2. Falls back to **Docker**, with a check to detect if `docker` is actually a Podman shim
3. Exports `CONTAINER_RUNTIME` (`docker` or `podman`) for use by the Kind cluster script

> Podman must run in **rootful mode** — rootless Podman is incompatible with Kind.

## PostgreSQL setup

`install_postgres.sh` deploys two Kubernetes Secrets before starting the workload:

| Secret | Keys |
|---|---|
| `postgres-credentials` | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` (used by the Pod) |
| `causa-db-secrets` | `CAUSA_DB_USERNAME`, `CAUSA_DB_PASSWORD`, `CAUSA_DB_URL` (read by Causa Backend) |

The pgvector extension is initialised at startup via a ConfigMap-mounted SQL script.

## Optional components

Jafra MCP Server and Quarkus MCP Server are deployed only when their images are set in `lib/images.env`. If the image variable is empty, the installer skips that component with a warning rather than failing.

## Manifest substitution

Each manifest contains `PLACEHOLDER_NAMESPACE` as the namespace value. The `apply_manifest` helper in `lib/install_utils.sh` substitutes this with `INSTALL_NAMESPACE` at apply time using `sed` before piping to `kubectl apply`.
