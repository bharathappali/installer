#!/usr/bin/env bash

################################################################################
# Install Utilities — Causa RCA Installer
#
# Shared utility functions used across all component installation scripts.
################################################################################

# Prevent multiple sourcing
if [[ -n "${INSTALL_UTILS_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly INSTALL_UTILS_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
readonly EXIT_SUCCESS=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_PREREQ_FAILED=2
readonly EXIT_PERMISSION_DENIED=3
readonly EXIT_INSTALLATION_FAILED=4
readonly EXIT_VALIDATION_FAILED=5

################################################################################
# Error / cleanup
################################################################################
cleanup_on_error() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 && ${exit_code} -lt 128 ]]; then
        log_error "Installation failed with exit code: ${exit_code}"
        if [[ -n "${LOG_FILE:-}" ]]; then
            echo -e "${COLOR_GREEN}Check log file for details: ${LOG_FILE}${COLOR_RESET}" > /dev/tty 2>/dev/null || true
        fi
    fi
}

################################################################################
# enable_cleanup_trap
# Opt-in: call this from the top-level installer entrypoint after sourcing this
# library. Not called automatically to avoid interfering with callers' own traps.
################################################################################
enable_cleanup_trap() {
    trap cleanup_on_error EXIT
}

handle_error() {
    local exit_code="$1"
    local message="$2"
    log_error "${message}"
    exit "${exit_code}"
}

################################################################################
# OS / architecture detection
################################################################################
detect_os() {
    case "$OSTYPE" in
        linux-gnu*) echo "linux" ;;
        darwin*)    echo "darwin" ;;
        *) handle_error ${EXIT_GENERAL_ERROR} "Unsupported OS type: $OSTYPE" ;;
    esac
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *) handle_error ${EXIT_GENERAL_ERROR} "Unsupported architecture: ${arch}" ;;
    esac
}

################################################################################
# Cross-platform timeout helper
# Preference order: GNU timeout → perl → no-timeout fallback (with warning)
################################################################################
run_with_timeout() {
    local timeout_duration="$1"; shift
    if command -v timeout &>/dev/null; then
        timeout "${timeout_duration}" "$@"
        return $?
    fi
    if command -v perl &>/dev/null; then
        perl -e '
            use POSIX ":sys_wait_h";
            my $t = shift; my $pid = fork();
            if ($pid == 0) { exec(@ARGV) or die "exec: $!\n"; }
            my $s = time();
            while (1) {
                my $k = waitpid($pid, WNOHANG);
                exit($? >> 8) if $k == $pid;
                if (time()-$s >= $t) { kill 15,$pid; sleep 2; kill 9,$pid; waitpid($pid,0); exit(124); }
                sleep 1;
            }
        ' "${timeout_duration}" "$@"
        return $?
    fi
    # Neither timeout nor perl available — run without a timeout and warn
    log_warn "run_with_timeout: neither 'timeout' nor 'perl' found; running '${*}' without a timeout"
    "$@"
    return $?
}

################################################################################
# Command existence check
################################################################################
check_command_exists() {
    command -v "$1" &>/dev/null
}

################################################################################
# Namespace creation (idempotent)
################################################################################
create_namespace() {
    local ns="${INSTALL_NAMESPACE}"
    write_to_log_file "INFO" "Ensuring namespace exists: ${ns}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping namespace creation"
        return 0
    fi

    if ${KUBE_CLI} get namespace "${ns}" &>/dev/null; then
        local phase
        phase=$(${KUBE_CLI} get namespace "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "${phase}" == "Terminating" ]]; then
            log_warn "Namespace ${ns} is terminating — waiting up to 120s..."
            local waited=0
            while ${KUBE_CLI} get namespace "${ns}" &>/dev/null; do
                [[ ${waited} -ge 120 ]] && { log_error "Timeout waiting for namespace deletion"; return 1; }
                sleep 5; waited=$((waited+5))
            done
        else
            write_to_log_file "INFO" "Namespace ${ns} already exists"
            return 0
        fi
    fi

    if ! ${KUBE_CLI} create namespace "${ns}" >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to create namespace ${ns}"
        return 1
    fi
    write_to_log_file "SUCCESS" "Namespace ${ns} created"
    return 0
}

################################################################################
# Wait for a deployment to reach ready state
# Usage: wait_for_deployment <name> <namespace> <timeout_seconds>
################################################################################
wait_for_deployment() {
    local name="$1"
    local ns="${2:-${INSTALL_NAMESPACE}}"
    local timeout="${3:-300}"

    write_to_log_file "INFO" "Waiting for deployment ${name} in ${ns} (timeout: ${timeout}s)..."

    if ! ${KUBE_CLI} wait --for=condition=Available \
        deployment/"${name}" \
        -n "${ns}" \
        --timeout="${timeout}s" >>"${LOG_FILE}" 2>&1; then
        write_to_log_file "ERROR" "Deployment ${name} failed to become ready"
        ${KUBE_CLI} get pods -n "${ns}" -l "app=${name}" >>"${LOG_FILE}" 2>&1 || true
        ${KUBE_CLI} describe deployment "${name}" -n "${ns}" >>"${LOG_FILE}" 2>&1 || true
        return 1
    fi

    write_to_log_file "SUCCESS" "Deployment ${name} is ready"
    return 0
}

################################################################################
# Calculate elapsed time label
# Usage: label=$(calculate_elapsed_label <start_epoch>)
################################################################################
calculate_elapsed_label() {
    local start="$1"
    local end; end=$(date +%s)
    local elapsed=$(( end - start ))
    local m=$(( elapsed / 60 ))
    local s=$(( elapsed % 60 ))
    [[ $m -gt 0 ]] && echo "${m}m ${s}s" || echo "${s}s"
}

################################################################################
# Apply a YAML manifest with optional namespace and image substitution.
#
# Usage: apply_manifest <manifest_file> [namespace] [image_var_name] [image_value]
#
# The function creates a temporary copy, performs sed replacements for the
# namespace placeholder (PLACEHOLDER_NAMESPACE) and an optional image line,
# applies it, then cleans up.
################################################################################
apply_manifest() {
    local manifest="$1"
    local ns="${2:-${INSTALL_NAMESPACE}}"
    local img_pattern="${3:-}"   # sed pattern to match image line
    local img_value="${4:-}"     # new image value

    if [[ ! -f "${manifest}" ]]; then
        write_to_log_file "ERROR" "Manifest not found: ${manifest}"
        return 1
    fi

    local tmp; tmp=$(mktemp /tmp/causa-rca-manifest-XXXXXX.yaml)

    # Namespace substitution
    sed "s/PLACEHOLDER_NAMESPACE/${ns}/g" "${manifest}" > "${tmp}"

    # Optional image substitution
    if [[ -n "${img_pattern}" && -n "${img_value}" ]]; then
        sed -i.bak "s|${img_pattern}|image: ${img_value}|g" "${tmp}" && rm -f "${tmp}.bak"
    fi

    write_to_log_file "INFO" "Applying manifest: ${manifest} → namespace ${ns}"

    local rc=0
    ${KUBE_CLI} apply -f "${tmp}" >>"${LOG_FILE}" 2>&1 || rc=$?
    rm -f "${tmp}"

    if [[ ${rc} -ne 0 ]]; then
        write_to_log_file "ERROR" "kubectl apply failed for ${manifest}"
        return 1
    fi

    write_to_log_file "SUCCESS" "Manifest applied: ${manifest}"
    return 0
}

################################################################################
# Delete a YAML manifest (for uninstall)
################################################################################
delete_manifest() {
    local manifest="$1"
    local ns="${2:-${INSTALL_NAMESPACE}}"

    if [[ ! -f "${manifest}" ]]; then
        write_to_log_file "WARN" "Manifest not found during delete (already removed?): ${manifest}"
        return 0
    fi

    local tmp; tmp=$(mktemp /tmp/causa-rca-manifest-XXXXXX.yaml)
    sed "s/PLACEHOLDER_NAMESPACE/${ns}/g" "${manifest}" > "${tmp}"

    ${KUBE_CLI} delete -f "${tmp}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true
    rm -f "${tmp}"

    write_to_log_file "INFO" "Resources from ${manifest} deleted (or already absent)"
    return 0
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
export -f cleanup_on_error
export -f enable_cleanup_trap
export -f handle_error
export -f detect_os
export -f detect_arch
export -f run_with_timeout
export -f check_command_exists
export -f create_namespace
export -f wait_for_deployment
export -f calculate_elapsed_label
export -f apply_manifest
export -f delete_manifest
