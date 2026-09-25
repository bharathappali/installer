# Configuration

All configuration options for the Causa RCA Installer — CLI flags, environment variables, and image overrides.
For installation steps, see the [Installation Guide](installation.md).

## CLI flags

| Flag | Default | Description |
|---|---|---|
| `--target TARGET` | `kind` | Target platform: `kind` or `openshift` |
| `-n, --namespace NAMESPACE` | `causa-rca` | Namespace for all components |
| `-t, --terminate` | — | Uninstall all components |
| `--delete-cluster` | — | Also delete the Kind cluster when terminating (kind only) |
| `--dry-run` | — | Validate without making changes |
| `--cluster-name NAME` | `causa-rca` | Kind cluster name (kind only) |
| `--registry-port PORT` | `5001` | Local registry host port (kind only) |
| `-h, --help` | — | Print usage |

## Environment variables

### General

| Variable | Default | Description |
|---|---|---|
| `INSTALL_TARGET` | `kind` | Target platform: `kind` or `openshift` |
| `INSTALL_NAMESPACE` | `causa-rca` | Namespace for all components |
| `KUBE_CLI` | `kubectl` | kubectl binary to use (set to `oc` automatically when `oc` is detected on OpenShift) |
| `DRY_RUN` | `false` | Set to `true` to validate without installing |
| `TERMINATE` | `false` | Set to `true` to uninstall |
| `DELETE_CLUSTER` | `false` | Set to `true` to delete cluster on terminate (kind only) |

### Kind-specific

| Variable | Default | Description |
|---|---|---|
| `KIND_CLUSTER_NAME` | `causa-rca` | Kind cluster name |
| `KIND_REGISTRY_PORT` | `5001` | Local registry host port |
| `PROMETHEUS_NAMESPACE` | `monitoring` | Namespace where kube-prometheus-stack is installed |

### Causa endpoint configuration

| Variable | Default | Description |
|---|---|---|
| `CAUSA_MCP_QUARKUS_METRICS_BASE_URL` | `""` | Base URL of the Quarkus app under analysis (e.g. `http://my-app.default.svc.cluster.local:8080`). Leave empty if unknown at install time — set via `kubectl set env` afterwards. |

The following two endpoints are derived automatically from `INSTALL_NAMESPACE` and do not need to be set:

| Env var stamped on deployment | Value |
|---|---|
| `CAUSA_MCP_QUARKUS_ENDPOINT` | `http://mcp-metrics.<namespace>.svc.cluster.local:8080` |
| `CAUSA_MCP_ASYNC_PROFILER_ENDPOINT` | `http://jafra-mcp.<namespace>.svc.cluster.local:8083` |
| `JAFRA_ANALYZER_URL` | `http://jafra-analyzer.<namespace>.svc.cluster.local:8080` |

## Image overrides

Default images are defined in [`lib/images.env`](../lib/images.env) — the single source of truth for all image defaults.

Priority order (highest to lowest):
1. CLI flag
2. Exported environment variable
3. Value in `lib/images.env`

### CLI flags

| Flag | Component | Target |
|---|---|---|
| `--k8s-mcp-server-image IMAGE` | Kubernetes MCP Server | both |
| `--cryostat-mcp-server-image IMAGE` | Cryostat MCP Server | both |
| `--cryostat-auth-token TOKEN` | Cryostat MCP bearer token (minted if omitted) | both |
| `--causa-backend-image IMAGE` | Causa | both |
| `--quarkus-mcp-image IMAGE` | Quarkus MCP Server | both |
| `--causa-mcp-image IMAGE` | Causa MCP Server | both |
| `--postgres-kind-image IMAGE` | PostgreSQL (Kind — pgvector-enabled image) | kind only |
| `--postgres-ocp-image IMAGE` | PostgreSQL (OpenShift — CloudNativePG image) | openshift only |
| `--jafra-mcp-image IMAGE` | Jafra MCP Server | kind only |
| `--jafra-controller-image IMAGE` | Jafra Controller | kind only |
| `--jafra-analyzer-image IMAGE` | Jafra Analyzer | kind only |
| `--jafra-agent-image IMAGE` | Jafra Agent | kind only |

### Environment variables

| Variable | Component | Target |
|---|---|---|
| `K8S_MCP_SERVER_IMAGE` | Kubernetes MCP Server | both |
| `CRYOSTAT_MCP_SERVER_IMAGE` | Cryostat MCP Server | both |
| `CRYOSTAT_AUTH_TOKEN` | Cryostat MCP bearer token (minted if omitted) | both |
| `CAUSA_BACKEND_IMAGE` | Causa | both |
| `QUARKUS_MCP_IMAGE` | Quarkus MCP Server | both |
| `CAUSA_MCP_IMAGE` | Causa MCP Server | both |
| `POSTGRES_KIND_IMAGE` | PostgreSQL (Kind) | kind only |
| `POSTGRES_OCP_IMAGE` | PostgreSQL (OpenShift / CloudNativePG) | openshift only |
| `JAFRA_MCP_IMAGE` | Jafra MCP Server | kind only |
| `JAFRA_CONTROLLER_IMAGE` | Jafra Controller | kind only |
| `JAFRA_ANALYZER_IMAGE` | Jafra Analyzer | kind only |
| `JAFRA_AGENT_IMAGE` | Jafra Agent | kind only |

### Examples

```bash
# Override Causa image (works on both targets)
./install.sh --causa-backend-image quay.io/myorg/causa-backend:v1.2.3

# Override PostgreSQL image on OpenShift
./install.sh --target openshift --postgres-ocp-image quay.io/myorg/postgres-pgvector:17

# Override via environment variable
export CAUSA_MCP_IMAGE=quay.io/causaai/causa-mcp:v0.1.0
./install.sh

# Set target app URL before install
export CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-quarkus-app.default.svc.cluster.local:8080"
./install.sh
```

### Image validation

Every image value is validated before use:

- Must contain a tag (e.g. `:v0.1.0` or `:latest`)
- No spaces or shell-special characters (`;`, `|`, `&`, `$`, `` ` ``, etc.)
- Maximum 255 characters

### Optional components

The following components are skipped when their image variables are empty.
To enable them, set the image in `lib/images.env` or pass the CLI flag.

| Component | Required image variables | Target |
|---|---|---|
| Jafra Ecosystem | `JAFRA_CONTROLLER_IMAGE`, `JAFRA_ANALYZER_IMAGE`, `JAFRA_AGENT_IMAGE` (all three required) | kind only |
| Jafra MCP Server | `JAFRA_MCP_IMAGE` | kind only |
| Quarkus MCP Server | `QUARKUS_MCP_IMAGE` | both |
