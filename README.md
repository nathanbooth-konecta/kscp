<div align="center">

# Konecta Secure Container Pipeline

**A SHA-pinned, defense-in-depth GitHub Actions reusable workflow that builds, scans, signs, attests, and publishes every Konecta container image — with every external tool independently switchable for air-gapped builds.**

[![Status: GA](https://img.shields.io/badge/status-GA-brightgreen)](#roadmap)
[![Version: 1.0.0](https://img.shields.io/badge/version-1.0.0-blue)](version.txt)
[![License: Proprietary](https://img.shields.io/badge/license-proprietary-red)](LICENSE)
[![Workflow: reusable](https://img.shields.io/badge/workflow-reusable-2088FF?logo=githubactions&logoColor=white)](.github/workflows/scp.yml)
[![Actions: SHA-pinned](https://img.shields.io/badge/actions-SHA--pinned-success)](docs/pinned-actions.md)
[![Air-gap: supported](https://img.shields.io/badge/air--gap-supported-informational)](#air-gapped-mode)

[![Vuln scan: Trivy](https://img.shields.io/badge/vuln-Trivy-1904DA?logo=aquasec&logoColor=white)](https://aquasecurity.github.io/trivy/)
[![Lint: Hadolint + Checkov](https://img.shields.io/badge/lint-Hadolint%20%2B%20Checkov-2B6CB0)](https://github.com/hadolint/hadolint)
[![Secrets: Gitleaks](https://img.shields.io/badge/secrets-Gitleaks-DA291C)](https://github.com/gitleaks/gitleaks)
[![Signing: Cosign keyless](https://img.shields.io/badge/signing-Cosign_keyless-FF9900)](https://docs.sigstore.dev/)
[![Provenance: SLSA L3](https://img.shields.io/badge/provenance-SLSA_L3-7E57C2)](https://slsa.dev/spec/v1.0/levels#build-l3)
[![SBOM: CycloneDX](https://img.shields.io/badge/SBOM-CycloneDX-007EC6)](https://cyclonedx.org/)
[![Schema: actionlint](https://img.shields.io/badge/schema-actionlint-2DCE89)](https://github.com/rhysd/actionlint)
[![Tests: 17 unit · 15 negative](https://img.shields.io/badge/tests-17_unit_%C2%B7_15_negative-brightgreen)](#testing)

[Overview](#overview) ·
[Architecture](#architecture) ·
[Job Catalog](#job-catalog) ·
[Quick Start](#quick-start) ·
[Air-gapped Mode](#air-gapped-mode) ·
[Security](#security) ·
[Documentation](#documentation)

</div>

---

`konecta/kscp` is a single reusable GitHub Actions workflow, designed for
any team across Konecta, that supersedes per-repo `docker-build-push.yml`,
`docker-build-push-python.yml`, and `image-promote.yml` patterns. It
**always** builds, scans, signs, attests, and atomically publishes container
images to your chosen Artifact Registry; it **never** assumes outbound network
access, and **never** publishes an image that failed a configured gate without
an explicit, audited `*_bypass: true` override.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
  - [Pipeline Stages](#pipeline-stages)
  - [Defense-in-Depth Map](#defense-in-depth-map)
- [Job Catalog](#job-catalog)
- [Quick Start](#quick-start)
  - [Prerequisites](#prerequisites)
  - [Minimum-Viable Caller](#minimum-viable-caller)
  - [Verification](#verification)
- [Air-gapped Mode](#air-gapped-mode)
- [Bypass Flags](#bypass-flags)
- [Testing](#testing)
- [Project Structure](#project-structure)
- [Security](#security)
- [Speed Optimisations](#speed-optimisations)
- [Roadmap](#roadmap)
- [Documentation](#documentation)
- [License](#license)

## Overview

Every Konecta service today pastes the same ~500 lines of GitHub Actions for
build / lint / scan / sign / push. KSCP collapses that into one
`workflow_call`. A caller workflow declares `image_name`, `ar_registry`,
`environment`, and (optionally) overrides any of the 39 typed inputs.

The pipeline runs **11 jobs across 8 execution stages**, with three scanners
fanning out in parallel before the build and two attestations fanning out
after publish. Every third-party `uses:` is pinned to a 40-character commit
SHA — enforced by a dedicated `pin-audit.yml` workflow on every PR. Every
external integration (Sigstore, SLSA, Octopus, Trivy DB, Gitleaks SARIF
upload) has an `enable_*` boolean, so callers in restricted networks can flip
them off without forking.

## Features

- **39 typed inputs · 17 outputs** — every parameter is `required`-flagged and
  typed; outputs publish the final digest, all tag aliases, the signed digest,
  Trivy severity counts, and the SBOM/attestation paths for downstream jobs.
- **Defense-in-depth scanning** — Hadolint + Checkov on the Dockerfile,
  Gitleaks on the source tree, Trivy (vuln + secret + misconfig + license +
  SBOM) on the built image, all in a single Trivy invocation.
- **Keyless signing + Level-3 provenance** — Cosign keyless signature, SBOM
  attestation, vulnerability-report attestation, and `slsa-github-generator`
  build provenance — all verifiable with `cosign verify` and
  `slsa-verifier` against the Konecta org identity.
- **Atomic multi-tag publish** — Skopeo copies one staging digest to every
  derived tag (`<version>`, `<lane>`, `latest`, `<sha>`) in one transaction;
  no `docker push` per tag.
- **Lane-based tagging** — `derive-tags.sh` derives `release` / `rc` / `dev` /
  `branch` / `imported` lanes from `version.txt` + the git ref, with a
  17-assertion unit test suite.
- **Tamper-evident approver record** — when `sign_container: true`, the
  workflow captures the GitHub Environment approver, timestamp, run URL, and
  workflow SHA into a JSON artefact attached to the run.
- **Air-gap parity** — every external dependency has an `enable_*` flag; the
  `test-air-gapped.yml` workflow exercises the all-disabled path end-to-end
  in CI on every push.
- **Bypass with audit** — a build can override a failing gate via
  `allow_*_bypass: true`, which still emits a `::warning::` and records the
  bypass in the run summary. The default for every bypass flag is `false`.

## Architecture

KSCP is invoked as a reusable workflow from one of many caller repos. A
single caller `uses: konecta/kscp/.github/workflows/scp.yml@v1` pulls in
the full pipeline; the caller never installs tools or duplicates pin lines.

### Pipeline Stages

![KSCP pipeline stages: caller workflow_call invokes scp.yml, which orchestrates 11 jobs across 8 stages — setenv, then parallel secrets-scan/checkov/hadolint, then build-and-scan with a single Trivy invocation, then environment-gated sign-container, then parallel signed_image/approvals into record-of-approvals, then Skopeo atomic publish, then parallel slsa-provenance and octopus, finally pushing version/lane/latest/sha tags to the Konecta Artifact Registry.](docs/img/pipeline-stages.svg)

Eight execution stages; three pre-build scans run concurrently; signing,
record-of-approvals, and the post-publish attestations all fan out where
ordering permits. The full job graph is reproduced by `act -l` and validated
in `tasks/validation-report.md`.

### Defense-in-Depth Map

![KSCP defense-in-depth map: source artefacts (Dockerfile, application source, git history) flow through three soft pre-build gates (Hadolint, Checkov, Gitleaks) into build-and-scan, where Trivy runs once with vuln/secret/misconfig/license scanners plus a CycloneDX SBOM. Trivy secret findings hard-fail with no bypass. Surviving images flow through Cosign keyless signing, SBOM and vulnerability attestations, and SLSA Level 3 provenance into the final tag set in the Konecta Artifact Registry. Each phase is annotated with its disable_* and allow_*_bypass flags.](docs/img/defense-in-depth.svg)

Each gate fails closed by default. Every gate is independently disable-able
(`enable_*: false`) and independently bypass-able under audit
(`allow_*_bypass: true`). Trivy's secret scanner is the only gate that
**always** hard-fails on findings — there is no severity dial for a secret
baked into a layer.

## Job Catalog

| Job | Stage | Purpose | Disable input | Bypass input |
| --- | :---: | --- | --- | --- |
| `setenv`              | 0 | Derive tags, lane, image URI, effective flags | — | — |
| `secrets-scan`        | 1 | Gitleaks scan over source + git history | `enable_gitleaks` | `allow_secrets_bypass` |
| `checkov`             | 1 | Dockerfile IaC misconfig (OSS) | `enable_checkov` | `allow_dockerfile_scan_bypass` |
| `hadolint`            | 1 | Dockerfile lint, SARIF → code-scanning | `enable_hadolint` | `allow_dockerfile_scan_bypass` |
| `build-and-scan`      | 2 | `buildx --load`, Trivy (vuln+secret+misconfig+license+SBOM) | `enable_trivy` | `allow_scan_bypass` |
| `sign-container`      | 3 | Cosign keyless + SBOM + vuln attestation (env-gated) | `sign_container` | — |
| `signed_image`        | 4 | Surface signed digest to caller | — | — |
| `approvals`           | 4 | Capture GitHub Environment reviewer metadata | — | — |
| `record-of-approvals` | 5 | Write tamper-evident JSON artefact | — | — |
| `publish`             | 6 | Skopeo atomic multi-tag retag → Artifact Registry | `push` | — |
| `slsa-provenance`     | 7 | `slsa-github-generator` Level-3 attestation | `enable_slsa_provenance` | — |
| `octopus`             | 7 | Push build info to Octopus (non-blocking) | `enable_octopus` | — |

Every job runs on `ubuntu-latest` with a 30-minute timeout. Full input
reference is in `.github/workflows/scp.yml` and explained line-by-line in
**[tasks/prd-konecta-secure-container-pipeline.md](tasks/prd-konecta-secure-container-pipeline.md)**.

## Quick Start

### Prerequisites

| Requirement | Notes |
| --- | --- |
| GitHub repo with Actions enabled | Caller must grant `id-token: write`, `contents: read`, `packages: write`, `actions: read`, `security-events: write`. |
| GCP Workload Identity Federation | Service account mapped to the repo; KSCP authenticates with no static keys. |
| `version.txt` at repo root | SemVer (e.g. `1.2.3`). Used as the primary tag; falls back to derived lane tags on non-main refs. |
| `Dockerfile` at repo root | Or override `dockerfile_path` / `build_context`. |
| GitHub Environment `kscp-signed-image` | Only if `sign_container: true`. Add required reviewers there. |

### Minimum-Viable Caller

```yaml
# .github/workflows/build.yml
name: build-and-publish

on:
  push:
    branches: [main, develop]
    tags: ['v*']

permissions:
  id-token: write
  contents: read
  packages: write
  actions: read
  security-events: write

jobs:
  kscp:
    uses: konecta/kscp/.github/workflows/scp.yml@v1
    with:
      image_name: kix-app-myservice
      ar_registry: europe-west1-docker.pkg.dev/kd-ix-eur-shr-artifacts/approved-images
      environment: ${{ github.ref == 'refs/heads/main' && 'prod' || 'dev' }}
    secrets:
      WORKLOAD_REPO_APP_ID:          ${{ secrets.WORKLOAD_REPO_APP_ID }}
      WORKLOAD_REPO_APP_PRIVATE_KEY: ${{ secrets.WORKLOAD_REPO_APP_PRIVATE_KEY }}
      # Optional — only required if you set `enable_octopus: true` above and have
      # the OCTOPUS_URL repo variable set:
      # OCTOPUS_API_KEY:             ${{ secrets.OCTOPUS_API_KEY }}
```

Four more variants — Python CI passthrough, `built_image` promote flow, and
fully air-gapped — are in **[examples/](examples/)**.

### Verification

```bash
# Static checks (run from kscp checkout):
actionlint .github/workflows/*.yml      # 0 errors expected
yamllint .github/workflows/ examples/   # 0 errors with project .yamllint
shellcheck scripts/*.sh test/*.sh       # 0 errors expected

# Unit tests:
bash test/test-derive-tags.sh           # 17 assertions across 7 scenarios

# Negative tests (proves the pipeline FAILS on bad input):
bash test/test-negative-cases.sh        # 15 assertions across 5 scanners
```

The negative-test driver builds deliberately-bad fixtures (`alpine:3.11` for
CVEs, a Dockerfile with baked AWS keys, lint-violating syntax, misconfigured
ports, source files with synthetic secret tokens) and verifies that each
scanner detects the issue **and** that the workflow's enforcement gate exits
non-zero by default and exits zero with a `::warning::` only when the
corresponding `*_bypass` flag is explicitly set.

## Air-gapped Mode

Set every external integration to `false` in the caller:

```yaml
jobs:
  kscp:
    uses: konecta/kscp/.github/workflows/scp.yml@v1
    with:
      image_name: my-app
      ar_registry: localhost:5000
      environment: dev
      scan_dockerfile:         false   # disable Checkov + Hadolint
      enable_gitleaks:         false   # disable source secret scan
      enable_trivy:            false   # disable image scan + SBOM
      sign_container:          false   # disable Cosign + Fulcio + Rekor
      enable_cosign:           false
      enable_slsa_provenance:  false   # disable slsa-github-generator
      enable_octopus:          false   # disable Octopus build info
      enable_compliance_pr:    false   # disable cross-repo compliance PR
      push:                    false   # local-only build
```

In this mode the workflow makes **zero** outbound calls to Sigstore, Aqua
(Trivy DB), Bridgecrew (Checkov public catalog), Octopus, or the SLSA
generator. The `test-air-gapped.yml` workflow exercises this path on every
push and was last verified in `tasks/validation-report.md`.

## Bypass Flags

A bypass flag turns a gate's `exit 1` into `exit 0` plus a GitHub-Actions
`::warning::` annotation. Bypass is never silent — every bypass invocation
appears in the run's annotations and in `record-of-approvals.json`.

| Bypass input | Affects | When you might need it |
| --- | --- | --- |
| `allow_dockerfile_scan_bypass` | Checkov + Hadolint | Legacy Dockerfile mid-refactor; bypass while a fix PR lands. |
| `allow_secrets_bypass`         | Gitleaks            | Reviewed false-positive that the project `.gitleaks.toml` does not yet allowlist. |
| `allow_scan_bypass`            | Trivy (vuln, misconfig, license) | Upstream-only CVE pending vendor patch; **does not** bypass Trivy secret detection. |

Defaults are all `false`. Setting any of these to `true` should be reviewed
by `@konecta/security-team` (CODEOWNERS-enforced; each host org adjusts the
team handle to match their structure).

## Testing

| Layer | Files | Coverage |
| --- | --- | --- |
| Static lint | `.github/workflows/*.yml`, `examples/*.yml`, `scripts/*.sh`, `test/*.sh` | actionlint + yamllint + shellcheck |
| Pin audit | `.github/workflows/pin-audit.yml` | Every `uses:` outside the `actions/*` / `github/*` / SLSA-tag allow-list, plus any namespaces listed in repo variable `ALLOWED_ORG_NAMESPACES` (default `konecta`), must be a 40-char SHA. |
| Unit tests | `test/test-derive-tags.sh` | 17 assertions across 7 lane scenarios. |
| Negative tests | `test/test-negative-cases.sh` + `test/fixtures/bad/` | Hadolint · Checkov · Gitleaks · Trivy vuln · Trivy secret. 15 assertions; verifies both detection and gate enforcement. |
| Air-gapped | `.github/workflows/test-air-gapped.yml` | All-disabled run on every push. |
| End-to-end  | `.github/workflows/test-e2e.yml` | Full chain dry-run with bypasses true. |

Local validation results are in **[tasks/validation-report.md](tasks/validation-report.md)**.

## Project Structure

```text
kscp/
├── .github/workflows/
│   ├── scp.yml                       main reusable workflow (39 inputs, 17 outputs)
│   ├── scorecard.yml                 weekly OpenSSF Scorecard self-assessment
│   ├── release.yml                   version.txt → git tag + GitHub Release
│   ├── pin-audit.yml                 enforce 40-char SHA pins on every uses:
│   ├── test-air-gapped.yml           CI test for all-disabled path
│   └── test-e2e.yml                  CI test for full-chain dry-run
├── docs/
│   ├── img/
│   │   ├── pipeline-stages.svg       rendered execution-graph diagram
│   │   └── defense-in-depth.svg      rendered control-flow diagram
│   ├── pinned-actions.md             SHA pin manifest with provenance
│   ├── migration-from-legacy.md      field-by-field map from z_docker-build-push.yml
│   └── verify-provenance.md          cosign verify + slsa-verifier howto
├── examples/
│   ├── caller-minimal.yml            simplest possible caller
│   ├── caller-python.yml             pytest + KSCP composition
│   ├── caller-promote.yml            built_image short-circuit (re-tag flow)
│   └── caller-air-gapped.yml         every external tool off
├── scripts/
│   ├── derive-tags.sh                lane + tag derivation (mirrors inline workflow logic)
│   ├── render-trivy-summary.sh       Trivy JSON → markdown step summary
│   └── record-approvals.sh           approver metadata capture
├── test/
│   ├── test-derive-tags.sh           17 unit assertions
│   ├── test-negative-cases.sh        15 negative-test assertions
│   └── fixtures/
│       ├── Dockerfile.simple         clean fixture for positive tests
│       └── bad/                      deliberately-bad fixtures (vuln, secret, lint, misconfig)
├── tasks/
│   ├── prd-konecta-secure-container-pipeline.md
│   └── validation-report.md          local validation evidence
├── .gitleaks.toml                    repo-local allowlist (incl. negative-fixture exclusions)
├── .yamllint                         flow-mapping-friendly config for inputs blocks
├── CODEOWNERS                        platform-team + security-team ownership
├── version.txt                       1.0.0
├── LICENSE
└── README.md                         (this file)
```

## Security

KSCP itself is part of the supply chain it protects, so it applies its own
controls to its own source:

- **SHA-pinned actions.** Every third-party `uses:` is pinned to a 40-character
  commit SHA. The only exception is the SLSA reusable workflow, which must be
  tag-referenced for the trusted-builder check (documented in
  [docs/pinned-actions.md](docs/pinned-actions.md)). `pin-audit.yml` enforces
  this on every PR.
- **Gitleaks on its own source.** The same Gitleaks gate KSCP imposes on
  consumers also runs on KSCP itself, with a documented allowlist for the
  PRD-review HTML and the negative-test fixtures.
- **Weekly OpenSSF Scorecard.** `scorecard.yml` runs every Monday, uploads
  results to GitHub code-scanning, and auto-opens an issue if the score drops
  below 8.0.
- **CODEOWNERS gate.** All workflow and policy file changes require approval
  from `@konecta/platform-team` **and** `@konecta/security-team` (host orgs
  remap to their own team handles).
- **Negative-test suite.** `test/test-negative-cases.sh` proves the pipeline
  fails closed on real bad inputs — see the [Testing](#testing) section.
- **Bypass is auditable, not silent.** Every bypass emits a GitHub annotation
  and is recorded in `record-of-approvals.json`.

If you discover a security issue, please report it privately to
`security@konecta.com` rather than opening a public issue.

## Speed Optimisations

| Optimisation | Implementation | Estimated saving |
| --- | --- | --- |
| Parallel pre-build scans | Checkov / Hadolint / Gitleaks all `needs: setenv` only | 30–60 s |
| Combined build + scan job | `buildx --load` then Trivy locally (no tar artifact transfer) | 60–120 s |
| Single Trivy invocation | `--scanners vuln,secret,misconfig,license` in one call (one DB init) | ~3× vs four sequential calls |
| BuildKit GHA cache | `cache-from: type=gha`, `cache-to: type=gha,mode=max` | proportional to layer reuse |
| Trivy DB cache | `actions/cache@v4` on `~/.cache/trivy` | 10–20 s warm |
| Concurrency cancel-in-progress | `concurrency.group: kscp-${image_name}-${ref}` | kills stale runs immediately |
| Job-level `if:` (not step-level) | Skipped jobs cost ~0 s, not pod warm-up | ~10 s per skipped scan |
| No QEMU unless multi-arch | `if: contains(inputs.platforms, ',')` | 15–20 s for default amd64 |
| Skopeo retag (not re-push) | `skopeo copy docker://staging docker://final` per tag | 30–60 s vs `docker push` per tag |

## Roadmap

- **v1.1** — Provenance verification job that callers can chain after deploy.
- **v1.2** — Pluggable scanner ordering for licence-first workflows.
- **v1.3** — Native multi-arch attestation (`cosign sign --recursive` matrix).
- **v2.0** — Switch the trusted builder when SLSA L4 spec stabilises.

## Documentation

| Doc | Purpose |
| --- | --- |
| [docs/pinned-actions.md](docs/pinned-actions.md) | SHA pin manifest with release dates for every third-party action. |
| [docs/migration-from-legacy.md](docs/migration-from-legacy.md) | Field-by-field map from the legacy `docker-build-push.yml`. |
| [docs/verify-provenance.md](docs/verify-provenance.md) | `cosign verify` + `slsa-verifier` recipes for downstream consumers. |
| [tasks/prd-konecta-secure-container-pipeline.md](tasks/prd-konecta-secure-container-pipeline.md) | Full PRD with every input rationale. |
| [tasks/validation-report.md](tasks/validation-report.md) | Local validation evidence (static checks, unit tests, fixture runs). |

## License

Konecta internal — see [LICENSE](LICENSE).
