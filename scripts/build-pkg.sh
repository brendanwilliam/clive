#!/bin/zsh
set -euo pipefail
ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${ROOT_DIR}/dist
STAGE_DIR=$(mktemp -d)
trap 'rm -rf "${STAGE_DIR}"' EXIT
swift build --package-path "${ROOT_DIR}" -c release --arch arm64
mkdir -p "${STAGE_DIR}/usr/local/bin" "${OUTPUT_DIR}"
cp "${ROOT_DIR}/.build/arm64-apple-macosx/release/iphone-terminald" "${STAGE_DIR}/usr/local/bin/iphone-terminald"
if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
    codesign --force --options runtime --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${STAGE_DIR}/usr/local/bin/iphone-terminald"
fi
UNSIGNED_PKG=${OUTPUT_DIR}/iphone-terminal-unsigned.pkg
pkgbuild --root "${STAGE_DIR}" --identifier com.iphoneterminal.cli --version "${VERSION:-0.1.0}" --install-location / "${UNSIGNED_PKG}"
if [[ -n ${DEVELOPER_ID_INSTALLER:-} ]]; then
    SIGNED_PKG=${OUTPUT_DIR}/iphone-terminal.pkg
    productsign --sign "${DEVELOPER_ID_INSTALLER}" "${UNSIGNED_PKG}" "${SIGNED_PKG}"
    if [[ -n ${NOTARY_PROFILE:-} ]]; then
        xcrun notarytool submit "${SIGNED_PKG}" --keychain-profile "${NOTARY_PROFILE}" --wait
        xcrun stapler staple "${SIGNED_PKG}"
    fi
else
    cp "${UNSIGNED_PKG}" "${OUTPUT_DIR}/iphone-terminal.pkg"
fi
echo "Created ${OUTPUT_DIR}/iphone-terminal.pkg"
