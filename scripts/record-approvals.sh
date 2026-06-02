#!/usr/bin/env bash
# record-approvals.sh — write a JSON + Markdown record of the signing event.
#
# Inputs (env):
#   GH_TOKEN              required — token with `actions: read` scope
#   GITHUB_REPOSITORY     required
#   GITHUB_RUN_ID         required
#   GITHUB_ACTOR          required
#   GITHUB_SERVER_URL     required
#   GITHUB_SHA            required
#   IMAGE_URI             required
#   IMAGE_DIGEST          required
#   SBOM_ARTIFACT         optional
#   TRIVY_CRITICAL_COUNT  optional, default 0
#   TRIVY_HIGH_COUNT      optional, default 0
#   SLSA_ATTESTATION      optional — present | verified | not-generated (default not-generated)
#   OUT_JSON              required — path to write JSON record
#   OUT_MD                required — path to write Markdown record
set -euo pipefail

: "${GH_TOKEN:?required}"
: "${GITHUB_REPOSITORY:?required}"
: "${GITHUB_RUN_ID:?required}"
: "${GITHUB_ACTOR:?required}"
: "${GITHUB_SERVER_URL:?required}"
: "${GITHUB_SHA:?required}"
: "${IMAGE_URI:?required}"
: "${IMAGE_DIGEST:?required}"
: "${OUT_JSON:?required}"
: "${OUT_MD:?required}"

SBOM_ARTIFACT="${SBOM_ARTIFACT:-}"
TRIVY_CRITICAL_COUNT="${TRIVY_CRITICAL_COUNT:-0}"
TRIVY_HIGH_COUNT="${TRIVY_HIGH_COUNT:-0}"
SLSA_ATTESTATION="${SLSA_ATTESTATION:-not-generated}"

approval_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
workflow_run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

# Resolve approver identities. Pending approvals are not present here — by the
# time this script runs, the gate has been passed, so /approvals returns the
# users who clicked Approve. If env protection wasn't configured (no reviewers
# required), the API returns an empty list; we treat that as a hard fail
# because sign_container=true implies an approver gate (FR-9).
approvals_json="$(
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/approvals" \
    || echo '[]'
)"

approvers_count="$(echo "$approvals_json" | jq 'length')"
if [[ "$approvers_count" -eq 0 ]]; then
  echo "::error::No approvers resolved from /actions/runs/${GITHUB_RUN_ID}/approvals."
  echo "::error::sign_container=true requires the signing GitHub Environment to have required reviewers."
  exit 1
fi

approvers_list="$(echo "$approvals_json" | jq -c '[.[] | {login: .user.login, id: .user.id, approved_at: .updated_at, comment: (.comment // "")}]')"
triggered_by_id="$(curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" "${GITHUB_API_URL:-https://api.github.com}/users/${GITHUB_ACTOR}" | jq -r '.id // 0')"

jq -n \
  --arg triggered_by "$GITHUB_ACTOR" \
  --argjson triggered_by_id "$triggered_by_id" \
  --argjson approvers "$approvers_list" \
  --arg approval_timestamp "$approval_timestamp" \
  --arg commit_sha "$GITHUB_SHA" \
  --arg image_uri "$IMAGE_URI" \
  --arg image_digest "$IMAGE_DIGEST" \
  --arg workflow_run_url "$workflow_run_url" \
  --arg sbom_artifact "$SBOM_ARTIFACT" \
  --argjson trivy_critical $((TRIVY_CRITICAL_COUNT)) \
  --argjson trivy_high $((TRIVY_HIGH_COUNT)) \
  --arg slsa_attestation "$SLSA_ATTESTATION" \
  '{
    triggered_by: $triggered_by,
    triggered_by_id: $triggered_by_id,
    approvers: $approvers,
    approval_timestamp: $approval_timestamp,
    commit_sha: $commit_sha,
    image_uri: $image_uri,
    image_digest: $image_digest,
    workflow_run_url: $workflow_run_url,
    sbom_artifact: $sbom_artifact,
    scan_summary: { critical: $trivy_critical, high: $trivy_high },
    slsa_attestation: $slsa_attestation
  }' > "$OUT_JSON"

{
  echo "# Signing record — $IMAGE_URI"
  echo ""
  echo "| Field | Value |"
  echo "|-------|-------|"
  echo "| Image | \`$IMAGE_URI\` |"
  echo "| Digest | \`$IMAGE_DIGEST\` |"
  echo "| Commit | \`$GITHUB_SHA\` |"
  echo "| Triggered by | @$GITHUB_ACTOR (id $triggered_by_id) |"
  echo "| Approval timestamp | $approval_timestamp |"
  echo "| Workflow run | $workflow_run_url |"
  echo "| SBOM artifact | ${SBOM_ARTIFACT:-(none)} |"
  echo "| Trivy CRITICAL / HIGH | $TRIVY_CRITICAL_COUNT / $TRIVY_HIGH_COUNT |"
  echo "| SLSA attestation | $SLSA_ATTESTATION |"
  echo ""
  echo "## Approvers"
  echo ""
  echo "| Login | User ID | Approved at | Comment |"
  echo "|-------|---------|-------------|---------|"
  echo "$approvals_json" \
    | jq -r '.[] | "| @\(.user.login) | \(.user.id) | \(.updated_at) | \((.comment // "") | gsub("\\|"; "\\|")) |"'
} > "$OUT_MD"

echo "approvers_count=$approvers_count"
