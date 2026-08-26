# Installation Guide

Full installation reference for the Causa RCA Installer.
For a quick start, see the [README](../README.md).

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| `docker` or `podman` | Container runtime for Kind | [docker](https://docs.docker.com/get-docker/) / [podman](https://podman.io/getting-started/installation) |
| `kind` | Local Kubernetes cluster | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| `kubectl` | Kubernetes CLI | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | Kubernetes package manager (required for Prometheus/kube-prometheus-stack) | [helm.sh](https://helm.sh/docs/intro/install/) |
| `curl`, `grep`, `sed`, `awk` | Script utilities | Pre-installed on macOS and most Linux distributions |

> **Podman users:** Kind requires rootful mode. Initialise the machine with:
> ```bash
> podman machine init --rootful --cpus 4 --memory 4096
> podman machine start
> ```

## Default installation

Provisions a Kind cluster and deploys all components into the `causa-rca` namespace.

```bash
git clone https://github.com/causaai/installer.git
cd installer
./install.sh
```

## Custom namespace

```bash
./install.sh -n my-namespace
```

## Dry run

Validates prerequisites and configuration without making any cluster changes:

```bash
./install.sh --dry-run
```

## View all flags

```bash
./install.sh --help
```

See [Configuration](configuration.md) for the full reference.

## Installation order

Components are deployed in this sequence:

1. Kind cluster + local registry
2. Kubernetes MCP Server
3. Jafra MCP Server _(skipped if image not set)_
4. Quarkus MCP Server _(skipped if image not set)_
5. PostgreSQL + pgvector
6. Causa Backend
7. Causa MCP Server

## Uninstallation

Removes all components in reverse order. The Kind cluster is preserved by default.

```bash
# Remove all components, keep cluster
./install.sh --terminate

# Remove all components and delete the cluster
./install.sh --terminate --delete-cluster
```

> Always pass the same flags during uninstallation that you used during installation.

## Re-installation

Uninstall first, then install again:

```bash
./install.sh --terminate
./install.sh
```

## Logs

Installation activity is written to `install.log` in the same directory as the script.

```bash
cat install.log
```
