#!/usr/bin/env bash
# render-trivy-summary.sh — produce a Markdown table from Trivy JSON output.
#
# Inputs (env):
#   TRIVY_JSON     path to Trivy `--format json` output (single multi-scanner run)
#   SEVERITY_FAIL  comma-separated severities that should set scan_passed=false
#                  (default CRITICAL,HIGH; HIGH-only does NOT fail per legacy)
#   IMAGE_URI      string interpolated into the summary heading
#
# Outputs (stdout: KEY=VALUE lines for GITHUB_OUTPUT):
#   trivy_critical_count
#   trivy_high_count
#   trivy_medium_count
#   trivy_low_count
#   trivy_secret_count
#   trivy_misconfig_count
#   trivy_license_restricted_count
#   scan_passed
#
# Side effect: appends a Markdown summary table to $GITHUB_STEP_SUMMARY when set.
set -euo pipefail

: "${TRIVY_JSON:?required}"
: "${IMAGE_URI:?required}"
SEVERITY_FAIL="${SEVERITY_FAIL:-CRITICAL}"

[[ -s "$TRIVY_JSON" ]] || { echo "::warning::Trivy JSON is empty" >&2; }

count() { jq -r "$1" "$TRIVY_JSON" 2>/dev/null || echo 0; }

crit=$(count '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length')
high=$(count '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length')
med=$(count '[.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length')
low=$(count '[.Results[]?.Vulnerabilities[]? | select(.Severity=="LOW")] | length')
secrets=$(count '[.Results[]?.Secrets[]?] | length')
misconfig=$(count '[.Results[]?.Misconfigurations[]?] | length')
license_restricted=$(count '[.Results[]?.Licenses[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL")] | length')

scan_passed=true
IFS=',' read -ra fail_levels <<<"$SEVERITY_FAIL"
for lvl in "${fail_levels[@]}"; do
  case "$lvl" in
    CRITICAL) [[ "$crit" -gt 0 ]] && scan_passed=false ;;
    HIGH)     [[ "$high" -gt 0 ]] && scan_passed=false ;;
    MEDIUM)   [[ "$med"  -gt 0 ]] && scan_passed=false ;;
    LOW)      [[ "$low"  -gt 0 ]] && scan_passed=false ;;
  esac
done
# Secrets baked into image layers are always a hard fail (US-006 AC).
[[ "$secrets" -gt 0 ]] && scan_passed=false

{
  echo "trivy_critical_count=$crit"
  echo "trivy_high_count=$high"
  echo "trivy_medium_count=$med"
  echo "trivy_low_count=$low"
  echo "trivy_secret_count=$secrets"
  echo "trivy_misconfig_count=$misconfig"
  echo "trivy_license_restricted_count=$license_restricted"
  echo "scan_passed=$scan_passed"
}

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo ""
    echo "## Trivy scan — \`$IMAGE_URI\`"
    echo ""
    echo "| Category | Count |"
    echo "|----------|-------|"
    echo "| CRITICAL vulnerabilities | $crit |"
    echo "| HIGH vulnerabilities | $high |"
    echo "| MEDIUM vulnerabilities | $med |"
    echo "| LOW vulnerabilities | $low |"
    echo "| Secrets in image | $secrets |"
    echo "| Misconfigurations | $misconfig |"
    echo "| Restricted licences | $license_restricted |"
    echo ""
    echo "**Scan passed:** \`$scan_passed\` (fail-on: \`$SEVERITY_FAIL\`)"
  } >> "$GITHUB_STEP_SUMMARY"
fi
