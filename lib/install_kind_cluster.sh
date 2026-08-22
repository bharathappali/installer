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

# Returns 0 if the registry container exists (running or stopped)
_kind_registry_exists() {
    ${CONTAINER_RUNTIME:-docker} inspect "${KIND_REGISTRY_NAME}" &>/dev/null
}

# _start_local_registry — idempotent; removes a stopped container before starting fresh
_start_local_registry() {
    if _kind_registry_running; then
        write_to_log_file "INFO" "Local registry '${KIND_REGISTRY_NAME}' is already running"
        return 0
    fi

    if _kind_registry_exists; then
        write_to_log_file "INFO" "Removing stopped registry container '${KIND_REGISTRY_NAME}'..."
        ${CONTAINER_RUNTIME:-docker} rm -f "${KIND_REGISTRY_NAME}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    fi

    write_to_log_file "INFO" "Starting local registry (localhost:${KIND_REGISTRY_PORT})..."
    local runtime="${CONTAINER_RUNTIME:-docker}"
    local restart_flag="--restart=always"
    [[ "${runtime}" == "podman" ]] && restart_flag=""

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

# _write_kind_config — writes cluster config YAML to a temp file and prints the path
_write_kind_config() {
    local config_file; config_file=$(mktemp /tmp/kind-config-XXXXXX.yaml)
    cat > "${config_file}" << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${KIND_CLUSTER_NAME}
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = false
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.test-handler.options]
      SystemdCgroup = false
kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    apiVersion: kubelet.config.k8s.io/v1beta1
    cgroupDriver: cgroupfs
nodes:
  - role: control-plane
    image: kindest/node:v1.31.14
    extraPortMappings:
      - containerPort: 30000
        hostPort: 30000
        protocol: TCP
      - containerPort: 30001
        hostPort: 30001
        protocol: TCP
      - containerPort: 30004
        hostPort: 30004
        protocol: TCP
      - containerPort: 30005
        hostPort: 30005
        protocol: TCP
EOF
    echo "${config_file}"
}

# _connect_registry_to_kind_network — attaches the registry to the Kind network
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

# _write_registry_hosts_toml — writes the containerd v2 registry mirror config into each node
_write_registry_hosts_toml() {
    local runtime="${CONTAINER_RUNTIME:-docker}"
    local hosts_dir="/etc/containerd/certs.d/localhost:${KIND_REGISTRY_PORT}"
    local hosts_toml
    hosts_toml=$(printf '[host."http://%s:5000"]\n  capabilities = ["pull", "resolve"]\n' "${KIND_REGISTRY_NAME}")

    for node in $(kind get nodes --name "${KIND_CLUSTER_NAME}" 2>/dev/null); do
        ${runtime} exec "${node}" mkdir -p "${hosts_dir}" >>"${LOG_FILE}" 2>&1
        ${runtime} exec "${node}" sh -c \
            "printf '%s\n' '${hosts_toml}' > ${hosts_dir}/hosts.toml" >>"${LOG_FILE}" 2>&1
        write_to_log_file "INFO" "Registry mirror hosts.toml written to node '${node}'"
    done
}

# _apply_registry_configmap — applies the standard local-registry-hosting ConfigMap
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

# install_kind_cluster — start registry → create cluster → wire registry
install_kind_cluster() {
    log_section_silent "Provisioning Kind Cluster"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Kind cluster creation"
        return 0
    fi

    local runtime="${CONTAINER_RUNTIME:-docker}"
    if ! ${runtime} info &>/dev/null; then
        log_error "${runtime} is not running. Start it and retry."
        return 1
    fi

    if ! _start_local_registry; then
        return 1
    fi

    if _kind_cluster_exists; then
        write_to_log_file "INFO" "Kind cluster '${KIND_CLUSTER_NAME}' already exists — skipping creation"
    else
        local kind_config
        kind_config=$(_write_kind_config)
        write_to_log_file "INFO" "Creating Kind cluster '${KIND_CLUSTER_NAME}'..."

        if ! KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_RUNTIME}" \
                kind create cluster --config "${kind_config}" >>"${LOG_FILE}" 2>&1; then
            log_error "Failed to create Kind cluster '${KIND_CLUSTER_NAME}'"
            rm -f "${kind_config}"
            return 1
        fi
        rm -f "${kind_config}"
        write_to_log_file "SUCCESS" "Kind cluster '${KIND_CLUSTER_NAME}' created"
    fi

    ${KUBE_CLI} config use-context "kind-${KIND_CLUSTER_NAME}" >>"${LOG_FILE}" 2>&1 || true
    write_to_log_file "INFO" "kubectl context set to kind-${KIND_CLUSTER_NAME}"

    _connect_registry_to_kind_network
    _write_registry_hosts_toml
    _apply_registry_configmap

    write_to_log_file "SUCCESS" "Kind cluster '${KIND_CLUSTER_NAME}' is ready"
    write_to_log_file "INFO"    "Local registry: localhost:${KIND_REGISTRY_PORT}"
    write_to_log_file "INFO"    "Push images:    ${CONTAINER_RUNTIME:-docker} tag <img> localhost:${KIND_REGISTRY_PORT}/<name>:<tag> && ${CONTAINER_RUNTIME:-docker} push localhost:${KIND_REGISTRY_PORT}/<name>:<tag>"
    return 0
}

# uninstall_kind_cluster — deletes the cluster and removes the registry container
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

export -f install_kind_cluster
export -f uninstall_kind_cluster
