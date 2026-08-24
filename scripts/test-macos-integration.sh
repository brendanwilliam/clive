#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TEST_STATE=$(mktemp -d)
DAEMON=${ROOT_DIR}/.build/debug/clive
DAEMON_PID=""
fail() {
    echo "Integration failure: $1" >&2
    if [[ -f ${TEST_STATE}/daemon.log ]]; then
        echo "Daemon log:" >&2
        cat "${TEST_STATE}/daemon.log" >&2
    fi
    exit 1
}
cleanup() {
    if [[ -n ${DAEMON_PID} ]] && kill -0 ${DAEMON_PID} 2>/dev/null; then kill ${DAEMON_PID} 2>/dev/null || true; fi
    rm -rf "${TEST_STATE}"
}
trap cleanup EXIT

swift build --package-path "${ROOT_DIR}"
CLIVE_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" start --allow-non-private-network >"${TEST_STATE}/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in {1..1200}; do
    [[ -S ${TEST_STATE}/control.sock ]] && break
    sleep 0.05
done
if [[ ! -S ${TEST_STATE}/control.sock ]]; then
    fail "control socket was not created"
fi
PERMISSIONS=$(stat -f %Lp "${TEST_STATE}/control.sock")
[[ ${PERMISSIONS} == 600 ]] || fail "control socket permissions were ${PERMISSIONS}, expected 600"
LOCK_PERMISSIONS=$(stat -f %Lp "${TEST_STATE}/daemon.lock")
[[ ${LOCK_PERMISSIONS} == 600 ]] || fail "daemon lock permissions were ${LOCK_PERMISSIONS}, expected 600"
STATUS=$(CLIVE_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" status) || fail "status command failed"
[[ ${STATUS} == "No paired devices."* ]] || fail "unexpected status output: ${STATUS}"
CLIVE_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" start --allow-non-private-network >"${TEST_STATE}/second-daemon.log" 2>&1 &
SECOND_DAEMON_PID=$!
if wait ${SECOND_DAEMON_PID}; then
    fail "second daemon started successfully"
fi
SECOND_OUTPUT=$(<"${TEST_STATE}/second-daemon.log")
[[ ${SECOND_OUTPUT} == *"Another Clive daemon is already running."* ]] || fail "unexpected second daemon output: ${SECOND_OUTPUT}"
STATUS=$(CLIVE_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" status) || fail "status failed after rejected second daemon"
[[ ${STATUS} == "No paired devices."* ]] || fail "unexpected status after rejected second daemon: ${STATUS}"
STOP_OUTPUT=$(CLIVE_STATE_DIRECTORY=${TEST_STATE} "${DAEMON}" stop) || fail "stop command failed"
[[ ${STOP_OUTPUT} == "Stopping daemon." ]] || fail "unexpected stop output: ${STOP_OUTPUT}"
wait ${DAEMON_PID} || fail "daemon exited unsuccessfully"
DAEMON_PID=""
[[ ! -e ${TEST_STATE}/control.sock ]] || fail "control socket remained after shutdown"
echo "macOS control-socket integration test passed"
