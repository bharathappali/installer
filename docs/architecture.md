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
  install_kind_cluster.sh               ← Kind cluster + local registry (kind only)
  install_prometheus.sh                 ← Prometheus Stack via Helm (kind only)
  enable_monitoring.sh                  ← OpenShift UWM + Alertmanager webhook config (openshift only)
  install_cert_manager.sh               ← cert-manager via official release manifest (kind only)
  install_k8s_mcp.sh                    ← Kubernetes MCP Server
  install_cryostat.sh                   ← Cryostat operator + instance
  install_cryostat_mcp.sh               ← Cryostat MCP Server
  install_jafra.sh                      ← Jafra Ecosystem (kind only)
  install_jafra_mcp.sh                  ← Jafra MCP Server (kind only)
  install_quarkus_mcp.sh                ← Quarkus MCP Server
  install_postgres.sh                   ← PostgreSQL — standalone Deployment (kind) / CloudNativePG (openshift)
  install_causa.sh                      ← Causa Backend
  install_causa_mcp.sh                  ← Causa MCP Server
manifests/
  k8s_mcp_server.yaml                   ← Kubernetes MCP Server (NodePort 30000)
  cryostat_cr.yaml                      ← Cryostat custom resource
  cryostat_mcp_server.yaml              ← Cryostat MCP Server (ClusterIP)
  cryostat_mcp_client_rbac.yaml         ← Cryostat MCP client ServiceAccount
  causa/deployment.yaml                 ← Causa Backend (NodePort 30001, kind)
  jafra/                                ← Jafra Ecosystem (kind only)
  jafra_mcp/deployment.yaml             ← Jafra MCP Server (NodePort 30003, kind only)
  quarkus_mcp/deployment.yaml           ← Quarkus MCP Server (NodePort 30004)
  causa_mcp/deployment.yaml             ← Causa MCP Server (NodePort 30005)
  postgres/                             ← kind Deployment + OpenShift CNPG operator manifests
  openshift/                            ← OpenShift-specific manifests (Routes, Causa Backend, monitoring)
  prometheus/                           ← PrometheusRule (applied on both targets)
```

## Startup sequence

When `install.sh` is run:

1. Loads default images from `lib/images.env`
2. Parses CLI arguments — flags override env vars which override `lib/images.env`
3. Initialises the log file
4. Runs pre-flight validation (container runtime, tools, cluster access)
5. Deploys components in sequence (see [Installation order](installation.md#installation-order))
6. Runs post-installation health check and prints the access summary

## Target-specific behaviour

The `--target` flag (default: `kind`) controls which infrastructure steps run:

| Step | Kind | OpenShift |
|---|---|---|
| Cluster provisioning | Creates Kind cluster + local registry | Skipped — connects to existing cluster |
| Prometheus | Installs kube-prometheus-stack via Helm | Skipped — uses built-in UWM |
| cert-manager | Installs from official release manifest | Must be pre-installed (validated before deploy) |
| Alertmanager webhook | Configured via kube-prometheus-stack | Configured via UWM Secret or platform Alertmanager patch |
| Jafra Ecosystem | Deployed (if images set) | Skipped — not supported |
| Jafra MCP Server | Deployed (if image set) | Skipped — not supported |
| PostgreSQL | Standalone Deployment + pgvector | CloudNativePG operator via OLM Subscription |
| Causa Backend | NodePort Service | Deployment + OpenShift Route |
| Kubernetes MCP Server | NodePort Service | Deployment + OpenShift Route |
| Cryostat | Operator bundle via `operator-sdk`; OLM installed if missing | Operator bundle via `operator-sdk` (OLM is built in) |
| Cryostat MCP Server | ClusterIP, installed only when Cryostat is present | ClusterIP, installed only when Cryostat is present |
| Quarkus MCP Server | NodePort Service | ClusterIP (OpenShift) |
| Causa MCP Server | NodePort Service | Deployment + OpenShift Route |

## Image resolution

Every component image is resolved in this priority order:

```
CLI flag  >  exported env var  >  lib/images.env
```

`lib/images.env` uses `${VAR:-value}` syntax, so any value already exported in the environment before the script runs is preserved. There are no hardcoded image fallbacks in the component scripts — `lib/images.env` is the single source of truth.

## Container runtime detection (kind only)

The validator detects the available container runtime automatically:

1. Prefers **Podman** if `podman` is available and responding
2. Falls back to **Docker**, with a check to detect if `docker` is actually a Podman shim
3. Exports `CONTAINER_RUNTIME` (`docker` or `podman`) for use by the Kind cluster script

## PostgreSQL setup

### Kind — standalone Deployment

`install_postgres.sh` deploys two Kubernetes Secrets before starting the workload:

| Secret | Keys |
|---|---|
| `postgres-credentials` | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` (used by the Pod) |
| `causa-db-secrets` | `CAUSA_DB_USERNAME`, `CAUSA_DB_PASSWORD`, `CAUSA_DB_URL` (read by Causa) |

The pgvector extension is initialised at startup via a ConfigMap-mounted SQL script.

### OpenShift — CloudNativePG operator

`install_postgres.sh` installs the CloudNativePG operator via OLM (Subscription + InstallPlan approval), then applies the `iri-db` Cluster CRD. Once the cluster is healthy, credentials are read from the CNPG-generated `iri-db-app` Secret and re-exposed as the `causa-db-secrets` Secret that Causa reads.

## OpenShift monitoring

On OpenShift, `enable_monitoring.sh` handles Prometheus integration instead of installing a separate stack:

1. Enables User Workload Monitoring (UWM) by patching `cluster-monitoring-config`
2. Detects the Alertmanager topology:
   - **Topology A** — UWM Alertmanager present (`alertmanager-user-workload`): configures it directly via its own Secret
   - **Topology B** — platform Alertmanager only (`alertmanager-main`): merges the `causa-webhook` receiver into the existing config using `python3` + PyYAML
3. Applies a `PrometheusRule` with Causa alert definitions
4. Applies a `NetworkPolicy` allowing Alertmanager and the OpenShift ingress router to reach Causa on port 8080

## Causa — MCP endpoint configuration

After the Causa deployment becomes ready, `install_causa.sh` stamps three env vars
onto the running deployment using `kubectl set env` (idempotent — safe on every re-run):

| Env var | Value | Source |
|---|---|---|
| `CAUSA_MCP_QUARKUS_ENDPOINT` | `http://mcp-metrics.<ns>.svc.cluster.local:8080` | Derived from `INSTALL_NAMESPACE` |
| `CAUSA_MCP_QUARKUS_METRICS_BASE_URL` | user-supplied URL | `CAUSA_MCP_QUARKUS_METRICS_BASE_URL` env var (default: `""`) |
| `CAUSA_MCP_ASYNC_PROFILER_ENDPOINT` | `http://jafra-mcp.<ns>.svc.cluster.local:8083` | Derived from `INSTALL_NAMESPACE` |
| `JAFRA_ANALYZER_URL` | `http://jafra-analyzer.<ns>.svc.cluster.local:8080` | Derived from `INSTALL_NAMESPACE` |

`kubectl set env` triggers a new rollout. The installer then waits up to 180 s for
`kubectl rollout status deployment/causa-backend` to confirm the pods are running the
new configuration before proceeding.

## Manifest substitution

Each manifest contains placeholder tokens that are substituted at apply time using `sed`:

| Placeholder | Replaced with |
|---|---|
| `PLACEHOLDER_NAMESPACE` | `INSTALL_NAMESPACE` |
| `PLACEHOLDER_CLUSTER_TYPE` | `INSTALL_TARGET` (e.g. `kind` or `openshift`) |
| `PLACEHOLDER_QUARKUS_METRICS_BASE_URL` | `CAUSA_MCP_QUARKUS_METRICS_BASE_URL` (may be empty) |

The standard `apply_manifest` helper in `lib/install_utils.sh` handles `PLACEHOLDER_NAMESPACE`
and `PLACEHOLDER_CLUSTER_TYPE`. The `PLACEHOLDER_QUARKUS_METRICS_BASE_URL` substitution is
applied automatically for the Causa manifests during installation.

## Optional components

The Jafra Ecosystem, Jafra MCP Server, and Quarkus MCP Server are deployed only when their
images are set in `lib/images.env`. If any required image variable is empty, the installer
skips that component with a warning rather than failing.

Jafra (Ecosystem + MCP Server) is additionally gated by target: these components are
**skipped entirely on OpenShift** regardless of image settings.
