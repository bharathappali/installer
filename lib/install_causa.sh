#!/usr/bin/env bash

################################################################################
# Causa Backend — Installation Functions
#
# Deploys the Causa RCA engine as a Kubernetes Deployment + Service.
# Image is configured via CAUSA_BACKEND_IMAGE (see lib/images.env).
################################################################################

# Source guard
if [[ -n "${INSTALL_CAUSA_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_CAUSA_LIB_LOADED=1

################################################################################
# install_causa
################################################################################
install_causa() {
    log_section_silent "Installing Causa Backend"

    if ! create_namespace; then return 1; fi

    local manifest="${SCRIPT_DIR}/manifests/causa/deployment.yaml"
    local img="${CAUSA_BACKEND_IMAGE}"

    write_to_log_file "INFO" "Using image: ${img}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    # Delete any existing deployment so stale replicasets don't accumulate
    # and new pods always get the latest secret bindings
    ${KUBE_CLI} delete deployment causa-backend -n "${INSTALL_NAMESPACE}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*causa-backend.*" "${img}"; then
        log_error "Failed to apply Causa Backend manifest"
        return 1
    fi

    if ! wait_for_deployment "causa-backend" "${INSTALL_NAMESPACE}" 600; then
        log_error "Causa Backend did not become ready in time"
        return 1
    fi

    write_to_log_file "SUCCESS" "Causa Backend installed"
    write_to_log_file "INFO"    "Internal URL: http://causa-backend.${INSTALL_NAMESPACE}.svc.cluster.local:8080"
    write_to_log_file "INFO"    "NodePort:     localhost:30001  (kubectl port-forward or NodePort)"
    return 0
}

################################################################################
# uninstall_causa
################################################################################
uninstall_causa() {
    log_section_silent "Uninstalling Causa Backend"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    local manifest="${SCRIPT_DIR}/manifests/causa/deployment.yaml"
    delete_manifest "${manifest}" "${INSTALL_NAMESPACE}"

    write_to_log_file "SUCCESS" "Causa Backend uninstalled"
    return 0
}

export -f install_causa
export -f uninstall_causa
