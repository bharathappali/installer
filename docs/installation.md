# Installation Guide

Full installation reference for the Causa RCA Installer.
For a quick start, see the [README](../README.md).

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| `docker` | Container runtime for Kind | [docs.docker.com](https://docs.docker.com/get-docker/) |
| `kind` | Local Kubernetes cluster | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| `kubectl` | Kubernetes CLI | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | Kubernetes package manager (v3+) | [helm.sh](https://helm.sh/docs/intro/install/) |
| `curl`, `sed`, `awk` | Script utilities | Pre-installed on macOS and most Linux distributions |

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
2. Prometheus Stack (kube-prometheus-stack + Alertmanager webhook)
3. Kubernetes MCP Server
4. Causa Backend
5. Async Profiler
6. Async Profiler MCP Server
7. Quarkus MCP Server
8. Causa MCP Server

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
