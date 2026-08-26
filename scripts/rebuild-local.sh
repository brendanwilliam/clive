#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
IOS_DIR=${ROOT_DIR}/Apps/Clive
BUILD_DIR=${CLIVE_REBUILD_DIR:-${ROOT_DIR}/scripts/outputs/rebuild-local}
source "${ROOT_DIR}/scripts/lib/script-performance.zsh" "rebuild-local:${1:-unknown}"
trap 'exit_code=$?; clive_record_script_performance ${exit_code}' EXIT

usage() {
    cat <<'EOF'
Usage: ./scripts/rebuild-local.sh app|cli

app  Generate and rebuild the unsigned iOS app without booting a Simulator.
cli  Rebuild the clive command-line executable with SwiftPM.

Use ./scripts/update-local.sh when a signed physical-device install and daemon
replacement are required.
EOF
}

case ${1:-} in
app)
    command -v xcodegen >/dev/null
    command -v xcodebuild >/dev/null
    mkdir -p "${BUILD_DIR}"
    (cd "${IOS_DIR}" && xcodegen generate)
    xcodebuild -quiet \
        -project "${IOS_DIR}/Clive.xcodeproj" \
        -scheme Clive \
        -configuration Debug \
        -destination "generic/platform=iOS Simulator" \
        -derivedDataPath "${BUILD_DIR}/app-derived-data" \
        CODE_SIGNING_ALLOWED=NO \
        SWIFT_ENABLE_EXPLICIT_MODULES=NO \
        CLANG_ENABLE_EXPLICIT_MODULES=NO \
        build
    echo "iOS app rebuilt at ${BUILD_DIR}/app-derived-data/Build/Products/Debug-iphonesimulator/."
    ;;
cli)
    swift build --package-path "${ROOT_DIR}" --product clive
    echo "CLI rebuilt at ${ROOT_DIR}/.build/debug/clive."
    ;;
*)
    usage >&2
    exit 64
    ;;
esac
