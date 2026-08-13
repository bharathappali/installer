#!/usr/bin/env bash

################################################################################
# Causa RCA Installer — Main Orchestrator
#
# Provisions the Kind cluster and local registry.
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

IMAGES_ENV_FILE="${SCRIPT_DIR}/lib/images.env"
if [[ -f "${IMAGES_ENV_FILE}" ]]; then
    # shellcheck source=lib/images.env
    source "${IMAGES_ENV_FILE}"
fi

MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-causa-rca}"
export INSTALL_NAMESPACE

KUBE_CLI="${KUBE_CLI:-kubectl}"
export KUBE_CLI

INSTALL_TARGET="${INSTALL_TARGET:-kind}"
export INSTALL_TARGET

DRY_RUN="${DRY_RUN:-false}"
TERMINATE="${TERMINATE:-false}"
export DRY_RUN TERMINATE

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-causa-rca}"
KIND_REGISTRY_NAME="${KIND_REGISTRY_NAME:-causa-rca-registry}"
KIND_REGISTRY_PORT="${KIND_REGISTRY_PORT:-5001}"
export KIND_CLUSTER_NAME KIND_REGISTRY_NAME KIND_REGISTRY_PORT

K8S_MCP_SERVER_IMAGE="${K8S_MCP_SERVER_IMAGE:-}"
CAUSA_BACKEND_IMAGE="${CAUSA_BACKEND_IMAGE:-}"
QUARKUS_MCP_IMAGE="${QUARKUS_MCP_IMAGE:-}"
CAUSA_MCP_IMAGE="${CAUSA_MCP_IMAGE:-}"
export K8S_MCP_SERVER_IMAGE CAUSA_BACKEND_IMAGE
export QUARKUS_MCP_IMAGE CAUSA_MCP_IMAGE

K8S_MCP_SERVER_IMAGE_OVERRIDDEN=false
CAUSA_BACKEND_IMAGE_OVERRIDDEN=false
QUARKUS_MCP_IMAGE_OVERRIDDEN=false
CAUSA_MCP_IMAGE_OVERRIDDEN=false
export K8S_MCP_SERVER_IMAGE_OVERRIDDEN CAUSA_BACKEND_IMAGE_OVERRIDDEN
export QUARKUS_MCP_IMAGE_OVERRIDDEN CAUSA_MCP_IMAGE_OVERRIDDEN

source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/install_utils.sh"
source "${SCRIPT_DIR}/lib/validator.sh"
source "${SCRIPT_DIR}/lib/install_kind_cluster.sh"
source "${SCRIPT_DIR}/lib/install_k8s_mcp.sh"
source "${SCRIPT_DIR}/lib/install_postgres.sh"
source "${SCRIPT_DIR}/lib/install_causa.sh"

enable_cleanup_trap
enable_spinner_trap

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

_is_kind_target() {
    [[ "${INSTALL_TARGET}" == "kind" ]]
}

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

    if ! validate_image_overrides; then
        log_error "Image validation failed"
        exit 1
    fi

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

    if [[ "${DRY_RUN}" != "true" ]] || ! _is_kind_target; then
        if ! validate_cluster_access; then
            log_error "Cluster access check failed"
            exit 1
        fi
    fi

    local installed_components=()
    installed_components+=("Kind Cluster (${KIND_CLUSTER_NAME})")

    start_spinner "Installing Kubernetes MCP Server..."
    if ! install_kubernetes_mcp_server; then
        stop_spinner
        log_error "Failed to install Kubernetes MCP Server"
        exit 1
    fi
    stop_spinner
    log_install_success "Kubernetes MCP Server"
    installed_components+=("Kubernetes MCP Server")

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
    write_to_log_file "SUCCESS" "Installation completed in ${elapsed}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        write_to_log_file "INFO" "Log: ${LOG_FILE}"
    fi
}

uninstall_main() {
    local start_time; start_time=$(date +%s)

    log_file_only "Starting Causa RCA uninstallation..."

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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    initialize_logging
    parse_arguments "$@"

    if [[ "${TERMINATE}" == "true" ]]; then
        uninstall_main
    else
        main
    fi
fi
