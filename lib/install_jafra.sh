#!/usr/bin/env bash

################################################################################
# Jafra — Installation Functions
#
# Installs the complete Jafra ecosystem for Java Flight Recorder analysis:
#   1. Jafra Controller — Webhook that injects JFR sidecar into Java pods
#   2. Jafra Analyzer   — Processes and stores JFR recordings
#   3. Jafra Agent      — DaemonSet that collects JFR files from nodes
#
# Prerequisites:
#   - cert-manager must be installed (for webhook TLS certificates)
#   - Kubernetes cluster with StorageClass for PVC
#
# Architecture:
#   Controller (webhook) → injects JFR sidecar into pods with jafra.io/enabled=true
#   Agent (DaemonSet)    → watches /var/lib/jafra/recordings on each node
#   Analyzer (Deployment)→ receives JFR data via gRPC, provides REST API
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
# _jafra_images_not_set
# Returns 0 if any Jafra image variable is not set
################################################################################
_jafra_images_not_set() {
    [[ -z "${JAFRA_CONTROLLER_IMAGE:-}" ]] || \
    [[ -z "${JAFRA_AGENT_IMAGE:-}" ]] || \
    [[ -z "${JAFRA_ANALYZER_IMAGE:-}" ]]
}

################################################################################
# _cert_manager_ready
# Returns 0 if cert-manager is installed and ready
################################################################################
_cert_manager_ready() {
    ${KUBE_CLI} get namespace cert-manager &>/dev/null &&
    ${KUBE_CLI} get deployment cert-manager -n cert-manager &>/dev/null &&
    ${KUBE_CLI} rollout status deployment/cert-manager -n cert-manager --timeout=5s &>/dev/null
}

################################################################################
# _wait_for_certificate
# Waits for a cert-manager Certificate to be ready
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
# _switch_agent_to_grpc
# Switches jafra-agent from log-only mode to grpc mode
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

    write_to_log_file "INFO" "Waiting for agent restart..."
    sleep 3
    if ! ${KUBE_CLI} rollout status daemonset/jafra-agent \
            -n "${INSTALL_NAMESPACE}" \
            --timeout="${JAFRA_DEPLOY_TIMEOUT}s" \
            >>"${LOG_FILE}" 2>&1; then
        log_error "Agent did not restart successfully"
        return 1
    fi

    write_to_log_file "SUCCESS" "Agent now streaming to analyzer via gRPC"
    return 0
}

################################################################################
# install_jafra_controller
# Installs the Jafra controller (webhook + RBAC + certificate)
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

    # ── 3. Deploy service ────────────────────────────────────────────────────
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

    # ── 6. Register webhook ──────────────────────────────────────────────────
    manifest="${SCRIPT_DIR}/manifests/jafra/controller/webhook.yaml"
    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}"; then
        log_error "Failed to register webhook"
        return 1
    fi
    write_to_log_file "SUCCESS" "Webhook registered"

    return 0
}

################################################################################
# install_jafra_analyzer
# Installs the Jafra analyzer (deployment + PVC + service)
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
# install_jafra_agent
# Installs the Jafra agent (DaemonSet + RBAC)
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

    # ── 2. Deploy agent with image substitution ──────────────────────────────
    manifest="${SCRIPT_DIR}/manifests/jafra/agent/daemonset.yaml"
    local img="${JAFRA_AGENT_IMAGE}"
    write_to_log_file "INFO" "Using agent image: ${img}"

    if ! apply_manifest "${manifest}" "${INSTALL_NAMESPACE}" \
        "image: .*jafra-agent.*" "${img}"; then
        log_error "Failed to apply agent DaemonSet"
        return 1
    fi

    # ── 3. Wait for agent to be ready ────────────────────────────────────────
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
# install_jafra
# Main entry point: installs complete Jafra ecosystem
################################################################################
install_jafra() {
    log_section_silent "Installing Jafra Ecosystem"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Jafra installation"
        return 0
    fi

    # ── Pre-flight checks ────────────────────────────────────────────────────
    if _jafra_images_not_set; then
        log_warn "Jafra: images not configured — skipping (set JAFRA_*_IMAGE in lib/images.env to enable)"
        return 0
    fi

    if ! _cert_manager_ready; then
        log_error "cert-manager is not installed or not ready"
        log_error "Jafra controller requires cert-manager for webhook TLS certificates"
        return 1
    fi

    # Ensure namespace exists
    if ! create_namespace; then return 1; fi

    # ── Install components in order ──────────────────────────────────────────
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

    # ── Switch agent to gRPC mode ────────────────────────────────────────────
    if ! _switch_agent_to_grpc; then
        log_warn "Failed to switch agent to gRPC mode — agent will remain in log-only mode"
        log_warn "Manually switch: kubectl set env daemonset/jafra-agent -n ${INSTALL_NAMESPACE} JAFRA_MODE=grpc"
    fi

    write_to_log_file "SUCCESS" "Jafra ecosystem installed"
    write_to_log_file "INFO"    "To profile a Java app, add these labels to your Pod:"
    write_to_log_file "INFO"    "  labels:"
    write_to_log_file "INFO"    "    jafra.io/enabled: \"true\""
    write_to_log_file "INFO"    "    jafra.io/mode: \"continuous\""
    write_to_log_file "INFO"    "  annotations:"
    write_to_log_file "INFO"    "    jafra.io/containers: \"<your-container-name>\""
    return 0
}

################################################################################
# uninstall_jafra
# Removes all Jafra components
################################################################################
uninstall_jafra() {
    log_section_silent "Uninstalling Jafra Ecosystem"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Jafra uninstall"
        return 0
    fi

    if _jafra_images_not_set; then
        write_to_log_file "INFO" "Jafra: images not configured — nothing to uninstall"
        return 0
    fi

    # ── Delete in reverse order ──────────────────────────────────────────────
    write_to_log_file "INFO" "Deleting webhook..."
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/webhook.yaml" "${INSTALL_NAMESPACE}"

    write_to_log_file "INFO" "Deleting agent..."
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/agent/daemonset.yaml" "${INSTALL_NAMESPACE}"
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/agent/rbac.yaml" "${INSTALL_NAMESPACE}"

    write_to_log_file "INFO" "Deleting analyzer..."
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/analyzer/deployment.yaml" "${INSTALL_NAMESPACE}"

    write_to_log_file "INFO" "Deleting controller..."
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/deployment.yaml" "${INSTALL_NAMESPACE}"
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/service.yaml" "${INSTALL_NAMESPACE}"
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/certificate.yaml" "${INSTALL_NAMESPACE}"
    delete_manifest "${SCRIPT_DIR}/manifests/jafra/controller/rbac.yaml" "${INSTALL_NAMESPACE}"

    write_to_log_file "SUCCESS" "Jafra ecosystem uninstalled"
    return 0
}

export -f install_jafra
export -f uninstall_jafra
