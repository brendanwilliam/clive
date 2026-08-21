#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
VERIFY_DIR=${CLIVE_VERIFY_DIR:-/private/tmp/clive-local-verify}
LOG_DIR=${VERIFY_DIR}/logs
SIGNED=false

if [[ ${1:-} == --signed ]]; then
    SIGNED=true
    shift
fi
if (( $# > 0 )); then
    echo "Usage: ./scripts/verify-local.sh [--signed]" >&2
    exit 64
fi

mkdir -p "${LOG_DIR}"
command -v swift >/dev/null
command -v xcodebuild >/dev/null

signing_arguments=()
if [[ ${SIGNED} == false ]]; then
    signing_arguments+=(CODE_SIGNING_ALLOWED=NO)
fi

echo "Running shared tests and both platform builds in parallel…"
swift test --package-path "${ROOT_DIR}" >"${LOG_DIR}/swift-test.log" 2>&1 &
swift_pid=$!
xcodebuild -quiet \
    -project "${ROOT_DIR}/Apps/CliveMac/CliveMac.xcodeproj" \
    -scheme CliveMac \
    -configuration Debug \
    -destination platform=macOS \
    -derivedDataPath "${VERIFY_DIR}/mac-derived-data" \
    "${signing_arguments[@]}" \
    build >"${LOG_DIR}/mac-build.log" 2>&1 &
mac_pid=$!
xcodebuild -quiet \
    -project "${ROOT_DIR}/Apps/Clive/Clive.xcodeproj" \
    -scheme Clive \
    -configuration Debug \
    -destination generic/platform=iOS \
    -derivedDataPath "${VERIFY_DIR}/ios-derived-data" \
    "${signing_arguments[@]}" \
    build >"${LOG_DIR}/ios-build.log" 2>&1 &
ios_pid=$!

failed=0
for check in "swift:${swift_pid}:swift-test.log" "macOS:${mac_pid}:mac-build.log" "iOS:${ios_pid}:ios-build.log"; do
    parts=(${(s/:/)check})
    if wait ${parts[2]}; then
        echo "✓ ${parts[1]}"
    else
        echo "✗ ${parts[1]} — ${LOG_DIR}/${parts[3]}" >&2
        tail -80 "${LOG_DIR}/${parts[3]}" >&2
        failed=1
    fi
done

if (( failed )); then
    echo "Local compatibility verification failed. Full logs are in ${LOG_DIR}." >&2
    exit 1
fi

echo "CliveCore tests and both app builds are compatible."
