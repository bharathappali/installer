#!/usr/bin/env bash

################################################################################
# Causa MCP Server — Installation Functions
#
# Wraps the Causa Backend REST API as MCP tools:
#   - list_diagnostics()    → GET /api/v1/diagnostics
#   - get_diagnostic(id)    → GET /api/v1/diagnostics/{id}
#
# Image: configured via CAUSA_MCP_IMAGE (see lib/images.env).
# NodePort: 30005
################################################################################

# Source guard
if [[ -n "${INSTALL_CAUSA_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_CAUSA_MCP_LIB_LOADED=1

################################################################################
# _validate_causa_backend_ready
# Checks that the Causa Backend deployment exists and is fully available before
# installing the Causa MCP Server, which depends on it at startup.
################################################################################
_validate_causa_backend_ready() {
    local ns="${INSTALL_NAMESPACE}"
    local deploy="causa-backend"

    write_to_log_file "INFO" "Checking Causa Backend is ready before installing Causa MCP Server..."

    if ! ${KUBE_CLI} get deployment "${deploy}" -n "${ns}" &>/dev/null; then
        log_error "Causa Backend deployment not found in namespace '${ns}'."
        log_error "Causa MCP Server requires Causa Backend to be installed first."
        return 1
    fi

    # readyReplicas is absent from the status JSON (not "0") when no pods are up,
    # so we must default an empty result to "0" explicitly after command substitution.
    local ready desired
    ready=$(${KUBE_CLI} get deployment "${deploy}" -n "${ns}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    ready="${ready:-0}"
    desired=$(${KUBE_CLI} get deployment "${deploy}" -n "${ns}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null)
    desired="${desired:-0}"

    # A deployment scaled to 0 is explicitly stopped — treat as not ready.
    if [[ "${desired}" -eq 0 ]] 2>/dev/null || [[ "${ready}" != "${desired}" ]]; then
        log_error "Causa Backend is not ready (${ready}/${desired} replicas)."
        log_error "Causa MCP Server requires Causa Backend to be fully running first."
        log_error "Scale it back up:  ${KUBE_CLI} scale deployment ${deploy} -n ${ns} --replicas=1"
        return 1
    fi

    write_to_log_file "SUCCESS" "Causa Backend is ready (${ready}/${desired} replicas)"
    return 0
}

################################################################################
# install_causa_mcp
################################################################################
install_causa_mcp() {
    log_section_silent "Installing Causa MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if ! _validate_causa_backend_ready; then
        return 1
    fi

    if ! create_namespace; then return 1; fi

    local manifest="${SCRIPT_DIR}/manifests/causa_mcp/deployment.yaml"
    local img="${CAUSA_MCP_IMAGE}"

    # On Kind, ClusterIP routing through the CNI bridge is unreliable on macOS
    # hosts (Docker Desktop / Podman). Use the backend NodePort (localhost:30001)
    # instead — reachable because the pod runs with hostNetwork:true, so
    # kube-proxy NodePort rules on the node are always in effect.
    # The URL is baked into the manifest before apply so no second rollout is
    # triggered (a post-apply `kubectl set env` would cause a port conflict
    # because hostNetwork:true binds port 8081 on the node).
    local engine_url
    if [[ "${INSTALL_TARGET:-kind}" == "kind" ]]; then
        engine_url="http://localhost:30001"
    else
        engine_url="http://causa-backend.${INSTALL_NAMESPACE}.svc.cluster.local:8080"
    fi
    write_to_log_file "INFO" "CAUSA_ENGINE_URL → ${engine_url}"

    write_to_log_file "INFO" "Using image: ${img}"

    local tmp; tmp=$(mktemp /tmp/causa-$$-causa-mcp-XXXXXX.yaml) || {
        log_error "mktemp failed for causa-mcp manifest"
        return 1
    }
    sed "s|PLACEHOLDER_ENGINE_URL|${engine_url}|g" "${manifest}" > "${tmp}"

    if ! apply_manifest "${tmp}" "${INSTALL_NAMESPACE}" \
        "image: .*causa-mcp.*" "${img}"; then
        rm -f "${tmp}"
        log_error "Failed to apply Causa MCP manifest"
        return 1
    fi
    rm -f "${tmp}"

    if ! wait_for_deployment "causa-mcp" "${INSTALL_NAMESPACE}" 300; then
        log_error "Causa MCP did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Causa MCP Server installed"
    write_to_log_file "INFO"    "NodePort: localhost:30005"
    return 0
}

################################################################################
# uninstall_causa_mcp
################################################################################
uninstall_causa_mcp() {
    log_section_silent "Uninstalling Causa MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    local manifest="${SCRIPT_DIR}/manifests/causa_mcp/deployment.yaml"
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    write_to_log_file "SUCCESS" "Causa MCP Server uninstalled"
    return 0
}

export -f _validate_causa_backend_ready
export -f install_causa_mcp
export -f uninstall_causa_mcp
