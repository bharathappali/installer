#!/usr/bin/env bash

################################################################################
# Kind Cluster Setup
#
# Provisions a local Kind cluster with a local container registry.
# Idempotent — safe to run when the cluster is already present.
#
# Exported functions:
#   install_kind_cluster   — creates cluster + registry if absent
#   uninstall_kind_cluster — deletes cluster and registry
################################################################################

# Prevent multiple sourcing
if [[ -n "${INSTALL_KIND_CLUSTER_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly INSTALL_KIND_CLUSTER_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Global variable defaults — safe to source standalone or from other entrypoints
# ---------------------------------------------------------------------------
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
DRY_RUN="${DRY_RUN:-false}"
export SCRIPT_DIR CONTAINER_RUNTIME DRY_RUN

# Kind-specific constants (overridable via env vars before sourcing this file)
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-causa-rca}"
KIND_REGISTRY_NAME="${KIND_REGISTRY_NAME:-causa-rca-registry}"
KIND_REGISTRY_PORT="${KIND_REGISTRY_PORT:-5001}"
export KIND_CLUSTER_NAME KIND_REGISTRY_NAME KIND_REGISTRY_PORT

# ---------------------------------------------------------------------------
# _kind_cluster_exists  — returns 0 if the cluster is already present
# ---------------------------------------------------------------------------
_kind_cluster_exists() {
    kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"
}

# ---------------------------------------------------------------------------
# _kind_registry_running  — returns 0 if the registry container is running
# ---------------------------------------------------------------------------
_kind_registry_running() {
    ${CONTAINER_RUNTIME:-docker} inspect --format='{{.State.Running}}' "${KIND_REGISTRY_NAME}" 2>/dev/null | grep -q "true"
}

# ---------------------------------------------------------------------------
# _start_local_registry
# Starts a local Docker registry on localhost:KIND_REGISTRY_PORT.
# Idempotent: does nothing if already running.
# ---------------------------------------------------------------------------
_start_local_registry() {
    if _kind_registry_running; then
        write_to_log_file "INFO" "Local registry '${KIND_REGISTRY_NAME}' is already running"
        return 0
    fi

    write_to_log_file "INFO" "Starting local registry (localhost:${KIND_REGISTRY_PORT})..."
    local runtime="${CONTAINER_RUNTIME:-docker}"
    local restart_flag="--restart=always"
    # podman run does not support --restart=always in the same way; use 'unless-stopped' equivalent
    [[ "${runtime}" == "podman" ]] && restart_flag=""

    # Use the runtime's default network for Podman; 'bridge' for Docker.
    local network_flag="--network bridge"
    [[ "${runtime}" == "podman" ]] && network_flag=""

    ${runtime} run -d \
        ${restart_flag:+${restart_flag}} \
        --name "${KIND_REGISTRY_NAME}" \
        -p "127.0.0.1:${KIND_REGISTRY_PORT}:5000" \
        ${network_flag:+${network_flag}} \
        registry:2 >>"${LOG_FILE:-/dev/null}" 2>&1

    write_to_log_file "SUCCESS" "Local registry started at localhost:${KIND_REGISTRY_PORT}"
    return 0
}

# ---------------------------------------------------------------------------
# _write_kind_config
# Writes a Kind cluster config YAML to a temp file and prints the path.
# The config enables:
#   - Local registry mirror
#   - Extra port mappings for NodePort services (30000-30005)
#   - SYS_PTRACE for async-profiler container attach
# ---------------------------------------------------------------------------
_write_kind_config() {
    local config_file; config_file=$(mktemp /tmp/kind-config-XXXXXX.yaml)
    cat > "${config_file}" << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${KIND_CLUSTER_NAME}
# Mirror localhost:KIND_REGISTRY_PORT so Kind nodes can pull from it
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${KIND_REGISTRY_PORT}"]
      endpoint = ["http://${KIND_REGISTRY_NAME}:5000"]
nodes:
  - role: control-plane
    # NodePort mappings — each component exposes one NodePort in 30000-30005
    extraPortMappings:
      - containerPort: 30000   # Kubernetes MCP Server
        hostPort: 30000
        protocol: TCP
      - containerPort: 30001   # Causa Backend
        hostPort: 30001
        protocol: TCP
      - containerPort: 30002   # Async Profiler
        hostPort: 30002
        protocol: TCP
      - containerPort: 30003   # Async Profiler MCP
        hostPort: 30003
        protocol: TCP
      - containerPort: 30004   # Quarkus MCP
        hostPort: 30004
        protocol: TCP
      - containerPort: 30005   # Causa MCP
        hostPort: 30005
        protocol: TCP
    # kubeadm patch: allow SYS_PTRACE in default namespaces
    # (required by async-profiler to attach to JVM inside pods)
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            allow-privileged: "true"
EOF
    echo "${config_file}"
}

# ---------------------------------------------------------------------------
# _connect_registry_to_kind_network
# Attaches the registry container to the Kind Docker network so nodes
# can resolve its hostname.
# ---------------------------------------------------------------------------
_connect_registry_to_kind_network() {
    local runtime="${CONTAINER_RUNTIME:-docker}"
    if ${runtime} network inspect kind &>/dev/null; then
        if ${runtime} inspect "${KIND_REGISTRY_NAME}" \
            --format='{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' 2>/dev/null \
            | grep -q "$(${runtime} network inspect kind --format='{{.Id}}' 2>/dev/null)"; then
            write_to_log_file "INFO" "Registry already connected to 'kind' network"
        else
            ${runtime} network connect kind "${KIND_REGISTRY_NAME}" >>"${LOG_FILE}" 2>&1 || true
            write_to_log_file "SUCCESS" "Registry connected to 'kind' network"
        fi
    fi
}

# ---------------------------------------------------------------------------
# _apply_registry_configmap
# Tells Kind nodes about the local registry via the standard ConfigMap
# (https://kind.sigs.k8s.io/docs/user/local-registry/)
# ---------------------------------------------------------------------------
_apply_registry_configmap() {
    ${KUBE_CLI} apply -f - >>"${LOG_FILE}" 2>&1 << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${KIND_REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
    write_to_log_file "SUCCESS" "Local registry ConfigMap applied"
}

# ---------------------------------------------------------------------------
# install_kind_cluster
# Main entry point: start registry → create cluster → wire registry
# ---------------------------------------------------------------------------
install_kind_cluster() {
    log_section_silent "Provisioning Kind Cluster"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Kind cluster creation"
        return 0
    fi

    # 1. Ensure container runtime is running
    local runtime="${CONTAINER_RUNTIME:-docker}"
    if ! ${runtime} info &>/dev/null; then
        log_error "${runtime} is not running. Start it and retry."
        return 1
    fi

    # 2. Start local registry (idempotent)
    if ! _start_local_registry; then
        return 1
    fi

    # 3. Create cluster if it doesn't exist
    if _kind_cluster_exists; then
        write_to_log_file "INFO" "Kind cluster '${KIND_CLUSTER_NAME}' already exists — skipping creation"
    else
        local kind_config
        kind_config=$(_write_kind_config)
        write_to_log_file "INFO" "Creating Kind cluster '${KIND_CLUSTER_NAME}'..."

        if ! kind create cluster --config "${kind_config}" >>"${LOG_FILE}" 2>&1; then
            log_error "Failed to create Kind cluster '${KIND_CLUSTER_NAME}'"
            rm -f "${kind_config}"
            return 1
        fi
        rm -f "${kind_config}"
        write_to_log_file "SUCCESS" "Kind cluster '${KIND_CLUSTER_NAME}' created"
    fi

    # 4. Switch kubectl context to this cluster
    ${KUBE_CLI} config use-context "kind-${KIND_CLUSTER_NAME}" >>"${LOG_FILE}" 2>&1 || true
    write_to_log_file "INFO" "kubectl context set to kind-${KIND_CLUSTER_NAME}"

    # 5. Wire registry to Kind network and apply ConfigMap
    _connect_registry_to_kind_network
    _apply_registry_configmap

    write_to_log_file "SUCCESS" "Kind cluster '${KIND_CLUSTER_NAME}' is ready"
    write_to_log_file "INFO"    "Local registry: localhost:${KIND_REGISTRY_PORT}"
    write_to_log_file "INFO"    "Push images:    ${CONTAINER_RUNTIME:-docker} tag <img> localhost:${KIND_REGISTRY_PORT}/<name>:<tag> && ${CONTAINER_RUNTIME:-docker} push localhost:${KIND_REGISTRY_PORT}/<name>:<tag>"
    return 0
}

# ---------------------------------------------------------------------------
# uninstall_kind_cluster
# Deletes the cluster and stops/removes the registry container.
# ---------------------------------------------------------------------------
uninstall_kind_cluster() {
    log_section_silent "Removing Kind Cluster"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Kind cluster deletion"
        return 0
    fi

    if _kind_cluster_exists; then
        write_to_log_file "INFO" "Deleting Kind cluster '${KIND_CLUSTER_NAME}'..."
        kind delete cluster --name "${KIND_CLUSTER_NAME}" >>"${LOG_FILE}" 2>&1
        write_to_log_file "SUCCESS" "Kind cluster '${KIND_CLUSTER_NAME}' deleted"
    else
        write_to_log_file "INFO" "Kind cluster '${KIND_CLUSTER_NAME}' not found — nothing to delete"
    fi

    local runtime="${CONTAINER_RUNTIME:-docker}"
    if _kind_registry_running; then
        write_to_log_file "INFO" "Stopping and removing local registry '${KIND_REGISTRY_NAME}'..."
        ${runtime} stop "${KIND_REGISTRY_NAME}" >>"${LOG_FILE}" 2>&1 || true
        ${runtime} rm   "${KIND_REGISTRY_NAME}" >>"${LOG_FILE}" 2>&1 || true
        write_to_log_file "SUCCESS" "Local registry removed"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
export -f install_kind_cluster
export -f uninstall_kind_cluster
