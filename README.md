# Causa RCA Installer

Deploys the full Causa RCA infrastructure stack in a single command.
Supports two target platforms: a local [Kind](https://kind.sigs.k8s.io/) cluster and an existing [OpenShift](https://www.redhat.com/en/technologies/cloud-computing/openshift) cluster.

## What gets installed

| Component | Kind | OpenShift | Access |
|---|---|---|---|
| Kubernetes MCP Server | ✓ | ✓ | NodePort 30000 (Kind) / Route (OpenShift) |
| Causa Backend | ✓ | ✓ | NodePort 30001 (Kind) / Route (OpenShift) |
| Quarkus MCP Server | ✓ | ✓ | NodePort 30004 (Kind) / Route (OpenShift) |
| Causa MCP Server | ✓ | ✓ | NodePort 30005 (Kind) / Route (OpenShift) |
| PostgreSQL (pgvector) | ✓ | ✓ | ClusterIP — standalone Deployment (Kind) / CloudNativePG operator (OpenShift) |
| Prometheus Stack | ✓ | — | kube-prometheus-stack on Kind; built-in UWM on OpenShift (no install needed) |
| Jafra Ecosystem (Controller + Analyzer + Agent) | ✓ | — | Not supported on OpenShift |
| Jafra MCP Server | ✓ | — | Not supported on OpenShift |

## Prerequisites

### Kind

- [`docker`](https://docs.docker.com/get-docker/) **or** [`podman`](https://podman.io/getting-started/installation) (rootful mode)
- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)
- [`helm`](https://helm.sh/docs/intro/install/) — required for the Prometheus Stack
- `curl`, `grep`, `sed`, `awk` — pre-installed on macOS and most Linux distributions

> **Podman users:** the Podman machine must be started in rootful mode (`podman machine init --rootful`).

### OpenShift

- [`oc`](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) (preferred) or `kubectl`
- `curl`, `grep`, `sed`, `awk`
- An active login to the target cluster (`oc login`)
- `cert-manager` already installed in the cluster
- `python3` with `PyYAML` — required to merge the Alertmanager config (`pip3 install pyyaml`)

## Quickstart

```bash
git clone https://github.com/causaai/installer.git
cd installer

# Kind — provisions a local cluster and deploys all components
./install.sh

# OpenShift — deploys into an existing logged-in cluster
./install.sh --target openshift

# Dry run — validate prerequisites without making changes
./install.sh --dry-run

# Uninstall everything
./install.sh --terminate

# View all CLI flags
./install.sh --help
```

## Target Quarkus app (Quarkus MCP metrics)

The Causa Backend needs to know the URL of the Quarkus application being profiled.
Set this before running the installer if you have a known target app:

```bash
export CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"
./install.sh
```

If not set, the installer leaves this value empty — it can be updated later via:

```bash
# Replace causa-rca with your installation namespace if you used -n
kubectl set env deployment/causa-backend -n causa-rca \
  CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"
```

## Repo layout

```
install.sh          # Entry point — orchestrates all components
lib/
  images.env                  # Default image tags (single source of truth)
  logging.sh                  # Logging helpers and spinner
  install_utils.sh            # Shared helpers, manifest apply/delete, exit codes
  validator.sh                # Pre-flight checks: CLI tools, container runtime, cluster
  install_kind_cluster.sh     # Kind cluster + local registry (kind only)
  install_prometheus.sh       # Prometheus Stack via Helm (kind only)
  enable_monitoring.sh        # OpenShift UWM + Alertmanager webhook config (openshift only)
  install_cert_manager.sh     # cert-manager via official release manifest (kind only)
  install_k8s_mcp.sh          # Kubernetes MCP Server
  install_jafra.sh            # Jafra Ecosystem — kind only
  install_jafra_mcp.sh        # Jafra MCP Server — kind only
  install_quarkus_mcp.sh      # Quarkus MCP Server
  install_postgres.sh         # PostgreSQL — standalone Deployment (kind) / CloudNativePG (openshift)
  install_causa.sh            # Causa Backend
  install_causa_mcp.sh        # Causa MCP Server
manifests/
  k8s_mcp_server.yaml         # Kubernetes MCP Server (NodePort 30000)
  causa/                      # Causa Backend (NodePort 30001, kind)
  jafra/                      # Jafra Ecosystem (kind only)
  jafra_mcp/                  # Jafra MCP Server (NodePort 30003, kind only)
  quarkus_mcp/                # Quarkus MCP Server (NodePort 30004)
  causa_mcp/                  # Causa MCP Server (NodePort 30005)
  postgres/                   # PostgreSQL — kind Deployment + OpenShift CNPG manifests
  openshift/                  # OpenShift-specific manifests (Routes, Causa Backend, monitoring)
  prometheus/                 # PrometheusRule (applied on both targets)
```

## Jafra

**J**VM **A**dvanced **F**light **R**ecording with **A**sync-profiler — a continuous profiling ecosystem for Java workloads running in Kubernetes. Jafra injects [async-profiler](https://github.com/async-profiler/async-profiler) into opted-in Pods without requiring any application changes, collects rotated JFR chunks from the node, and centralises analysis. CPU, allocation, lock, GC, and compilation events land in the same `.jfr` file because the controller defaults to `jfrsync=default` — this is set by the controller, not by the installer.

> **Kind only.** Jafra is not supported on OpenShift. Current release: `v0.0.1`.

### Components

| Component | Repo | Role |
|---|---|---|
| **jafra-controller** | [jafra-controller](https://github.com/bharathappali/jafra-controller) | Go mutating admission webhook. Validates Pod opt-in labels/annotations and injects async-profiler, a recording `hostPath` volume, and `JAVA_TOOL_OPTIONS` into targeted containers. Requires cert-manager for TLS. |
| **jafra-agent** | [jafra-agent](https://github.com/bharathappali/jafra-agent) | Rust DaemonSet. Watches `/var/lib/jafra/recordings` on each node, detects finalized JFR chunks from the 68-byte header, and streams them to the analyzer over gRPC. Deletes closed rotations after acknowledgement. |
| **jafra-analyzer** | [jafra-analyzer](https://github.com/bharathappali/jafra-analyzer) | Quarkus gRPC receiver. Accepts chunk streams, persists them to a PVC, stitches contiguous chunks into per-recording JFR files, and serves JMC-rule analysis and raw event summaries over HTTP. |

### How it works on Kind (v0.0.1)

```
Opted-in Java Pod
    │  labels: jafra.io/enabled=true, jafra.io/mode=continuous
    │  annotations: jafra.io/containers=<name>
    ▼
jafra-controller  (MutatingWebhook)
    │  injects async-profiler agent + hostPath recording volume
    │  appends -agentpath to JAVA_TOOL_OPTIONS
    ▼
/var/lib/jafra/recordings  (node hostPath)
    │  rotated .jfr chunks written by the JVM
    ▼
jafra-agent  (DaemonSet, one per node)
    │  detects finalized chunks via JFR header
    │  streams OpenChunk → ChunkFrame → CommitChunk over gRPC
    ▼
jafra-analyzer  (Deployment, port 9090 gRPC / 8080 HTTP)
    │  persists + stitches chunks on PVC
    │  serves /api/v1/recordings, /report, /summary
    ▼
(optional) Jafra MCP Server  (NodePort 30003)
    └─ exposes JFR summaries and JMC reports from the analyzer to Causa over MCP
```

To opt a Pod in, add to its metadata:

```yaml
labels:
  jafra.io/enabled: "true"
  jafra.io/mode: "continuous"
annotations:
  jafra.io/containers: "<container-name>"
```

### Umbrella repo

[jafra-io](https://github.com/bharathappali/jafra-io) — Kubernetes manifests, the shared `jafra.proto` contract, and git submodules for all three components above.

## Documentation

| Doc | What's in it |
|---|---|
| [Installation Guide](docs/installation.md) | Full install steps, prerequisites, uninstall, reinstall |
| [Configuration](docs/configuration.md) | All CLI flags, env vars, image overrides, and defaults |
| [Architecture](docs/architecture.md) | How the installer works internally, component wiring |
| [Troubleshooting](docs/troubleshooting.md) | Status checks, log locations, common errors |

## Support

Open an issue or raise a PR against the `mvp_demo` branch.
