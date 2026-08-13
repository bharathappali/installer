 #!/usr/bin/env bash

################################################################################
# Async Profiler — Installation Functions
################################################################################

# Source guard
if [[ -n "${INSTALL_ASYNC_PROFILER_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_ASYNC_PROFILER_LIB_LOADED=1

_async_profiler_not_released() {
    [[ "${ASYNC_PROFILER_IMAGE}" == "quay.io/causaai/async-profiler:latest" ]]
}

################################################################################
# install_async_profiler
################################################################################
install_async_profiler() {
    log_section_silent "Installing Async Profiler"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if _async_profiler_not_released; then
        log_warn "Async Profiler: image not yet released — skipping (set ASYNC_PROFILER_IMAGE in lib/images.env to enable)"
        return 0
    fi

    if ! create_namespace; then return 1; fi

    local manifest="${SCRIPT_DIR}/manifests/async_profiler/deployment.yaml"
    local img="${ASYNC_PROFILER_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*async-profiler[^-].*" "${img}"; then
        log_error "Failed to apply Async Profiler manifest"
        return 1
    fi

    if ! wait_for_deployment "async-profiler" "${INSTALL_NAMESPACE}" 300; then
        log_error "Async Profiler did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Async Profiler installed"
    write_to_log_file "INFO"    "NodePort: localhost:30002"
    return 0
}

################################################################################
# uninstall_async_profiler
################################################################################
uninstall_async_profiler() {
    log_section_silent "Uninstalling Async Profiler"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    if _async_profiler_not_released; then
        write_to_log_file "INFO" "Async Profiler: image not released — nothing to uninstall"
        return 0
    fi

    local manifest="${SCRIPT_DIR}/manifests/async_profiler/deployment.yaml"
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    write_to_log_file "SUCCESS" "Async Profiler uninstalled"
    return 0
}

export -f install_async_profiler
export -f uninstall_async_profiler
