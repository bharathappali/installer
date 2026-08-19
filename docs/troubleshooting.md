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
curl http://localhost:30001/api/v1/healthz
```

### Causa MCP Server

```bash
kubectl get pods -n causa-rca -l app=causa-mcp
kubectl logs -n causa-rca -l app=causa-mcp
```

### Prometheus Stack

```bash
# Check all monitoring pods
kubectl get pods -n monitoring

# Port-forward to access UIs
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
```

### Kind cluster

```bash
kind get clusters
kubectl cluster-info --context kind-causa-rca
kubectl get nodes
```

## Common errors

### Prerequisites missing

The installer checks for `kubectl`, `docker`, `kind`, `helm`, `curl`, `sed`, and `awk` before doing anything. Install any missing tools and rerun.

```bash
# kind — macOS
brew install kind
# or see https://kind.sigs.k8s.io/docs/user/quick-start/#installation

# helm — macOS
brew install helm
# or see https://helm.sh/docs/intro/install/
```

### Docker not running

The `kind` target requires Docker to be running.

```bash
# macOS — start Docker Desktop from the menu bar
# Linux
sudo systemctl start docker
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

### Pod stuck in `Pending`

Usually a resource or scheduling issue on the Kind node.

```bash
kubectl describe pod -n causa-rca <pod-name>
kubectl get events -n causa-rca --sort-by='.lastTimestamp'
```

## Logs

The full installation log is written to `install.log` in the same directory as the script.

```bash
cat install.log
```
