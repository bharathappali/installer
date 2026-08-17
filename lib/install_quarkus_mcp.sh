#!/usr/bin/env bash

################################################################################
# Quarkus MCP Server — Installation Functions
################################################################################

# Source guard
if [[ -n "${INSTALL_QUARKUS_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_QUARKUS_MCP_LIB_LOADED=1

_quarkus_mcp_not_released() {
    [[ -z "${QUARKUS_MCP_IMAGE:-}" ]]
}

################################################################################
# install_quarkus_mcp
################################################################################
install_quarkus_mcp() {
    log_section_silent "Installing Quarkus MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if ! create_namespace; then return 1; fi

    local manifest="${SCRIPT_DIR}/manifests/quarkus_mcp/deployment.yaml"
    local img="${QUARKUS_MCP_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*quarkus-mcp.*" "${img}"; then
        log_error "Failed to apply Quarkus MCP manifest"
        return 1
    fi

    if ! wait_for_deployment "mcp-metrics" "${INSTALL_NAMESPACE}" 300; then
        log_error "Quarkus MCP did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Quarkus MCP Server installed"
    write_to_log_file "INFO"    "NodePort: localhost:30004  (MCP: /mcp, SSE: /mcp/sse)"
    return 0
}

################################################################################
# uninstall_quarkus_mcp
################################################################################
uninstall_quarkus_mcp() {
    log_section_silent "Uninstalling Quarkus MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    local manifest="${SCRIPT_DIR}/manifests/quarkus_mcp/deployment.yaml"
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    write_to_log_file "SUCCESS" "Quarkus MCP Server uninstalled"
    return 0
}

export -f install_quarkus_mcp
export -f uninstall_quarkus_mcp
