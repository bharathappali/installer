#!/usr/bin/env bash

################################################################################
# Jafra — Installation Functions
#
# Installs the Jafra ecosystem for Java Flight Recorder analysis.
#
# Prerequisites:
#   - cert-manager must be installed (for webhook TLS certificates)
#
# All components are installed in INSTALL_NAMESPACE (causa-rca by default)
################################################################################

# Source guard
if [[ -n "${INSTALL_JAFRA_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_JAFRA_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
JAFRA_DEPLOY_TIMEOUT="${JAFRA_DEPLOY_TIMEOUT:-180}"

################################################################################
# _cert_manager_ready
# Returns 0 if cert-manager is installed and its main deployment is ready
################################################################################
_cert_manager_ready() {
    ${KUBE_CLI} get namespace cert-manager &>/dev/null &&
    ${KUBE_CLI} get deployment cert-manager -n cert-manager &>/dev/null &&
    ${KUBE_CLI} rollout status deployment/cert-manager -n cert-manager --timeout=5s &>/dev/null
}

################################################################################
# _wait_for_certificate
# Waits for a cert-manager Certificate resource to reach Ready condition
################################################################################
_wait_for_certificate() {
    local cert_name="$1"
    local namespace="$2"
    local timeout="${3:-120}"

    write_to_log_file "INFO" "Waiting for certificate ${cert_name} to be ready..."
    if ! ${KUBE_CLI} wait --for=condition=Ready \
            certificate/"${cert_name}" \
            -n "${namespace}" \
            --timeout="${timeout}s" \
            >>"${LOG_FILE}" 2>&1; then
        log_error "Certificate ${cert_name} did not become ready"
        log_error "Check cert-manager logs: kubectl logs -n cert-manager -l app=cert-manager"
        return 1
    fi
    write_to_log_file "SUCCESS" "Certificate ${cert_name} is ready"
    return 0
}

################################################################################
# install_jafra_controller
# Installs the Jafra controller (RBAC + TLS certificate + Service + Deployment
# + MutatingWebhookConfiguration)
################################################################################
install_jafra_controller() {
    write_to_log_file "INFO" "Installing Jafra Controller..."

    # ── 1. Apply RBAC ────────────────────────────────────────────────────────
    local manifest="${SCRIPT_DIR}/manifests/jafra/controller/rbac.yaml"
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}"; then
        log_error "Failed to apply controller RBAC"
        return 1
    fi
    write_to_log_file "SUCCESS" "Controller RBAC applied"

    # ── 2. Create TLS certificate (requires cert-manager) ────────────────────
    manifest="${SCRIPT_DIR}/manifests/jafra/controller/certificate.yaml"
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}"; then
        log_error "Failed to create controller certificate"
        return 1
    fi
    if ! _wait_for_certificate "jafra-controller-serving-cert" "${INSTALL_NAMESPACE}" 120; then
        return 1
    fi

    # ── 3. Deploy Service ────────────────────────────────────────────────────
    manifest="${SCRIPT_DIR}/manifests/jafra/controller/service.yaml"
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}"; then
        log_error "Failed to create controller service"
        return 1
    fi
    write_to_log_file "SUCCESS" "Controller service created"

    # ── 4. Deploy controller with image substitution ─────────────────────────
    manifest="${SCRIPT_DIR}/manifests/jafra/controller/deployment.yaml"
    local img="${JAFRA_CONTROLLER_IMAGE}"
    write_to_log_file "INFO" "Using controller image: ${img}"
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*jafra-controller.*" "${img}"; then
        log_error "Failed to apply controller deployment"
        return 1
    fi

    # ── 5. Wait for controller to be ready ───────────────────────────────────
    if ! wait_for_deployment "jafra-controller" "${INSTALL_NAMESPACE}" "${JAFRA_DEPLOY_TIMEOUT}"; then
        log_error "Controller did not become ready"
        return 1
    fi
    write_to_log_file "SUCCESS" "Controller is ready"

    # ── 6. Register MutatingWebhookConfiguration ─────────────────────────────
    manifest="${SCRIPT_DIR}/manifests/jafra/controller/webhook.yaml"
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}"; then
        log_error "Failed to register webhook"
        return 1
    fi
    write_to_log_file "SUCCESS" "Webhook registered"

    return 0
}

################################################################################
# uninstall_jafra_controller
################################################################################
uninstall_jafra_controller() {
    write_to_log_file "INFO" "Deleting Jafra Controller..."
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/webhook.yaml"     "${INSTALL_NAMESPACE}"
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/deployment.yaml"  "${INSTALL_NAMESPACE}"
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/service.yaml"     "${INSTALL_NAMESPACE}"
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/certificate.yaml" "${INSTALL_NAMESPACE}"
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/rbac.yaml"        "${INSTALL_NAMESPACE}"
    write_to_log_file "SUCCESS" "Jafra Controller removed"
}

################################################################################
# install_jafra_analyzer
# Installs the Jafra analyzer (PVC + Deployment + Service)
################################################################################
install_jafra_analyzer() {
    write_to_log_file "INFO" "Installing Jafra Analyzer..."

    local manifest="${SCRIPT_DIR}/manifests/jafra/analyzer/deployment.yaml"
    local img="${JAFRA_ANALYZER_IMAGE}"
    write_to_log_file "INFO" "Using analyzer image: ${img}"

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*jafra-analyzer.*" "${img}"; then
        log_error "Failed to apply analyzer deployment"
        return 1
    fi

    if ! wait_for_deployment "jafra-analyzer" "${INSTALL_NAMESPACE}" "${JAFRA_DEPLOY_TIMEOUT}"; then
        log_error "Analyzer did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Analyzer is ready"
    write_to_log_file "INFO"    "Analyzer API: kubectl -n ${INSTALL_NAMESPACE} port-forward svc/jafra-analyzer 8080:8080"
    return 0
}

################################################################################
# uninstall_jafra_analyzer
################################################################################
uninstall_jafra_analyzer() {
    write_to_log_file "INFO" "Deleting Jafra Analyzer..."
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/analyzer/deployment.yaml" "${INSTALL_NAMESPACE}"
    write_to_log_file "SUCCESS" "Jafra Analyzer removed"
}

################################################################################
# _switch_agent_to_grpc
# Switches jafra-agent from log-only mode to grpc mode once analyzer is ready
################################################################################
_switch_agent_to_grpc() {
    write_to_log_file "INFO" "Switching jafra-agent to gRPC mode..."
    if ! ${KUBE_CLI} set env daemonset/jafra-agent \
            -n "${INSTALL_NAMESPACE}" \
            JAFRA_MODE=grpc \
            >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to switch agent to gRPC mode"
        return 1
    fi

    write_to_log_file "INFO" "Waiting for agent rollout after gRPC switch..."
    sleep 3
    if ! ${KUBE_CLI} rollout status daemonset/jafra-agent \
            -n "${INSTALL_NAMESPACE}" \
            --timeout="${JAFRA_DEPLOY_TIMEOUT}s" \
            >>"${LOG_FILE}" 2>&1; then
        log_error "Agent did not restart successfully after gRPC switch"
        return 1
    fi

    write_to_log_file "SUCCESS" "Agent is now streaming to analyzer via gRPC"
    return 0
}

################################################################################
# install_jafra_agent
# Installs the Jafra agent (ServiceAccount + DaemonSet)
################################################################################
install_jafra_agent() {
    write_to_log_file "INFO" "Installing Jafra Agent..."

    # ── 1. Apply RBAC ────────────────────────────────────────────────────────
    local manifest="${SCRIPT_DIR}/manifests/jafra/agent/rbac.yaml"
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}"; then
        log_error "Failed to apply agent RBAC"
        return 1
    fi
    write_to_log_file "SUCCESS" "Agent RBAC applied"

    # ── 2. Deploy agent DaemonSet with image substitution ────────────────────
    manifest="${SCRIPT_DIR}/manifests/jafra/agent/daemonset.yaml"
    local img="${JAFRA_AGENT_IMAGE}"
    write_to_log_file "INFO" "Using agent image: ${img}"
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*jafra-agent.*" "${img}"; then
        log_error "Failed to apply agent DaemonSet"
        return 1
    fi

    # ── 3. Wait for agent DaemonSet to be ready ──────────────────────────────
    write_to_log_file "INFO" "Waiting for agent DaemonSet..."
    if ! ${KUBE_CLI} rollout status daemonset/jafra-agent \
            -n "${INSTALL_NAMESPACE}" \
            --timeout="${JAFRA_DEPLOY_TIMEOUT}s" \
            >>"${LOG_FILE}" 2>&1; then
        log_error "Agent DaemonSet did not become ready"
        return 1
    fi

    write_to_log_file "SUCCESS" "Agent is ready (mode: log-only)"
    return 0
}

################################################################################
# uninstall_jafra_agent
################################################################################
uninstall_jafra_agent() {
    write_to_log_file "INFO" "Deleting Jafra Agent..."
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/agent/daemonset.yaml" "${INSTALL_NAMESPACE}"
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/agent/rbac.yaml"      "${INSTALL_NAMESPACE}"
    write_to_log_file "SUCCESS" "Jafra Agent removed"
}

################################################################################
# install_jafra
# Main entry point — installs all Jafra components.
################################################################################
install_jafra() {
    log_section_silent "Installing Jafra Ecosystem"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Jafra installation"
        return 0
    fi

    if [[ -z "${JAFRA_CONTROLLER_IMAGE:-}" ]] || \
       [[ -z "${JAFRA_ANALYZER_IMAGE:-}" ]] || \
       [[ -z "${JAFRA_AGENT_IMAGE:-}" ]]; then
        log_warn "Jafra: one or more images not set — skipping (set JAFRA_*_IMAGE in lib/images.env to enable)"
        return 0
    fi

    if ! _cert_manager_ready; then
        log_error "cert-manager is not installed or not ready"
        log_error "Jafra controller requires cert-manager for webhook TLS certificates"
        return 1
    fi

    if ! create_namespace; then return 1; fi

    if ! install_jafra_controller; then
        log_error "Failed to install Jafra controller"
        return 1
    fi

    if ! install_jafra_analyzer; then
        log_error "Failed to install Jafra analyzer"
        return 1
    fi

    if ! install_jafra_agent; then
        log_error "Failed to install Jafra agent"
        return 1
    fi

    # Switch agent from log-only to grpc now that analyzer is ready
    if ! _switch_agent_to_grpc; then
        log_warn "Failed to switch agent to gRPC mode — agent will stay in log-only mode"
        log_warn "Switch manually: kubectl set env daemonset/jafra-agent -n ${INSTALL_NAMESPACE} JAFRA_MODE=grpc"
    fi

    write_to_log_file "SUCCESS" "Jafra Ecosystem installed (Controller + Analyzer + Agent)"
    write_to_log_file "INFO"    "To enable JFR profiling on a pod, add:"
    write_to_log_file "INFO"    "  labels:"
    write_to_log_file "INFO"    "    jafra.io/enabled: \"true\""
    write_to_log_file "INFO"    "    jafra.io/mode: \"continuous\""
    write_to_log_file "INFO"    "  annotations:"
    write_to_log_file "INFO"    "    jafra.io/containers: \"<your-container-name>\""
    return 0
}

################################################################################
# uninstall_jafra
# Removes all installed Jafra components in reverse install order.
################################################################################
uninstall_jafra() {
    log_section_silent "Uninstalling Jafra Ecosystem"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Jafra uninstall"
        return 0
    fi

    if [[ -z "${JAFRA_CONTROLLER_IMAGE:-}" ]] && \
       [[ -z "${JAFRA_ANALYZER_IMAGE:-}" ]] && \
       [[ -z "${JAFRA_AGENT_IMAGE:-}" ]]; then
        write_to_log_file "INFO" "Jafra: images not configured — nothing to uninstall"
        return 0
    fi

    uninstall_jafra_agent
    uninstall_jafra_analyzer
    uninstall_jafra_controller

    write_to_log_file "SUCCESS" "Jafra Ecosystem uninstalled"
    return 0
}

export -f install_jafra
export -f uninstall_jafra
