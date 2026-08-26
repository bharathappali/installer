# Troubleshooting

Common issues and status checks for the Causa RCA stack.
For installation steps, see the [Installation Guide](installation.md).

## Check overall status

```bash
# List all pods
kubectl get pods -n causa-rca

# Watch pod status in real time
kubectl get pods -n causa-rca -w
```

## Component-specific checks

### Kubernetes MCP Server

```bash
kubectl get pods -n causa-rca -l app=kubernetes-mcp-server
kubectl logs -n causa-rca -l app=kubernetes-mcp-server
```

### Causa Backend

```bash
kubectl get pods -n causa-rca -l app=causa-backend
kubectl logs -n causa-rca -l app=causa-backend

# Health check (requires NodePort access)
curl http://localhost:30001/q/health/ready
```

### Jafra MCP Server

```bash
kubectl get pods -n causa-rca -l app=jafra-mcp
kubectl logs -n causa-rca -l app=jafra-mcp
```

### Quarkus MCP Server

```bash
kubectl get pods -n causa-rca -l app=mcp-metrics
kubectl logs -n causa-rca -l app=mcp-metrics
```

### Causa MCP Server

```bash
kubectl get pods -n causa-rca -l app=causa-mcp
kubectl logs -n causa-rca -l app=causa-mcp
```

### PostgreSQL

```bash
kubectl get pods -n causa-rca -l app=postgres
kubectl logs -n causa-rca -l app=postgres

# Verify secrets exist
kubectl get secret causa-db-secrets -n causa-rca
kubectl get secret postgres-credentials -n causa-rca
```

### Kind cluster

```bash
kind get clusters
kubectl cluster-info --context kind-causa-rca
kubectl get nodes
```

## Common errors

### Prerequisites missing

The installer checks for `kubectl`, `docker`/`podman`, `kind`, `curl`, `grep`, `sed`, and `awk` before doing anything. Install any missing tools and rerun.

```bash
# kind — macOS
brew install kind
# or see https://kind.sigs.k8s.io/docs/user/quick-start/#installation
```

### Container runtime not running

```bash
# Docker — macOS: start Docker Desktop from the menu bar
# Docker — Linux
sudo systemctl start docker

# Podman — start the machine
podman machine start
```

### Podman rootless mode

Kind requires rootful Podman. Recreate the machine with rootful mode:

```bash
podman machine stop
podman machine rm
podman machine init --rootful --cpus 4 --memory 4096
podman machine start
```

### Cluster not reachable

```bash
# Verify the cluster exists
kind get clusters

# Switch to the correct context
kubectl config use-context kind-causa-rca

# Recreate if needed
kind delete cluster --name causa-rca
./install.sh
```

### Ports already in use (30000–30005)

After deleting a Kind cluster, gvproxy (Podman/Docker network proxy) may still hold the port bindings.

```bash
# Option 1 — restart the container runtime
podman machine stop && podman machine start
# or restart Docker Desktop

# Option 2 — reuse the existing cluster (installer is idempotent)
./install.sh
```

### Pod stuck in `Pending`

Usually a resource or scheduling issue on the Kind node.

```bash
kubectl describe pod -n causa-rca <pod-name>
kubectl get events -n causa-rca --sort-by='.lastTimestamp'
```

### PostgreSQL not ready

The Causa Backend waits for PostgreSQL before starting. Check:

```bash
kubectl get pods -n causa-rca -l app=postgres
kubectl describe pod -n causa-rca -l app=postgres
```

Ensure the `postgres-credentials` secret was created:

```bash
kubectl get secret postgres-credentials -n causa-rca
```

## Logs

The full installation log is written to `install.log` in the same directory as the script.

```bash
cat install.log
```
