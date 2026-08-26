zmodload zsh/datetime

CLIVE_SCRIPT_PERFORMANCE_NAME=$1
CLIVE_SCRIPT_PERFORMANCE_STARTED_AT=${EPOCHREALTIME}
CLIVE_SCRIPT_PERFORMANCE_FILE=${CLIVE_SCRIPT_PERFORMANCE_FILE:-${HOME}/Library/Application Support/Clive/Development/script-runs.tsv}

clive_record_script_performance() {
    local exit_code=$1
    local finished_at=${EPOCHREALTIME}
    local duration=$(( finished_at - CLIVE_SCRIPT_PERFORMANCE_STARTED_AT ))
    local metrics_dir=${CLIVE_SCRIPT_PERFORMANCE_FILE:h}

    mkdir -p "${metrics_dir}" 2>/dev/null || return ${exit_code}
    printf '%s\t%s\t%d\t%.3f\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "${CLIVE_SCRIPT_PERFORMANCE_NAME}" \
        "${exit_code}" \
        "${duration}" >>"${CLIVE_SCRIPT_PERFORMANCE_FILE}" 2>/dev/null || true
    return ${exit_code}
}
