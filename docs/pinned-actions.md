# Pinned-action manifest

This is the source-of-truth table for every third-party action used by KSCP.
The `pin-audit.yml` workflow rejects any PR that introduces an unpinned action
outside the allow-listed namespaces (`actions/*`, `github/*`, the SLSA
reusable-workflow exemption, and any first-party namespaces listed in repo
variable `ALLOWED_ORG_NAMESPACES` — default `konecta`).

When updating a pin, refresh both the SHA in the workflow file and the row
below in the same PR. Reviewers should verify the SHA matches the release tag
on the source repo.

| Action | SHA | Tag | Released | Source |
|--------|-----|-----|----------|--------|
| `actions/checkout` | `93cb6efe18208431cddfb8368fd83d5badbf9bfd` | v5 | 2025-08-29 | https://github.com/actions/checkout |
| `actions/upload-artifact` | `330a01c490aca151604b8cf639adc76d48f6c5d4` | v5 | 2025-10-14 | https://github.com/actions/upload-artifact |
| `actions/download-artifact` | `634f93cb2916e3fdff6788551b99b062d0335ce0` | v5 | 2025-10-14 | https://github.com/actions/download-artifact |
| `actions/cache` | `1bd1e32a3bdc45362d1e726936510720a7c30a57` | v4 | 2025-09-30 | https://github.com/actions/cache |
| `actions/create-github-app-token` | `d72941d797fd3113feb6b93fd0dec494b13a2547` | v1 | 2025-08-15 | https://github.com/actions/create-github-app-token |
| `google-github-actions/auth` | `c200f3691d83b41bf9bbd8638997a462592937ed` | v2 | 2025-06-12 | https://github.com/google-github-actions/auth |
| `google-github-actions/setup-gcloud` | `e427ad8a34f8676edf47cf7d7925499adf3eb74f` | v2 | 2025-04-22 | https://github.com/google-github-actions/setup-gcloud |
| `docker/setup-buildx-action` | `8d2750c68a42422c14e847fe6c8ac0403b4cbd6f` | v3 | 2025-09-15 | https://github.com/docker/setup-buildx-action |
| `docker/setup-qemu-action` | `49b3bc8e6bdd4a60e6116a5414239cba5943d3cf` | v3.2.0 | 2024-09-25 | https://github.com/docker/setup-qemu-action |
| `docker/build-push-action` | `10e90e3645eae34f1e60eeb005ba3a3d33f178e8` | v6 | 2025-10-08 | https://github.com/docker/build-push-action |
| `aquasecurity/trivy-action` | `57a97c7e7821a5776cebc9bb87c984fa69cba8f1` | 0.35.0 | 2025-07-10 | https://github.com/aquasecurity/trivy-action |
| `sigstore/cosign-installer` | `398d4b0eeef1380460a10c8013a76f728fb906ac` | v3 | 2025-09-04 | https://github.com/sigstore/cosign-installer |
| `github/codeql-action/upload-sarif` | `38697555549f1db7851b81482ff19f1fa5c4fedc` | v4 | 2025-10-21 | https://github.com/github/codeql-action |
| `bridgecrewio/checkov-action` | `38a95e98d734de90b74687a0fc94cfb4dcc9c169` | v12 | 2025-05-30 | https://github.com/bridgecrewio/checkov-action |
| `hadolint/hadolint-action` | `54c9adbab1582c2ef04b2016b760714a4bfde3cf` | v3.1.0 | 2023-08-14 | https://github.com/hadolint/hadolint-action |
| `gitleaks/gitleaks-action` | `ff98106e4c7b2bc287b24eaf42907196329070c7` | v2.3.9 | 2025-02-11 | https://github.com/gitleaks/gitleaks-action |
| `ossf/scorecard-action` | `f49aabe0b5af0936a0987cfb85d86b75731b0186` | v2.4.1 | 2025-01-30 | https://github.com/ossf/scorecard-action |
| `OctopusDeploy/login` | `e485a40e4b47a154bdf59cc79e57894b0769a760` | v1 | 2024-04-22 | https://github.com/OctopusDeploy/login |
| `OctopusDeploy/push-build-information-action` | `251acb0783c656ebf30d5bc69474a037116cce09` | v3 | 2024-05-08 | https://github.com/OctopusDeploy/push-build-information-action |
| `astral-sh/setup-uv` | `bd01e18f51369d5a26f1651c3cb451d3417e3bba` | v6 | 2025-09-12 | https://github.com/astral-sh/setup-uv |

## SLSA reusable-workflow exemption

`slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml`
is consumed as a reusable workflow rather than an action. GitHub's
trusted-builder check for SLSA Level 3 requires the workflow to be referenced
by a release tag (`@v2.0.0`), not a commit SHA — pinning to a SHA breaks the
trusted-builder identity that the generator embeds in the provenance subject.

The `pin-audit.yml` workflow explicitly allows tag refs only for this
namespace; the tag itself is verified by the upstream maintainers via signed
releases.

## Rotation policy

- Verify and refresh each pin quarterly via a single tracking PR.
- Rotate immediately when an upstream advisory affects the action's
  repository, regardless of severity.
- The `pin-audit.yml` workflow blocks merges that introduce or restore an
  unpinned reference.
