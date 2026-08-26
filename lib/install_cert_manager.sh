#!/usr/bin/env bash

################################################################################
# cert-manager — Installation Functions
#
# Installs cert-manager (required by Jafra controller for webhook TLS certificates)
# via official manifests from GitHub releases.
#
# Ownership tracking:
#   When this script installs cert-manager it labels the cert-manager namespace
#   with:  app.kubernetes.io/managed-by=causa-installer
#   Uninstall checks for that label before removing anything.
#   If cert-manager was pre-existing (installed by the user before running this
#   installer) the label is absent and uninstall is a no-op, leaving the
#   pre-existing installation untouched.
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
# Label applied to the cert-manager namespace when WE install it.
# Its presence is the signal that uninstall should remove cert-manager.
_CERT_MANAGER_MANAGED_LABEL="app.kubernetes.io/managed-by=causa-installer"

export CERT_MANAGER_NAMESPACE

################################################################################
# _cert_manager_installed
# Returns 0 if cert-manager deployments are present (regardless of who installed)
################################################################################
_cert_manager_installed() {
    ${KUBE_CLI} get namespace "${CERT_MANAGER_NAMESPACE}" &>/dev/null &&
    ${KUBE_CLI} get deployment cert-manager          -n "${CERT_MANAGER_NAMESPACE}" &>/dev/null &&
    ${KUBE_CLI} get deployment cert-manager-webhook  -n "${CERT_MANAGER_NAMESPACE}" &>/dev/null &&
    ${KUBE_CLI} get deployment cert-manager-cainjector -n "${CERT_MANAGER_NAMESPACE}" &>/dev/null
}

################################################################################
# _cert_manager_owned_by_us
# Returns 0 if the cert-manager namespace carries our managed-by label,
# meaning this installer was the one that installed it.
################################################################################
_cert_manager_owned_by_us() {
    ${KUBE_CLI} get namespace "${CERT_MANAGER_NAMESPACE}" \
        -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' \
        2>/dev/null | grep -q "^causa-installer$"
}

################################################################################
# _label_cert_manager_namespace
# Stamps the cert-manager namespace with our ownership label.
################################################################################
_label_cert_manager_namespace() {
    ${KUBE_CLI} label namespace "${CERT_MANAGER_NAMESPACE}" \
        "${_CERT_MANAGER_MANAGED_LABEL}" \
        --overwrite \
        >>"${LOG_FILE}" 2>&1
}

################################################################################
# install_cert_manager
# Installs cert-manager if not already present, then labels the namespace so
# uninstall knows it was us who installed it.
################################################################################
install_cert_manager() {
    log_section_silent "Installing cert-manager"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping cert-manager installation"
        return 0
    fi

    # ── 1. Check if already installed ────────────────────────────────────────
    if _cert_manager_installed; then
        write_to_log_file "INFO" "cert-manager is already installed (pre-existing) — skipping install"
        write_to_log_file "INFO" "Pre-existing cert-manager will NOT be removed on --terminate"
        write_to_log_file "SUCCESS" "cert-manager already present"
        # Do NOT label — we did not install it, so uninstall must not touch it
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

    # ── 4. Label namespace — marks cert-manager as ours to uninstall ─────────
    write_to_log_file "INFO" "Labelling cert-manager namespace as causa-installer managed"
    if ! _label_cert_manager_namespace; then
        write_to_log_file "WARN" "Failed to label cert-manager namespace — uninstall may not remove it automatically"
    fi

    write_to_log_file "SUCCESS" "cert-manager is ready"
    write_to_log_file "INFO"    "cert-manager version: ${CERT_MANAGER_VERSION}"
    write_to_log_file "INFO"    "Namespace: ${CERT_MANAGER_NAMESPACE}"
    return 0
}

################################################################################
# uninstall_cert_manager
# Removes cert-manager ONLY if this installer was the one that installed it
# (detected via the causa-installer label on the cert-manager namespace).
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

    # ── Ownership check ───────────────────────────────────────────────────────
    if ! _cert_manager_owned_by_us; then
        write_to_log_file "INFO" "cert-manager was pre-existing (not installed by this installer) — skipping uninstall"
        write_to_log_file "INFO" "To remove cert-manager manually: kubectl delete -f ${CERT_MANAGER_MANIFEST_URL}"
        return 0
    fi

    # ── We installed it — remove it ───────────────────────────────────────────
    write_to_log_file "INFO" "Deleting cert-manager (installed by causa-installer)..."
    ${KUBE_CLI} delete -f "${CERT_MANAGER_MANIFEST_URL}" \
        --ignore-not-found=true \
        >>"${LOG_FILE}" 2>&1 || true

    # Wait for namespace to disappear
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
