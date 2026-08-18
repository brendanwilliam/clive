#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEST_STATE=$(mktemp -d)
DAEMON=${ROOT_DIR}/.build/debug/iphone-terminald
DAEMON_PID=""
cleanup() {
    if [[ -n ${DAEMON_PID} ]] && kill -0 ${DAEMON_PID} 2>/dev/null; then kill ${DAEMON_PID} 2>/dev/null || true; fi
    rm -rf "${TEST_STATE}"
}
trap cleanup EXIT

swift build --package-path "${ROOT_DIR}"
IPHONE_TERMINAL_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" start --allow-non-private-network &
DAEMON_PID=$!
for _ in {1..100}; do
    [[ -S ${TEST_STATE}/control.sock ]] && break
    sleep 0.05
done
[[ -S ${TEST_STATE}/control.sock ]]
PERMISSIONS=$(stat -f %Lp "${TEST_STATE}/control.sock")
[[ ${PERMISSIONS} == 600 ]]
STATUS=$(IPHONE_TERMINAL_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" status)
[[ ${STATUS} == "No paired devices." ]]
IPHONE_TERMINAL_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" stop
wait ${DAEMON_PID}
DAEMON_PID=""
[[ ! -e ${TEST_STATE}/control.sock ]]
echo "macOS control-socket integration test passed"
