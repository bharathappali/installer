#!/usr/bin/env bash

################################################################################
# Causa RCA Installer — Main Orchestrator
#
# Provisions the target environment and deploys the full RCA stack:
#   - Kubernetes MCP Server
#   - Causa Backend (RCA engine)
#   - Async Profiler
#   - Async Profiler MCP Server
#   - Quarkus MCP Server
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

# Namespace where all RCA components are deployed
INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-causa-rca}"
export INSTALL_NAMESPACE

# Cluster CLI
KUBE_CLI="${KUBE_CLI:-kubectl}"
export KUBE_CLI

# Target platform — determines which infrastructure steps run.
# Supported values: kind
# kind  → creates a Kind cluster + local registry (no Prometheus — RCA is triggered on demand via Bob)
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

# Image variables (populated by images.env; can be overridden via CLI flags)
K8S_MCP_SERVER_IMAGE="${K8S_MCP_SERVER_IMAGE:-}"
CAUSA_BACKEND_IMAGE="${CAUSA_BACKEND_IMAGE:-}"
ASYNC_PROFILER_IMAGE="${ASYNC_PROFILER_IMAGE:-}"
ASYNC_PROFILER_MCP_IMAGE="${ASYNC_PROFILER_MCP_IMAGE:-}"
QUARKUS_MCP_IMAGE="${QUARKUS_MCP_IMAGE:-}"
CAUSA_MCP_IMAGE="${CAUSA_MCP_IMAGE:-}"
export K8S_MCP_SERVER_IMAGE CAUSA_BACKEND_IMAGE
export ASYNC_PROFILER_IMAGE ASYNC_PROFILER_MCP_IMAGE
export QUARKUS_MCP_IMAGE CAUSA_MCP_IMAGE

# Sentinel flags — set to "true" only when a CLI flag explicitly overrides an image
K8S_MCP_SERVER_IMAGE_OVERRIDDEN=false
CAUSA_BACKEND_IMAGE_OVERRIDDEN=false
ASYNC_PROFILER_IMAGE_OVERRIDDEN=false
ASYNC_PROFILER_MCP_IMAGE_OVERRIDDEN=false
QUARKUS_MCP_IMAGE_OVERRIDDEN=false
CAUSA_MCP_IMAGE_OVERRIDDEN=false
export K8S_MCP_SERVER_IMAGE_OVERRIDDEN CAUSA_BACKEND_IMAGE_OVERRIDDEN
export ASYNC_PROFILER_IMAGE_OVERRIDDEN ASYNC_PROFILER_MCP_IMAGE_OVERRIDDEN
export QUARKUS_MCP_IMAGE_OVERRIDDEN CAUSA_MCP_IMAGE_OVERRIDDEN

# ---------------------------------------------------------------------------
# Source library files
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/install_utils.sh"
source "${SCRIPT_DIR}/lib/validator.sh"
source "${SCRIPT_DIR}/lib/install_kind_cluster.sh"
source "${SCRIPT_DIR}/lib/install_k8s_mcp.sh"
source "${SCRIPT_DIR}/lib/install_postgres.sh"
source "${SCRIPT_DIR}/lib/install_causa.sh"
source "${SCRIPT_DIR}/lib/install_async_profiler.sh"
source "${SCRIPT_DIR}/lib/install_async_profiler_mcp.sh"
source "${SCRIPT_DIR}/lib/install_quarkus_mcp.sh"
source "${SCRIPT_DIR}/lib/install_causa_mcp.sh"

# ---------------------------------------------------------------------------
# Activate opt-in traps (scoped here, not in shared libraries)
# ---------------------------------------------------------------------------
enable_cleanup_trap   # lib/install_utils.sh — log error on unexpected EXIT
enable_spinner_trap   # lib/logging.sh       — stop spinner cleanly on INT/TERM

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

    if _is_kind_target; then
        if ! validate_docker_running; then
            log_error "Docker is not running"
            exit 1
        fi
    fi

    if ! validate_rbac_permissions; then
        log_error "RBAC permissions check failed"
        exit 1
    fi

    if ! validate_image_overrides; then
        log_error "Image validation failed"
        exit 1
    fi

    # ── Step 1: Kind cluster + local registry (kind target only) ────────────
    if _is_kind_target; then
        start_spinner "Provisioning Kind cluster and local registry..."
        if ! install_kind_cluster; then
            stop_spinner
            log_error "Failed to provision Kind cluster"
            exit 1
        fi
        stop_spinner
        log_install_success "Kind Cluster (${KIND_CLUSTER_NAME})"
    fi

    # After cluster is ready, validate connectivity
    # Skip for dry-run on kind target — the cluster doesn't exist yet
    if [[ "${DRY_RUN}" != "true" ]] || ! _is_kind_target; then
        if ! validate_cluster_access; then
            log_error "Cluster access check failed"
            exit 1
        fi
    fi

    # ── Track installed components ───────────────────────────────────────────
    local installed_components=()

    # ── Step 2: Kubernetes MCP Server ───────────────────────────────────────
    start_spinner "Installing Kubernetes MCP Server..."
    if ! install_kubernetes_mcp_server; then
        stop_spinner
        log_error "Failed to install Kubernetes MCP Server"
        exit 1
    fi
    stop_spinner
    log_install_success "Kubernetes MCP Server"
    installed_components+=("Kubernetes MCP Server")

    # ── Step 4: Async Profiler ───────────────────────────────────────────────
    start_spinner "Installing Async Profiler..."
    if ! install_async_profiler; then
        stop_spinner
        log_warn "Async Profiler installation skipped or failed"
    else
        stop_spinner
        log_install_success "Async Profiler"
        installed_components+=("Async Profiler")
    fi

    # ── Step 5: Async Profiler MCP Server ────────────────────────────────────
    start_spinner "Installing Async Profiler MCP Server..."
    if ! install_async_profiler_mcp; then
        stop_spinner
        log_warn "Async Profiler MCP Server installation skipped or failed"
    else
        stop_spinner
        log_install_success "Async Profiler MCP Server"
        installed_components+=("Async Profiler MCP Server")
    fi

    # ── Step 6: Quarkus MCP Server ───────────────────────────────────────────
    start_spinner "Installing Quarkus MCP Server..."
    if ! install_quarkus_mcp; then
        stop_spinner
        log_warn "Quarkus MCP Server installation skipped or failed"
    else
        stop_spinner
        log_install_success "Quarkus MCP Server"
        installed_components+=("Quarkus MCP Server")
    fi

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

    # ── Port-forward instructions ────────────────────────────────────────────
    _print_access_summary

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

    start_spinner "Uninstalling Causa MCP Server..."
    uninstall_causa_mcp
    stop_spinner; log_uninstall_success "Causa MCP Server"

    start_spinner "Uninstalling Quarkus MCP Server..."
    uninstall_quarkus_mcp
    stop_spinner; log_uninstall_success "Quarkus MCP Server"

    start_spinner "Uninstalling Async Profiler MCP Server..."
    uninstall_async_profiler_mcp
    stop_spinner; log_uninstall_success "Async Profiler MCP Server"

    start_spinner "Uninstalling Async Profiler..."
    uninstall_async_profiler
    stop_spinner; log_uninstall_success "Async Profiler"

    start_spinner "Uninstalling Causa Backend..."
    if ! uninstall_causa; then
        stop_spinner; log_error "Failed to uninstall Causa Backend"; exit 1
    fi
    stop_spinner; log_uninstall_success "Causa Backend"

    start_spinner "Uninstalling PostgreSQL..."
    uninstall_postgres
    stop_spinner; log_uninstall_success "PostgreSQL"

    start_spinner "Uninstalling Kubernetes MCP Server..."
    if ! uninstall_kubernetes_mcp_server; then
        stop_spinner; log_error "Failed to uninstall Kubernetes MCP Server"; exit 1
    fi
    stop_spinner; log_uninstall_success "Kubernetes MCP Server"

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
# _print_access_summary
################################################################################
_print_access_summary() {
    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Access Summary${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
        echo ""
        echo -e "${COLOR_GREEN}Causa Backend API  :${COLOR_RESET}  http://localhost:30001/api/v1/diagnostics"
        echo -e "${COLOR_GREEN}Causa MCP Server   :${COLOR_RESET}  http://localhost:30005/mcp"
        echo ""
        if [[ -n "${LOG_FILE:-}" ]]; then
            echo -e "${COLOR_CYAN}Log file:${COLOR_RESET} ${LOG_FILE}"
        fi
        echo ""
    } >/dev/tty 2>/dev/null || true
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
    echo "    --target TARGET               Target platform: kind (default: kind)"
    echo "                                  kind  — provisions a local Kind cluster"
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
    echo "    --causa-backend-image IMAGE                Override Causa Backend image"
    echo "    --async-profiler-image IMAGE               Override Async Profiler image"
    echo "    --async-profiler-mcp-image IMAGE           Override Async Profiler MCP Server image"
    echo "    --quarkus-mcp-image IMAGE                  Override Quarkus MCP Server image"
    echo "    --causa-mcp-image IMAGE                    Override Causa MCP Server image"
    echo ""
    echo "ENVIRONMENT VARIABLES:"
    echo "    INSTALL_TARGET                Target platform (kind)"
    echo "    INSTALL_NAMESPACE             Override default namespace"
    echo "    KIND_CLUSTER_NAME             Override Kind cluster name"
    echo "    KIND_REGISTRY_PORT            Override local registry port"
    echo "    DRY_RUN=true                  Dry run mode"
    echo "    TERMINATE=true                Uninstall mode"
    echo "    DELETE_CLUSTER=true           Delete cluster on --terminate"
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
                    kind) INSTALL_TARGET="$2" ;;
                    *)
                        log_error "Unsupported target '${2}'. Currently supported: kind"
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
            --causa-backend-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --causa-backend-image"; show_usage; exit 2; }
                CAUSA_BACKEND_IMAGE="$2"; CAUSA_BACKEND_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --async-profiler-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --async-profiler-image"; show_usage; exit 2; }
                ASYNC_PROFILER_IMAGE="$2"; ASYNC_PROFILER_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --async-profiler-mcp-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --async-profiler-mcp-image"; show_usage; exit 2; }
                ASYNC_PROFILER_MCP_IMAGE="$2"; ASYNC_PROFILER_MCP_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --quarkus-mcp-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --quarkus-mcp-image"; show_usage; exit 2; }
                QUARKUS_MCP_IMAGE="$2"; QUARKUS_MCP_IMAGE_OVERRIDDEN=true; shift 2 ;;
            --causa-mcp-image)
                [[ -z "${2:-}" ]] && { log_error "Value required for --causa-mcp-image"; show_usage; exit 2; }
                CAUSA_MCP_IMAGE="$2"; CAUSA_MCP_IMAGE_OVERRIDDEN=true; shift 2 ;;
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
