#!/usr/bin/env bash

################################################################################
# Cryostat MCP Server — Installation Functions
#
# Deploys the Cryostat Kubernetes mux from manifests/cryostat_mcp_server.yaml.
# A dedicated ServiceAccount token is injected as K8S_MUX_AUTHORIZATION_HEADER
# so the mux can pass Cryostat's SubjectAccessReview gate.
################################################################################

# Source guard
if [[ -n "${INSTALL_CRYOSTAT_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_CRYOSTAT_MCP_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Global variable defaults — safe to source standalone or from other entrypoints
# ---------------------------------------------------------------------------
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-causa-rca}"
KUBE_CLI="${KUBE_CLI:-kubectl}"
DRY_RUN="${DRY_RUN:-false}"
CRYOSTAT_MCP_SERVER_IMAGE="${CRYOSTAT_MCP_SERVER_IMAGE:-}"
CRYOSTAT_AUTH_TOKEN="${CRYOSTAT_AUTH_TOKEN:-}"
export SCRIPT_DIR INSTALL_NAMESPACE KUBE_CLI DRY_RUN
export CRYOSTAT_MCP_SERVER_IMAGE CRYOSTAT_AUTH_TOKEN

_CRYOSTAT_MCP_DEPLOYMENT="cryostat-mcp-cryostat-k8s-multi-mcp"
_CRYOSTAT_MCP_SERVER_MANIFEST="${SCRIPT_DIR}/manifests/cryostat_mcp_server.yaml"
_CRYOSTAT_MCP_CLIENT_RBAC="${SCRIPT_DIR}/manifests/cryostat_mcp_client_rbac.yaml"

################################################################################
# _cryostat_sed_escape — escape a string for use in a sed replacement
################################################################################
_cryostat_sed_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//|/\\|}"
    printf '%s' "${s}"
}

################################################################################
# generate_cryostat_auth_token
#
# Applies the client RBAC manifest and mints a 1-year token, unless
# CRYOSTAT_AUTH_TOKEN is already set.
#
# Outputs "Bearer <token>" on stdout.
################################################################################
generate_cryostat_auth_token() {
    local namespace="${INSTALL_NAMESPACE}"

    if [[ -n "${CRYOSTAT_AUTH_TOKEN:-}" ]]; then
        write_to_log_file "INFO" "Using provided CRYOSTAT_AUTH_TOKEN"
        echo "Bearer ${CRYOSTAT_AUTH_TOKEN}"
        return 0
    fi

    if [[ ! -f "${_CRYOSTAT_MCP_CLIENT_RBAC}" ]]; then
        write_to_log_file "ERROR" "Cryostat MCP client RBAC manifest not found: ${_CRYOSTAT_MCP_CLIENT_RBAC}"
        return 1
    fi

    write_to_log_file "INFO" "Applying Cryostat MCP client RBAC manifest (namespace: ${namespace})..."
    if ! apply_manifest "${_CRYOSTAT_MCP_CLIENT_RBAC}" "${namespace}"; then
        write_to_log_file "ERROR" "Failed to apply Cryostat MCP client RBAC manifest"
        return 1
    fi
    write_to_log_file "SUCCESS" "Cryostat MCP client SA and RBAC applied"

    write_to_log_file "INFO" "Generating token for service account: cryostat-mcp-client"
    local token
    local token_err
    token=$(${KUBE_CLI} create token cryostat-mcp-client \
            -n "${namespace}" --duration=8760h 2>/tmp/cryostat_token_err) || {
        token_err=$(cat /tmp/cryostat_token_err 2>/dev/null)
        write_to_log_file "ERROR" "Failed to generate token for service account cryostat-mcp-client: ${token_err}"
        rm -f /tmp/cryostat_token_err
        return 1
    }
    rm -f /tmp/cryostat_token_err

    write_to_log_file "SUCCESS" "Generated token for cryostat-mcp-client"
    echo "Bearer ${token}"
    return 0
}

################################################################################
# install_cryostat_mcp_server
################################################################################
install_cryostat_mcp_server() {
    log_section_silent "Installing Cryostat MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Cryostat MCP Server installation"
        return 0
    fi

    local namespace="${INSTALL_NAMESPACE}"
    local mcp_image="${CRYOSTAT_MCP_SERVER_IMAGE}"

    if [[ ! -f "${_CRYOSTAT_MCP_SERVER_MANIFEST}" ]]; then
        log_error "Cryostat MCP Server manifest not found: ${_CRYOSTAT_MCP_SERVER_MANIFEST}"
        return 1
    fi

    write_to_log_file "INFO" "Using image: ${mcp_image}"
    write_to_log_file "INFO" "Manifest:    ${_CRYOSTAT_MCP_SERVER_MANIFEST}"

    write_to_log_file "INFO" "Configuring Cryostat authentication..."
    local auth_header
    if ! auth_header=$(generate_cryostat_auth_token); then
        log_error "Failed to generate Cryostat authentication token"
        return 1
    fi
    auth_header=$(echo -n "${auth_header}" | tr -d '\r\n')
    local auth_header_escaped
    auth_header_escaped=$(_cryostat_sed_escape "${auth_header}")

    local temp_manifest
    temp_manifest=$(mktemp /tmp/causa-rca-$$-cryostat-mcp-XXXXXX.yaml)
    sed -e "s|K8S_MUX_AUTHORIZATION_HEADER_PLACEHOLDER|${auth_header_escaped}|g" \
        "${_CRYOSTAT_MCP_SERVER_MANIFEST}" > "${temp_manifest}"

    if ! apply_manifest "${temp_manifest}" "${namespace}" \
        "image: .*cryostat-mcp-k8s-mux.*" "${mcp_image}"; then
        rm -f "${temp_manifest}"
        log_error "Failed to apply Cryostat MCP Server manifest"
        return 1
    fi
    rm -f "${temp_manifest}"

    if ! wait_for_deployment "${_CRYOSTAT_MCP_DEPLOYMENT}" "${namespace}" 300; then
        log_error "Cryostat MCP Server did not become ready"
        ${KUBE_CLI} get pods -n "${namespace}" -l app.kubernetes.io/name=cryostat-k8s-multi-mcp >>"${LOG_FILE}" 2>&1 || true
        return 1
    fi

    write_to_log_file "INFO" "Cryostat MCP Server is accessible at: http://${_CRYOSTAT_MCP_DEPLOYMENT}.${namespace}.svc.cluster.local:8080"
    write_to_log_file "SUCCESS" "Cryostat MCP Server installed"
    return 0
}

################################################################################
# uninstall_cryostat_mcp_server
################################################################################
uninstall_cryostat_mcp_server() {
    log_section_silent "Uninstalling Cryostat MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    local namespace="${INSTALL_NAMESPACE}"

    delete_manifest "${_CRYOSTAT_MCP_SERVER_MANIFEST}" "${namespace}"

    # ClusterRole / ClusterRoleBinding are cluster-scoped — delete explicitly
    ${KUBE_CLI} delete clusterrolebinding "${_CRYOSTAT_MCP_DEPLOYMENT}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete clusterrole        "${_CRYOSTAT_MCP_DEPLOYMENT}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    if [[ -f "${_CRYOSTAT_MCP_CLIENT_RBAC}" ]]; then
        delete_manifest "${_CRYOSTAT_MCP_CLIENT_RBAC}" "${namespace}"
    else
        ${KUBE_CLI} delete rolebinding cryostat-mcp-client -n "${namespace}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
        ${KUBE_CLI} delete role cryostat-mcp-client -n "${namespace}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
        ${KUBE_CLI} delete serviceaccount cryostat-mcp-client -n "${namespace}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    fi

    write_to_log_file "SUCCESS" "Cryostat MCP Server uninstalled"
    return 0
}

export -f generate_cryostat_auth_token
export -f install_cryostat_mcp_server
export -f uninstall_cryostat_mcp_server
