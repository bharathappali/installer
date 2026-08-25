#!/usr/bin/env bash

################################################################################
# Kubernetes MCP Server — Installation Functions
#
# Kind target:       NodePort service (manifests/k8s_mcp_server.yaml)
# OpenShift target:  ClusterIP + Route (manifests/openshift/k8s_mcp_server.yaml)
################################################################################

# Source guard
if [[ -n "${INSTALL_K8S_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_K8S_MCP_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Global variable defaults — safe to source standalone or from other entrypoints
# ---------------------------------------------------------------------------
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-causa-rca}"
KUBE_CLI="${KUBE_CLI:-kubectl}"
DRY_RUN="${DRY_RUN:-false}"
K8S_MCP_SERVER_IMAGE="${K8S_MCP_SERVER_IMAGE:-}"
export SCRIPT_DIR INSTALL_NAMESPACE KUBE_CLI DRY_RUN K8S_MCP_SERVER_IMAGE

# _k8s_mcp_manifest — returns the correct manifest path for the active target
_k8s_mcp_manifest() {
    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        echo "${SCRIPT_DIR}/manifests/openshift/k8s_mcp_server.yaml"
    else
        echo "${SCRIPT_DIR}/manifests/k8s_mcp_server.yaml"
    fi
}

################################################################################
# install_kubernetes_mcp_server
################################################################################
install_kubernetes_mcp_server() {
    log_section_silent "Installing Kubernetes MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if ! create_namespace; then return 1; fi

    local manifest; manifest=$(_k8s_mcp_manifest)
    local img="${K8S_MCP_SERVER_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"
    write_to_log_file "INFO" "Manifest:    ${manifest}"

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*kubernetes_mcp_server.*" "${img}"; then
        log_error "Failed to apply Kubernetes MCP Server manifest"
        return 1
    fi

    if ! wait_for_deployment "kubernetes-mcp-server" "${INSTALL_NAMESPACE}" 300; then
        log_error "Kubernetes MCP Server did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Kubernetes MCP Server installed"

    if [[ "${INSTALL_TARGET:-kind}" == "openshift" ]]; then
        local route_url
        route_url=$(${KUBE_CLI} get route kubernetes-mcp-server \
            -n "${INSTALL_NAMESPACE}" \
            -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [[ -n "${route_url}" ]]; then
            write_to_log_file "INFO" "Route: https://${route_url}/mcp"
        fi
    else
        write_to_log_file "INFO" "NodePort: http://localhost:30000/mcp"
    fi

    return 0
}

################################################################################
# uninstall_kubernetes_mcp_server
################################################################################
uninstall_kubernetes_mcp_server() {
    log_section_silent "Uninstalling Kubernetes MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    local manifest; manifest=$(_k8s_mcp_manifest)
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    # ClusterRole / ClusterRoleBinding are cluster-scoped — delete explicitly
    ${KUBE_CLI} delete clusterrolebinding kubernetes-mcp-server --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete clusterrole        kubernetes-mcp-server --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    write_to_log_file "SUCCESS" "Kubernetes MCP Server uninstalled"
    return 0
}

export -f install_kubernetes_mcp_server
export -f uninstall_kubernetes_mcp_server
