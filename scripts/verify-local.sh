#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
VERIFY_DIR=${CLIVE_VERIFY_DIR:-/private/tmp/clive-local-verify}
LOG_DIR=${VERIFY_DIR}/logs
SIGNED=false

echo "Validating UI feature map…"
python3 "${ROOT_DIR}/scripts/feature-map.py" validate

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
if [[ ! -d "${ROOT_DIR}/Apps/Clive/Clive.xcodeproj" ]]; then
    command -v xcodegen >/dev/null || {
        echo "Clive.xcodeproj is generated; install XcodeGen and retry." >&2
        exit 69
    }
    (cd "${ROOT_DIR}/Apps/Clive" && xcodegen generate)
fi

signing_arguments=()
if [[ ${SIGNED} == false ]]; then
    signing_arguments+=(CODE_SIGNING_ALLOWED=NO)
fi

print_simulator_diagnostics() {
    local raw_destinations=$1

    echo "Xcode version:" >&2
    xcodebuild -version >&2 || true
    echo "Installed simulator runtimes:" >&2
    xcrun simctl list runtimes >&2 || true
    echo "Available simulator devices:" >&2
    xcrun simctl list devices available >&2 || true
    echo "Raw Clive scheme destinations:" >&2
    print -r -- "${raw_destinations}" >&2
}

print_ios_test_diagnostics() {
    local result_bundle=$1

    echo "iOS result bundle: ${result_bundle}" >&2
    if [[ ! -d ${result_bundle} ]]; then
        echo "No iOS result bundle was produced." >&2
        return
    fi

    if ! xcrun xcresulttool get test-results summary --path "${result_bundle}" --compact 2>/dev/null |
        python3 -c '
import json
import sys

try:
    summary = json.load(sys.stdin)
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)

failures = summary.get("testFailures", [])
if not failures:
    print("The iOS result bundle contains no individual test failures.", file=sys.stderr)
    raise SystemExit(0)

print("iOS test failure summary:", file=sys.stderr)
for failure in failures:
    identifier = failure.get("testIdentifierString", "Unknown test")
    detail = failure.get("failureText", "").lower()
    if "signal" in detail or "crash" in detail:
        category = "test process crashed"
    elif "timed out" in detail:
        category = "test timed out"
    else:
        category = "test failure (details retained in result bundle)"
    print(f"- {identifier}: {category}", file=sys.stderr)
'
    then
        echo "Unable to summarize the iOS result bundle." >&2
    fi
}

raw_ios_destinations=$(xcodebuild \
    -project "${ROOT_DIR}/Apps/Clive/Clive.xcodeproj" \
    -scheme Clive \
    -showdestinations 2>&1) || {
    echo "Unable to discover iOS Simulator destinations." >&2
    print_simulator_diagnostics "${raw_ios_destinations}"
    exit 69
}
IOS_DESTINATION_ID=${CLIVE_IOS_DESTINATION_ID:-}
if [[ -z ${IOS_DESTINATION_ID} ]]; then
    IOS_DESTINATION_ID=$(print -r -- "${raw_ios_destinations}" | awk '
    /^[[:space:]]*\{/ {
        line = $0
        sub(/^[^{]*\{[[:space:]]*/, "", line)
        sub(/[[:space:]]*\}[^}]*$/, "", line)
        count = split(line, fields, ",")
        platform = id = name = error = ""
        for (field_index = 1; field_index <= count; field_index++) {
            separator = match(fields[field_index], /:/)
            if (!separator) continue
            key = substr(fields[field_index], 1, separator - 1)
            value = substr(fields[field_index], separator + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (key == "platform") platform = value
            else if (key == "id") id = value
            else if (key == "name") name = value
            else if (key == "error") error = value
        }
        if (platform == "iOS Simulator" && id != "" &&
            name != "Any iOS Simulator Device" && error == "") {
            print id
            exit
        }
    }
')
fi
if [[ -z ${IOS_DESTINATION_ID} ]]; then
    echo "No iOS Simulator destination is installed." >&2
    print_simulator_diagnostics "${raw_ios_destinations}"
    exit 69
fi
xcrun simctl boot "${IOS_DESTINATION_ID}" 2>/dev/null || true
xcrun simctl bootstatus "${IOS_DESTINATION_ID}" -b

echo "Running shared, macOS, and iOS tests in parallel…"
IOS_RESULT_BUNDLE=${CLIVE_IOS_RESULT_BUNDLE:-"${VERIFY_DIR}/ios-test-$(date +%Y%m%d-%H%M%S).xcresult"}
swift test --package-path "${ROOT_DIR}" >"${LOG_DIR}/swift-test.log" 2>&1 &
swift_pid=$!
xcodebuild -quiet \
    -project "${ROOT_DIR}/Apps/CliveMac/CliveMac.xcodeproj" \
    -scheme CliveMac \
    -configuration Debug \
    -destination platform=macOS \
    -derivedDataPath "${VERIFY_DIR}/mac-derived-data" \
    "${signing_arguments[@]}" \
    test >"${LOG_DIR}/mac-test.log" 2>&1 &
mac_pid=$!
xcodebuild -quiet \
    -project "${ROOT_DIR}/Apps/Clive/Clive.xcodeproj" \
    -scheme Clive \
    -configuration Debug \
    -destination "id=${IOS_DESTINATION_ID}" \
    -derivedDataPath "${VERIFY_DIR}/ios-derived-data" \
    -resultBundlePath "${IOS_RESULT_BUNDLE}" \
    test >"${LOG_DIR}/ios-test.log" 2>&1 &
ios_pid=$!

failed=0
for check in "swift:${swift_pid}:swift-test.log" "macOS:${mac_pid}:mac-test.log" "iOS:${ios_pid}:ios-test.log"; do
    parts=(${(s/:/)check})
    if wait ${parts[2]}; then
        echo "✓ ${parts[1]}"
    else
        echo "✗ ${parts[1]} — ${LOG_DIR}/${parts[3]}" >&2
        tail -80 "${LOG_DIR}/${parts[3]}" >&2
        if [[ ${parts[1]} == iOS ]]; then
            print_ios_test_diagnostics "${IOS_RESULT_BUNDLE}"
        fi
        failed=1
    fi
done

if (( failed )); then
    echo "Local compatibility verification failed. Full logs are in ${LOG_DIR}." >&2
    exit 1
fi

echo "Shared, macOS, and iOS tests passed."
