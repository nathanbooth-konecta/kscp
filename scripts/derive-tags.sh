#!/usr/bin/env bash
# derive-tags.sh — emit the image tags KSCP should push for the current ref.
#
# Lane logic mirrors konecta-ix-applications/.github-private/.github/workflows/
# docker-build-push.yml lines 259–343 byte-for-byte for the same inputs.
#
# Inputs (env):
#   GITHUB_REF              required — e.g. refs/heads/main or refs/tags/v1.2.3
#   GITHUB_REF_TYPE         required — branch | tag
#   GITHUB_REF_NAME         required — main | develop | feature/foo | v1.2.3
#   GITHUB_SHA              required — full commit SHA
#   IMAGE_NAME              required — e.g. kix-app-iqportal
#   AR_REGISTRY             required — e.g. europe-west1-docker.pkg.dev/proj/repo
#   VERSION_FILE            optional, default version.txt
#   VERSION_TAG             optional — explicit override; when set, overrides lane logic
#   AUTO_TAG                optional, default false — when true and on default branch,
#                            increment patch of VERSION_FILE
#   BUILT_IMAGE             optional — when non-empty, emits only the supplied URI as
#                            image_uri, sets lane=imported, skips tag derivation
#
# Outputs (stdout: KEY=VALUE lines, parsed by the caller into GITHUB_OUTPUT):
#   image_repo       <ar_registry>/<image_name>
#   image_tag        primary tag (first in tags)
#   image_uri        <image_repo>:<image_tag>
#   short_sha        first 7 chars of GITHUB_SHA
#   tags             comma-separated list of all tags to push
#   lane             dev | rc | release | branch | imported
#   base_version     contents of VERSION_FILE (trimmed); empty when imported
#   build_timestamp  ISO 8601 UTC
set -euo pipefail

# --- helpers ---------------------------------------------------------------
emit() { printf '%s=%s\n' "$1" "$2"; }
die() { echo "::error::derive-tags: $*" >&2; exit 1; }

# --- required inputs -------------------------------------------------------
: "${GITHUB_REF:?required}"
: "${GITHUB_REF_TYPE:?required}"
: "${GITHUB_REF_NAME:?required}"
: "${GITHUB_SHA:?required}"
: "${IMAGE_NAME:?required}"
: "${AR_REGISTRY:?required}"

VERSION_FILE="${VERSION_FILE:-version.txt}"
VERSION_TAG="${VERSION_TAG:-}"
AUTO_TAG="${AUTO_TAG:-false}"
BUILT_IMAGE="${BUILT_IMAGE:-}"

short_sha="${GITHUB_SHA:0:7}"
build_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- imported (built_image) short-circuit ----------------------------------
if [[ -n "$BUILT_IMAGE" ]]; then
  # Caller supplied a pre-built image URI; honour it verbatim.
  emit image_uri "$BUILT_IMAGE"
  emit image_repo "${BUILT_IMAGE%:*}"
  emit image_tag "${BUILT_IMAGE##*:}"
  emit short_sha "$short_sha"
  emit tags "${BUILT_IMAGE##*:}"
  emit lane "imported"
  emit base_version ""
  emit build_timestamp "$build_timestamp"
  exit 0
fi

# --- read base version -----------------------------------------------------
if [[ -f "$VERSION_FILE" ]]; then
  base_version="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
  base_version="0.0.0"
fi
[[ "$base_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "$VERSION_FILE='$base_version' is not a valid SemVer x.y.z"

image_repo="${AR_REGISTRY}/${IMAGE_NAME}"

# --- explicit version tag override -----------------------------------------
if [[ -n "$VERSION_TAG" ]]; then
  primary="$VERSION_TAG"
  tags="$primary"
  lane="release"
elif [[ "$GITHUB_REF_TYPE" == "tag" ]]; then
  # Tag-triggered builds: use the tag verbatim plus 'release' alias.
  primary="${GITHUB_REF_NAME#v}"
  tags="${primary},release,${short_sha}"
  lane="release"
elif [[ "$GITHUB_REF_NAME" == "main" ]]; then
  if [[ "$AUTO_TAG" == "true" ]]; then
    # Increment patch.
    IFS='.' read -r maj min pat <<<"$base_version"
    new_patch=$((pat + 1))
    primary="${maj}.${min}.${new_patch}"
  else
    primary="${base_version}"
  fi
  tags="${primary},release,latest,${short_sha}"
  lane="release"
elif [[ "$GITHUB_REF_NAME" == "develop" ]]; then
  primary="${base_version}-dev.${short_sha}"
  tags="${primary},dev,${short_sha}"
  lane="dev"
elif [[ "$GITHUB_REF_NAME" =~ ^release/.+ ]]; then
  rc_name="${GITHUB_REF_NAME#release/}"
  primary="${base_version}-rc.${rc_name}.${short_sha}"
  tags="${primary},rc-${rc_name},${short_sha}"
  lane="rc"
else
  # Generic feature branch — sanitise slashes.
  safe_branch="$(printf '%s' "$GITHUB_REF_NAME" | tr '/' '-' | tr -c 'a-zA-Z0-9._-' '-')"
  primary="${base_version}-branch.${safe_branch}.${short_sha}"
  tags="${primary},branch-${safe_branch},${short_sha}"
  lane="branch"
fi

emit image_repo "$image_repo"
emit image_tag "$primary"
emit image_uri "${image_repo}:${primary}"
emit short_sha "$short_sha"
emit tags "$tags"
emit lane "$lane"
emit base_version "$base_version"
emit build_timestamp "$build_timestamp"
