#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
LOG_PATH=${CLIVE_FAST_CHECK_LOG:-/private/tmp/clive-fast-check.log}
BASE_REF=${1:-}
source "${ROOT_DIR}/scripts/lib/script-performance.zsh" check-fast
trap 'exit_code=$?; clive_record_script_performance ${exit_code}' EXIT

echo "Checking whitespace…"
if [[ -n ${BASE_REF} ]]; then
    git -C "${ROOT_DIR}" diff --check "${BASE_REF}" HEAD
else
    git -C "${ROOT_DIR}" diff --check
fi

echo "Running Swift package tests…"
if ! swift test --package-path "${ROOT_DIR}" >"${LOG_PATH}" 2>&1; then
    echo "Swift package tests failed. Full output: ${LOG_PATH}" >&2
    tail -120 "${LOG_PATH}" >&2
    exit 1
fi

echo "Fast checks passed."
