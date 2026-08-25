#!/usr/bin/env bash

################################################################################
# cert-manager — Installation Functions
#
# Installs cert-manager (required by Jafra controller for webhook TLS certificates)
# via official manifests from GitHub releases.
#
# cert-manager provides:
#   - Certificate management and automatic renewal
#   - CA injection for webhooks
#   - Self-signed certificate issuers
#
# Required by: Jafra controller webhook
# Docs: https://cert-manager.io/docs/
################################################################################

# Source guard
if [[ -n "${INSTALL_CERT_MANAGER_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_CERT_MANAGER_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-latest}"
CERT_MANAGER_NAMESPACE="cert-manager"
CERT_MANAGER_MANIFEST_URL="https://github.com/cert-manager/cert-manager/releases/${CERT_MANAGER_VERSION}/download/cert-manager.yaml"
CERT_MANAGER_DEPLOY_TIMEOUT="${CERT_MANAGER_DEPLOY_TIMEOUT:-180}"

export CERT_MANAGER_NAMESPACE

################################################################################
# _cert_manager_installed
# Returns 0 if cert-manager is already installed and running
################################################################################
_cert_manager_installed() {
    ${KUBE_CLI} get namespace "${CERT_MANAGER_NAMESPACE}" &>/dev/null &&
    ${KUBE_CLI} get deployment cert-manager -n "${CERT_MANAGER_NAMESPACE}" &>/dev/null &&
    ${KUBE_CLI} get deployment cert-manager-webhook -n "${CERT_MANAGER_NAMESPACE}" &>/dev/null &&
    ${KUBE_CLI} get deployment cert-manager-cainjector -n "${CERT_MANAGER_NAMESPACE}" &>/dev/null
}

################################################################################
# install_cert_manager
# Main entry point: apply cert-manager manifests and wait for deployments
################################################################################
install_cert_manager() {
    log_section_silent "Installing cert-manager"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping cert-manager installation"
        return 0
    fi

    # ── 1. Check if already installed ────────────────────────────────────────
    if _cert_manager_installed; then
        write_to_log_file "INFO" "cert-manager is already installed, skipping"
        write_to_log_file "SUCCESS" "cert-manager already present"
        return 0
    fi

    # ── 2. Apply cert-manager manifests ──────────────────────────────────────
    write_to_log_file "INFO" "Applying cert-manager manifests from ${CERT_MANAGER_MANIFEST_URL}"
    if ! ${KUBE_CLI} apply -f "${CERT_MANAGER_MANIFEST_URL}" >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to apply cert-manager manifests"
        return 1
    fi
    write_to_log_file "SUCCESS" "cert-manager manifests applied"

    # ── 3. Wait for cert-manager deployments to be ready ─────────────────────
    write_to_log_file "INFO" "Waiting for cert-manager deployments to be ready..."

    local deployments=("cert-manager" "cert-manager-webhook" "cert-manager-cainjector")
    for deployment in "${deployments[@]}"; do
        write_to_log_file "INFO" "Waiting for ${deployment}..."
        if ! ${KUBE_CLI} rollout status deployment/"${deployment}" \
                -n "${CERT_MANAGER_NAMESPACE}" \
                --timeout="${CERT_MANAGER_DEPLOY_TIMEOUT}s" \
                >>"${LOG_FILE}" 2>&1; then
            log_error "Deployment ${deployment} did not become ready"
            return 1
        fi
    done

    write_to_log_file "SUCCESS" "cert-manager is ready"
    write_to_log_file "INFO"    "cert-manager version: ${CERT_MANAGER_VERSION}"
    write_to_log_file "INFO"    "Namespace: ${CERT_MANAGER_NAMESPACE}"
    return 0
}

################################################################################
# uninstall_cert_manager
# Removes cert-manager and its CRDs
################################################################################
uninstall_cert_manager() {
    log_section_silent "Uninstalling cert-manager"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping cert-manager uninstall"
        return 0
    fi

    if ! _cert_manager_installed; then
        write_to_log_file "INFO" "cert-manager not installed — nothing to remove"
        return 0
    fi

    write_to_log_file "INFO" "Deleting cert-manager manifests..."
    ${KUBE_CLI} delete -f "${CERT_MANAGER_MANIFEST_URL}" \
        --ignore-not-found=true \
        >>"${LOG_FILE}" 2>&1 || true

    # Wait for namespace deletion
    write_to_log_file "INFO" "Waiting for cert-manager namespace deletion..."
    local waited=0
    while ${KUBE_CLI} get namespace "${CERT_MANAGER_NAMESPACE}" &>/dev/null; do
        if [[ ${waited} -ge 60 ]]; then
            write_to_log_file "WARN" "Namespace deletion timed out — may need manual cleanup"
            break
        fi
        sleep 5; waited=$(( waited + 5 ))
    done

    write_to_log_file "SUCCESS" "cert-manager uninstalled"
    return 0
}

export -f install_cert_manager
export -f uninstall_cert_manager
