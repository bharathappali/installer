# Configuration

All configuration options for the Causa RCA Installer — CLI flags, environment variables, and image overrides.
For installation steps, see the [Installation Guide](installation.md).

## CLI flags

| Flag | Default | Description |
|---|---|---|
| `--target TARGET` | `kind` | Target platform (`kind`) |
| `-n, --namespace NAMESPACE` | `causa-rca` | Namespace for all components |
| `-t, --terminate` | — | Uninstall all components |
| `--delete-cluster` | — | Also delete the Kind cluster when terminating |
| `--dry-run` | — | Validate without making changes |
| `--cluster-name NAME` | `causa-rca` | Kind cluster name |
| `--registry-port PORT` | `5001` | Local registry host port |
| `-h, --help` | — | Print usage |

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `INSTALL_TARGET` | `kind` | Target platform |
| `INSTALL_NAMESPACE` | `causa-rca` | Namespace for all components |
| `KIND_CLUSTER_NAME` | `causa-rca` | Kind cluster name |
| `KIND_REGISTRY_PORT` | `5001` | Local registry host port |
| `DRY_RUN` | `false` | Set to `true` to validate without installing |
| `TERMINATE` | `false` | Set to `true` to uninstall |
| `DELETE_CLUSTER` | `false` | Set to `true` to delete cluster on terminate |
| `PROMETHEUS_NAMESPACE` | `monitoring` | Namespace for kube-prometheus-stack |

## Image overrides

Default images are defined in [`lib/images.env`](../lib/images.env) — the single source of truth for all image defaults.

Priority order (highest to lowest):
1. CLI flag
2. Exported environment variable
3. Value in `lib/images.env`

### CLI flags

| Flag | Component |
|---|---|
| `--k8s-mcp-server-image IMAGE` | Kubernetes MCP Server |
| `--causa-backend-image IMAGE` | Causa Backend |
| `--async-profiler-image IMAGE` | Async Profiler |
| `--async-profiler-mcp-image IMAGE` | Async Profiler MCP Server |
| `--quarkus-mcp-image IMAGE` | Quarkus MCP Server |
| `--causa-mcp-image IMAGE` | Causa MCP Server |

### Environment variables

| Variable | Component |
|---|---|
| `K8S_MCP_SERVER_IMAGE` | Kubernetes MCP Server |
| `CAUSA_BACKEND_IMAGE` | Causa Backend |
| `ASYNC_PROFILER_IMAGE` | Async Profiler |
| `ASYNC_PROFILER_MCP_IMAGE` | Async Profiler MCP Server |
| `QUARKUS_MCP_IMAGE` | Quarkus MCP Server |
| `CAUSA_MCP_IMAGE` | Causa MCP Server |

### Examples

```bash
# Override a component image
./install.sh --causa-mcp-image quay.io/causaai/causa-mcp:v0.1.0

# Override multiple images
./install.sh \
  --async-profiler-image     quay.io/causaai/async-profiler:v0.1.0 \
  --async-profiler-mcp-image quay.io/causaai/async-profiler-mcp:v0.1.0 \
  --quarkus-mcp-image        quay.io/causaai/quarkus-mcp:v0.1.0

# Override via environment variable
export CAUSA_MCP_IMAGE=quay.io/causaai/causa-mcp:v0.1.0
./install.sh
```

### Image validation

Every image value is validated before use:

- Must contain a tag (e.g. `:v0.1.0` or `:latest`)
- No spaces or shell-special characters (`;`, `|`, `&`, `$`, `` ` ``, etc.)
- Maximum 255 characters
