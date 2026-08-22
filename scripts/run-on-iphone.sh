#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
IOS_DIR=${ROOT_DIR}/Apps/Clive
LOCAL_CONFIG=${IOS_DIR}/Config/Local.xcconfig
RUN_DIR=${CLIVE_DEVICE_RUN_DIR:-/private/tmp/clive-device-run}
DERIVED_DIR=${RUN_DIR}/DerivedData
DAEMON_LOG=${RUN_DIR}/daemon.log
DAEMON_ERROR_LOG=${RUN_DIR}/daemon-error.log
DAEMON_PLIST=${RUN_DIR}/com.clive.development-daemon.plist
DAEMON_LABEL=com.clive.development-daemon
LAUNCH_DOMAIN=gui/$(id -u)
LAUNCH_SERVICE=${LAUNCH_DOMAIN}/${DAEMON_LABEL}

if (( $# > 0 )); then
    echo "Usage: ./scripts/run-on-iphone.sh" >&2
    exit 64
fi

for command in swift xcodebuild xcrun xcodegen lsof plutil; do
    command -v "${command}" >/dev/null || {
        echo "Missing required command: ${command}" >&2
        exit 69
    }
done

if [[ ! -f ${LOCAL_CONFIG} ]]; then
    echo "Missing ${LOCAL_CONFIG}. Copy Local.xcconfig.example and set CLIVE_BUNDLE_ID and DEVELOPMENT_TEAM." >&2
    exit 78
fi

mkdir -p "${RUN_DIR}"

echo "Building the current Clive daemon…"
swift build --package-path "${ROOT_DIR}" --product clive
DAEMON=${ROOT_DIR}/.build/debug/clive

# Remove the previous development job before stopping any other daemon. A
# missing job or control socket is expected on the first run.
launchctl bootout "${LAUNCH_SERVICE}" >/dev/null 2>&1 || true
"${DAEMON}" stop >/dev/null 2>&1 || true
/usr/bin/osascript -e 'tell application "Clive" to quit' >/dev/null 2>&1 || true

clive_listener_pids() {
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '
        NR > 1 && ($1 == "clive" || $1 == "Clive") { print $2 }
    ' | sort -u
}

echo "Waiting for the previous Clive listener to stop…"
listener_stopped=false
for _ in {1..50}; do
    if [[ -z $(clive_listener_pids) ]]; then
        listener_stopped=true
        break
    fi
    sleep 0.1
done
if [[ ${listener_stopped} != true ]]; then
    listener_pids=(${(f)"$(clive_listener_pids)"})
    echo "Stopping unresponsive Clive listener process ${listener_pids[*]}…"
    kill -TERM ${listener_pids[@]}
    for _ in {1..50}; do
        if [[ -z $(clive_listener_pids) ]]; then
            listener_stopped=true
            break
        fi
        sleep 0.1
    done
fi
if [[ ${listener_stopped} != true ]]; then
    echo "The previous Clive listener did not stop within 10 seconds." >&2
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR == 1 || $1 == "clive" || $1 == "Clive"' >&2
    exit 1
fi

echo "Registering the current Clive daemon with launchd…"
: > "${DAEMON_LOG}"
: > "${DAEMON_ERROR_LOG}"
plutil -create xml1 "${DAEMON_PLIST}"
plutil -insert Label -string "${DAEMON_LABEL}" "${DAEMON_PLIST}"
plutil -insert ProgramArguments -json "[\"${DAEMON}\",\"start\",\"--allow-non-private-network\"]" "${DAEMON_PLIST}"
plutil -insert RunAtLoad -bool true "${DAEMON_PLIST}"
plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "${DAEMON_PLIST}"
plutil -insert ProcessType -string Background "${DAEMON_PLIST}"
plutil -insert ThrottleInterval -integer 2 "${DAEMON_PLIST}"
plutil -insert WorkingDirectory -string "${ROOT_DIR}" "${DAEMON_PLIST}"
plutil -insert StandardOutPath -string "${DAEMON_LOG}" "${DAEMON_PLIST}"
plutil -insert StandardErrorPath -string "${DAEMON_ERROR_LOG}" "${DAEMON_PLIST}"
launchctl bootstrap "${LAUNCH_DOMAIN}" "${DAEMON_PLIST}"

wait_for_daemon() {
    for _ in {1..100}; do
        if "${DAEMON}" status >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

if ! wait_for_daemon; then
    echo "The launchd development daemon did not become ready." >&2
    launchctl print "${LAUNCH_SERVICE}" >&2 || true
    echo "Standard error: ${DAEMON_ERROR_LOG}" >&2
    tail -40 "${DAEMON_ERROR_LOG}" >&2
    echo "Standard output: ${DAEMON_LOG}" >&2
    tail -40 "${DAEMON_LOG}" >&2
    exit 1
fi

echo "Generating the iOS project…"
(cd "${IOS_DIR}" && xcodegen generate)

raw_destinations=$(xcodebuild \
    -project "${IOS_DIR}/Clive.xcodeproj" \
    -scheme Clive \
    -showdestinations 2>&1)
IOS_DESTINATION_ID=${CLIVE_IOS_DESTINATION_ID:-}
if [[ -z ${IOS_DESTINATION_ID} ]]; then
    IOS_DESTINATION_ID=$(print -r -- "${raw_destinations}" | awk '
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
        if (platform == "iOS" && id != "" && name != "Any iOS Device" && error == "") {
            print id
            exit
        }
    }')
fi
if [[ -z ${IOS_DESTINATION_ID} ]]; then
    echo "No connected iPhone is available to Xcode. Unlock the phone, trust this Mac, and retry." >&2
    print -r -- "${raw_destinations}" >&2
    exit 69
fi

bundle_id=$(awk -F= '
    /^[[:space:]]*CLIVE_BUNDLE_ID[[:space:]]*=/ {
        value = $2
        sub(/[[:space:]]*\/\/.*/, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value != "") result = value
    }
    END { print result }
' "${LOCAL_CONFIG}")
if [[ -z ${bundle_id} ]]; then
    echo "CLIVE_BUNDLE_ID is not set in ${LOCAL_CONFIG}." >&2
    exit 78
fi

echo "Building Clive for iPhone ${IOS_DESTINATION_ID}…"
xcodebuild \
    -project "${IOS_DIR}/Clive.xcodeproj" \
    -scheme Clive \
    -configuration Debug \
    -destination "id=${IOS_DESTINATION_ID}" \
    -derivedDataPath "${DERIVED_DIR}" \
    -allowProvisioningUpdates \
    build

app_path=${DERIVED_DIR}/Build/Products/Debug-iphoneos/Clive\ -\ CLI\ for\ iOS.app
if [[ ! -d ${app_path} ]]; then
    echo "Built app was not found at ${app_path}." >&2
    exit 1
fi

echo "Installing and launching ${bundle_id}…"
xcrun devicectl device install app --device "${IOS_DESTINATION_ID}" "${app_path}"
xcrun devicectl device process launch \
    --device "${IOS_DESTINATION_ID}" \
    --terminate-existing \
    "${bundle_id}"

if ! wait_for_daemon; then
    echo "The development daemon stopped during the iPhone deployment." >&2
    launchctl print "${LAUNCH_SERVICE}" >&2 || true
    tail -40 "${DAEMON_ERROR_LOG}" >&2
    exit 1
fi

echo "Clive is running on the iPhone."
echo "Daemon log: ${DAEMON_LOG}"
echo "Daemon error log: ${DAEMON_ERROR_LOG}"
echo "Stop the daemon with: launchctl bootout ${LAUNCH_SERVICE}"
