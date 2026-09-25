#!/usr/bin/env bash

################################################################################
# Causa RCA Installer — Main Orchestrator
#
# Provisions the target environment and deploys the full RCA stack:
#   - Prometheus Stack (kube-prometheus-stack) + Alertmanager webhook → Causa
#   - Kubernetes MCP Server
#   - Cryostat (operator + instance)
#   - Cryostat MCP Server
#   - Jafra MCP Server
#   - Quarkus MCP Server
#   - PostgreSQL
#   - Causa Backend (RCA engine)
#   - Causa MCP Server
#
# Usage:
#   ./install.sh [OPTIONS]
#
# See show_usage() for full option list or run with --help.
################################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Script directory — all paths are relative to here
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# ---------------------------------------------------------------------------
# Source images.env FIRST — defines image defaults; can be overridden by
# CLI flags or exported env vars (priority: CLI > export > images.env)
# ---------------------------------------------------------------------------
IMAGES_ENV_FILE="${SCRIPT_DIR}/lib/images.env"
if [[ -f "${IMAGES_ENV_FILE}" ]]; then
    # shellcheck source=lib/images.env
    source "${IMAGES_ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# Global configuration defaults
# ---------------------------------------------------------------------------
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

# State file — persists values that must survive across separate invocations
# (e.g. install vs. uninstall).  Written by main(), read by uninstall_main().
# Keys written:
#   CONTAINER_RUNTIME          — docker|podman (kind target only)
#   KIND_CLUSTER_NAME          — cluster name used at install time (kind target only)
#   KIND_REGISTRY_NAME         — registry container name (kind target only)
#   KIND_REGISTRY_PORT         — local registry port (kind target only)
#   JAFRA_INSTALLED            — true if Jafra Ecosystem was successfully installed
#   JAFRA_MCP_INSTALLED        — true if Jafra MCP Server was successfully installed
#   QUARKUS_MCP_INSTALLED      — true if Quarkus MCP Server was successfully installed
INSTALLER_STATE_FILE="${SCRIPT_DIR}/.causa-rca-state"

# Namespace where all RCA components are deployed
INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-causa-rca}"
export INSTALL_NAMESPACE

# Cluster CLI
KUBE_CLI="${KUBE_CLI:-kubectl}"
export KUBE_CLI

# Target platform — determines which infrastructure steps run.
# Supported values: kind | openshift
#   kind       → creates a Kind cluster + local registry + installs Prometheus stack
#   openshift  → connects to an existing OpenShift cluster; uses built-in UWM
#                (no cluster creation, no Prometheus install, no cert-manager install)
INSTALL_TARGET="${INSTALL_TARGET:-kind}"
export INSTALL_TARGET

# Behaviour flags
DRY_RUN="${DRY_RUN:-false}"
TERMINATE="${TERMINATE:-false}"
export DRY_RUN TERMINATE

# Kind cluster settings (consumed by lib/install_kind_cluster.sh)
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-causa-rca}"
KIND_REGISTRY_NAME="${KIND_REGISTRY_NAME:-causa-rca-registry}"
KIND_REGISTRY_PORT="${KIND_REGISTRY_PORT:-5001}"
export KIND_CLUSTER_NAME KIND_REGISTRY_NAME KIND_REGISTRY_PORT

# Configurable endpoint for the Quarkus app under analysis (used by Causa Backend)
# Override via: export CAUSA_MCP_QUARKUS_METRICS_BASE_URL="http://my-app.my-ns.svc.cluster.local:8080"
CAUSA_MCP_QUARKUS_METRICS_BASE_URL="${CAUSA_MCP_QUARKUS_METRICS_BASE_URL:-}"
export CAUSA_MCP_QUARKUS_METRICS_BASE_URL

# Optional Cryostat bearer token. When unset, the installer creates
# cryostat-mcp-client and mints a one-year token.
CRYOSTAT_AUTH_TOKEN="${CRYOSTAT_AUTH_TOKEN:-}"
# Cryostat operator bundle. Empty until images.env is sourced; CLI may override.
CRYOSTAT_BUNDLE_IMAGE="${CRYOSTAT_BUNDLE_IMAGE:-}"
# Skip the Cryostat operator, instance, and Cryostat MCP server.
SKIP_CRYOSTAT="${SKIP_CRYOSTAT:-false}"
export CRYOSTAT_AUTH_TOKEN CRYOSTAT_BUNDLE_IMAGE SKIP_CRYOSTAT

# Image variables (populated by images.env; can be overridden via CLI flags)
K8S_MCP_SERVER_IMAGE="${K8S_MCP_SERVER_IMAGE:-}"
CRYOSTAT_MCP_SERVER_IMAGE="${CRYOSTAT_MCP_SERVER_IMAGE:-}"
CAUSA_BACKEND_IMAGE="${CAUSA_BACKEND_IMAGE:-}"
JAFRA_MCP_IMAGE="${JAFRA_MCP_IMAGE:-}"
QUARKUS_MCP_IMAGE="${QUARKUS_MCP_IMAGE:-}"
PROMETHEUS_MCP_SERVER_IMAGE="${PROMETHEUS_MCP_SERVER_IMAGE:-}"
CAUSA_MCP_IMAGE="${CAUSA_MCP_IMAGE:-}"
JAFRA_CONTROLLER_IMAGE="${JAFRA_CONTROLLER_IMAGE:-}"
JAFRA_ANALYZER_IMAGE="${JAFRA_ANALYZER_IMAGE:-}"
JAFRA_AGENT_IMAGE="${JAFRA_AGENT_IMAGE:-}"
POSTGRES_KIND_IMAGE="${POSTGRES_KIND_IMAGE:-}"
POSTGRES_OCP_IMAGE="${POSTGRES_OCP_IMAGE:-}"
export K8S_MCP_SERVER_IMAGE CRYOSTAT_MCP_SERVER_IMAGE CAUSA_BACKEND_IMAGE
export JAFRA_MCP_IMAGE QUARKUS_MCP_IMAGE PROMETHEUS_MCP_SERVER_IMAGE CAUSA_MCP_IMAGE
export JAFRA_CONTROLLER_IMAGE JAFRA_ANALYZER_IMAGE JAFRA_AGENT_IMAGE
export POSTGRES_KIND_IMAGE POSTGRES_OCP_IMAGE

# Sentinel flags — set to "true" only when a CLI flag explicitly overrides an image
K8S_MCP_SERVER_IMAGE_OVERRIDDEN=false
CRYOSTAT_MCP_SERVER_IMAGE_OVERRIDDEN=false
CRYOSTAT_BUNDLE_IMAGE_OVERRIDDEN=false
CAUSA_BACKEND_IMAGE_OVERRIDDEN=false
JAFRA_MCP_IMAGE_OVERRIDDEN=false
QUARKUS_MCP_IMAGE_OVERRIDDEN=false
PROMETHEUS_MCP_SERVER_IMAGE_OVERRIDDEN=false
CAUSA_MCP_IMAGE_OVERRIDDEN=false
JAFRA_CONTROLLER_IMAGE_OVERRIDDEN=false
JAFRA_ANALYZER_IMAGE_OVERRIDDEN=false
JAFRA_AGENT_IMAGE_OVERRIDDEN=false
POSTGRES_KIND_IMAGE_OVERRIDDEN=false
POSTGRES_OCP_IMAGE_OVERRIDDEN=false
export K8S_MCP_SERVER_IMAGE_OVERRIDDEN CRYOSTAT_MCP_SERVER_IMAGE_OVERRIDDEN CRYOSTAT_BUNDLE_IMAGE_OVERRIDDEN CAUSA_BACKEND_IMAGE_OVERRIDDEN
export JAFRA_MCP_IMAGE_OVERRIDDEN QUARKUS_MCP_IMAGE_OVERRIDDEN PROMETHEUS_MCP_SERVER_IMAGE_OVERRIDDEN CAUSA_MCP_IMAGE_OVERRIDDEN
export JAFRA_CONTROLLER_IMAGE_OVERRIDDEN JAFRA_ANALYZER_IMAGE_OVERRIDDEN JAFRA_AGENT_IMAGE_OVERRIDDEN
export POSTGRES_KIND_IMAGE_OVERRIDDEN POSTGRES_OCP_IMAGE_OVERRIDDEN

# ---------------------------------------------------------------------------
# Source library files
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/install_utils.sh"
source "${SCRIPT_DIR}/lib/validator.sh"
source "${SCRIPT_DIR}/lib/install_kind_cluster.sh"
source "${SCRIPT_DIR}/lib/install_prometheus.sh"
source "${SCRIPT_DIR}/lib/enable_monitoring.sh"
source "${SCRIPT_DIR}/lib/install_cert_manager.sh"
source "${SCRIPT_DIR}/lib/install_k8s_mcp.sh"
source "${SCRIPT_DIR}/lib/install_cryostat.sh"
source "${SCRIPT_DIR}/lib/install_cryostat_mcp.sh"
source "${SCRIPT_DIR}/lib/install_jafra.sh"
source "${SCRIPT_DIR}/lib/install_jafra_mcp.sh"
source "${SCRIPT_DIR}/lib/install_quarkus_mcp.sh"
source "${SCRIPT_DIR}/lib/install_prometheus_mcp.sh"
source "${SCRIPT_DIR}/lib/install_postgres.sh"
source "${SCRIPT_DIR}/lib/install_causa.sh"
source "${SCRIPT_DIR}/lib/install_causa_mcp.sh"

# ---------------------------------------------------------------------------
# Activate opt-in traps (scoped here, not in shared libraries)
# ---------------------------------------------------------------------------
enable_cleanup_trap   # lib/install_utils.sh — log error on unexpected EXIT
enable_spinner_trap   # lib/logging.sh       — stop spinner cleanly on INT/TERM

# Temp file cleanup — remove stale files from a previous crashed run.
# Only removes files whose name encodes this process's PID, so a concurrent
# installer invocation on the same host is not affected.
# ---------------------------------------------------------------------------
rm -f /tmp/causa-$$-*.yaml

# ---------------------------------------------------------------------------
# Logging initialisation
# ---------------------------------------------------------------------------
initialize_logging() {
    LOG_FILE="${SCRIPT_DIR}/install.log"
    if [[ "${TERMINATE:-false}" == "true" ]]; then
        {
            echo "========================================"
            echo "Uninstallation Log"
            echo "Started: $(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"
            echo "========================================"
            echo ""
        } > "${LOG_FILE}"
        init_logging "${LOG_FILE}" "true"
    else
        init_logging "${LOG_FILE}"
    fi
}

################################################################################
# _is_kind_target — returns 0 when the install target is kind
################################################################################
_is_kind_target() {
    [[ "${INSTALL_TARGET}" == "kind" ]]
}

################################################################################
# _is_openshift_target — returns 0 when the install target is openshift
################################################################################
_is_openshift_target() {
    [[  "${INSTALL_TARGET}" == "openshift" ]]
}

################################################################################
# _install_kind_only_components — kind-target-only steps (cert-manager path,
# PostgreSQL Deployment, Causa Backend, Causa MCP)
################################################################################
_install_kind_only_components() {
    # ── Step 7: PostgreSQL ───────────────────────────────────────────────────
    start_spinner "Installing PostgreSQL..."
    if ! install_postgres; then
        stop_spinner
        log_error "Failed to install PostgreSQL"
        exit 1
    fi
    stop_spinner
    log_install_success "PostgreSQL"
    installed_components+=("PostgreSQL")

    # ── Step 8: Causa Backend ────────────────────────────────────────────────
    start_spinner "Installing Causa Backend..."
    if ! install_causa; then
        stop_spinner
        log_error "Failed to install Causa Backend"
        exit 1
    fi
    stop_spinner
    log_install_success "Causa Backend"
    installed_components+=("Causa Backend")

    # ── Step 9: Causa MCP Server ─────────────────────────────────────────────
    start_spinner "Installing Causa MCP Server..."
    if ! install_causa_mcp; then
        stop_spinner
        log_warn "Causa MCP Server installation skipped or failed"
    else
        stop_spinner
        log_install_success "Causa MCP Server"
        installed_components+=("Causa MCP Server")
    fi
}

################################################################################
# _uninstall_kind_only_components — teardown for kind-only components
################################################################################
_uninstall_kind_only_components() {
    start_spinner "Uninstalling Causa MCP Server..."
    uninstall_causa_mcp
    stop_spinner; log_uninstall_success "Causa MCP Server"

    start_spinner "Uninstalling cert-manager..."
    uninstall_cert_manager
    stop_spinner; log_uninstall_success "cert-manager"

    start_spinner "Uninstalling Causa Backend..."
    if ! uninstall_causa; then
        stop_spinner; log_error "Failed to uninstall Causa Backend"; exit 1
    fi
    stop_spinner; log_uninstall_success "Causa Backend"

    start_spinner "Uninstalling PostgreSQL..."
    uninstall_postgres
    stop_spinner; log_uninstall_success "PostgreSQL"
}

################################################################################
# main — install
################################################################################
main() {
    local start_time; start_time=$(date +%s)

    write_to_log_file "INFO" "Starting Causa RCA installation..."
    write_to_log_file "INFO" "Target:         ${INSTALL_TARGET}"
    write_to_log_file "INFO" "Namespace:      ${INSTALL_NAMESPACE}"
    write_to_log_file "INFO" "kubectl:        ${KUBE_CLI}"
    if _is_kind_target; then
        write_to_log_file "INFO" "Kind cluster:   ${KIND_CLUSTER_NAME}"
        write_to_log_file "INFO" "Registry:       localhost:${KIND_REGISTRY_PORT}"
    fi

    # ── Pre-flight checks ────────────────────────────────────────────────────
    log_section "Pre-installation Validation"

    if ! validate_prerequisites; then
        log_error "Prerequisites check failed"
        exit 1
    fi

    # OpenShift pre-req: cert-manager must be present before any component runs.
    # Placed here — after validate_prerequisites confirms oc/kubectl is available
    # but before any cluster-side work — so a missing cert-manager is caught as
    # early as possible in the validation section.
    if _is_openshift_target; then
        if ! validate_cert_manager_with_prompt; then
            log_error "cert-manager pre-req check failed"
            exit 1
        fi
    fi

    # kind-only pre-flight: persist the detected runtime and cluster settings so
    # that an uninstall invocation without the original env vars targets the
    # correct Kind cluster and container daemon.
    if _is_kind_target; then
        {
            echo "CONTAINER_RUNTIME=${CONTAINER_RUNTIME}"
            echo "KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME}"
            echo "KIND_REGISTRY_NAME=${KIND_REGISTRY_NAME}"
            echo "KIND_REGISTRY_PORT=${KIND_REGISTRY_PORT}"
        } > "${INSTALLER_STATE_FILE}"
        write_to_log_file "INFO" "Installer state persisted: runtime=${CONTAINER_RUNTIME} cluster=${KIND_CLUSTER_NAME} (${INSTALLER_STATE_FILE})"

        if ! validate_docker_running; then
            log_error "Docker is not running"
            exit 1
        fi
    fi

    if ! validate_image_overrides; then
        log_error "Image validation failed"
        exit 1
    fi

    # ── Step 1: Kind cluster + local registry (kind target only) ────────────
    local installed_components=()

    if _is_kind_target; then
        start_spinner "Provisioning Kind cluster and local registry..."
        if ! install_kind_cluster; then
            stop_spinner
            log_error "Failed to provision Kind cluster"
            exit 1
        fi
        stop_spinner
        log_install_success "Kind Cluster (${KIND_CLUSTER_NAME})"
        installed_components+=("Kind Cluster (${KIND_CLUSTER_NAME})")
    fi

    # After cluster is ready, validate connectivity
    # Skip for dry-run on kind target — the cluster doesn't exist yet
    if [[ "${DRY_RUN}" != "true" ]] || ! _is_kind_target; then
        if ! validate_cluster_access; then
            log_error "Cluster access check failed"
            exit 1
        fi
    fi

    # ── Step 2: Enable monitoring + Prometheus alerts ────────
    if _is_openshift_target; then
        start_spinner "Enabling monitoring and Prometheus alerts..."
        if ! enable_monitoring; then
            stop_spinner
            log_error "Failed to enable monitoring"
            exit 1
        fi
        stop_spinner
        log_install_success "Monitoring and Prometheus Alerts"
    fi

    # ── Step 2: Prometheus Stack (kind target only) ──────────────────────────
    if _is_kind_target; then
        start_spinner "Installing Prometheus Stack (kube-prometheus-stack)..."
        if ! install_prometheus; then
            stop_spinner
            log_error "Failed to install Prometheus Stack"
            exit 1
        fi
        stop_spinner
        log_install_success "Prometheus Stack (kube-prometheus-stack)"
    fi

    # ── Step 3: cert-manager (kind target only, required by Jafra) ───────────
    if _is_kind_target; then
        start_spinner "Installing cert-manager..."
        if ! install_cert_manager; then
            stop_spinner
            log_error "Failed to install cert-manager"
            exit 1
        fi
        stop_spinner
        log_install_success "cert-manager"
        installed_components+=("cert-manager")
    fi

    # ── Step 4: Kubernetes MCP Server ───────────────────────────────────────
    start_spinner "Installing Kubernetes MCP Server..."
    if ! install_kubernetes_mcp_server; then
        stop_spinner
        log_error "Failed to install Kubernetes MCP Server"
        exit 1
    fi
    stop_spinner
    log_install_success "Kubernetes MCP Server"
    installed_components+=("Kubernetes MCP Server")

    # ── Cryostat operator + instance, then the MCP mux that routes to it ──
    # Spinner for Cryostat itself is owned by maybe_install_cryostat.
    # The MCP server is installed only when a Cryostat instance is available.
    if ! maybe_install_cryostat; then
        log_error "Failed to install Cryostat"
        exit 1
    fi
    if [[ "${CRYOSTAT_INSTALLED:-false}" == "true" ]]; then
        log_install_success "Cryostat"
        installed_components+=("Cryostat")

        start_spinner "Installing Cryostat MCP Server..."
        if ! install_cryostat_mcp_server; then
            stop_spinner
            log_error "Failed to install Cryostat MCP Server"
            exit 1
        fi
        stop_spinner
        log_install_success "Cryostat MCP Server"
        installed_components+=("Cryostat MCP Server")
    else
        write_to_log_file "INFO" "Cryostat MCP Server skipped because Cryostat was not installed"
    fi

    # ── Step 5: Jafra Ecosystem (Controller + Analyzer + Agent) ─────────────
    # Not supported on OpenShift — skipped for that target.
    if ! _is_openshift_target; then
        start_spinner "Installing Jafra Ecosystem..."
        if ! install_jafra; then
            stop_spinner
            log_warn "Jafra Ecosystem installation skipped or failed"
        else
            stop_spinner
            log_install_success "Jafra Ecosystem"
            installed_components+=("Jafra Ecosystem")
        fi
    fi

    # ── Step 6: Jafra MCP Server ─────────────────────────────────────────────
    # Not supported on OpenShift — skipped for that target.
    if ! _is_openshift_target; then
        start_spinner "Installing Jafra MCP Server..."
        if ! install_jafra_mcp; then
            stop_spinner
            log_warn "Jafra MCP Server installation skipped or failed"
        else
            stop_spinner
            log_install_success "Jafra MCP Server"
            installed_components+=("Jafra MCP Server")
        fi
    fi

    # ── Step 7: Quarkus MCP Server ───────────────────────────────────────────
    start_spinner "Installing Quarkus MCP Server..."
    if ! install_quarkus_mcp; then
        stop_spinner
        log_warn "Quarkus MCP Server installation skipped or failed"
    else
        stop_spinner
        log_install_success "Quarkus MCP Server"
        installed_components+=("Quarkus MCP Server")
    fi
    # ── Step 8: Prometheus MCP Server ────────────────────────────────────────
    start_spinner "Installing Prometheus MCP Server..."
    if ! install_prometheus_mcp_server; then
        stop_spinner
        log_warn "Prometheus MCP Server installation skipped or failed"
    else
        stop_spinner
        log_install_success "Prometheus MCP Server"
        installed_components+=("Prometheus MCP Server")
    fi

    # ── Steps 9-10: PostgreSQL + Causa Backend + Causa MCP ───────────────────
    # On kind these run via _install_kind_only_components (standalone PG Deployment).
    # On OpenShift they run directly (CNPG operator + OCP Route variants).
    if _is_kind_target; then
        _install_kind_only_components
    else
        start_spinner "Installing PostgreSQL..."
        if ! install_postgres; then
            stop_spinner
            log_error "Failed to install PostgreSQL"
            exit 1
        fi
        stop_spinner
        log_install_success "PostgreSQL"
        installed_components+=("PostgreSQL")

        start_spinner "Installing Causa Backend..."
        if ! install_causa; then
            stop_spinner
            log_error "Failed to install Causa Backend"
            exit 1
        fi
        stop_spinner
        log_install_success "Causa Backend"
        installed_components+=("Causa Backend")

        start_spinner "Installing Causa MCP Server..."
        if ! install_causa_mcp; then
            stop_spinner
            log_warn "Causa MCP Server installation skipped or failed"
        else
            stop_spinner
            log_install_success "Causa MCP Server"
            installed_components+=("Causa MCP Server")
        fi
    fi

    # ── Post-install summary ─────────────────────────────────────────────────
    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Component Installation Summary${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
        echo ""
        for c in "${installed_components[@]}"; do
            echo -e "${COLOR_BOLD_GREEN}${c} ✓${COLOR_RESET}"
        done
        echo ""
    } >/dev/tty 2>/dev/null || true

    local elapsed; elapsed=$(calculate_elapsed_label "${start_time}")

    post_component_validation "${elapsed}"

    _print_log_summary

    write_to_log_file "SUCCESS" "Installation completed in ${elapsed}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        write_to_log_file "INFO" "Log: ${LOG_FILE}"
    fi
}

################################################################################
# uninstall_main — teardown
################################################################################
uninstall_main() {
    local start_time; start_time=$(date +%s)

    log_file_only "Starting Causa RCA uninstallation..."

    # Restore the container runtime for kind targets — ensures uninstall drives
    # the same daemon (docker vs podman) that was detected at install time,
    # even when CONTAINER_RUNTIME is not set in the current shell environment.
    if _is_kind_target; then
        if [[ -f "${INSTALLER_STATE_FILE}" ]]; then
            # shellcheck source=/dev/null
            source "${INSTALLER_STATE_FILE}"
            write_to_log_file "INFO" "Installer state restored: runtime=${CONTAINER_RUNTIME} cluster=${KIND_CLUSTER_NAME} (${INSTALLER_STATE_FILE})"
        else
            CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
            write_to_log_file "WARN" "State file not found (${INSTALLER_STATE_FILE}); using current env (cluster=${KIND_CLUSTER_NAME}, runtime=${CONTAINER_RUNTIME})"
        fi
        export CONTAINER_RUNTIME KIND_CLUSTER_NAME KIND_REGISTRY_NAME KIND_REGISTRY_PORT
        # Switch kubectl to the Kind context before any delete calls.
        # Without this, a leftover OpenShift/other context causes every kubectl
        # delete to hang for the full API-server timeout before giving up.
        local kind_ctx="kind-${KIND_CLUSTER_NAME}"
        if ${KUBE_CLI} config get-contexts "${kind_ctx}" &>/dev/null; then
            ${KUBE_CLI} config use-context "${kind_ctx}" >>"${LOG_FILE}" 2>&1 || true
            write_to_log_file "INFO" "Switched kubectl context to ${kind_ctx} for uninstall"
        else
            write_to_log_file "WARN" "Kind context '${kind_ctx}' not found — kubectl may target the wrong cluster"
        fi
    fi

    start_spinner "Uninstalling Prometheus MCP Server..."
    uninstall_prometheus_mcp_server
    stop_spinner; log_uninstall_success "Prometheus MCP Server"

    start_spinner "Uninstalling Causa MCP Server..."
    uninstall_causa_mcp
    stop_spinner; log_uninstall_success "Causa MCP Server"

    start_spinner "Uninstalling Quarkus MCP Server..."
    uninstall_quarkus_mcp
    stop_spinner; log_uninstall_success "Quarkus MCP Server"

    start_spinner "Uninstalling Cryostat MCP Server..."
    uninstall_cryostat_mcp_server
    stop_spinner; log_uninstall_success "Cryostat MCP Server"

    start_spinner "Uninstalling Cryostat..."
    uninstall_cryostat
    stop_spinner; log_uninstall_success "Cryostat"

    # Jafra MCP and Jafra Ecosystem are not installed on OpenShift — skip uninstall.
    if ! _is_openshift_target; then
        start_spinner "Uninstalling Jafra MCP Server..."
        uninstall_jafra_mcp
        stop_spinner; log_uninstall_success "Jafra MCP Server"

        start_spinner "Uninstalling Jafra Ecosystem..."
        uninstall_jafra
        stop_spinner; log_uninstall_success "Jafra Ecosystem"
    fi

    # kind-only teardown (cert-manager, Causa Backend, Causa MCP, PostgreSQL Deployment)
    if _is_kind_target; then
        _uninstall_kind_only_components
    fi

    start_spinner "Uninstalling Kubernetes MCP Server..."
    if ! uninstall_kubernetes_mcp_server; then
        stop_spinner; log_error "Failed to uninstall Kubernetes MCP Server"; exit 1
    fi
    stop_spinner; log_uninstall_success "Kubernetes MCP Server"

    # Uninstall Prometheus Stack (kind target only — it was installed by us)
    if _is_kind_target; then
        start_spinner "Uninstalling Prometheus Stack..."
        uninstall_prometheus
        stop_spinner; log_uninstall_success "Prometheus Stack"
    fi

    # Uninstall OpenShift components (openshift target only)
    if _is_openshift_target; then
        start_spinner "Uninstalling Causa MCP Server..."
        uninstall_causa_mcp
        stop_spinner; log_uninstall_success "Causa MCP Server"

        start_spinner "Uninstalling Causa Backend..."
        if ! uninstall_causa; then
            stop_spinner; log_error "Failed to uninstall Causa Backend"; exit 1
        fi
        stop_spinner; log_uninstall_success "Causa Backend"

        start_spinner "Uninstalling PostgreSQL..."
        uninstall_postgres
        stop_spinner; log_uninstall_success "PostgreSQL"

        start_spinner "Disabling monitoring and Prometheus alerts..."
        disable_monitoring
        stop_spinner; log_uninstall_success "Monitoring and Prometheus Alerts"

        start_spinner "Removing namespace..."
        delete_namespace
        stop_spinner; log_uninstall_success "Namespace (${INSTALL_NAMESPACE})"
    fi

    # Optionally delete the Kind cluster entirely
    if _is_kind_target; then
        if [[ "${DELETE_CLUSTER:-false}" == "true" ]]; then
            start_spinner "Deleting Kind cluster ${KIND_CLUSTER_NAME}..."
            uninstall_kind_cluster
            stop_spinner; log_uninstall_success "Kind Cluster (${KIND_CLUSTER_NAME})"
        else
            {
                echo ""
                echo -e "${COLOR_YELLOW}Kind cluster '${KIND_CLUSTER_NAME}' preserved.${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}To delete it:  kind delete cluster --name ${KIND_CLUSTER_NAME}${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}Or rerun with: DELETE_CLUSTER=true ./install.sh --terminate${COLOR_RESET}"
                echo ""
            } >/dev/tty 2>/dev/null || true
        fi
    fi

    local elapsed; elapsed=$(calculate_elapsed_label "${start_time}")
    write_to_log_file "SUCCESS" "Uninstallation completed in ${elapsed}"
    {
        echo ""
        echo -e "${COLOR_BOLD_YELLOW}Total uninstallation time: ${elapsed}${COLOR_RESET}"
        echo ""
    } >/dev/tty 2>/dev/null || true
    exit 0
}

################################################################################
# _print_log_summary — print log file path on installer completion
################################################################################
_print_log_summary() {
    if [[ -n "${LOG_FILE:-}" ]]; then
        {
            echo ""
            echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
            echo -e "${COLOR_CYAN}${COLOR_BOLD}Installation Log${COLOR_RESET}"
            echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
            echo ""
            echo -e "${COLOR_CYAN}${COLOR_BOLD}Log file:${COLOR_RESET} ${LOG_FILE}"
            echo ""
        } >/dev/tty 2>/dev/null || true
    fi
}

################################################################################
# show_usage
################################################################################
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Install or uninstall the Causa RCA stack."
    echo ""
    echo "OPTIONS:"
    echo "    --target TARGET               Target platform (default: kind)"
    echo "                                    kind       — provisions a local Kind cluster"
    echo "                                    openshift  — deploys into an existing OpenShift cluster"
    echo "    -n, --namespace NAMESPACE     Installation namespace (default: causa-rca)"
    echo "    -t, --terminate               Uninstall all components"
    echo "    --delete-cluster              Also delete the Kind cluster when terminating"
    echo "    --dry-run                     Validate without making changes"
    echo "    -h, --help                    Display this help message"
    echo ""
    echo "KIND CLUSTER OPTIONS:"
    echo "    --cluster-name NAME           Kind cluster name (default: causa-rca)"
    echo "    --registry-port PORT          Local registry port (default: 5001)"
    echo ""
    echo "IMAGE OVERRIDE OPTIONS:"
    echo "    --k8s-mcp-server-image IMAGE              Override Kubernetes MCP Server image"
    echo "    --cryostat-bundle-image IMAGE             Override Cryostat operator bundle image"
    echo "    --cryostat-mcp-server-image IMAGE         Override Cryostat MCP Server image"
    echo "    --jafra-mcp-image IMAGE                    Override Jafra MCP Server image"
    echo "    --causa-backend-image IMAGE                Override Causa Backend image"
    echo "    --quarkus-mcp-image IMAGE                  Override Quarkus MCP Server image"
    echo "    --prometheus-mcp-server-image IMAGE        Override Prometheus MCP Server image"
    echo "    --causa-mcp-image IMAGE                    Override Causa MCP Server image"
    echo "    --jafra-controller-image IMAGE             Override Jafra Controller image"
    echo "    --jafra-analyzer-image IMAGE               Override Jafra Analyzer image"
    echo "    --jafra-agent-image IMAGE                  Override Jafra Agent image"
    echo ""
    echo "CRYOSTAT CONFIGURATION:"
    echo "    --skip-cryostat                   Skip Cryostat and the Cryostat MCP Server"
    echo "    --cryostat-auth-token TOKEN       Cryostat service account token"
    echo "                                      (auto-generated if not provided)"
    echo ""
    echo "ENVIRONMENT VARIABLES:"
    echo "    INSTALL_TARGET                Target platform (kind)"
    echo "    INSTALL_NAMESPACE             Override default namespace"
    echo "    KIND_CLUSTER_NAME             Override Kind cluster name"
    echo "    KIND_REGISTRY_PORT            Override local registry port"
    echo "    DRY_RUN=true                  Dry run mode"
    echo "    TERMINATE=true                Uninstall mode"
    echo "    PROMETHEUS_NAMESPACE=NAME     Namespace for kube-prometheus-stack (default: monitoring)"
    echo "    DELETE_CLUSTER=true           Delete cluster on --terminate"
    echo "    CAUSA_MCP_QUARKUS_METRICS_BASE_URL=URL"
    echo "                                  Base URL of the Quarkus app under analysis"
    echo "                                  (e.g. http://my-app.default.svc.cluster.local:8080)"
    echo "    CRYOSTAT_BUNDLE_IMAGE         Override Cryostat operator bundle image"
    echo "    CRYOSTAT_MCP_SERVER_IMAGE     Override Cryostat MCP Server image"
    echo "    CRYOSTAT_AUTH_TOKEN           Cryostat service account token"
    echo "    SKIP_CRYOSTAT=true            Skip Cryostat and the Cryostat MCP Server"
    echo ""
    echo "EXAMPLES:"
    echo "    # Full install on Kind (creates cluster + all components)"
    echo "    $0"
    echo ""
    echo "    # Install into a custom namespace"
    echo "    $0 -n my-rca"
    echo ""
    echo "    # Dry run — validate prerequisites without making changes"
    echo "    $0 --dry-run"
    echo ""
    echo "    # Uninstall all components (keep cluster)"
    echo "    $0 --terminate"
    echo ""
    echo "    # Uninstall and delete the Kind cluster"
    echo "    $0 --terminate --delete-cluster"
    echo ""
    echo "    # Override a component image"
    echo "    $0 --causa-mcp-image quay.io/causaai/causa-mcp:v0.1.0"
    echo ""
}

################################################################################
# parse_arguments
################################################################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --target)
                [[ -z "${2:-}" ]] && { log_error "Value required for --target"; show_usage; exit 2; }
                case "$2" in
                    kind|openshift) INSTALL_TARGET="$2" ;;
                    *)
                        log_error "Unsupported target '${2}'. Supported values: kind, openshift"
                        exit 2 ;;
                esac
                shift 2 ;;
            -n|--namespace)
                [[ -z "${2:-}" ]] && { log_error "Value required for --namespace"; show_usage; exit 2; }
                INSTALL_NAMESPACE="$2"; shift 2 ;;
            -t|--terminate)
                TERMINATE="true"; shift ;;
            --delete-cluster)
                DELETE_CLUSTER="true"; export DELETE_CLUSTER; shift ;;
            --dry-run)
                DRY_RUN="true"; shift ;;
            --cluster-name)
                [[ -z "${2:-}" ]] && { log_error "Value required for --cluster-name"; show_usage; exit 2; }
                KIND_CLUSTER_NAME="$2"; shift 2 ;;
            --registry-port)
                [[ -z "${2:-}" ]] && { log_error "Value required for --registry-port"; show_usage; exit 2; }
                KIND_REGISTRY_PORT="$2"; shift 2 ;;
            --k8s-mcp-server-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --k8s-mcp-server-image"; show_usage; exit 2; }
                K8S_MCP_SERVER_IMAGE="$2"; K8S_MCP_SERVER_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --cryostat-bundle-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --cryostat-bundle-image"; show_usage; exit 2; }
                CRYOSTAT_BUNDLE_IMAGE="$2"; CRYOSTAT_BUNDLE_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --cryostat-mcp-server-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --cryostat-mcp-server-image"; show_usage; exit 2; }
                CRYOSTAT_MCP_SERVER_IMAGE="$2"; CRYOSTAT_MCP_SERVER_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --skip-cryostat)
                SKIP_CRYOSTAT="true"; shift ;;
            --cryostat-auth-token)
                [[ -z "${2:-}" ]] && { log_error "Value required for --cryostat-auth-token"; show_usage; exit 2; }
                CRYOSTAT_AUTH_TOKEN="$2"; shift 2 ;;
            --jafra-mcp-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --jafra-mcp-image"; show_usage; exit 2; }
                JAFRA_MCP_IMAGE="$2"; JAFRA_MCP_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --causa-backend-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --causa-backend-image"; show_usage; exit 2; }
                CAUSA_BACKEND_IMAGE="$2"; CAUSA_BACKEND_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --quarkus-mcp-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --quarkus-mcp-image"; show_usage; exit 2; }
                QUARKUS_MCP_IMAGE="$2"; QUARKUS_MCP_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --prometheus-mcp-server-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --prometheus-mcp-server-image"; show_usage; exit 2; }
                PROMETHEUS_MCP_SERVER_IMAGE="$2"; PROMETHEUS_MCP_SERVER_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --causa-mcp-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --causa-mcp-image"; show_usage; exit 2; }
                CAUSA_MCP_IMAGE="$2"; CAUSA_MCP_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --jafra-controller-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --jafra-controller-image"; show_usage; exit 2; }
                JAFRA_CONTROLLER_IMAGE="$2"; JAFRA_CONTROLLER_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --jafra-analyzer-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --jafra-analyzer-image"; show_usage; exit 2; }
                JAFRA_ANALYZER_IMAGE="$2"; JAFRA_ANALYZER_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --jafra-agent-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --jafra-agent-image"; show_usage; exit 2; }
                JAFRA_AGENT_IMAGE="$2"; JAFRA_AGENT_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --postgres-kind-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --postgres-kind-image"; show_usage; exit 2; }
                POSTGRES_KIND_IMAGE="$2"; POSTGRES_KIND_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --postgres-ocp-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --postgres-ocp-image"; show_usage; exit 2; }
                POSTGRES_OCP_IMAGE="$2"; POSTGRES_OCP_IMAGE_OVERRIDDEN=true; shift 2 ;;
            -h|--help)
                show_usage; exit 0 ;;
            *)
                log_error "Unknown option: $1"; show_usage; exit 2 ;;
        esac
    done
}

################################################################################
# Entry point
################################################################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_arguments "$@"
    initialize_logging

    if [[ "${TERMINATE}" == "true" ]]; then
        uninstall_main
    else
        main
    fi
fi
