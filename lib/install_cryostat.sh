#!/usr/bin/env bash

################################################################################
# Cryostat — Installation Functions
#
# Installs the Cryostat operator from a bundle image and creates a Cryostat
# instance in INSTALL_NAMESPACE. The Cryostat MCP server is installed only
# after this succeeds, because the mux routes tool calls to a Cryostat CR.
#
# Requires operator-sdk on PATH. On clusters without OLM (Kind), OLM is
# installed first. OpenShift already provides OLM.
# cert-manager must already be present: the Cryostat CR sets enableCertManager.
################################################################################

# Source guard
if [[ -n "${INSTALL_CRYOSTAT_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_CRYOSTAT_LIB_LOADED=1

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-causa-rca}"
KUBE_CLI="${KUBE_CLI:-kubectl}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_CRYOSTAT="${SKIP_CRYOSTAT:-false}"
CRYOSTAT_BUNDLE_IMAGE="${CRYOSTAT_BUNDLE_IMAGE:-}"
export SCRIPT_DIR INSTALL_NAMESPACE KUBE_CLI DRY_RUN SKIP_CRYOSTAT CRYOSTAT_BUNDLE_IMAGE

_CRYOSTAT_OPERATOR_NAME="cryostat-operator"
_CRYOSTAT_CR_MANIFEST="${SCRIPT_DIR}/manifests/cryostat_cr.yaml"
_CRYOSTAT_OPERATOR_TIMEOUT=300
_CRYOSTAT_PODS_TIMEOUT=600

################################################################################
# detect_cryostat_namespace
# Prints the first namespace that has a Cryostat subscription or Cryostat CR.
# Returns 0 when one is found, 1 otherwise.
################################################################################
detect_cryostat_namespace() {
    local found_ns=""

    if found_ns=$(${KUBE_CLI} get subscription -A \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
            2>/dev/null \
        | awk '$2 ~ /cryostat/ {print $1; exit}') \
        && [[ -n "${found_ns}" ]]; then
        echo "${found_ns}"
        return 0
    fi

    if found_ns=$(${KUBE_CLI} get cryostat -A \
            --no-headers \
            -o custom-columns=NAMESPACE:.metadata.namespace \
            2>/dev/null \
        | awk 'NR==1 {print $1; exit}') \
        && [[ -n "${found_ns}" ]]; then
        echo "${found_ns}"
        return 0
    fi

    echo ""
    return 1
}

################################################################################
# maybe_install_cryostat
# Skips when Cryostat is already present or --skip-cryostat is set.
# Sets CRYOSTAT_INSTALLED=true when Cryostat is available afterwards.
################################################################################
maybe_install_cryostat() {
    local target_namespace="${INSTALL_NAMESPACE:-causa-rca}"

    write_to_log_file "INFO" "Checking for an existing Cryostat installation..."

    local existing_ns
    existing_ns=$(detect_cryostat_namespace || true)

    if [[ -n "${existing_ns}" ]]; then
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Cryostat is already installed in namespace \"${existing_ns}\".${COLOR_RESET}" > /dev/tty 2>/dev/null || true
        write_to_log_file "INFO" "Cryostat already installed in namespace \"${existing_ns}\" — skipping installation"
        CRYOSTAT_INSTALLED=true
        export CRYOSTAT_INSTALLED
        return 0
    fi

    if [[ "${SKIP_CRYOSTAT:-false}" == "true" ]]; then
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Skipping Cryostat installation (--skip-cryostat).${COLOR_RESET}" > /dev/tty 2>/dev/null || true
        write_to_log_file "INFO" "Cryostat not found — skipping installation because --skip-cryostat is set"
        CRYOSTAT_INSTALLED=false
        export CRYOSTAT_INSTALLED
        return 0
    fi

    write_to_log_file "INFO" "Cryostat not found — proceeding with installation"
    start_spinner "Installing Cryostat..."

    if ! install_cryostat; then
        stop_spinner
        return ${EXIT_INSTALLATION_FAILED}
    fi

    stop_spinner
    CRYOSTAT_INSTALLED=true
    export CRYOSTAT_INSTALLED
    return 0
}

################################################################################
# _validate_cryostat_namespace
# Cryostat refuses to run in the default namespace (runAsNonRoot SCC).
################################################################################
_validate_cryostat_namespace() {
    local namespace="$1"
    if [[ -z "${namespace}" ]]; then
        log_error "Namespace is required to install Cryostat"
        return 1
    fi
    if [[ "${namespace}" == "default" ]]; then
        log_error "Cannot install Cryostat in the 'default' namespace"
        log_error "Use -n to choose another namespace, for example causa-rca"
        return 1
    fi
    return 0
}

################################################################################
# _ensure_olm
# operator-sdk run bundle needs OLM. OpenShift ships it. Kind does not.
################################################################################
_ensure_olm() {
    if ${KUBE_CLI} get crd clusterserviceversions.operators.coreos.com &>/dev/null; then
        write_to_log_file "INFO" "OLM is already installed"
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — would install OLM with: operator-sdk olm install"
        return 0
    fi

    write_to_log_file "INFO" "OLM is not installed — installing it so the Cryostat operator bundle can run"
    if ! operator-sdk olm install >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to install OLM"
        return ${EXIT_INSTALLATION_FAILED}
    fi
    write_to_log_file "SUCCESS" "OLM installed"
    return 0
}

################################################################################
# _cleanup_cryostat_operator_in
# Removes a Cryostat operator left in a namespace other than the install target.
################################################################################
_cleanup_cryostat_operator_in() {
    local existing_namespace="$1"

    write_to_log_file "INFO" "Removing Cryostat operator from ${existing_namespace}"
    ${KUBE_CLI} delete cryostat --all -n "${existing_namespace}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    if command -v operator-sdk &>/dev/null; then
        if operator-sdk cleanup "${_CRYOSTAT_OPERATOR_NAME}" -n "${existing_namespace}" >>"${LOG_FILE}" 2>&1; then
            write_to_log_file "SUCCESS" "operator-sdk cleanup completed in ${existing_namespace}"
        else
            write_to_log_file "WARN" "operator-sdk cleanup failed in ${existing_namespace}; continuing with manual cleanup"
        fi
    fi

    ${KUBE_CLI} delete csv -n "${existing_namespace}" \
        -l "operators.coreos.com/${_CRYOSTAT_OPERATOR_NAME}.${existing_namespace}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete subscription -n "${existing_namespace}" \
        -l "operators.coreos.com/${_CRYOSTAT_OPERATOR_NAME}.${existing_namespace}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete catalogsource cryostat-operator-catalog -n "${existing_namespace}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete deployment -n "${existing_namespace}" \
        -l app.kubernetes.io/name=cryostat-operator --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    local i
    for i in $(seq 1 30); do
        if ! ${KUBE_CLI} get csv -n "${existing_namespace}" 2>/dev/null | grep -q cryostat-operator; then
            write_to_log_file "SUCCESS" "Cryostat operator CSV removed from ${existing_namespace}"
            return 0
        fi
        sleep 2
    done
    write_to_log_file "WARN" "Cryostat operator CSV still present in ${existing_namespace}"
    return 0
}

################################################################################
# install_cryostat
################################################################################
install_cryostat() {
    log_section_silent "Installing Cryostat"

    local operator_namespace="${INSTALL_NAMESPACE:-causa-rca}"
    local cryostat_namespace="${INSTALL_NAMESPACE:-causa-rca}"
    local bundle_image="${CRYOSTAT_BUNDLE_IMAGE}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Cryostat installation"
        write_to_log_file "INFO" "Would run: operator-sdk run bundle ${bundle_image} -n ${operator_namespace}"
        write_to_log_file "INFO" "Would create Cryostat from ${_CRYOSTAT_CR_MANIFEST}"
        return 0
    fi

    if ! command -v operator-sdk &>/dev/null; then
        log_error "operator-sdk not found"
        log_error "Install: https://sdk.operatorframework.io/docs/installation/"
        log_error "Or pass --skip-cryostat to install without Cryostat and its MCP server"
        return ${EXIT_PREREQ_FAILED}
    fi

    if [[ -z "${bundle_image}" ]]; then
        log_error "CRYOSTAT_BUNDLE_IMAGE is empty"
        return ${EXIT_VALIDATION_FAILED}
    fi

    if ! _validate_cryostat_namespace "${cryostat_namespace}"; then
        return ${EXIT_VALIDATION_FAILED}
    fi

    if [[ ! -f "${_CRYOSTAT_CR_MANIFEST}" ]]; then
        log_error "Cryostat manifest not found: ${_CRYOSTAT_CR_MANIFEST}"
        return ${EXIT_VALIDATION_FAILED}
    fi

    if ! create_namespace; then
        log_error "Failed to create namespace for Cryostat"
        return ${EXIT_INSTALLATION_FAILED}
    fi

    if ! _ensure_olm; then
        return ${EXIT_INSTALLATION_FAILED}
    fi

    local existing_namespace=""
    local needs_installation=true
    existing_namespace=$(${KUBE_CLI} get subscription -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | awk '$2 ~ /cryostat/ {print $1; exit}' || true)

    if [[ -n "${existing_namespace}" ]]; then
        if [[ "${existing_namespace}" == "${operator_namespace}" ]]; then
            write_to_log_file "INFO" "Cryostat operator already present in ${operator_namespace}"
            needs_installation=false
        else
            write_to_log_file "INFO" "Cryostat operator found in ${existing_namespace}; moving it to ${operator_namespace}"
            _cleanup_cryostat_operator_in "${existing_namespace}"
            needs_installation=true
        fi
    fi

    if [[ "${needs_installation}" == "true" ]]; then
        write_to_log_file "INFO" "Installing Cryostat operator bundle ${bundle_image} in ${operator_namespace}"
        if ${KUBE_CLI} get catalogsource cryostat-operator-catalog -n "${operator_namespace}" >>"${LOG_FILE}" 2>&1; then
            write_to_log_file "INFO" "Removing stale cryostat-operator-catalog before bundle install"
            ${KUBE_CLI} delete catalogsource cryostat-operator-catalog -n "${operator_namespace}" >>"${LOG_FILE}" 2>&1 || true
            sleep 5
        fi

        if ! operator-sdk run bundle "${bundle_image}" -n "${operator_namespace}" >>"${LOG_FILE}" 2>&1; then
            log_error "Failed to install the Cryostat operator bundle"
            return ${EXIT_INSTALLATION_FAILED}
        fi
        write_to_log_file "SUCCESS" "Cryostat operator bundle installed in ${operator_namespace}"

        write_to_log_file "INFO" "Waiting for the Cryostat operator to become ready"
        local operator_wait=0
        while [[ ${operator_wait} -lt 60 ]]; do
            if ${KUBE_CLI} get pods -n "${operator_namespace}" -l app.kubernetes.io/name=cryostat-operator --no-headers 2>/dev/null | grep -q .; then
                break
            fi
            sleep 5
            operator_wait=$((operator_wait + 1))
        done
        if ! ${KUBE_CLI} wait --for=condition=Ready pod \
            -l app.kubernetes.io/name=cryostat-operator \
            -n "${operator_namespace}" \
            --timeout="${_CRYOSTAT_OPERATOR_TIMEOUT}s" >>"${LOG_FILE}" 2>&1; then
            log_error "Cryostat operator pods did not become ready in ${operator_namespace}"
            ${KUBE_CLI} get pods -n "${operator_namespace}" -l app.kubernetes.io/name=cryostat-operator >>"${LOG_FILE}" 2>&1 || true
            return ${EXIT_INSTALLATION_FAILED}
        fi
        write_to_log_file "SUCCESS" "Cryostat operator is running"
    fi

    local instance_count=0
    instance_count=$(${KUBE_CLI} get cryostat -n "${cryostat_namespace}" --no-headers 2>/dev/null | wc -l | tr -d ' ') || instance_count=0
    instance_count="${instance_count:-0}"

    if [[ "${instance_count}" -gt 0 ]]; then
        write_to_log_file "INFO" "Cryostat instance already exists in ${cryostat_namespace}"
        ${KUBE_CLI} get cryostat -n "${cryostat_namespace}" >>"${LOG_FILE}" 2>&1 || true
    else
        write_to_log_file "INFO" "Creating Cryostat instance in ${cryostat_namespace}"
        if ! ${KUBE_CLI} create -f "${_CRYOSTAT_CR_MANIFEST}" -n "${cryostat_namespace}" >>"${LOG_FILE}" 2>&1; then
            log_error "Failed to create the Cryostat instance"
            return ${EXIT_INSTALLATION_FAILED}
        fi
        write_to_log_file "SUCCESS" "Cryostat instance created"

        write_to_log_file "INFO" "Waiting for Cryostat pods"
        local wait_count=0
        local pod_count=0
        while [[ ${wait_count} -lt 12 ]]; do
            pod_count=$(${KUBE_CLI} get pods -n "${cryostat_namespace}" -l component=cryostat --no-headers 2>/dev/null | wc -l | tr -d ' ') || pod_count=0
            if [[ "${pod_count}" -gt 0 ]]; then
                break
            fi
            sleep 5
            wait_count=$((wait_count + 1))
        done

        if [[ "${pod_count}" -eq 0 ]]; then
            write_to_log_file "WARN" "No Cryostat pods appeared within 60 seconds"
        elif ! ${KUBE_CLI} wait --for=condition=Ready pod \
            -l component=cryostat \
            -n "${cryostat_namespace}" \
            --timeout="${_CRYOSTAT_PODS_TIMEOUT}s" >>"${LOG_FILE}" 2>&1; then
            write_to_log_file "WARN" "Cryostat pods did not become ready within ${_CRYOSTAT_PODS_TIMEOUT}s"
            ${KUBE_CLI} get pods -n "${cryostat_namespace}" -l component=cryostat >>"${LOG_FILE}" 2>&1 || true
        else
            write_to_log_file "SUCCESS" "Cryostat pods are ready"
        fi
    fi

    write_to_log_file "SUCCESS" "Cryostat installation completed in ${cryostat_namespace}"
    return ${EXIT_SUCCESS}
}

################################################################################
# uninstall_cryostat
################################################################################
uninstall_cryostat() {
    log_section_silent "Uninstalling Cryostat"

    local operator_namespace="${INSTALL_NAMESPACE:-causa-rca}"
    local cryostat_namespace="${INSTALL_NAMESPACE:-causa-rca}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping Cryostat uninstallation"
        return 0
    fi

    local cryostat_deployed=false
    if ${KUBE_CLI} get cryostat -n "${cryostat_namespace}" --no-headers 2>/dev/null | grep -q .; then
        cryostat_deployed=true
    fi
    if ${KUBE_CLI} get csv -n "${operator_namespace}" -o name 2>/dev/null | grep -q "${_CRYOSTAT_OPERATOR_NAME}"; then
        cryostat_deployed=true
    fi
    if ${KUBE_CLI} get pods -n "${cryostat_namespace}" -l component=cryostat --no-headers 2>/dev/null | grep -q .; then
        cryostat_deployed=true
    fi

    if [[ "${cryostat_deployed}" == "false" ]]; then
        write_to_log_file "INFO" "Cryostat is not deployed in ${cryostat_namespace}"
        return 0
    fi

    write_to_log_file "INFO" "Deleting Cryostat instances in ${cryostat_namespace}"
    ${KUBE_CLI} delete cryostat --all -n "${cryostat_namespace}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    if command -v operator-sdk &>/dev/null; then
        if operator-sdk cleanup "${_CRYOSTAT_OPERATOR_NAME}" -n "${operator_namespace}" >>"${LOG_FILE}" 2>&1; then
            write_to_log_file "SUCCESS" "operator-sdk cleanup completed"
        else
            write_to_log_file "WARN" "operator-sdk cleanup failed; continuing with manual cleanup"
        fi
    else
        write_to_log_file "WARN" "operator-sdk not found; removing Cryostat operator resources directly"
    fi

    ${KUBE_CLI} delete csv -n "${operator_namespace}" \
        -l "operators.coreos.com/${_CRYOSTAT_OPERATOR_NAME}.${operator_namespace}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete subscription -n "${operator_namespace}" \
        -l "operators.coreos.com/${_CRYOSTAT_OPERATOR_NAME}.${operator_namespace}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete catalogsource cryostat-operator-catalog -n "${operator_namespace}" \
        --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete deployment -n "${operator_namespace}" \
        -l app.kubernetes.io/name=cryostat-operator --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    ${KUBE_CLI} delete pods -n "${operator_namespace}" \
        -l app.kubernetes.io/name=cryostat-operator --ignore-not-found=true \
        --grace-period=0 --force >>"${LOG_FILE}" 2>&1 || true

    write_to_log_file "SUCCESS" "Cryostat uninstalled from ${cryostat_namespace}"
    return 0
}

export -f detect_cryostat_namespace
export -f maybe_install_cryostat
export -f install_cryostat
export -f uninstall_cryostat
