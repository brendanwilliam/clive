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
        failed=1
    fi
done

if (( failed )); then
    echo "Local compatibility verification failed. Full logs are in ${LOG_DIR}." >&2
    exit 1
fi

echo "Shared, macOS, and iOS tests passed."
