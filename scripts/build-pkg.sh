#!/bin/zsh
set -euo pipefail
ROOT_DIR=${0:A:h:h}
OUTPUT_DIR=${ROOT_DIR}/dist
STAGE_DIR=$(mktemp -d)
MAC_DERIVED_DIR=$(mktemp -d)
trap 'rm -rf "${STAGE_DIR}" "${MAC_DERIVED_DIR}"' EXIT
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
rm -f "${OUTPUT_DIR}/clive-unsigned.pkg" "${OUTPUT_DIR}/clive.pkg" "${OUTPUT_DIR}/clive.pkg.sha256"

if [[ -n ${DEVELOPER_ID_APPLICATION:-} || -n ${DEVELOPER_ID_INSTALLER:-} ]]; then
    required=(
        DEVELOPER_ID_APPLICATION
        DEVELOPER_ID_INSTALLER
        APPLE_TEAM_ID
        CLIVE_MAC_BUNDLE_ID
        CLIVE_ICLOUD_CONTAINER
        MAC_PROVISIONING_PROFILE
    )
    for name in ${required[@]}; do
        [[ -n ${(P)name:-} ]] || { echo "Missing release configuration: ${name}" >&2; exit 1; }
    done
fi

swift build --package-path "${ROOT_DIR}" -c release --arch arm64
command -v xcodegen >/dev/null
xcodegen generate --spec "${ROOT_DIR}/Apps/CliveMac/project.yml"

xcode_arguments=(
    -project "${ROOT_DIR}/Apps/CliveMac/CliveMac.xcodeproj"
    -scheme CliveMac
    -configuration Release
    -derivedDataPath "${MAC_DERIVED_DIR}"
    ARCHS=arm64
    MARKETING_VERSION="${VERSION}"
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"
)
if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
    export CLIVE_RELEASE_CODE_SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION}"
    export CLIVE_RELEASE_TEAM_ID="${APPLE_TEAM_ID}"
    export CLIVE_RELEASE_BUNDLE_ID="${CLIVE_MAC_BUNDLE_ID}"
    export CLIVE_RELEASE_ICLOUD_CONTAINER="${CLIVE_ICLOUD_CONTAINER}"
    export CLIVE_RELEASE_PROVISIONING_PROFILE="${MAC_PROVISIONING_PROFILE}"
else
    export CLIVE_RELEASE_BUNDLE_ID="${CLIVE_MAC_BUNDLE_ID:-com.yourcompany.clive.mac}"
    export CLIVE_RELEASE_ICLOUD_CONTAINER="${CLIVE_ICLOUD_CONTAINER:-iCloud.com.yourcompany.clive}"
    xcode_arguments+=(CODE_SIGNING_ALLOWED=NO)
fi
xcodebuild "${xcode_arguments[@]}" build
mkdir -p "${STAGE_DIR}/usr/local/bin" "${STAGE_DIR}/Applications" "${OUTPUT_DIR}"
cp "${ROOT_DIR}/.build/arm64-apple-macosx/release/clive" "${STAGE_DIR}/usr/local/bin/clive"
cp -R "${MAC_DERIVED_DIR}/Build/Products/Release/Clive.app" "${STAGE_DIR}/Applications/Clive.app"
[[ $(lipo -archs "${STAGE_DIR}/usr/local/bin/clive") == arm64 ]]
if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
    codesign --force --options runtime --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${STAGE_DIR}/usr/local/bin/clive"
    codesign --verify --deep --strict --verbose=2 "${STAGE_DIR}/Applications/Clive.app"
    codesign --verify --strict --verbose=2 "${STAGE_DIR}/usr/local/bin/clive"
fi
UNSIGNED_PKG=${OUTPUT_DIR}/clive-unsigned.pkg
pkgbuild --root "${STAGE_DIR}" --identifier com.clive.pkg --version "${VERSION}" --install-location / "${UNSIGNED_PKG}"
if [[ -n ${DEVELOPER_ID_INSTALLER:-} ]]; then
    SIGNED_PKG=${OUTPUT_DIR}/clive.pkg
    productsign --sign "${DEVELOPER_ID_INSTALLER}" "${UNSIGNED_PKG}" "${SIGNED_PKG}"
    if [[ -n ${NOTARY_KEY_PATH:-} ]]; then
        : ${NOTARY_KEY_ID:?Missing NOTARY_KEY_ID}
        : ${NOTARY_ISSUER_ID:?Missing NOTARY_ISSUER_ID}
        xcrun notarytool submit "${SIGNED_PKG}" \
            --key "${NOTARY_KEY_PATH}" \
            --key-id "${NOTARY_KEY_ID}" \
            --issuer "${NOTARY_ISSUER_ID}" \
            --wait
        xcrun stapler staple "${SIGNED_PKG}"
        xcrun stapler validate "${SIGNED_PKG}"
    elif [[ -n ${NOTARY_PROFILE:-} ]]; then
        xcrun notarytool submit "${SIGNED_PKG}" --keychain-profile "${NOTARY_PROFILE}" --wait
        xcrun stapler staple "${SIGNED_PKG}"
        xcrun stapler validate "${SIGNED_PKG}"
    fi
else
    cp "${UNSIGNED_PKG}" "${OUTPUT_DIR}/clive.pkg"
fi
pkgutil --check-signature "${OUTPUT_DIR}/clive.pkg" >/dev/null 2>&1 || [[ -z ${DEVELOPER_ID_INSTALLER:-} ]]
pkgutil --payload-files "${OUTPUT_DIR}/clive.pkg" | grep -qx './usr/local/bin/clive'
pkgutil --payload-files "${OUTPUT_DIR}/clive.pkg" | grep -qx './Applications/Clive.app/Contents/MacOS/Clive'
(cd "${OUTPUT_DIR}" && shasum -a 256 clive.pkg > clive.pkg.sha256)
echo "Created ${OUTPUT_DIR}/clive.pkg"
