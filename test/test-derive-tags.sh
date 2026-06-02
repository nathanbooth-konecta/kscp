#!/usr/bin/env bash
# Self-contained unit test for scripts/derive-tags.sh.
# Run from the repo root: bash test/test-derive-tags.sh
set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT="$(pwd)/scripts/derive-tags.sh"

fail=0
total=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  total=$((total + 1))
  if [[ "$got" == "$want" ]]; then
    echo "  PASS: $label"
  else
    echo "  FAIL: $label"
    echo "        want: $want"
    echo "        got : $got"
    fail=$((fail + 1))
  fi
}

# --- shared base
common_env() {
  export IMAGE_NAME="kix-app-test"
  export AR_REGISTRY="europe-west1-docker.pkg.dev/kd-ix-eur-shr-artifacts/approved-images"
  export GITHUB_SHA="abcdef1234567890abcdef1234567890abcdef12"
  export VERSION_FILE=""
  export VERSION_TAG=""
  export AUTO_TAG="false"
  export BUILT_IMAGE=""
}

# --- helper: parse KEY=VALUE output
get() {
  awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print}' <<<"$OUTPUT"
}

# === Test: main branch, no auto_tag ===
common_env
export GITHUB_REF="refs/heads/main"
export GITHUB_REF_TYPE="branch"
export GITHUB_REF_NAME="main"
tmp=$(mktemp -d); echo "1.2.3" > "$tmp/version.txt"
( cd "$tmp" && OUTPUT="$($SCRIPT)" && \
  echo "[main / no auto_tag]" && \
  assert_eq "$(get image_tag)" "1.2.3" "image_tag" && \
  assert_eq "$(get lane)" "release" "lane" && \
  assert_eq "$(get tags)" "1.2.3,release,latest,abcdef1" "tags"
)
fail=$((fail + $?))

# === Test: main branch with auto_tag ===
common_env
export GITHUB_REF="refs/heads/main"
export GITHUB_REF_TYPE="branch"
export GITHUB_REF_NAME="main"
export AUTO_TAG="true"
tmp=$(mktemp -d); echo "1.2.3" > "$tmp/version.txt"
( cd "$tmp" && OUTPUT="$($SCRIPT)" && \
  echo "[main / auto_tag]" && \
  assert_eq "$(get image_tag)" "1.2.4" "image_tag bumped"
)
fail=$((fail + $?))

# === Test: develop branch ===
common_env
export GITHUB_REF="refs/heads/develop"
export GITHUB_REF_TYPE="branch"
export GITHUB_REF_NAME="develop"
tmp=$(mktemp -d); echo "0.5.0" > "$tmp/version.txt"
( cd "$tmp" && OUTPUT="$($SCRIPT)" && \
  echo "[develop]" && \
  assert_eq "$(get image_tag)" "0.5.0-dev.abcdef1" "image_tag" && \
  assert_eq "$(get lane)" "dev" "lane"
)
fail=$((fail + $?))

# === Test: release branch ===
common_env
export GITHUB_REF="refs/heads/release/2025-q4"
export GITHUB_REF_TYPE="branch"
export GITHUB_REF_NAME="release/2025-q4"
tmp=$(mktemp -d); echo "1.0.0" > "$tmp/version.txt"
( cd "$tmp" && OUTPUT="$($SCRIPT)" && \
  echo "[release branch]" && \
  assert_eq "$(get image_tag)" "1.0.0-rc.2025-q4.abcdef1" "image_tag" && \
  assert_eq "$(get lane)" "rc" "lane"
)
fail=$((fail + $?))

# === Test: tag push ===
common_env
export GITHUB_REF="refs/tags/v1.2.3"
export GITHUB_REF_TYPE="tag"
export GITHUB_REF_NAME="v1.2.3"
tmp=$(mktemp -d); echo "1.2.3" > "$tmp/version.txt"
( cd "$tmp" && OUTPUT="$($SCRIPT)" && \
  echo "[tag push]" && \
  assert_eq "$(get image_tag)" "1.2.3" "image_tag strip v" && \
  assert_eq "$(get lane)" "release" "lane"
)
fail=$((fail + $?))

# === Test: feature branch (slash sanitisation) ===
common_env
export GITHUB_REF="refs/heads/feature/multi-arm-support"
export GITHUB_REF_TYPE="branch"
export GITHUB_REF_NAME="feature/multi-arm-support"
tmp=$(mktemp -d); echo "0.1.0" > "$tmp/version.txt"
( cd "$tmp" && OUTPUT="$($SCRIPT)" && \
  echo "[feature branch]" && \
  assert_eq "$(get lane)" "branch" "lane" && \
  assert_eq "$(get image_tag)" "0.1.0-branch.feature-multi-arm-support.abcdef1" "image_tag sanitised"
)
fail=$((fail + $?))

# === Test: built_image short-circuit ===
common_env
export GITHUB_REF="refs/heads/main"
export GITHUB_REF_TYPE="branch"
export GITHUB_REF_NAME="main"
export BUILT_IMAGE="docker.io/library/nginx:1.27.1"
OUTPUT="$($SCRIPT)"
echo "[built_image short-circuit]"
assert_eq "$(get lane)" "imported" "lane"
assert_eq "$(get image_uri)" "docker.io/library/nginx:1.27.1" "image_uri"
assert_eq "$(get image_tag)" "1.27.1" "image_tag"

# === Test: invalid version.txt ===
common_env
unset BUILT_IMAGE
export GITHUB_REF="refs/heads/main"
export GITHUB_REF_TYPE="branch"
export GITHUB_REF_NAME="main"
tmp=$(mktemp -d); echo "not-a-version" > "$tmp/version.txt"
total=$((total + 1))
if ( cd "$tmp" && "$SCRIPT" >/dev/null 2>&1 ); then
  echo "  FAIL: invalid version should exit non-zero"
  fail=$((fail + 1))
else
  echo "  PASS: invalid version rejected"
fi

echo
echo "Total: $total assertion(s); $fail failure(s)"
exit $((fail > 0 ? 1 : 0))
