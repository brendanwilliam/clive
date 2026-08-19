#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEST_STATE=$(mktemp -d)
DAEMON=${ROOT_DIR}/.build/debug/clive
DAEMON_PID=""
cleanup() {
    if [[ -n ${DAEMON_PID} ]] && kill -0 ${DAEMON_PID} 2>/dev/null; then kill ${DAEMON_PID} 2>/dev/null || true; fi
    rm -rf "${TEST_STATE}"
}
trap cleanup EXIT

swift build --package-path "${ROOT_DIR}"
CLIVE_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" start --allow-non-private-network >"${TEST_STATE}/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in {1..400}; do
    [[ -S ${TEST_STATE}/control.sock ]] && break
    sleep 0.05
done
if [[ ! -S ${TEST_STATE}/control.sock ]]; then
    cat "${TEST_STATE}/daemon.log" >&2
    exit 1
fi
PERMISSIONS=$(stat -f %Lp "${TEST_STATE}/control.sock")
[[ ${PERMISSIONS} == 600 ]]
STATUS=$(CLIVE_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" status)
[[ ${STATUS} == "No paired devices."* ]]
CLIVE_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" stop
wait ${DAEMON_PID}
DAEMON_PID=""
[[ ! -e ${TEST_STATE}/control.sock ]]
echo "macOS control-socket integration test passed"
