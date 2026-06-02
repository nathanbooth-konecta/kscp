# Migration: legacy `docker-build-push.yml` → KSCP `scp.yml`

This document maps every input on the legacy reusable docker-build-push
workflows (the per-team `docker-build-push.yml`, `docker-build-push-python.yml`,
`image-promote.yml` patterns used inside Konecta) to its KSCP equivalent, so
consumers can migrate one repo at a time.

## Field-by-field mapping

| Legacy input | KSCP input | Notes |
|--------------|------------|-------|
| `image_name` | `image_name` | Identical. |
| `ar_registry` | `ar_registry` | Identical. |
| `environment` | `environment` | Drives the WIF pool/service-account suffix. |
| `dockerfile_path` | `dockerfile_path` | Identical. |
| `build_context` | `build_context` | Identical. |
| `built_image` | `built_image` | When set, KSCP skips build + Dockerfile scans + gitleaks. |
| `version_file` | `version_file` | Identical. |
| `version_tag` | `version_tag` | Identical. |
| `auto_tag` | `auto_tag` | Identical. |
| `enable_trivy` | `enable_trivy` | Now gates ALL Trivy sub-scanners. |
| `trivy_severity` | `trivy_severity` | Identical. |
| `allow_scan_bypass` | `allow_scan_bypass` | Identical. |
| `docker_no_cache` | `docker_no_cache` | Identical. |
| `push` | `push` | Identical. |
| `enable_octopus` | `enable_octopus` | Default flipped to `false`. Set explicitly. |
| `octopus_space` | `octopus_space` | Identical. |
| `build_args` | `build_args` | `__SHORT_SHA__` placeholder still works. |
| _(not in legacy)_ | `scan_dockerfile` | New umbrella toggle for Checkov + Hadolint. |
| _(not in legacy)_ | `enable_checkov` | New OSS Dockerfile/IaC scanner. |
| _(not in legacy)_ | `enable_hadolint` | New Dockerfile linter. |
| _(not in legacy)_ | `allow_dockerfile_scan_bypass` | New. |
| _(not in legacy)_ | `enable_gitleaks` | New source-tree secrets scan. |
| _(not in legacy)_ | `gitleaks_config` | New. |
| _(not in legacy)_ | `gitleaks_scan_mode` | New (`full` \| `head`). |
| _(not in legacy)_ | `allow_secrets_bypass` | New. |
| _(not in legacy)_ | `enable_trivy_vuln` | New sub-toggle (default `true`). |
| _(not in legacy)_ | `enable_trivy_secrets` | New sub-toggle (default `true`). |
| _(not in legacy)_ | `enable_trivy_misconfig` | New sub-toggle (default `true`). |
| _(not in legacy)_ | `enable_trivy_license` | New sub-toggle (default `false`). |
| _(not in legacy)_ | `license_fail_on` | New. |
| _(not in legacy)_ | `sign_container` | New umbrella toggle for sign + attestations + audit chain. |
| _(not in legacy)_ | `enable_cosign` | New (kept independent for forward compatibility). |
| _(not in legacy)_ | `enable_vuln_attestation` | New (in-toto vuln attestation). |
| _(not in legacy)_ | `signing_environment` | New (GitHub Environment for approval gate). |
| _(not in legacy)_ | `enable_compliance_pr` | New (PR to audit-trail repo). |
| _(not in legacy)_ | `compliance_repo` | New. |
| _(not in legacy)_ | `dry_run` | New (PR-preview mode). |
| _(not in legacy)_ | `enable_slsa_provenance` | New (SLSA L3). |
| _(not in legacy)_ | `platforms` | New (default `linux/amd64`; opt-in multi-arch). |

## Migrating a service repo

1. **Update the caller workflow.** Replace the legacy
   `uses: <legacy-org>/.github-private/.github/workflows/docker-build-push.yml@<sha>`
   line with `uses: konecta/kscp/.github/workflows/scp.yml@v1`. Pass the same
   inputs; legacy inputs map 1:1 (see table above).
2. **Add the signing environment.** If you want signing on day one, create a
   GitHub Environment named `kscp-signed-image` (or override via
   `signing_environment`) with at least one required reviewer.
3. **Decide on new defaults.** New scanners (`scan_dockerfile`,
   `enable_gitleaks`) default to `true`. If your repo has known noisy
   Dockerfile lint or historical leaks you've already triaged, set
   `allow_dockerfile_scan_bypass: true` and `allow_secrets_bypass: true` for
   the first one or two builds while you sweep and remediate.
4. **Verify a dry-run.** Open a PR and confirm the `kscp / build-and-scan`
   check runs and reports counts in the step summary.
5. **Promote.** Merge to your default branch. The first non-PR run hits the
   environment-gated `sign-container` job; an approver clicks Approve, KSCP
   captures the approver record, and the image publishes.

## Coexistence guarantee

KSCP v1 does not modify or deprecate any existing per-team `.github-private`
or legacy docker-build-push workflow files. Migration is one repo at a time,
on each team's own schedule.
