#!/usr/bin/env bash

################################################################################
# Async Profiler MCP Server — Installation Functions
################################################################################

# Source guard
if [[ -n "${INSTALL_ASYNC_PROFILER_MCP_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_ASYNC_PROFILER_MCP_LIB_LOADED=1

_async_profiler_mcp_not_released() {
    [[ "${ASYNC_PROFILER_MCP_IMAGE}" == "quay.io/causaai/async-profiler-mcp:latest" ]]
}

################################################################################
# install_async_profiler_mcp
################################################################################
install_async_profiler_mcp() {
    log_section_silent "Installing Async Profiler MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if _async_profiler_mcp_not_released; then
        log_warn "Async Profiler MCP Server: image not yet released — skipping (set ASYNC_PROFILER_MCP_IMAGE in lib/images.env to enable)"
        return 0
    fi

    if ! create_namespace; then return 1; fi

    local manifest="${SCRIPT_DIR}/manifests/async_profiler_mcp/deployment.yaml"
    local img="${ASYNC_PROFILER_MCP_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*async-profiler-mcp.*" "${img}"; then
        log_error "Failed to apply Async Profiler MCP Server manifest"
        return 1
    fi

    if ! wait_for_deployment "async-profiler-mcp" "${INSTALL_NAMESPACE}" 300; then
        log_error "Async Profiler MCP Server did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Async Profiler MCP Server installed"
    write_to_log_file "INFO"    "NodePort: localhost:30003"
    return 0
}

################################################################################
# uninstall_async_profiler_mcp
################################################################################
uninstall_async_profiler_mcp() {
    log_section_silent "Uninstalling Async Profiler MCP Server"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    if _async_profiler_mcp_not_released; then
        write_to_log_file "INFO" "Async Profiler MCP Server: image not released — nothing to uninstall"
        return 0
    fi

    local manifest="${SCRIPT_DIR}/manifests/async_profiler_mcp/deployment.yaml"
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    write_to_log_file "SUCCESS" "Async Profiler MCP Server uninstalled"
    return 0
}

export -f install_async_profiler_mcp
export -f uninstall_async_profiler_mcp
