# Installation Guide

Full installation reference for the Causa RCA Installer.
For a quick start, see the [README](../README.md).

## Prerequisites

### Kind

| Tool | Purpose | Install |
|---|---|---|
| `docker` or `podman` | Container runtime for Kind | [docker](https://docs.docker.com/get-docker/) / [podman](https://podman.io/getting-started/installation) |
| `kind` | Local Kubernetes cluster | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| `kubectl` | Kubernetes CLI | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | Prometheus Stack install | [helm.sh](https://helm.sh/docs/intro/install/) |
| `curl`, `grep`, `sed`, `awk` | Script utilities | Pre-installed on macOS and most Linux distributions |

> **Podman users:** Both rootful and rootless modes are supported. On macOS, ensure the machine is allocated sufficient resources:
> ```bash
> podman machine init --cpus 4 --memory 4096
> podman machine start
> ```

### OpenShift

| Tool | Purpose | Install |
|---|---|---|
| `oc` (preferred) or `kubectl` | Cluster CLI | [OpenShift CLI](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) / [kubectl](https://kubernetes.io/docs/tasks/tools/) |
| `helm`, `curl`, `grep`, `sed`, `awk` | Script utilities | Pre-installed on most Linux distributions |
| `python3` + `PyYAML` | Alertmanager config merge | `pip3 install pyyaml` |

**Cluster prerequisites (must be in place before running the installer):**
- Logged in to the cluster: `oc login <api-url>`
- `cert-manager` installed and running

## Default installation (Kind)

Provisions a Kind cluster and deploys all components into the `causa-rca` namespace.

```bash
git clone https://github.com/causaai/installer.git
cd installer
./install.sh
```

## OpenShift installation

Deploys into an existing OpenShift cluster. No cluster is created — the installer
connects to whichever cluster your current `oc`/`kubectl` context points to.

```bash
./install.sh --target openshift
```

> **Note:** Jafra (Ecosystem + MCP Server) is not supported on OpenShift and is automatically skipped.

The following components are installed on OpenShift:
- Kubernetes MCP Server
- Cryostat MCP Server
- Quarkus MCP Server
- PostgreSQL via CloudNativePG operator
- Causa
- Causa MCP Server
- OpenShift User Workload Monitoring enabled + Alertmanager webhook configured

## Custom namespace

```bash
./install.sh -n my-namespace

# OpenShift
./install.sh --target openshift -n my-namespace
```

## Setting the target Quarkus app URL

The Causa engine connects to the Quarkus application under analysis via
`CAUSA_MCP_QUARKUS_METRICS_BASE_URL`. Set this before running the installer when
you have a known target:

```bash
export CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"
./install.sh
```

If you leave it unset, the installer stamps an empty value that can be updated at any time:

```bash
# Replace causa-rca with your installation namespace if you used -n
kubectl set env deployment/causa-backend -n causa-rca \
  CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-namespace.svc.cluster.local:8080"
```

## Dry run

Validates prerequisites and configuration without making any cluster changes:

```bash
./install.sh --dry-run

# OpenShift
./install.sh --target openshift --dry-run
```

## View all flags

```bash
./install.sh --help
```

See [Configuration](configuration.md) for the full reference.

## Installation order

### Kind

1. Kind cluster + local registry
2. Prometheus Stack (kube-prometheus-stack, `monitoring` namespace)
3. cert-manager (installed from official release manifest via `kubectl apply -f`)
4. Kubernetes MCP Server
5. Cryostat MCP Server
6. Jafra Ecosystem (Controller → Analyzer → Agent) _(skipped if images not set)_
7. Jafra MCP Server _(skipped if image not set)_
8. Quarkus MCP Server _(skipped if image not set)_
9. PostgreSQL + pgvector
10. Causa _(stamps MCP env vars + waits for rollout)_
11. Causa MCP Server

### OpenShift

1. OpenShift User Workload Monitoring enabled + Alertmanager webhook configured
2. Kubernetes MCP Server + Route
3. Cryostat MCP Server
4. Quarkus MCP Server _(skipped if image not set)_
5. PostgreSQL via CloudNativePG operator
6. Causa Backend + Route _(stamps MCP env vars + waits for rollout)_
7. Causa MCP Server + Route

## Uninstallation

### Kind

Removes all components in reverse order. The Kind cluster is preserved by default.

```bash
# Remove all components, keep cluster
./install.sh --terminate

# Remove all components and delete the cluster
./install.sh --terminate --delete-cluster
```

> Always pass the same `-n` and `--cluster-name` flags during uninstallation that you used during installation.

### OpenShift

Removes all installed components and the namespace.

```bash
./install.sh --target openshift --terminate

# Custom namespace
./install.sh --target openshift -n my-namespace --terminate
```

## Re-installation

Uninstall first, then install again:

```bash
# Kind
./install.sh --terminate
./install.sh

# OpenShift
./install.sh --target openshift --terminate
./install.sh --target openshift
```

## Logs

Installation activity is written to `install.log` in the same directory as the script.

```bash
cat install.log
```
