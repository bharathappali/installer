#!/usr/bin/env bash

################################################################################
# Jafra MCP Server — Installation Functions
#
# Deploys the Jafra MCP Server from manifests/jafra_mcp/deployment.yaml.
################################################################################

# Source guard
if [[ -n "${INSTALL_JAFRA_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_JAFRA_MCP_LIB_LOADED=1

_jafra_mcp_not_released() {
    [[ -z "${JAFRA_MCP_IMAGE:-}" ]]
}

# _jafra_mcp_manifest — returns the manifest path
_jafra_mcp_manifest() {
    echo "${SCRIPT_DIR}/manifests/jafra_mcp/deployment.yaml"
}

################################################################################
# install_jafra_mcp
################################################################################
install_jafra_mcp() {
    log_section_silent "Installing Jafra MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if _jafra_mcp_not_released; then
        log_warn "Jafra MCP Server: image not yet released — skipping (set JAFRA_MCP_IMAGE in lib/images.env to enable)"
        return 0
    fi

    if ! create_namespace; then return 1; fi

    local manifest; manifest=$(_jafra_mcp_manifest)
    local img="${JAFRA_MCP_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"
    write_to_log_file "INFO" "Manifest:    ${manifest}"

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
         "image: .*jafra-mcp.*" "${img}"; then
        log_error "Failed to apply Jafra MCP Server manifest"
        return 1
    fi

    if ! wait_for_deployment "jafra-mcp" "${INSTALL_NAMESPACE}" 300; then
        log_error "Jafra MCP Server did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Jafra MCP Server installed"
    write_to_log_file "INFO" "NodePort: localhost:30003"

    return 0
}

################################################################################
# uninstall_jafra_mcp
################################################################################
uninstall_jafra_mcp() {
    log_section_silent "Uninstalling Jafra MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    if _jafra_mcp_not_released; then
        write_to_log_file "INFO" "Jafra MCP Server: image not released — nothing to uninstall"
        return 0
    fi

    local manifest; manifest=$(_jafra_mcp_manifest)
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    write_to_log_file "SUCCESS" "Jafra MCP Server uninstalled"
    return 0
}

export -f install_jafra_mcp
export -f uninstall_jafra_mcp
