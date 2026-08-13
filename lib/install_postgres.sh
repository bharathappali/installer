#!/usr/bin/env bash

################################################################################
# PostgreSQL — Installation Functions
#
# Deploys a single-instance Postgres with pgvector into the install namespace,
# then creates the 'causa-db-secrets' Secret that Causa Backend reads.
#
# Database : iri-db
# User     : causa_backend
# Secret   : causa-db-secrets (keys: CAUSA_DB_USERNAME, CAUSA_DB_PASSWORD,
#                                     CAUSA_DB_HOST, CAUSA_DB_PORT, CAUSA_DB_NAME)
################################################################################

# Source guard
if [[ -n "${INSTALL_POSTGRES_LIB_LOADED:-}" ]]; then return 0; fi
readonly INSTALL_POSTGRES_LIB_LOADED=1

readonly _PG_MANIFEST="${SCRIPT_DIR}/manifests/postgres/deployment.yaml"
readonly _PG_SECRET_NAME="causa-db-secrets"
readonly _PG_DB_NAME="iri-db"
readonly _PG_USER="causa_backend"
readonly _PG_PASS="causa_backend_pass"

################################################################################
# install_postgres
################################################################################
install_postgres() {
    log_section_silent "Installing PostgreSQL"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping apply"
        return 0
    fi

    if ! create_namespace; then return 1; fi

    write_to_log_file "INFO" "Applying Postgres manifest..."
    if ! apply_manifest "${_PG_MANIFEST}" "${INSTALL_NAMESPACE}" \
        "image: .*pgvector.*" "pgvector/pgvector:pg17"; then
        log_error "Failed to apply Postgres manifest"
        return 1
    fi

    # Wait for Postgres pod to be ready before creating the secret
    if ! wait_for_deployment "postgres" "${INSTALL_NAMESPACE}" 180; then
        log_error "Postgres did not become ready in time"
        return 1
    fi

    write_to_log_file "INFO" "Creating ${_PG_SECRET_NAME} secret..."
    # Delete existing secret first (idempotent)
    ${KUBE_CLI} delete secret "${_PG_SECRET_NAME}" \
        -n "${INSTALL_NAMESPACE}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    if ! ${KUBE_CLI} create secret generic "${_PG_SECRET_NAME}" \
        -n "${INSTALL_NAMESPACE}" \
        --from-literal=CAUSA_DB_USERNAME="${_PG_USER}" \
        --from-literal=CAUSA_DB_PASSWORD="${_PG_PASS}" \
        --from-literal=CAUSA_DB_URL="jdbc:postgresql://postgres.${INSTALL_NAMESPACE}.svc.cluster.local:5432/${_PG_DB_NAME}" \
        >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to create ${_PG_SECRET_NAME} secret"
        return 1
    fi

    write_to_log_file "SUCCESS" "PostgreSQL installed"
    write_to_log_file "INFO"    "URL:      jdbc:postgresql://postgres.${INSTALL_NAMESPACE}.svc.cluster.local:5432/${_PG_DB_NAME}"
    write_to_log_file "INFO"    "User:     ${_PG_USER}"
    return 0
}

################################################################################
# uninstall_postgres
################################################################################
uninstall_postgres() {
    log_section_silent "Uninstalling PostgreSQL"

    if [[ "${DRY_RUN}" == "true" ]]; then
        write_to_log_file "INFO" "Dry run — skipping delete"
        return 0
    fi

    delete_manifest "${_PG_MANIFEST}" "${INSTALL_NAMESPACE}"

    ${KUBE_CLI} delete secret "${_PG_SECRET_NAME}" \
        -n "${INSTALL_NAMESPACE}" --ignore-not-found=true >>"${LOG_FILE}" 2>&1 || true

    write_to_log_file "SUCCESS" "PostgreSQL uninstalled"
    return 0
}

export -f install_postgres
export -f uninstall_postgres
