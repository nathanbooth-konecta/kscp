#!/usr/bin/env bash
# Negative-test driver for KSCP. For each scanner the workflow embeds, this
# script:
#   1. Runs the scanner against a deliberately-bad fixture and asserts that
#      it produces non-zero findings (i.e. detection works).
#   2. Replicates the scp.yml enforcement-gate logic verbatim and asserts
#      that with bypass=false the gate exits 1, and with bypass=true the
#      gate exits 0 while emitting ::warning::.
#
# This is the "does the pipeline correctly FAIL on bad input?" test.
#
# Usage: bash test/test-negative-cases.sh
# Requires: docker, hadolint, checkov, gitleaks, trivy, jq.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BAD="$ROOT/test/fixtures/bad"

pass=0
fail=0
skipped=0

c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_yel()   { printf '\033[33m%s\033[0m' "$1"; }

note()    { printf '  %s %s\n' "$(c_yel '·')" "$1"; }
ok()      { pass=$((pass + 1)); printf '  %s %s\n' "$(c_green 'PASS')" "$1"; }
ko()      { fail=$((fail + 1)); printf '  %s %s\n' "$(c_red   'FAIL')" "$1"; }
skip()    { skipped=$((skipped + 1)); printf '  %s %s\n' "$(c_yel 'SKIP')" "$1"; }

require() {
  command -v "$1" >/dev/null 2>&1
}

# -------- Gate replicas (copied verbatim from scp.yml, isolated as functions).
# Each takes the scanner finding count + bypass flag and returns the gate's
# exit code via the function's return value.

gate_dockerfile() {  # checkov / hadolint share the same shape
  local outcome="$1" bypass="$2"
  if [[ "$outcome" == "success" ]]; then return 0; fi
  if [[ "$bypass" == "true" ]]; then
    echo "    ::warning::Dockerfile scan finding present but allow_dockerfile_scan_bypass=true"
    return 0
  fi
  echo "    ::error::Dockerfile scan finding detected"
  return 1
}

gate_hadolint() {
  local err_count="$1" bypass="$2"
  if [[ "$err_count" -eq 0 ]]; then return 0; fi
  if [[ "$bypass" == "true" ]]; then
    echo "    ::warning::Hadolint error-level findings present but allow_dockerfile_scan_bypass=true"
    return 0
  fi
  echo "    ::error::Hadolint reported $err_count error-level finding(s)"
  return 1
}

gate_gitleaks() {
  local count="$1" bypass="$2"
  if [[ "$count" -eq 0 ]]; then return 0; fi
  if [[ "$bypass" == "true" ]]; then
    echo "    ::warning::Gitleaks found $count secret(s) but allow_secrets_bypass=true"
    return 0
  fi
  echo "    ::error::Gitleaks found $count secret(s)"
  return 1
}

gate_trivy() {
  local passed="$1" bypass="$2"
  if [[ "$passed" == "true" ]]; then return 0; fi
  if [[ "$bypass" == "true" ]]; then
    echo "    ::warning::Trivy scan failed but allow_scan_bypass=true"
    return 0
  fi
  echo "    ::error::Trivy scan failed"
  return 1
}

trivy_scan_passed() {  # mirrors render-trivy-summary.sh
  local crit="$1" high="$2" med="$3" low="$4" secrets="$5" fail_on="$6"
  local result=true
  IFS=',' read -ra lvls <<<"$fail_on"
  for lvl in "${lvls[@]}"; do
    case "$lvl" in
      CRITICAL) [[ "$crit" -gt 0 ]] && result=false ;;
      HIGH)     [[ "$high" -gt 0 ]] && result=false ;;
      MEDIUM)   [[ "$med"  -gt 0 ]] && result=false ;;
      LOW)      [[ "$low"  -gt 0 ]] && result=false ;;
    esac
  done
  [[ "$secrets" -gt 0 ]] && result=false
  echo "$result"
}

# ============================================================================
# Case 1: Hadolint detects + gate blocks Dockerfile.lint
# ============================================================================
echo
echo "=== Case 1: Hadolint error-level findings ==="

if ! require hadolint; then
  skip "hadolint not installed"
else
  sarif="$(mktemp)"
  hadolint --format sarif "$BAD/Dockerfile.lint" > "$sarif" 2>/dev/null || true
  err_count=$(jq '[.runs[].results[] | select(.level=="error")] | length' "$sarif" 2>/dev/null || echo 0)
  note "Hadolint produced $err_count error-level finding(s)"

  if [[ "$err_count" -gt 0 ]]; then
    ok "detection: hadolint found error-level violations"
  else
    ko "detection: expected error-level findings, got 0"
  fi

  if gate_hadolint "$err_count" "false" >/tmp/g.log 2>&1; then
    ko "gate (bypass=false) should have exited non-zero"
    cat /tmp/g.log | sed 's/^/    /'
  else
    ok "gate (bypass=false) blocks build [exit 1]"
    grep -q '::error::' /tmp/g.log && note "emitted ::error:: marker"
  fi

  if gate_hadolint "$err_count" "true" >/tmp/g.log 2>&1; then
    ok "gate (bypass=true) allows build [exit 0]"
    grep -q '::warning::' /tmp/g.log && note "emitted ::warning:: marker"
  else
    ko "gate (bypass=true) should have exited 0"
  fi
fi

# ============================================================================
# Case 2: Checkov detects + gate blocks Dockerfile.misconfig
# ============================================================================
echo
echo "=== Case 2: Checkov misconfig findings ==="

if ! require checkov; then
  skip "checkov not installed"
else
  ck_out="$(mktemp)"
  checkov -f "$BAD/Dockerfile.misconfig" --framework dockerfile --quiet \
          --output json --soft-fail >"$ck_out" 2>/dev/null || true
  ck_failed=$(jq '.results.failed_checks | length' "$ck_out" 2>/dev/null || echo 0)
  note "Checkov produced $ck_failed failed check(s)"

  if [[ "$ck_failed" -gt 0 ]]; then
    ok "detection: checkov flagged misconfigurations"
  else
    ko "detection: expected failed checks, got 0"
  fi

  outcome="failure"
  [[ "$ck_failed" -eq 0 ]] && outcome="success"

  if gate_dockerfile "$outcome" "false" >/tmp/g.log 2>&1; then
    ko "gate (bypass=false) should have exited non-zero"
  else
    ok "gate (bypass=false) blocks build [exit 1]"
  fi

  if gate_dockerfile "$outcome" "true" >/tmp/g.log 2>&1; then
    ok "gate (bypass=true) allows build [exit 0]"
    grep -q '::warning::' /tmp/g.log && note "emitted ::warning:: marker"
  else
    ko "gate (bypass=true) should have exited 0"
  fi
fi

# ============================================================================
# Case 3: Gitleaks detects source secrets
# ============================================================================
echo
echo "=== Case 3: Gitleaks source-secret detection ==="

if ! require gitleaks; then
  skip "gitleaks not installed"
else
  # Copy fixture to a clean tempdir so the repo-root .gitleaks.toml allowlist
  # (intended for the *production* scan path) doesn't suppress detection here.
  src_dir="$(mktemp -d)"
  cp "$BAD/source-with-secret.py" "$src_dir/"
  report="$src_dir/report.json"
  gitleaks detect --source="$src_dir" --no-banner --no-git \
                  --report-format=json --report-path="$report" \
                  --redact >/dev/null 2>&1 || true
  gl_count=$(jq 'length' "$report" 2>/dev/null || echo 0)
  note "Gitleaks produced $gl_count finding(s)"

  if [[ "$gl_count" -gt 0 ]]; then
    ok "detection: gitleaks found secrets in source"
  else
    ko "detection: expected gitleaks findings, got 0"
  fi

  if gate_gitleaks "$gl_count" "false" >/tmp/g.log 2>&1; then
    ko "gate (bypass=false) should have exited non-zero"
  else
    ok "gate (bypass=false) blocks build [exit 1]"
  fi

  if gate_gitleaks "$gl_count" "true" >/tmp/g.log 2>&1; then
    ok "gate (bypass=true) allows build [exit 0]"
    grep -q '::warning::' /tmp/g.log && note "emitted ::warning:: marker"
  else
    ko "gate (bypass=true) should have exited 0"
  fi
fi

# ============================================================================
# Case 4: Trivy detects CRITICAL/HIGH vulns in built image
# ============================================================================
echo
echo "=== Case 4: Trivy vulnerability detection ==="

if ! require docker || ! require trivy; then
  skip "docker or trivy not installed"
else
  if ! docker info >/dev/null 2>&1; then
    skip "docker daemon not running"
  else
    img="kscp-neg-vuln:test"
    note "building $img from Dockerfile.vuln (this may pull ~5MB)"
    if docker build --quiet -f "$BAD/Dockerfile.vuln" -t "$img" "$BAD" >/dev/null 2>&1; then
      tr_out="$(mktemp)"
      trivy image --quiet --scanners vuln --severity CRITICAL,HIGH \
                  --format json --output "$tr_out" "$img" >/dev/null 2>&1 || true
      crit=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$tr_out" 2>/dev/null || echo 0)
      high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")]     | length' "$tr_out" 2>/dev/null || echo 0)
      note "Trivy found CRITICAL=$crit HIGH=$high"

      if [[ "$crit" -gt 0 || "$high" -gt 0 ]]; then
        ok "detection: trivy found CRITICAL/HIGH vulns in alpine:3.11"
      else
        ko "detection: expected vulns in old alpine, got crit=$crit high=$high"
      fi

      passed=$(trivy_scan_passed "$crit" "$high" "0" "0" "0" "CRITICAL,HIGH")
      note "render-trivy-summary computed scan_passed=$passed"

      if gate_trivy "$passed" "false" >/tmp/g.log 2>&1; then
        ko "gate (bypass=false) should have exited non-zero"
      else
        ok "gate (bypass=false) blocks build [exit 1]"
      fi

      if gate_trivy "$passed" "true" >/tmp/g.log 2>&1; then
        ok "gate (bypass=true) allows build [exit 0]"
        grep -q '::warning::' /tmp/g.log && note "emitted ::warning:: marker"
      else
        ko "gate (bypass=true) should have exited 0"
      fi

      docker rmi -f "$img" >/dev/null 2>&1 || true
    else
      ko "docker build failed for Dockerfile.vuln"
    fi
  fi
fi

# ============================================================================
# Case 5: Trivy detects secrets baked into image (hard-fail, no severity gate)
# ============================================================================
echo
echo "=== Case 5: Trivy secret-in-image detection ==="

if ! require docker || ! require trivy; then
  skip "docker or trivy not installed"
else
  if ! docker info >/dev/null 2>&1; then
    skip "docker daemon not running"
  else
    img="kscp-neg-secret:test"
    note "building $img from Dockerfile.secret"
    if docker build --quiet -f "$BAD/Dockerfile.secret" -t "$img" "$BAD" >/dev/null 2>&1; then
      tr_out="$(mktemp)"
      trivy image --quiet --scanners secret --format json \
                  --output "$tr_out" "$img" >/dev/null 2>&1 || true
      sec=$(jq '[.Results[]?.Secrets[]?] | length' "$tr_out" 2>/dev/null || echo 0)
      note "Trivy found $sec secret(s) baked into image"

      if [[ "$sec" -gt 0 ]]; then
        ok "detection: trivy found baked-in secrets"
      else
        ko "detection: expected secrets in image, got 0"
      fi

      # render-trivy-summary always hard-fails on secrets > 0 regardless of severity
      passed=$(trivy_scan_passed "0" "0" "0" "0" "$sec" "CRITICAL,HIGH")
      note "scan_passed=$passed (secrets always hard-fail)"

      if [[ "$passed" == "false" ]]; then
        ok "render-trivy-summary correctly flags secrets > 0 as scan_passed=false"
      else
        ko "expected scan_passed=false when secrets>0"
      fi

      if gate_trivy "$passed" "false" >/tmp/g.log 2>&1; then
        ko "gate (bypass=false) should have exited non-zero"
      else
        ok "gate (bypass=false) blocks build on baked secrets [exit 1]"
      fi

      docker rmi -f "$img" >/dev/null 2>&1 || true
    else
      ko "docker build failed for Dockerfile.secret"
    fi
  fi
fi

# ============================================================================
# Summary
# ============================================================================
echo
echo "============================================================"
echo "  Negative-test summary"
echo "============================================================"
printf "  %s passed   %s failed   %s skipped\n" \
  "$(c_green "$pass")" "$(c_red "$fail")" "$(c_yel "$skipped")"
echo

exit $((fail > 0 ? 1 : 0))
