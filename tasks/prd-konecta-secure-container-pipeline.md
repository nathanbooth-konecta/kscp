# PRD: Konecta Secure Container Pipeline (KSCP)

## 1. Introduction / Overview

The Konecta Secure Container Pipeline (KSCP) is a single reusable GitHub Actions workflow
(`scp.yml`) that standardises how every Konecta service builds, scans, signs and publishes
container images. It consolidates the existing fragmented patterns found in
`konecta-ix-applications/.github-private/.github/workflows/` (`docker-build-push.yml`,
`docker-build-push-python.yml`) into a single, opinionated, configurable pipeline that ships
from a new repository (`konecta-ix/kscp`).

KSCP replaces ad-hoc Dockerfile linting, optional security scanning and inconsistent signing
with a deterministic, conditional flow whose stages can each be toggled by callers. Every
external dependency (Checkov, Hadolint, Trivy, Cosign, Skopeo, Octopus, GCP Artifact
Registry) must be independently disable-able so the workflow can run in air-gapped or
restricted-tooling contexts. Every third-party action must be pinned to an immutable SHA
of the most recent stable release.

The pipeline implements the conditional flow shown in the v1.0.0 design:

```
setenv → [BUILT_IMAGE?]
            ├─ No  → ┬─ [SCAN_DOCKERFILE?]  → checkov + hadolint ─┐
            │       └─ [ENABLE_GITLEAKS?]   → gitleaks ───────────┤
            │                                                       ▼
            │                                                container-build
            │                                                       │
            └─ Yes ───────────────────────────────────────────────────►
                                                                     ▼
                                              security-scan (Trivy: vuln + SBOM
                                                          + secret + misconfig + license)
                                                                     │
                                                            [SIGN_CONTAINER?]
                                                             ├─ Yes → sign-container
                                                             │         (image sig + SBOM
                                                             │          attest + vuln attest)
                                                             │         ├─ approvals
                                                             │         ├─ signed_image
                                                             │         └─ record_of_approvals → publish
                                                             └─ No  → publish
                                                                     │
                                                             [SLSA + SIGN + PUSH?]
                                                                     ▼
                                                              slsa-provenance
```

A separate `ossf-scorecard` workflow (not part of `scp.yml`) scores the KSCP repo itself
on supply-chain hygiene; it does not gate consumer builds.

## 2. Goals

- Provide a single `workflow_call` workflow (`konecta-ix/kscp/.github/workflows/scp.yml@v1`)
  that every Konecta service can adopt without copy-pasting CI code.
- Implement all stages from the v1.0.0 design: `setenv`, `checkov`, `hadolint`,
  `gitleaks`, `container-build`, `security-scan` (vulnerability + SBOM + secret +
  misconfig + license), `sign-container` (image signature + SBOM attestation + vuln
  attestation), `approvals`, `signed_image`, `record_of_approvals`, `publish`,
  `slsa-provenance`.
- Make every external tool individually disable-able via a typed boolean input
  (default `true`) so callers can run KSCP without internet egress when required.
- Pin 100% of third-party actions (and the action versions referenced inside composite
  steps) to immutable SHAs of the latest stable release, with the human-readable tag
  preserved in a trailing comment for reviewability.
- Match the existing repo's authentication, tagging and bypass semantics
  (`WIF_POOL_ID`, lane-based SemVer tagging, `allow_scan_bypass`) so consumers can migrate
  without re-doing GitHub Environments / `vars.GCP_PROJECT_NUMBER` configuration.
- Capture a verifiable, append-only audit trail when an image is signed: who triggered the
  build, who approved the GitHub Environment gate, what digest was signed, when, and from
  which commit.
- Generate and attach SLSA Level 3 build provenance attestations on every published image,
  alongside the Cosign signature and CycloneDX SBOM, so KSCP-produced images satisfy the
  highest tier of supply-chain compliance frameworks on day one.
- Allow promotion of pre-built images (`BUILT_IMAGE` flag) so the same workflow can
  re-scan / re-sign an image that was built elsewhere without rebuilding.
- Provide a first-class `dry_run` mode for PR previews that runs every analysis stage but
  skips push and signing, so consumers don't have to remember which combination of toggles
  to set.
- Coexist with the existing `z_docker-build-push*.yml` workflows in `.github-private` so
  teams can adopt KSCP at their own pace; do not break any current consumer.

## 3. User Stories

### US-001: Repository bootstrap

**Description:** As a platform engineer, I want a new `konecta-ix/kscp` repo seeded with the
workflow skeleton, README, version file and CODEOWNERS so KSCP can be versioned and released
independently from any consumer.

**Acceptance Criteria:**
- [ ] `/Users/nathanbooth/code/kscp/.github/workflows/scp.yml` exists and is a valid
      `workflow_call` workflow (passes `actionlint` and `yamllint`).
- [ ] Repo contains `README.md`, `CODEOWNERS`, `version.txt` (`1.0.0`),
      `.github/workflows/release.yml` (creates a GitHub Release tag from `version.txt`).
- [ ] An example caller workflow exists in `examples/caller-minimal.yml` and references
      the new pipeline at `konecta-ix/kscp/.github/workflows/scp.yml@v1`.

### US-002: SHA-pinned action manifest

**Description:** As a security engineer, I want every third-party action used by KSCP pinned
to the SHA of its latest stable release so a malicious tag re-point cannot affect builds.

**Acceptance Criteria:**
- [ ] Every `uses:` line outside `actions/*` and `konecta-ix/*` references an explicit
      40-character commit SHA, with the human-readable version in a `#` trailing comment.
- [ ] A `docs/pinned-actions.md` table lists every pinned action, its current SHA, the
      release tag it maps to, the release date and the source repo URL.
- [ ] A GitHub Action (`.github/workflows/pin-audit.yml`) runs `pin-github-action --dry-run`
      on PRs and fails if any `uses:` reference is unpinned.

### US-003: `setenv` stage — image metadata

**Description:** As a service owner, I want KSCP to compute the image name and tag using the
existing lane-based SemVer scheme (`dev`/`rc`/`release`/`branch`) so KSCP-built images are
indistinguishable from images built by the legacy workflow.

**Acceptance Criteria:**
- [ ] `setenv` job emits outputs: `image_repo`, `image_tag`, `image_uri`, `short_sha`,
      `tags` (comma-separated), `lane`, `base_version`, `build_timestamp`.
- [ ] Tag derivation matches the algorithm in
      `docker-build-push.yml` lines 259–343 (auto_tag → ref_type=tag → main → develop →
      branch) byte-for-byte for the same inputs.
- [ ] When `built_image` input is non-empty, `setenv` uses the supplied image URI for
      `image_uri` and skips tag derivation; `lane` is set to `imported`.
- [ ] Workflow logs include a `::notice::` line summarising the chosen lane and primary tag.

### US-004: `scan-dockerfile` stage — Checkov + Hadolint (toggle)

**Description:** As a service owner, I want Dockerfile security and style scanning to run
before the image is built, but I want the option to skip scanning entirely when working in
an air-gapped fork.

**Acceptance Criteria:**
- [ ] `scan_dockerfile` input (boolean, default `true`) controls whether the `checkov` and
      `hadolint` jobs run.
- [ ] `enable_checkov` and `enable_hadolint` inputs (boolean, default `true`) allow
      disabling each scanner independently when `scan_dockerfile=true`.
- [ ] Checkov runs against `inputs.dockerfile_path` using the OSS
      `bridgecrewio/checkov-action@<SHA>` with `framework: dockerfile`. **No Prisma Cloud
      integration** — findings stay in GitHub code scanning only (see §9 decision 7).
- [ ] Hadolint is the chosen Dockerfile linter (see §9 decision 6); runs against the same
      Dockerfile using `hadolint/hadolint-action@<SHA>` and exports SARIF.
- [ ] Both tools' SARIF output uploads to GitHub code scanning via
      `github/codeql-action/upload-sarif@<SHA>` (continue-on-error).
- [ ] When `scan_dockerfile=false` the job is skipped (`if:` expression) and the workflow
      proceeds directly to `container-build`.
- [ ] Failing Checkov/Hadolint findings block `container-build` unless
      `allow_dockerfile_scan_bypass=true` (default `false`).

### US-005: `container-build` stage — BuildKit (toggle via `BUILT_IMAGE`)

**Description:** As a service owner, I want KSCP to build the image with BuildKit by
default, but skip the build and use a pre-built image when `built_image` is supplied.

**Acceptance Criteria:**
- [ ] `built_image` input (string, default empty). When non-empty, `container-build` is
      skipped and `security-scan` operates on the supplied image URI.
- [ ] When building, KSCP uses `docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8 # v6`
      with `push: false`, `load: true`, GHA cache (`cache-from: type=gha`,
      `cache-to: type=gha,mode=max`).
- [ ] Multi-arch build is opt-in via `platforms` input (default `linux/amd64`); when set
      to a comma list, KSCP uses `docker/setup-qemu-action@<SHA>` and BuildKit emulation.
- [ ] OCI labels (`org.opencontainers.image.*`) match those produced by
      `docker-build-push.yml` lines 368–376, plus a new
      `konecta.ix.build.kscp-version=<value of version.txt>` label.
- [ ] `docker_no_cache` input (boolean, default `false`) toggles `--no-cache`.
- [ ] Build args support `__SHORT_SHA__` placeholder substitution exactly as the legacy
      workflow does.

### US-006: `security-scan` stage — Trivy multi-scanner with SBOM

**Description:** As a security engineer, I want every image scanned by Trivy for
vulnerabilities, in-image secrets, runtime misconfigurations and restricted licences, and
an SBOM generated alongside, so we have a single comprehensive supply-chain record per
image.

**Acceptance Criteria:**
- [ ] `enable_trivy` input (boolean, default `true`) toggles all Trivy steps.
- [ ] Trivy scans the loaded local image (or `built_image` URI) using
      `aquasecurity/trivy-action@57a97c7e7821a5776cebc9bb87c984fa69cba8f1 # 0.35.0`
      and produces SARIF, JSON and CycloneDX SBOM outputs.
- [ ] Trivy is invoked with `--scanners vuln,secret,misconfig,license` when the
      corresponding sub-toggles are enabled:
      - `enable_trivy_vuln` (boolean, default `true`) — CVE detection (current behaviour).
      - `enable_trivy_secrets` (boolean, default `true`) — secrets baked into image layers.
      - `enable_trivy_misconfig` (boolean, default `true`) — Dockerfile/K8s/IaC misconfig
        rules evaluated against files found inside the image.
      - `enable_trivy_license` (boolean, default `false`) — package licence detection;
        opt-in so it doesn't surprise existing consumers with new findings.
- [ ] Each enabled sub-scanner emits its own counts into job outputs:
      `trivy_secret_count`, `trivy_misconfig_count`,
      `trivy_license_restricted_count` (in addition to the existing
      CRITICAL/HIGH/MEDIUM/LOW vuln counts).
- [ ] SBOM is uploaded as an artifact (`sbom-<image_name>-<short_sha>.cdx.json`,
      30-day retention) and attached to the image via `cosign attach sbom` when
      `sign_container=true`.
- [ ] Per-severity vulnerability counts and per-sub-scanner counts are rendered as
      collapsible markdown tables in `$GITHUB_STEP_SUMMARY`, matching the format of
      `docker-build-push.yml` lines 776–842.
- [ ] CRITICAL findings set `scan_passed=false`; HIGH-only findings do not (matches
      existing behaviour). `trivy_severity` input lets callers tighten thresholds.
- [ ] Any secret detected by `enable_trivy_secrets` sets `scan_passed=false` regardless
      of the vulnerability threshold (secrets in images are always a hard fail).
- [ ] `enable_trivy_license` findings produce warnings only by default; a separate
      `license_fail_on` input (string, default `""`) lets callers list licences
      (e.g. `AGPL-3.0,GPL-3.0`) that should fail the scan.
- [ ] `allow_scan_bypass` input (boolean, default `false`) allows the pipeline to proceed
      past a failed scan (vulns, secrets, or licences) with a `::warning::` annotation,
      mirroring legacy behaviour.

### US-007: `sign-container` stage — Cosign keyless (toggle)

**Description:** As a security engineer, I want every approved image signed with Cosign
keyless before it is published, and I want signing to be cleanly skip-able for non-prod
builds.

**Acceptance Criteria:**
- [ ] `sign_container` input (boolean, default `true`) toggles the entire
      `sign-container` → `approvals` → `signed_image` → `record_of_approvals` chain.
- [ ] When `sign_container=false`, the pipeline jumps directly from `security-scan` to
      `publish`.
- [ ] Cosign is installed via
      `sigstore/cosign-installer@398d4b0eeef1380460a10c8013a76f728fb906ac # v3`.
- [ ] Signing uses keyless mode (`cosign sign --yes <repo>@<digest>`) backed by GitHub
      OIDC, exactly as the legacy workflow does.
- [ ] The signed digest is captured as a job output `signed_digest`.
- [ ] Cosign signature is verified before publish using `cosign verify --certificate-identity-regexp`
      against the expected workflow identity; verification failure blocks publish.
- [ ] When `enable_vuln_attestation` input (boolean, default `true`) is set AND
      `enable_trivy=true`, KSCP attaches a signed in-toto vulnerability attestation
      (predicate type `https://cosign.sigstore.dev/attestation/vuln/v1`) to the image
      digest via `cosign attest --type vuln --predicate trivy-results.json`. This lets
      downstream admission controllers reject images whose attached scan exceeds policy
      thresholds without re-running Trivy.
- [ ] Attestation attachment uses the same keyless OIDC identity as the image signature
      and is verified via `cosign verify-attestation` before `publish` completes.

### US-008: `approvals` stage — capture approver metadata

**Description:** As a compliance officer, I want a tamper-evident record of who approved a
signing event so we can satisfy SOC 2 / ISO 27001 evidence requests.

**Acceptance Criteria:**
- [ ] The `sign-container` job targets a GitHub Environment (default name
      `kscp-signed-image`, overridable via `signing_environment` input) so required
      reviewers gate the step.
- [ ] `approvals` job runs after `sign-container` and writes a JSON record containing:
      `triggered_by` (github.actor), `triggered_by_id`, `approvers[]` (resolved from the
      Environment deployment reviewers via the GitHub REST API), `approval_timestamp`,
      `commit_sha`, `image_uri`, `image_digest`, `workflow_run_url`.
- [ ] The JSON record is uploaded as a workflow artifact named
      `approvals-<image_name>-<short_sha>.json` with 365-day retention.
- [ ] When KSCP cannot resolve approvers from the API (e.g. environment protection not
      configured), the job fails with a clear `::error::` instructing the consumer how to
      configure the environment.

### US-009: `signed_image` stage — digest record

**Description:** As an SRE, I want a flat `signed_images.txt` artifact listing every
signed image digest so we can diff it against what is running in production.

**Acceptance Criteria:**
- [ ] `signed_image` job appends one line in the form
      `<image_repo>@<digest>\t<image_tag>\t<commit_sha>\t<iso_timestamp>` to
      `signed_images.txt` (created if absent).
- [ ] The file is uploaded as `signed-images-<image_name>-<short_sha>.txt`
      (90-day retention).
- [ ] Job outputs `signed_image_digest` for downstream consumption.

### US-010: `record_of_approvals` stage — compliance artifact

**Description:** As a compliance officer, I want a permanent, human-readable Markdown
record of every signing event so auditors can review approvals without API access.

**Acceptance Criteria:**
- [ ] `record_of_approvals` job renders a Markdown table combining the `approvals` JSON,
      the SBOM filename, the Trivy CRITICAL/HIGH counts and the Cosign verification result.
- [ ] The Markdown record is uploaded as an artifact
      `record-of-approvals-<image_name>-<short_sha>.md` (365-day retention) and appended
      to `$GITHUB_STEP_SUMMARY`.
- [ ] When `compliance_repo` input is set (e.g. `konecta-ix/kscp-audit-trail`), the job
      opens a PR to that repo committing the Markdown record under
      `records/<year>/<month>/<image_name>-<short_sha>.md`. PR creation is feature-gated
      by `enable_compliance_pr` (default `false`).

### US-011: `publish` stage — Skopeo to GCP Artifact Registry

**Description:** As a service owner, I want the signed image published to GCP Artifact
Registry using Skopeo so we get atomic multi-tag pushes without re-pulling the image.

**Acceptance Criteria:**
- [ ] `publish` job uses Skopeo (installed from the official static binary release, SHA
      pinned) to copy the image from the local Docker daemon to all tags in
      `setenv.outputs.tags`.
- [ ] `push` input (boolean, default `true`) and the existing `push-gate` logic from
      `docker-build-push.yml` lines 598–623 are preserved verbatim (push-not-requested /
      scan-passed / bypass branches).
- [ ] GCP auth uses the same `Configure GCP Auth` step as the legacy workflow
      (`vars.GCP_PROJECT_NUMBER`, `vars.SERVICE_NAME`, `vars.WIF_POOL_ID`,
      `vars.WIF_PROVIDER_ID`, `vars.GCP_GKE_PROJECT_ID`) so no consumer needs to
      re-configure variables.
- [ ] After publish, Cosign re-verifies the pushed digest matches `signed_digest`.

### US-012: Optional Octopus build info passthrough

**Description:** As a release manager, I want KSCP to optionally push build information
to Octopus Deploy the same way the legacy workflow does, so deployment dashboards keep
working.

**Acceptance Criteria:**
- [ ] `enable_octopus` input (boolean, default `false`) and `octopus_space` input
      (string, default `Default`) preserved from legacy workflow.
- [ ] `OCTOPUS_URL` and `OCTOPUS_API_KEY` declared as optional secrets on `workflow_call`.
- [ ] The Octopus steps run only when `enable_octopus=true` AND publish succeeded; failures
      are non-blocking (`continue-on-error: true`, `timeout-minutes: 2`).

### US-013: Disable-any-external-tool matrix

**Description:** As a platform engineer evaluating KSCP for an isolated build environment,
I want to verify every external integration can be disabled and the pipeline still
produces a usable artifact.

**Acceptance Criteria:**
- [ ] When `scan_dockerfile=false`, `enable_gitleaks=false`, `enable_trivy=false`,
      `enable_cosign=false`, `sign_container=false`, `enable_octopus=false`,
      `enable_checkov=false`, `enable_hadolint=false`, `enable_compliance_pr=false`,
      `enable_slsa_provenance=false`, the pipeline builds and pushes the image with no
      calls to Sigstore, Aqua, Bridgecrew, Hadolint, Gitleaks, SLSA generator or
      Octopus.
- [ ] When `push=false` in addition to the above, the workflow makes no network calls to
      GCP Artifact Registry; the image stays as an uploaded artifact only.
- [ ] An integration test (`.github/workflows/test-air-gapped.yml`) runs KSCP against a
      sample Dockerfile with all toggles `false` and asserts success.

### US-014: Caller examples for common stacks

**Description:** As a service owner adopting KSCP, I want copy-pasteable example caller
workflows for the stacks Konecta uses (Python, Node, generic Docker, pre-built image
promote) so onboarding takes minutes, not hours.

**Acceptance Criteria:**
- [ ] `examples/caller-minimal.yml` — smallest possible caller, build + push to dev.
- [ ] `examples/caller-python.yml` — runs Python CI (lint/test) before invoking KSCP,
      mirroring the structure of `docker-build-push-python.yml`.
- [ ] `examples/caller-promote.yml` — uses `built_image` to scan/sign/publish an image
      that was built upstream.
- [ ] `examples/caller-air-gapped.yml` — all external tools disabled.
- [ ] Each example file's frontmatter cites the kscp version it was validated against.

### US-015: Coexistence with legacy workflows

**Description:** As an existing consumer of `z_docker-build-push.yml`, I want KSCP to ship
without breaking my pipelines, and I want a documented migration path I can adopt when
ready.

**Acceptance Criteria:**
- [ ] No edits are made to `konecta-ix-applications/.github-private/.github/workflows/`
      during the initial KSCP release.
- [ ] `docs/migration-from-legacy.md` documents the field-by-field mapping from
      `z_docker-build-push.yml` inputs to `scp.yml` inputs, including renamed flags
      (`enable_trivy` → `enable_trivy` unchanged, new `scan_dockerfile`, new
      `sign_container`, new `built_image`).
- [ ] A deprecation notice is added to the top of `z_docker-build-push.yml` (separate
      follow-up PR, not part of this PRD's scope) pointing to KSCP.

### US-016: SLSA Level 3 build provenance

**Description:** As a security engineer, I want every published image to carry a SLSA Level 3
build provenance attestation so downstream verifiers can cryptographically prove the image
was built from a specific commit by a specific workflow on GitHub-hosted infrastructure.

**Acceptance Criteria:**
- [ ] New `slsa-provenance` job runs after `publish` and uses
      `slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@<SHA>`
      (the reusable SLSA L3 container generator).
- [ ] The generator emits a signed in-toto provenance attestation attached to the image
      digest in the registry (visible via `cosign download attestation`).
- [ ] `enable_slsa_provenance` input (boolean, default `true`) gates the job so air-gapped
      consumers can disable it.
- [ ] The job is skipped automatically when `sign_container=false` OR `push=false` (no
      sense provenance-attesting an unsigned, unpublished image).
- [ ] `slsa_provenance_digest` is added to the workflow's outputs so callers can verify.
- [ ] Verification example added to `docs/verify-provenance.md` showing how to use
      `slsa-verifier verify-image` against a published KSCP image.
- [ ] The `record_of_approvals` Markdown record (US-010) includes a row for the SLSA
      attestation status (present / verified / not generated).

### US-017: `secrets-scan` stage — Gitleaks on the source checkout

**Description:** As a security engineer, I want every build to scan the source repository
for committed secrets (API keys, tokens, certs, hard-coded credentials in Dockerfiles or
build scripts) before any image is built, so leaked credentials are caught before they end
up baked into a published image or pushed to a public registry.

**Acceptance Criteria:**
- [ ] New `gitleaks` job runs in parallel with `checkov` and `hadolint` (same
      `needs: setenv` edge) when `built_image` is empty.
- [ ] Gitleaks runs via `gitleaks/gitleaks-action@<SHA>` against the checked-out workspace
      (default: full git history; configurable to `HEAD` only via `gitleaks_scan_mode`).
- [ ] `enable_gitleaks` input (boolean, default `true`) toggles the job; air-gapped
      consumers can disable it without other side effects.
- [ ] `gitleaks_config` input (string, default `""`) optionally points at a repo-local
      Gitleaks config (`.gitleaks.toml`) for custom rules / allowlists. When unset,
      Gitleaks uses its built-in default ruleset.
- [ ] Gitleaks SARIF output uploads to GitHub code scanning via
      `github/codeql-action/upload-sarif@<SHA>` under category `gitleaks-<image_name>`.
- [ ] Any finding fails the job and blocks `container-build` unless
      `allow_secrets_bypass` input (boolean, default `false`) is set — in which case the
      pipeline proceeds with a `::warning::` annotation listing how many secrets were
      found (not the secret values).
- [ ] The `gitleaks` job is automatically skipped when `built_image` is non-empty
      (there's no source code to scan in that flow).
- [ ] Finding counts are surfaced as job output `gitleaks_findings_count` and rendered
      in `$GITHUB_STEP_SUMMARY` (without printing the secret values).

### US-018: OpenSSF Scorecard self-assessment

**Description:** As the KSCP maintainer, I want the KSCP repo itself to publish an
OpenSSF Scorecard so adopters can see at a glance that this pipeline follows the
supply-chain hygiene practices it enforces on others (pinned deps, signed releases,
branch protection, etc.).

**Acceptance Criteria:**
- [ ] New workflow `.github/workflows/scorecard.yml` in the KSCP repo (not part of
      `scp.yml`) runs `ossf/scorecard-action@<SHA>` on push to default branch and on a
      weekly cron.
- [ ] Workflow has `permissions: security-events: write, id-token: write,
      contents: read` to publish results to GitHub code scanning.
- [ ] Workflow uploads SARIF results to GitHub code scanning and publishes a public
      `https://api.securityscorecards.dev/projects/github.com/konecta-ix/kscp` badge.
- [ ] `README.md` includes the Scorecard badge in its header.
- [ ] The scorecard workflow targets a minimum score of 8.0 (out of 10); a drop below
      the threshold opens a tracking issue automatically via a follow-up step.
- [ ] This is a self-assessment only — KSCP does NOT run Scorecard against consumer
      repos; it has no `scp.yml` input toggles.

## 4. Functional Requirements

- FR-1: KSCP MUST be implemented as a single `workflow_call` workflow at
  `konecta-ix/kscp/.github/workflows/scp.yml`.
- FR-2: KSCP MUST expose the following typed inputs, with defaults shown:
  - `image_name` (string, required)
  - `ar_registry` (string, required)
  - `environment` (string, required)
  - `dockerfile_path` (string, default `./Dockerfile`)
  - `build_context` (string, default `.`)
  - `built_image` (string, default `""`)
  - `scan_dockerfile` (boolean, default `true`)
  - `enable_checkov` (boolean, default `true`)
  - `enable_hadolint` (boolean, default `true`)
  - `allow_dockerfile_scan_bypass` (boolean, default `false`)
  - `enable_gitleaks` (boolean, default `true`)
  - `gitleaks_config` (string, default `""`)
  - `gitleaks_scan_mode` (string, default `full`; values: `full` | `head`)
  - `allow_secrets_bypass` (boolean, default `false`)
  - `enable_trivy` (boolean, default `true`)
  - `enable_trivy_vuln` (boolean, default `true`)
  - `enable_trivy_secrets` (boolean, default `true`)
  - `enable_trivy_misconfig` (boolean, default `true`)
  - `enable_trivy_license` (boolean, default `false`)
  - `license_fail_on` (string, default `""`)
  - `trivy_severity` (string, default `CRITICAL,HIGH`)
  - `sign_container` (boolean, default `true`)
  - `enable_cosign` (boolean, default `true`)
  - `enable_vuln_attestation` (boolean, default `true`)
  - `signing_environment` (string, default `kscp-signed-image`)
  - `enable_compliance_pr` (boolean, default `false`)
  - `compliance_repo` (string, default `""`)
  - `push` (boolean, default `true`)
  - `dry_run` (boolean, default `false`) — see FR-19
  - `enable_slsa_provenance` (boolean, default `true`)
  - `allow_scan_bypass` (boolean, default `false`)
  - `docker_no_cache` (boolean, default `false`)
  - `platforms` (string, default `linux/amd64`)
  - `version_file` (string, default `version.txt`)
  - `version_tag` (string, default `""`)
  - `auto_tag` (boolean, default `false`)
  - `enable_octopus` (boolean, default `false`)
  - `octopus_space` (string, default `Default`)
  - `build_args` (string, default `""`)
- FR-3: KSCP MUST expose the following outputs:
  `image_uri`, `image_tag`, `image_repo`, `signed_digest`, `scan_passed`,
  `trivy_critical_count`, `trivy_high_count`, `trivy_medium_count`,
  `trivy_secret_count`, `trivy_misconfig_count`, `trivy_license_restricted_count`,
  `gitleaks_findings_count`, `vuln_attestation_digest`,
  `sbom_artifact_name`, `approvals_artifact_name`, `slsa_provenance_digest`,
  `version_created`.
- FR-4: Every `uses:` referencing an action outside the `actions/` or `konecta-ix/`
  namespaces MUST be pinned to a 40-character commit SHA with the version tag in a
  trailing `# vX` comment. CI MUST reject PRs that fail this check.
- FR-5: When `built_image` is non-empty, KSCP MUST skip the `container-build` job and the
  `scan-dockerfile` job, and operate on the supplied image URI for `security-scan`
  onwards.
- FR-6: When `scan_dockerfile=false`, KSCP MUST skip the Checkov and Hadolint jobs and
  proceed directly to `container-build` (or `security-scan` if `built_image` is set).
- FR-7: When `sign_container=false`, KSCP MUST skip `sign-container`, `approvals`,
  `signed_image` and `record_of_approvals`, and proceed directly from `security-scan` to
  `publish`.
- FR-8: When `sign_container=true`, the `sign-container` job MUST target the GitHub
  Environment named by `signing_environment` so required reviewers gate the step.
- FR-9: The `approvals` job MUST resolve approver identities via the GitHub REST API
  (`GET /repos/{owner}/{repo}/actions/runs/{run_id}/approvals`) and fail the workflow if
  the API returns zero approvers when one or more reviewers were required.
- FR-10: KSCP MUST generate a CycloneDX SBOM via Trivy and upload it as a workflow
  artifact whenever `enable_trivy=true`.
- FR-11: When both `enable_trivy=true` and `sign_container=true`, KSCP MUST attach the
  SBOM to the image via `cosign attach sbom`.
- FR-12: KSCP MUST use Skopeo (not `docker push`) for the `publish` job to atomically
  copy the image to every tag in `setenv.outputs.tags`.
- FR-13: KSCP MUST re-verify the published image's Cosign signature after `publish` when
  `sign_container=true`, failing the workflow on mismatch.
- FR-14: KSCP MUST render a `$GITHUB_STEP_SUMMARY` for each job with at minimum:
  the job's status, key counts (Trivy severities, approvers count) and links to uploaded
  artifacts.
- FR-15: The Octopus integration MUST remain identical to the legacy workflow (lines
  1083–1114 of `docker-build-push.yml`): optional, opt-in via `enable_octopus`,
  non-blocking on failure.
- FR-16: KSCP MUST authenticate to GCP using the existing Workload Identity Federation
  pattern (`vars.GCP_PROJECT_NUMBER`, `vars.SERVICE_NAME`, `vars.WIF_POOL_ID`,
  `vars.WIF_PROVIDER_ID`, `vars.GCP_GKE_PROJECT_ID`) so no consumer reconfiguration is
  required.
- FR-17: KSCP MUST be released as immutable Git tags (`v1.0.0`, `v1.0.1`, …) with a
  floating major-version tag (`v1`) that consumers can pin to.
- FR-18: When all `enable_*` and `scan_*` and `sign_*` and `push` toggles are `false`,
  KSCP MUST complete successfully producing only the built image as a workflow artifact,
  with no outbound network calls to third-party services.
- FR-19: When `dry_run=true`, KSCP MUST implicitly set `push=false` and
  `sign_container=false` regardless of their explicit values (with a `::notice::` log
  explaining the override), so consumers get a single switch for PR-preview runs. All
  other analysis stages (Dockerfile scan, Trivy, SBOM) MUST still run.
- FR-20: The `slsa-provenance` job MUST use the upstream reusable workflow
  `slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml`
  pinned to a release SHA, and MUST run only when `enable_slsa_provenance=true` AND
  `sign_container=true` AND `push=true`. When any of those is false, the job is skipped
  and `slsa_provenance_digest` output is empty.
- FR-21: When `enable_compliance_pr=true`, KSCP MUST authenticate to `compliance_repo`
  using the existing workload-repo GitHub App (`WORKLOAD_REPO_APP_ID` /
  `WORKLOAD_REPO_APP_PRIVATE_KEY` secrets, reused verbatim from `image-promote.yml`).
  The audit-trail repository MUST be added to that app's installation as a prerequisite,
  not provisioned by KSCP.
- FR-22: When `enable_gitleaks=true` AND `built_image=""`, the `gitleaks` job MUST run
  in parallel with `checkov` and `hadolint` (parallel `needs: setenv` edges). A finding
  MUST block `container-build` unless `allow_secrets_bypass=true`. The job MUST NOT
  print secret values to logs or summaries.
- FR-23: When `enable_vuln_attestation=true` AND `sign_container=true` AND
  `enable_trivy=true`, the `sign-container` job MUST attach a signed in-toto
  vulnerability attestation (predicate type
  `https://cosign.sigstore.dev/attestation/vuln/v1`) to the image digest using
  `cosign attest --type vuln --predicate trivy-results.json --yes`. The attestation MUST
  be re-verified via `cosign verify-attestation` after `publish`; failure to verify
  blocks the workflow.
- FR-24: The KSCP repository MUST publish an OpenSSF Scorecard via a standalone workflow
  (`.github/workflows/scorecard.yml`); this workflow is NOT exposed as a `workflow_call`
  surface and has no inputs callable from consumer repos. A README badge MUST link to
  the public Scorecard project page.

## 5. Non-Goals (Out of Scope)

- Artifactory as a publish target. (Future v5; current scope is GCP Artifact Registry
  only, matching the existing workflows.)
- Replacing or editing the existing `z_docker-build-push*.yml` workflows in
  `.github-private`. Migration is voluntary and handled in a separate follow-up.
- A Python CI sub-pipeline equivalent to `docker-build-push-python.yml`. KSCP is
  container-only; language-specific CI stays in caller workflows.
- An equivalent for the `image-promote.yml` cross-repo PR flow. Promotion stays in its
  own workflow; KSCP's `built_image` input is the integration seam.
- A Helm-lint / Helm-values-check equivalent. KSCP's scope is the container image only.
- Self-hosted runner provisioning. KSCP runs on the runner labels chosen by the caller
  (default `ubuntu-latest`); existing `static-ip-runner` users can override per job.
- Custom signing CAs (BYO Fulcio). KSCP uses Sigstore's public Fulcio + Rekor for v1.
- Long-term audit retention beyond 365 days via cloud storage (GCS, S3, etc.). The
  optional `compliance_repo` PR is the long-term retention mechanism — git history is the
  archive (see §9 decision 2).
- Centralised IaC scanning via Prisma Cloud / Bridgecrew SaaS. KSCP uses the OSS Checkov
  action only; findings stay in GitHub code scanning (see §9 decision 7).
- A web UI or dashboard for viewing approvals; the `record_of_approvals` Markdown
  artifact and the optional `compliance_repo` PR are the only surfaces.

## 6. Design Considerations

- **Conditional flow via `needs:` + `if:`**: model the screenshot's diamond as job-level
  `needs:` edges with `if:` guards on the conditional inputs, not as composite steps.
  This keeps each stage independently re-runnable in the GitHub Actions UI.
- **Job naming**: use the names from the v1.0.0 diagram (`setenv`, `checkov`, `hadolint`,
  `container-build`, `security-scan`, `sign-container`, `approvals`, `signed_image`,
  `record_of_approvals`, `publish`) so the GitHub Actions UI matches the design doc.
- **Image transfer**: continue the legacy pattern of `docker save` → `actions/upload-artifact`
  → `actions/download-artifact` → `docker load` between `container-build` and `publish`.
  Skopeo then copies from the loaded daemon image to AR. Avoid re-building.
- **SHA-pin manifest**: track pinned actions in `docs/pinned-actions.md` rather than
  comments, so a single PR can refresh all pins with one diff. Comments in the workflow
  point to the manifest.
- **Action authors**: prefer first-party actions (`docker/*`, `actions/*`, `sigstore/*`,
  `aquasecurity/*`, `hadolint/*`, `bridgecrewio/*`) over wrapper actions to minimise the
  supply chain surface.
- **`scp.yml` length**: the workflow will exceed 1000 lines; group jobs with banner
  comments matching the existing `z_docker-build-push.yml` style for navigability.

## 7. Technical Considerations

- **Action version freshness at release**: pin to whichever stable release tag is current
  on the KSCP release date. Today's known-good SHAs from the legacy workflow are valid
  starting points:
  - `actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd # v5`
  - `actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4 # v5`
  - `actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0 # v5`
  - `google-github-actions/auth@c200f3691d83b41bf9bbd8638997a462592937ed # v2`
  - `google-github-actions/setup-gcloud@e427ad8a34f8676edf47cf7d7925499adf3eb74f # v2`
  - `docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f # v3`
  - `docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8 # v6`
  - `aquasecurity/trivy-action@57a97c7e7821a5776cebc9bb87c984fa69cba8f1 # 0.35.0`
  - `sigstore/cosign-installer@398d4b0eeef1380460a10c8013a76f728fb906ac # v3`
  - `github/codeql-action/upload-sarif@38697555549f1db7851b81482ff19f1fa5c4fedc # v4`
  - `OctopusDeploy/login@e485a40e4b47a154bdf59cc79e57894b0769a760 # v1`
  - `OctopusDeploy/push-build-information-action@251acb0783c656ebf30d5bc69474a037116cce09 # v3`
  - New (verify current SHA at implementation time): `bridgecrewio/checkov-action`,
    `hadolint/hadolint-action`, `docker/setup-qemu-action`,
    `gitleaks/gitleaks-action`, `ossf/scorecard-action`,
    `slsa-framework/slsa-github-generator` (use the
    `generator_container_slsa3.yml` reusable workflow at its latest release SHA).
  - Skopeo: install from official GitHub release tarball, pin to release SHA in a
    shell step (Skopeo has no maintained GitHub Action).
- **GCP Artifact Registry permissions**: existing WIF service accounts already have
  `artifactregistry.writer`; no IAM changes required.
- **`signing_environment`**: consumers must create a GitHub Environment with required
  reviewers before they can set `sign_container=true`. Document this prerequisite.
- **Run time**: the legacy workflow runs in ~6–10 min. Adding Checkov+Hadolint+SBOM
  generation adds ~2 min; the approvals gate adds wall-clock time but no compute.
- **Concurrency**: declare a `concurrency:` group on `image_name + ref` so two pushes to
  the same branch serialise rather than racing on tags.
- **Approver API permissions**: `GET .../approvals` requires the `repo` scope on the
  GitHub Actions token. KSCP must declare `permissions: deployments: read,
  actions: read` at the job level.
- **Cosign verification identity**: `cosign verify` must use
  `--certificate-identity-regexp "https://github.com/konecta-ix/kscp/.github/workflows/scp.yml@.*"`
  and `--certificate-oidc-issuer https://token.actions.githubusercontent.com`.
- **SLSA generator constraints**: the upstream
  `generator_container_slsa3.yml` reusable workflow runs in its own job and produces its
  own attestation. Per its docs, it requires `permissions: id-token: write,
  contents: read, packages: write, actions: read` and that the calling workflow be
  triggered by a tag or branch push (not pull_request). The KSCP `slsa-provenance` job
  must propagate those permissions and check the trigger context before invoking.
- **GitHub App reuse for `compliance_repo`** (§9 decision 1): the existing
  `WORKLOAD_REPO_APP_ID` / `WORKLOAD_REPO_APP_PRIVATE_KEY` secrets (already used by
  `image-promote.yml`) cover the audit-trail repo. The platform team must add the
  audit-trail repository to that app's installation; no new app is provisioned.
- **Gitleaks performance**: full-history scans on large monorepos can take 30–90s.
  `gitleaks_scan_mode=head` short-circuits to HEAD-only for fast PR feedback, while the
  default `full` mode is used on main-branch builds to catch historical leaks introduced
  by force-pushes. Tune via the input rather than the action's flags so the contract
  stays explicit.
- **Gitleaks log safety**: the `gitleaks-action` already redacts secret values from
  logs and SARIF, but the KSCP `$GITHUB_STEP_SUMMARY` step must format only counts and
  rule IDs — never include the matched substring — to avoid re-leaking what was found.
- **Vulnerability attestation predicate**: use the cosign vuln predicate spec
  (`https://cosign.sigstore.dev/attestation/vuln/v1`) wrapping Trivy's JSON output.
  Downstream admission controllers (Kyverno, Gatekeeper) can then evaluate policies
  against the attached attestation without re-running the scan.
- **OpenSSF Scorecard self-assessment**: Scorecard is scored on the KSCP repo's own
  practices (pinned actions, branch protection, signed releases, CodeQL enabled,
  dependency-update tooling, etc.). Hitting the 8.0 target requires KSCP itself to
  practice what it preaches; this also serves as a regression guard against
  inadvertently weakening the repo's own posture.

## 8. Success Metrics

- **Adoption**: 5 services adopt KSCP within 30 days of the v1.0.0 tag.
- **Coverage**: 100% of images built via KSCP have an attached SBOM and a Cosign
  signature (verified by a daily audit job).
- **Pin discipline**: 0 unpinned third-party actions in `scp.yml` (enforced by CI).
- **Air-gap parity**: the all-toggles-off integration test passes on every commit.
- **No regressions**: existing `z_docker-build-push.yml` consumers are unchanged; no
  open issues about broken legacy pipelines attributable to the KSCP release.
- **Audit completeness**: every `sign_container=true` run produces a downloadable
  `record-of-approvals-*.md` artifact (verified by a daily audit job that samples 10%
  of signed runs).
- **SLSA L3 attestation rate**: 100% of images published with `sign_container=true` and
  `push=true` carry a SLSA L3 provenance attestation verifiable by `slsa-verifier`
  (verified by the same daily audit job).
- **Secret-leak prevention**: zero published images contain a secret that gitleaks would
  detect on the source repo OR that Trivy's secret scanner would detect inside the image
  (sampled monthly).
- **KSCP Scorecard score**: KSCP repo maintains an OpenSSF Scorecard ≥ 8.0; a drop below
  that threshold opens a tracking issue automatically.

## 9. Resolved Decisions

Resolved 2026-05-28 by Nathan Booth via the open-questions review page
(`tasks/prd-open-questions-review.html`). Each decision below feeds back into a specific
FR or user story noted in brackets.

### Decision 1 — `compliance_repo` authentication

**Question:** Should `compliance_repo` use a GitHub App token or a PAT?

**Decision:** Reuse the existing workload-repo GitHub App.

**Rationale:** Add the audit-trail repo to the existing app's installation. Zero new
infra; one app already trusted across the org. Same secrets (`WORKLOAD_REPO_APP_ID`,
`WORKLOAD_REPO_APP_PRIVATE_KEY`) that power `image-promote.yml`.

**Implementation impact:** FR-21; §7 "GitHub App reuse" bullet.

### Decision 2 — Long-term audit retention

**Question:** Should `record_of_approvals` Markdown also be uploaded to GCS for retention
beyond 365 days?

**Decision:** No — 365 days is sufficient. Rely on the optional `compliance_repo` PR
(git history) for long-term retention.

**Rationale:** Git history is already an append-only, signed, distributed audit log.
Adding a GCS bucket creates another surface to secure, monitor and lifecycle-manage for
marginal benefit when consumers can already get permanent retention via the
`compliance_repo` PR.

**Implementation impact:** §5 Non-Goals updated to explicitly exclude cloud-storage
retention.

### Decision 3 — Explicit `dry_run` input

**Question:** Add an explicit `dry_run` input, or rely on existing toggles?

**Decision:** Add an explicit `dry_run` input.

**Rationale:** Single boolean for PR-preview runs is more discoverable than asking
consumers to remember to set both `push=false` and `sign_container=false`. Worth the one
extra API contract for the ergonomic win.

**Implementation impact:** FR-2 input list; FR-19 (override semantics).

### Decision 4 — Multi-arch in v1.0.0

**Question:** Multi-arch (`linux/arm64`) — ship in v1.0.0 or punt to v1.1?

**Decision:** Ship in v1.0.0 as optional input (default `linux/amd64`).

**Rationale:** No regression risk for current consumers since the default is unchanged.
ARM users opt in via the `platforms` input. Adds ~30 min of implementation work
(QEMU setup, `load: false` when multi-platform).

**Implementation impact:** US-005 already covers this; no new FR needed.

### Decision 5 — SLSA Level 3 provenance on day one

**Question:** Emit OpenSSF Scorecard / SLSA Level 3 provenance attestations on day one?

**Decision:** Include in v1.0.0.

**Rationale:** Add as another job (`slsa-provenance`) gated by `enable_slsa_provenance`.
More upfront effort, but ships one cohesive supply-chain story (Cosign signature + SBOM +
SLSA L3 provenance) instead of stringing them out across releases. Reduces churn for
downstream verifiers.

**Implementation impact:** US-016 (new user story); FR-2 (new input
`enable_slsa_provenance`); FR-3 (new output `slsa_provenance_digest`); FR-20 (job
constraints); §2 Goals (new bullet); §7 "SLSA generator constraints" bullet; §8 success
metric for SLSA attestation rate.

### Decision 6 — Hadolint as Dockerfile linter

**Question:** Confirm Hadolint as the long-term Dockerfile linter (vs `dockerfilelint` /
`dockle`)?

**Decision:** Hadolint — confirmed.

**Rationale:** Matches the design doc. Pin to latest stable SHA, run alongside Checkov.
Dockle overlaps with Trivy more than Checkov does, so Hadolint stays the better
complement (style + best-practice) vs Checkov (security + IaC compliance).

**Implementation impact:** US-004 acceptance criteria updated to call out Hadolint as
the confirmed choice.

### Decision 7 — Checkov OSS only

**Question:** Checkov OSS action vs Prisma Cloud licensed integration?

**Decision:** OSS action only — no Prisma Cloud integration.

**Rationale:** No licence concerns with the Apache 2.0 OSS action. Findings stay in
GitHub code scanning; we already have a single pane of glass there. Avoids adding a SaaS
dependency to the pipeline.

**Implementation impact:** US-004 acceptance criteria updated to explicitly exclude
Prisma Cloud integration; §5 Non-Goals updated.
