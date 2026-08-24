#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
TAP_REPOSITORY="brendanwilliam/homebrew-tap"
RELEASE_REPOSITORY="brendanwilliam/clive"
VERSION=${1#v}

usage() {
    echo "Usage: $0 <semantic-version>" >&2
}

[[ -n ${VERSION} ]] || { usage; exit 64; }
command -v gh >/dev/null || { echo "Missing required command: gh" >&2; exit 69; }
[[ -n ${HOMEBREW_TAP_TOKEN:-} ]] || { echo "Missing required release secret: HOMEBREW_TAP_TOKEN" >&2; exit 78; }
[[ -n ${RELEASE_GITHUB_TOKEN:-} ]] || { echo "Missing required release token: RELEASE_GITHUB_TOKEN" >&2; exit 78; }

TAG="v${VERSION}"
checksum_path="${ROOT_DIR}/dist/clive.pkg.sha256"
package_path="${ROOT_DIR}/dist/clive.pkg"
[[ -f ${checksum_path} && -f ${package_path} ]] || {
    echo "Release package metadata is missing; cannot update the Homebrew cask." >&2
    exit 65
}

expected_checksum="$(awk '$2 == "clive.pkg" { print $1 }' "${checksum_path}")"
if [[ ! ${expected_checksum} =~ ^[0-9a-f]{64}$ ]] || [[ ${expected_checksum} != $(shasum -a 256 "${package_path}" | awk '{ print $1 }') ]]; then
    echo "Release package checksum is malformed or does not match clive.pkg; refusing to publish the Homebrew cask." >&2
    exit 65
fi

release_assets="$(GH_TOKEN="${RELEASE_GITHUB_TOKEN}" gh release view "${TAG}" --repo "${RELEASE_REPOSITORY}" --json assets --jq '.assets[].name')" || {
    echo "GitHub Release ${TAG} is unavailable; refusing to publish the Homebrew cask." >&2
    exit 65
}
if ! print -r -- "${release_assets}" | grep -qx 'clive.pkg' || ! print -r -- "${release_assets}" | grep -qx 'clive.pkg.sha256'; then
    echo "GitHub Release ${TAG} is missing clive.pkg or clive.pkg.sha256; refusing to publish the Homebrew cask." >&2
    exit 65
fi

cask_path="${RUNNER_TEMP:-/tmp}/clive.rb"
"${ROOT_DIR}/scripts/render-homebrew-cask.py" --version "${VERSION}" --sha256 "${expected_checksum}" > "${cask_path}"
cask_content="$(base64 < "${cask_path}" | tr -d '\n')"
existing_sha="$(GH_TOKEN="${HOMEBREW_TAP_TOKEN}" gh api "repos/${TAP_REPOSITORY}/contents/Casks/clive.rb" --jq .sha)" || {
    echo "The Homebrew tap does not contain Casks/clive.rb; refusing to replace or create an unexpected path." >&2
    exit 65
}

GH_TOKEN="${HOMEBREW_TAP_TOKEN}" gh api --method PUT "repos/${TAP_REPOSITORY}/contents/Casks/clive.rb" \
    -f message="Update Clive to ${VERSION}" \
    -f content="${cask_content}" \
    -f sha="${existing_sha}" \
    -f branch=main >/dev/null

echo "Updated ${TAP_REPOSITORY} Casks/clive.rb for ${TAG}."
