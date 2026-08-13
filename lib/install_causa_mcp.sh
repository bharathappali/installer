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
# install_causa_mcp
################################################################################
install_causa_mcp() {
    log_section_silent "Installing Causa MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if ! create_namespace; then return 1; fi

    local manifest="${SCRIPT_DIR}/manifests/causa_mcp/deployment.yaml"
    local img="${CAUSA_MCP_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*causa-mcp.*" "${img}"; then
        log_error "Failed to apply Causa MCP manifest"
        return 1
    fi

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

export -f install_causa_mcp
export -f uninstall_causa_mcp
