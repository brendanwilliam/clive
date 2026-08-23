#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
VERSION=""
SCHEMA_CONFIRMED=false
PRERELEASE=true
VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
STABLE_TAG_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$'

usage() {
    echo "Usage: ./scripts/update-builds.sh [version] --cloudkit-production-schema-deployed [--release]" >&2
}

if [[ ${1:-} != --* && -n ${1:-} ]]; then
    VERSION=$1
    shift
fi
for argument in "$@"; do
    case "${argument}" in
        --cloudkit-production-schema-deployed) SCHEMA_CONFIRMED=true ;;
        --release) PRERELEASE=false ;;
        *) usage; exit 64 ;;
    esac
done
if [[ -n ${VERSION} && ! ${VERSION} =~ ${VERSION_PATTERN} ]]; then
    usage
    exit 64
fi
if [[ ${SCHEMA_CONFIRMED} != true ]]; then
    echo "Confirm the CloudKit schema is deployed to Production with --cloudkit-production-schema-deployed." >&2
    exit 64
fi

command -v gh >/dev/null || { echo "Missing required command: gh" >&2; exit 69; }
if [[ $(git -C "${ROOT_DIR}" branch --show-current) != main ]]; then
    echo "update-builds must be run from the main branch." >&2
    exit 64
fi
if [[ -n $(git -C "${ROOT_DIR}" status --porcelain) ]]; then
    echo "update-builds requires a clean working tree." >&2
    exit 65
fi

git -C "${ROOT_DIR}" fetch --tags origin main
if [[ $(git -C "${ROOT_DIR}" rev-parse HEAD) != $(git -C "${ROOT_DIR}" rev-parse origin/main) ]]; then
    echo "Local main must exactly match origin/main before releasing." >&2
    exit 65
fi

if [[ -z ${VERSION} ]]; then
    latest_tag=""
    for tag in ${(f)"$(git -C "${ROOT_DIR}" tag --list 'v[0-9]*' --sort=-version:refname)"}; do
        if [[ ${tag} =~ ${STABLE_TAG_PATTERN} ]]; then
            latest_tag=${tag}
            break
        fi
    done
    if [[ -z ${latest_tag} ]]; then
        echo "No stable release tag was found. Provide an explicit version." >&2
        exit 65
    fi
    version_parts=(${(s:.:)${latest_tag#v}})
    VERSION="${version_parts[1]}.${version_parts[2]}.$((version_parts[3] + 1))"
    echo "No version provided; incrementing ${latest_tag} to ${VERSION}."
fi

repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
login=$(gh api user --jq .login)
permission=$(gh api "repos/${repository}/collaborators/${login}/permission" --jq .permission)
if [[ ${permission} != admin ]]; then
    echo "update-builds requires repository owner or administrator permission." >&2
    exit 77
fi

echo "Dispatching the ${VERSION} coordinated release as ${login}…"
gh workflow run coordinated-release.yml \
    --repo "${repository}" \
    --ref main \
    --raw-field "version=${VERSION}" \
    --raw-field "prerelease=${PRERELEASE}" \
    --raw-field "cloudkit_production_schema_deployed=true"
echo "Release dispatched. Monitor it with: gh run list --workflow coordinated-release.yml --repo ${repository}"
