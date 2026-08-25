#!/usr/bin/env bash

################################################################################
# Validator Library — Causa RCA Installer
#
# Pre-flight checks: required CLI tools, Docker, cluster access.
################################################################################

# Prevent multiple sourcing
if [[ -n "${VALIDATOR_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly VALIDATOR_LIB_LOADED=1

################################################################################
# validate_prerequisites
# Checks that all required CLI tools are present.
################################################################################
validate_prerequisites() {
    log_file_only "Validating Prerequisites"

    local missing=()
    # Core tools always required
    # Accept either docker or podman as the container runtime.
    # When both are present, check whether 'docker' is a Podman shim/alias
    # (common on macOS with Podman Desktop's docker-compat socket).  Running
    # Kind with KIND_EXPERIMENTAL_PROVIDER=docker against a Podman-backed
    # socket causes inspect template failures, so we must detect this case.
    local container_runtime=""
    if check_command_exists "podman" && podman info &>/dev/null 2>&1; then
        container_runtime="podman"
    elif check_command_exists "docker" && docker info &>/dev/null 2>&1; then
        # Podman ships a docker-compat shim; detect it by checking the server name
        if docker info --format '{{.ServerVersion}}' 2>/dev/null | grep -qi "podman"; then
            container_runtime="podman"
        else
            container_runtime="docker"
        fi
    elif check_command_exists "docker"; then
        container_runtime="docker"
    fi

    local required_tools=("kubectl" "kind" "helm" "curl" "grep" "sed" "awk")
    [[ -z "${container_runtime}" ]] && required_tools+=("docker")  # will fail with a clear message

    for tool in "${required_tools[@]}"; do
        if ! check_command_exists "${tool}"; then
            log_error "Required tool not found: ${tool}"
            missing+=("${tool}")
        else
            write_to_log_file "SUCCESS" "${tool} found"
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install them and retry."
        log_error "  - kind:    https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
        log_error "  - kubectl: https://kubernetes.io/docs/tasks/tools/"
        log_error "  - helm:    https://helm.sh/docs/intro/install/"
        return 1
    fi

    if [[ -z "${container_runtime}" ]]; then
        log_error "No container runtime found. Install docker or podman."
        log_error "  - docker: https://docs.docker.com/get-docker/"
        log_error "  - podman: https://podman.io/getting-started/installation"
        return 1
    fi

    # Export so other scripts can use the correct runtime
    export CONTAINER_RUNTIME="${container_runtime}"
    write_to_log_file "SUCCESS" "Container runtime: ${container_runtime}"

    log_validation_success "Validating Prerequisites"
    return 0
}

################################################################################
# validate_docker_running
# Ensures the Docker daemon is reachable.
################################################################################
validate_docker_running() {
    local runtime="${CONTAINER_RUNTIME:-docker}"
    log_file_only "Validating container runtime (${runtime})"

    if ! ${runtime} info &>/dev/null; then
        if [[ "${runtime}" == "podman" ]]; then
            log_error "Podman is not running or not reachable."
            log_error "Start the Podman machine:  podman machine start"
        else
            log_error "Docker daemon is not running or not reachable."
            log_error "Start Docker Desktop (macOS/Windows) or run: sudo systemctl start docker"
        fi
        return 1
    fi

    if [[ "${runtime}" == "podman" ]]; then
        local rootful
        rootful=$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null || echo "")
        if [[ "${rootful}" == "false" ]]; then
            log_error "Podman machine is running in rootless mode — Kind requires rootful mode."
            log_error "Recreate the Podman machine as rootful:"
            log_error "  podman machine stop"
            log_error "  podman machine rm"
            log_error "  podman machine init --rootful --cpus 4 --memory 4096"
            log_error "  podman machine start"
            return 1
        fi
    fi

    write_to_log_file "SUCCESS" "Container runtime is running (${runtime})"
    log_validation_success "Validating container runtime"
    return 0
}

################################################################################
# validate_cluster_access
# For the kind target: switches to the kind-<cluster-name> context before
# checking connectivity, so an unrelated current context doesn't cause a hang.
################################################################################
validate_cluster_access() {
    log_file_only "Validating cluster access"

    local prev_ctx
    prev_ctx=$(${KUBE_CLI} config current-context 2>/dev/null || echo "")

    if [[ "${INSTALL_TARGET:-kind}" == "kind" ]]; then
        local kind_ctx="kind-${KIND_CLUSTER_NAME:-causa-rca}"
        if ${KUBE_CLI} config get-contexts "${kind_ctx}" &>/dev/null; then
            ${KUBE_CLI} config use-context "${kind_ctx}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
            write_to_log_file "INFO" "Switched kubectl context to ${kind_ctx} (was: ${prev_ctx:-none})"
        else
            log_error "Kind context '${kind_ctx}' not found in kubeconfig."
            log_error "The Kind cluster may not have been created yet — this should not happen at this stage."
            return 1
        fi
    fi

    local ctx
    ctx=$(${KUBE_CLI} config current-context 2>/dev/null || echo "")
    write_to_log_file "INFO" "Current context: ${ctx}"

    local rc=0
    if ! ${KUBE_CLI} cluster-info --request-timeout=10s &>/dev/null; then
        log_error "Cannot reach the cluster API server (context: ${ctx})"
        log_error "Ensure the Kind cluster is running:  kind get clusters"
        rc=1
    fi

    if [[ -n "${prev_ctx}" && "${prev_ctx}" != "${ctx}" ]]; then
        ${KUBE_CLI} config use-context "${prev_ctx}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
        write_to_log_file "INFO" "Restored kubectl context to ${prev_ctx}"
    fi

    if [[ ${rc} -ne 0 ]]; then
        return 1
    fi

    write_to_log_file "SUCCESS" "Cluster is reachable (context: ${ctx})"
    log_validation_success "Validating Cluster Access"
    return 0
}

################################################################################
# validate_image_format_silent
# Validates image format for images loaded from images.env (silent on success).
################################################################################
validate_image_format_silent() {
    local image="$1"
    local flag_name="$2"

    [[ -z "${image}" ]]                                     && { log_error "Image empty for ${flag_name}"; return 1; }
    [[ "${image}" =~ [[:space:]] ]]                         && { log_error "Image has spaces: ${image} (${flag_name})"; return 1; }
    [[ "${image}" =~ [\$\`\!\&\|\;\<\>\(\)\{\}\[\]\\] ]]   && { log_error "Image has invalid chars: ${image}"; return 1; }
    [[ ! "${image}" =~ : ]]                                 && { log_error "Image missing tag: ${image}"; return 1; }

    local tag="${image##*:}"
    [[ -z "${tag}" ]]                                       && { log_error "Empty tag in image: ${image}"; return 1; }
    [[ ! "${tag}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]       && { log_error "Invalid tag: ${tag}"; return 1; }

    local repo="${image%:*}"
    [[ -z "${repo}" ]]                                      && { log_error "Empty repo in image: ${image}"; return 1; }
    [[ ! "${repo}" =~ ^[a-zA-Z0-9._/-]+$ ]]                 && { log_error "Invalid repo: ${repo}"; return 1; }
    [[ ${#image} -gt 255 ]]                                 && { log_error "Image name too long: ${image}"; return 1; }

    write_to_log_file "SUCCESS" "Image validated (images.env): ${image}"
    return 0
}

################################################################################
# validate_image_format
# Same as above but also prints success to the terminal (used for CLI overrides).
################################################################################
validate_image_format() {
    local image="$1"
    local flag_name="$2"

    validate_image_format_silent "${image}" "${flag_name}" || return 1

    echo -e "${COLOR_GREEN}Image format validated: ${image}${COLOR_RESET}" > /dev/tty 2>/dev/null || true
    write_to_log_file "SUCCESS" "Image format validated: ${image}"
    return 0
}

################################################################################
# validate_image_overrides
# Validates all image variables (whether from images.env or CLI override).
################################################################################
validate_image_overrides() {
    local failed=false

    _vi() {
        local img="$1" flag="$2" overridden="$3"
        [[ -z "${img}" ]] && return 0
        if [[ "${overridden}" == "true" ]]; then
            validate_image_format "${img}" "${flag}" || failed=true
        else
            validate_image_format_silent "${img}" "${flag}" || failed=true
        fi
    }

    _vi "${K8S_MCP_SERVER_IMAGE}"          "--k8s-mcp-server-image"       "${K8S_MCP_SERVER_IMAGE_OVERRIDDEN:-false}"
    _vi "${JAFRA_MCP_IMAGE}"               "--jafra-mcp-image"            "${JAFRA_MCP_IMAGE_OVERRIDDEN:-false}"
    _vi "${CAUSA_BACKEND_IMAGE}"           "--causa-backend-image"        "${CAUSA_BACKEND_IMAGE_OVERRIDDEN:-false}"
    _vi "${QUARKUS_MCP_IMAGE}"             "--quarkus-mcp-image"          "${QUARKUS_MCP_IMAGE_OVERRIDDEN:-false}"
    _vi "${CAUSA_MCP_IMAGE}"               "--causa-mcp-image"            "${CAUSA_MCP_IMAGE_OVERRIDDEN:-false}"

    if [[ "${failed}" == "true" ]]; then
        log_error "Image validation failed. Correct the image format and retry."
        return 1
    fi
    return 0
}

################################################################################
# post_component_validation
# Health summary after all components are installed.
################################################################################
post_component_validation() {
    local elapsed_label="${1:-}"
    log_section_silent "Post-Installation Validation"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping post-install health validation"
        return 0
    fi

    local failed=0

    _check_deployment() {
        local display="$1" deploy="$2" var="$3"
        local rr dr
        if ${KUBE_CLI} get deployment "${deploy}" -n "${INSTALL_NAMESPACE}" &>/dev/null; then
            rr=$(${KUBE_CLI} get deployment "${deploy}" -n "${INSTALL_NAMESPACE}" \
                    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            dr=$(${KUBE_CLI} get deployment "${deploy}" -n "${INSTALL_NAMESPACE}" \
                    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
            if [[ "${rr:-0}" == "${dr}" ]]; then
                printf -v "${var}" '%b' "${COLOR_BOLD_GREEN}${display} ✓${COLOR_RESET}"
                write_to_log_file "SUCCESS" "${display} is healthy"
            else
                printf -v "${var}" '%b' "${COLOR_BOLD_RED}${display} ✗${COLOR_RESET}"
                write_to_log_file "ERROR" "${display} pods not ready: ${rr:-0}/${dr}"
                (( failed++ ))
            fi
        else
            printf -v "${var}" '%b' "${COLOR_YELLOW}${display} — not installed${COLOR_RESET}"
            write_to_log_file "INFO" "${display} deployment not found (skipped)"
        fi
    }

    local k8s_mcp_status jafra_mcp_status quarkus_status postgres_status causa_status causa_mcp_status

    _check_deployment "Kubernetes MCP Server"  "kubernetes-mcp-server"  k8s_mcp_status
    _check_deployment "Jafra MCP Server"       "jafra-mcp"              jafra_mcp_status
    _check_deployment "Quarkus MCP Server"         "mcp-metrics"            quarkus_status
    _check_deployment "PostgreSQL"                 "postgres"               postgres_status
    _check_deployment "Causa Backend"              "causa-backend"          causa_status
    _check_deployment "Causa MCP Server"           "causa-mcp"              causa_mcp_status

    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Component Health Summary${COLOR_RESET}"
        echo ""
        echo -e "${k8s_mcp_status}"
        echo -e "${jafra_mcp_status}"
        echo -e "${quarkus_status}"
        echo -e "${postgres_status}"
        echo -e "${causa_status}"
        echo -e "${causa_mcp_status}"
        echo ""
        [[ -n "${elapsed_label}" ]] && echo -e "${COLOR_BOLD_YELLOW}Total installation time: ${elapsed_label}${COLOR_RESET}" && echo ""
    } >/dev/tty 2>/dev/null || true

    if [[ ${failed} -eq 0 ]]; then
        write_to_log_file "SUCCESS" "All components passed health validation"
        return 0
    else
        log_error "${failed} component(s) failed health validation"
        return 1
    fi
}

################################################################################
# validate_prometheus_available
# Checks that a Prometheus instance is reachable at the configured URL.
#
# On kind: Prometheus must have been deployed (via kube-prometheus-stack helm
#          chart) before Quarkus MCP is installed.  Returns 1 and prints a
#          clear install hint when it is absent.
# On other targets (e.g. OpenShift): Prometheus is built-in; this check is
#          skipped and the function returns 0 gracefully.
################################################################################
validate_prometheus_available() {
    # Only enforce on kind — other platforms (OpenShift, etc.) ship Prometheus OOB.
    if [[ "${INSTALL_TARGET:-kind}" != "kind" ]]; then
        write_to_log_file "INFO" "Skipping Prometheus check on non-kind target (${INSTALL_TARGET:-unknown})"
        return 0
    fi

    local prometheus_url
    prometheus_url="http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"

    write_to_log_file "INFO" "Checking Prometheus readiness at ${prometheus_url}/-/ready ..."

    # Use kubectl exec into a temporary pod to probe inside the cluster network,
    # or use a lightweight in-cluster curl via kubectl run.
    # Prefer checking via the Kubernetes API whether the Deployment/StatefulSet
    # is ready — avoids needing a debug pod.

    # Check for the kube-prometheus-stack Prometheus StatefulSet in monitoring namespace
    local ready_replicas total_replicas
    if ! ${KUBE_CLI} get namespace "monitoring" &>/dev/null; then
        log_error "Prometheus check: 'monitoring' namespace not found."
        log_error "Quarkus MCP requires Prometheus (kube-prometheus-stack) to be installed."
        log_error "Install it with:"
        log_error "  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
        log_error "  helm repo update"
        log_error "  helm install prometheus prometheus-community/kube-prometheus-stack \\"
        log_error "    --namespace monitoring --create-namespace \\"
        log_error "    --set prometheus.service.type=ClusterIP"
        return 1
    fi

    # Find the Prometheus StatefulSet (kube-prometheus-stack naming convention)
    local prom_sts
    prom_sts=$(${KUBE_CLI} get statefulset -n monitoring \
        --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
        | grep -E "^prometheus-" | head -1 || true)

    if [[ -z "${prom_sts}" ]]; then
        log_error "Prometheus check: no Prometheus StatefulSet found in 'monitoring' namespace."
        log_error "Quarkus MCP requires Prometheus (kube-prometheus-stack) to be installed."
        log_error "Install it with:"
        log_error "  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
        log_error "  helm repo update"
        log_error "  helm install prometheus prometheus-community/kube-prometheus-stack \\"
        log_error "    --namespace monitoring --create-namespace \\"
        log_error "    --set prometheus.service.type=ClusterIP"
        return 1
    fi

    # readyReplicas is absent from the JSON (not "0") when no pods are up — default explicitly.
    ready_replicas=$(${KUBE_CLI} get statefulset "${prom_sts}" -n monitoring \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    ready_replicas="${ready_replicas:-0}"
    total_replicas=$(${KUBE_CLI} get statefulset "${prom_sts}" -n monitoring \
        -o jsonpath='{.spec.replicas}' 2>/dev/null)
    total_replicas="${total_replicas:-0}"

    # A StatefulSet scaled to 0 is explicitly stopped — treat as not ready.
    if [[ "${total_replicas}" -eq 0 ]] 2>/dev/null || [[ "${ready_replicas}" != "${total_replicas}" ]]; then
        log_error "Prometheus StatefulSet '${prom_sts}' is not ready (${ready_replicas}/${total_replicas} replicas)."
        log_error "Wait for Prometheus to become ready before installing Quarkus MCP."
        log_error "  ${KUBE_CLI} rollout status statefulset/${prom_sts} -n monitoring"
        return 1
    fi

    write_to_log_file "SUCCESS" "Prometheus is ready (${prom_sts}: ${ready_replicas}/${total_replicas})"
    return 0
}

export -f validate_prerequisites
export -f validate_docker_running
export -f validate_cluster_access
export -f validate_image_format_silent
export -f validate_image_format
export -f validate_image_overrides
export -f post_component_validation
export -f validate_prometheus_available
