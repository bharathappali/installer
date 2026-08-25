#!/usr/bin/env bash

################################################################################
# Logging Library
#
# Provides standardized logging functions with different severity levels
# and colored output for better readability.
################################################################################

# Prevent multiple sourcing
if [[ -n "${LOGGING_LIB_LOADED:-}" ]]; then
    return 0
fi
readonly LOGGING_LIB_LOADED=1

# Color codes for terminal output
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_WHITE='\033[0;37m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_ORANGE='\033[0;38;5;214m'
readonly COLOR_BOLD_GREEN='\033[1;32m'
readonly COLOR_BOLD_RED='\033[1;31m'
readonly COLOR_BOLD_YELLOW='\033[1;33m'
readonly COLOR_BOLD_MAGENTA='\033[1;35m'

# Log levels
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_SUCCESS=4

# Current log level (can be overridden by environment variable).
# Accepts numeric values (0–4) or string names: DEBUG, INFO, WARN, ERROR, SUCCESS.
_parse_log_level() {
    local val="${1:-}"
    case "${val}" in
        0|DEBUG)   echo "${LOG_LEVEL_DEBUG}" ;;
        1|INFO)    echo "${LOG_LEVEL_INFO}" ;;
        2|WARN)    echo "${LOG_LEVEL_WARN}" ;;
        3|ERROR)   echo "${LOG_LEVEL_ERROR}" ;;
        4|SUCCESS) echo "${LOG_LEVEL_SUCCESS}" ;;
        *)
            # Unknown value — default to INFO and warn on stderr
            echo "${LOG_LEVEL_INFO}"
            echo "[WARN] LOG_LEVEL '${val}' is not recognised; defaulting to INFO (1)" >&2
            ;;
    esac
}
CURRENT_LOG_LEVEL="$(_parse_log_level "${LOG_LEVEL:-1}")"

# Log file path (optional)
LOG_FILE="${LOG_FILE:-}"

################################################################################
# Get timestamp in ISO 8601 format
################################################################################
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

################################################################################
# Write log message to file if LOG_FILE is set
################################################################################
write_to_log_file() {
    local level="$1"
    local message="$2"
    
    if [[ -n "${LOG_FILE}" ]]; then
        echo "[$(get_timestamp)] [${level}] ${message}" >> "${LOG_FILE}"
    fi
}

################################################################################
# Log debug message
# Usage: log_debug "Debug message"
################################################################################
log_debug() {
    local message="$1"
    
    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_DEBUG} ]]; then
        if [[ -t 2 ]]; then
            echo -e "${COLOR_MAGENTA}[DEBUG]${COLOR_RESET} ${message}" >&2
        else
            echo "[DEBUG] ${message}" >&2
        fi
        write_to_log_file "DEBUG" "${message}"
    fi
}

################################################################################
# Log info message
# Usage: log_info "Info message"
################################################################################
log_info() {
    local message="$1"
    
    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_INFO} ]]; then
        if [[ -t 1 ]]; then
            echo -e "${message}"
        else
            echo "${message}"
        fi
        write_to_log_file "INFO" "${message}"
    fi
}

################################################################################
# Log message to file only (no terminal output)
# Usage: log_file_only "Message"
################################################################################
log_file_only() {
    local message="$1"
    write_to_log_file "INFO" "${message}"
}

################################################################################
# Log warning message
# Usage: log_warn "Warning message"
################################################################################
log_warn() {
    local message="$1"
    
    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_WARN} ]]; then
        if [[ -t 2 ]]; then
            echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} ${message}" >&2
        else
            echo "[WARN] ${message}" >&2
        fi
        write_to_log_file "WARN" "${message}"
    fi
}

################################################################################
# Log error message
# Usage: log_error "Error message"
################################################################################
log_error() {
    local message="$1"
    
    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_ERROR} ]]; then
        echo -e "${COLOR_BOLD_RED}[ERROR] ${message}${COLOR_RESET}" > /dev/tty 2>/dev/null || echo -e "${COLOR_BOLD_RED}[ERROR] ${message}${COLOR_RESET}" >&2
        write_to_log_file "ERROR" "${message}"
    fi
}

################################################################################
# Log success message
# Usage: log_success "Success message"
################################################################################
log_success() {
    local message="$1"
    
    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_SUCCESS} ]]; then
        if [[ -t 1 ]]; then
            echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} ${message}"
        else
            echo "[SUCCESS] ${message}"
        fi
        write_to_log_file "SUCCESS" "${message}"
    fi
}

################################################################################
# Log validation success message (bold cyan with blue checkmark)
# Usage: log_validation_success "Validation message"
################################################################################
log_validation_success() {
    local message="$1"
    
    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_SUCCESS} ]]; then
        echo -e "${COLOR_CYAN}${COLOR_BOLD}${message} ✓${COLOR_RESET}" > /dev/tty 2>/dev/null || echo -e "${COLOR_CYAN}${COLOR_BOLD}${message} ✓${COLOR_RESET}"
        write_to_log_file "SUCCESS" "${message}"
    fi
}

################################################################################
# Log component installation success (bold orange with tick)
# Usage: log_install_success "Component Name"
################################################################################
log_install_success() {
    local message="$1"
    
    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_SUCCESS} ]]; then
        echo -e "${COLOR_ORANGE}${COLOR_BOLD}${message} ✓${COLOR_RESET}" > /dev/tty 2>/dev/null || echo -e "${COLOR_ORANGE}${COLOR_BOLD}${message} ✓${COLOR_RESET}"
        write_to_log_file "SUCCESS" "${message}"
    fi
}

################################################################################
# Log component uninstallation success (bold orange with tick)
# Usage: log_uninstall_success "Component Name"
################################################################################
log_uninstall_success() {
    local message="$1"

    if [[ ${CURRENT_LOG_LEVEL} -le ${LOG_LEVEL_SUCCESS} ]]; then
        echo -e "${COLOR_ORANGE}${COLOR_BOLD}${message} ✓${COLOR_RESET}" > /dev/tty 2>/dev/null || echo -e "${COLOR_ORANGE}${COLOR_BOLD}${message} ✓${COLOR_RESET}"
        write_to_log_file "SUCCESS" "${message} uninstalled"
    fi
}

################################################################################
# Log section header
# Usage: log_section "Section Title"
################################################################################
log_section() {
    local title="$1"
    local separator="============================================================"
    
    # Terminal output (colored, shorter separator) - bypass redirections
    {
        echo ""
        echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}${title}${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}========================================${COLOR_RESET}"
        echo ""
    } > /dev/tty 2>/dev/null || true
    
    # Log file output (plain text with longer separator and section marker)
    if [[ -n "${LOG_FILE}" ]]; then
        {
            echo ""
            echo "${separator}"
            echo "${title}"
            echo "${separator}"
            echo ""
            echo "[$(get_timestamp)] [SECTION] ${title}"
        } >> "${LOG_FILE}"
    fi
}

################################################################################
# Log section header (log file only, no terminal output)
# Usage: log_section_silent "Section Title"
################################################################################
log_section_silent() {
    local title="$1"
    local separator="============================================================"
    
    # Log file output only (plain text with separator and section marker)
    if [[ -n "${LOG_FILE}" ]]; then
        {
            echo ""
            echo "${separator}"
            echo "${title}"
            echo "${separator}"
            echo ""
            echo "[$(get_timestamp)] [SECTION] ${title}"
        } >> "${LOG_FILE}"
    fi
}

################################################################################
# Log step with number
# Usage: log_step 1 "First step"
################################################################################
log_step() {
    local step_number="$1"
    local message="$2"
    
    if [[ -t 1 ]]; then
        echo -e "${COLOR_CYAN}[Step ${step_number}]${COLOR_RESET} ${message}"
    else
        echo "[Step ${step_number}] ${message}"
    fi
    write_to_log_file "STEP" "[${step_number}] ${message}"
}

################################################################################
# Log command execution
# Usage: log_command "kubectl apply -f manifest.yaml"
################################################################################
log_command() {
    local command="$1"
    
    echo -e "${COLOR_WHITE}$ ${command}${COLOR_RESET}"
    write_to_log_file "COMMAND" "${command}"
}

################################################################################
# Log with custom color
# Usage: log_custom "COLOR_GREEN" "Custom message"
################################################################################
log_custom() {
    local color="$1"
    local message="$2"
    
    # Use indirect variable expansion to get the color code
    local color_code="${!color}"
    
    echo -e "${color_code}${message}${COLOR_RESET}"
    write_to_log_file "CUSTOM" "${message}"
}

################################################################################
# Print a separator line
# Usage: log_separator
################################################################################
log_separator() {
    echo -e "${COLOR_WHITE}----------------------------------------${COLOR_RESET}"
}

################################################################################
# Log progress with percentage
# Usage: log_progress 50 "Installing components"
################################################################################
log_progress() {
    local percentage="$1"
    local message="$2"
    
    local bar_length=40
    local filled_length=$((percentage * bar_length / 100))
    local empty_length=$((bar_length - filled_length))
    
    local bar=""
    for ((i=0; i<filled_length; i++)); do
        bar+="█"
    done
    for ((i=0; i<empty_length; i++)); do
        bar+="░"
    done
    
    echo -ne "\r${COLOR_CYAN}[${bar}] ${percentage}%${COLOR_RESET} ${message}"
    
    if [[ ${percentage} -eq 100 ]]; then
        echo ""
    fi
    
    write_to_log_file "PROGRESS" "[${percentage}%] ${message}"
}

################################################################################
# Start a spinner with a message in the background
# Usage: start_spinner "Installing Operator SDK"
# Sets SPINNER_PID — call stop_spinner afterwards
################################################################################
start_spinner() {
    local message="$1"
    local spinners=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    (
        trap 'exit 0' TERM INT
        set +e
        local i=0
        while true; do
            printf "\r${COLOR_CYAN}${COLOR_BOLD}${message} ${spinners[$((i % ${#spinners[@]}))]}${COLOR_RESET}" > /dev/tty 2>/dev/null
            sleep 0.1
            i=$(( i + 1 ))
        done
    ) &
    SPINNER_PID=$!
    # Do NOT disown — we need to be able to kill it on INT/TERM
}

################################################################################
# Stop the running spinner and clear the line
# Usage: stop_spinner
################################################################################
stop_spinner() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "${SPINNER_PID}" 2>/dev/null || true
        wait "${SPINNER_PID}" 2>/dev/null || true
        printf "\r\033[K" > /dev/tty 2>/dev/null || true
        SPINNER_PID=""
    fi
    return 0
}

################################################################################
# _spinner_cleanup_trap — internal handler, stops the spinner on signal
################################################################################
_spinner_cleanup_trap() {
    stop_spinner
}

################################################################################
# enable_spinner_trap
# Opt-in: call this from the top-level installer entrypoint after sourcing this
# library. Not called automatically to avoid overriding callers' own traps.
################################################################################
enable_spinner_trap() {
    trap '_spinner_cleanup_trap' INT TERM
}

################################################################################
# Initialize logging
# Usage: init_logging [log_file_path]
################################################################################
init_logging() {
    local log_file="${1:-}"
    local skip_header="${2:-false}"
    
    if [[ -n "${log_file}" ]]; then
        LOG_FILE="${log_file}"
        
        # Create log directory if it doesn't exist
        local log_dir
        log_dir="$(dirname "${LOG_FILE}")"
        mkdir -p "${log_dir}"
        
        # Initialize log file with header only if not skipping
        if [[ "${skip_header}" != "true" ]]; then
            echo "========================================" > "${LOG_FILE}"
            echo "Installation Log" >> "${LOG_FILE}"
            echo "Started: $(get_timestamp)" >> "${LOG_FILE}"
            echo "========================================" >> "${LOG_FILE}"
            echo "" >> "${LOG_FILE}"
        fi
        
        echo -e "${COLOR_GREEN}Logging initialized. Log file: ${LOG_FILE}${COLOR_RESET}"
        write_to_log_file "INFO" "Logging initialized. Log file: ${LOG_FILE}"
    fi
}

################################################################################
# Set log level
# Usage: set_log_level LOG_LEVEL_DEBUG
################################################################################
set_log_level() {
    local level="$1"
    CURRENT_LOG_LEVEL="$(_parse_log_level "${level}")"
    log_debug "Log level set to: ${CURRENT_LOG_LEVEL}"
}

################################################################################
# Export functions for use in other scripts
################################################################################
export -f _parse_log_level
export -f get_timestamp
export -f write_to_log_file
export -f log_debug
export -f log_info
export -f log_file_only
export -f log_warn
export -f log_error
export -f log_success
export -f log_validation_success
export -f log_section
export -f log_section_silent
export -f log_step
export -f log_command
export -f log_custom
export -f log_separator
export -f log_progress
export -f log_install_success
export -f log_uninstall_success
export -f start_spinner
export -f stop_spinner
export -f _spinner_cleanup_trap
export -f enable_spinner_trap
export -f init_logging
export -f set_log_level

