#!/bin/zsh
set -euo pipefail
ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${ROOT_DIR}/dist
STAGE_DIR=$(mktemp -d)
MAC_DERIVED_DIR=$(mktemp -d)
trap 'rm -rf "${STAGE_DIR}" "${MAC_DERIVED_DIR}"' EXIT
swift build --package-path "${ROOT_DIR}" -c release --arch arm64
command -v xcodegen >/dev/null
xcodegen generate --spec "${ROOT_DIR}/Apps/iPhoneTerminalMac/project.yml"
xcodebuild -project "${ROOT_DIR}/Apps/iPhoneTerminalMac/iPhoneTerminalMac.xcodeproj" -scheme iPhoneTerminalMac -configuration Release -derivedDataPath "${MAC_DERIVED_DIR}" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
mkdir -p "${STAGE_DIR}/usr/local/bin" "${STAGE_DIR}/Applications" "${OUTPUT_DIR}"
cp "${ROOT_DIR}/.build/arm64-apple-macosx/release/iphone-terminald" "${STAGE_DIR}/usr/local/bin/iphone-terminald"
cp -R "${MAC_DERIVED_DIR}/Build/Products/Release/iPhone Terminal.app" "${STAGE_DIR}/Applications/iPhone Terminal.app"
[[ $(lipo -archs "${STAGE_DIR}/usr/local/bin/iphone-terminald") == arm64 ]]
if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
    codesign --force --options runtime --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${STAGE_DIR}/usr/local/bin/iphone-terminald"
    codesign --force --deep --options runtime --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${STAGE_DIR}/Applications/iPhone Terminal.app"
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
pkgutil --check-signature "${OUTPUT_DIR}/iphone-terminal.pkg" >/dev/null 2>&1 || [[ -z ${DEVELOPER_ID_INSTALLER:-} ]]
pkgutil --payload-files "${OUTPUT_DIR}/iphone-terminal.pkg" | grep -qx './usr/local/bin/iphone-terminald'
pkgutil --payload-files "${OUTPUT_DIR}/iphone-terminal.pkg" | grep -qx './Applications/iPhone Terminal.app/Contents/MacOS/iPhone Terminal'
echo "Created ${OUTPUT_DIR}/iphone-terminal.pkg"
