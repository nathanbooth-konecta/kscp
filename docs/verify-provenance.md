# Verifying a KSCP-built image

Every image KSCP publishes (with `sign_container: true` and `push: true`) has
**four** attached artefacts that downstream verifiers can check:

1. Cosign keyless signature
2. CycloneDX SBOM attestation
3. Vulnerability attestation (in-toto, predicate `vuln/v1`)
4. SLSA Level 3 build provenance

All four are tied to the image **digest** (not the tag). Pull by digest when
verifying so a later re-tag can't substitute a different image.

## Prerequisites

```bash
brew install cosign trivy
go install github.com/slsa-framework/slsa-verifier/v2/cli/slsa-verifier@latest
```

You also need read access to the registry. For GCP Artifact Registry:

```bash
gcloud auth login
gcloud auth configure-docker europe-west1-docker.pkg.dev --quiet
```

## 1. Resolve the digest

Tag → digest:

```bash
IMAGE=europe-west1-docker.pkg.dev/kd-ix-eur-shr-artifacts/approved-images/kix-app-myservice:1.2.3
DIGEST=$(gcloud artifacts docker images describe "$IMAGE" --format='value(image_summary.digest)')
echo "$IMAGE@$DIGEST"
```

## 2. Verify the signature

```bash
cosign verify \
  --certificate-identity-regexp "https://github.com/konecta-ix/.+/.github/workflows/.+@.+" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "${IMAGE%:*}@${DIGEST}"
```

A passing verification prints `Verified OK` and the signing certificate's
GitHub Actions OIDC identity (workflow path + ref).

## 3. Verify the SBOM attestation

```bash
cosign verify-attestation \
  --type cyclonedx \
  --certificate-identity-regexp "https://github.com/konecta-ix/.+/.github/workflows/.+@.+" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "${IMAGE%:*}@${DIGEST}"
```

To extract the SBOM JSON:

```bash
cosign download attestation "${IMAGE%:*}@${DIGEST}" \
  | jq -r '.payload | @base64d | fromjson | .predicate' > sbom.cdx.json
```

## 4. Verify the vulnerability attestation

```bash
cosign verify-attestation \
  --type vuln \
  --certificate-identity-regexp "https://github.com/konecta-ix/.+/.github/workflows/.+@.+" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "${IMAGE%:*}@${DIGEST}"
```

The decoded predicate contains the Trivy scan results that KSCP attached at
sign time — useful for downstream admission controllers (Kyverno, Gatekeeper)
to evaluate policy against scan output without re-running the scan.

## 5. Verify SLSA Level 3 provenance

```bash
slsa-verifier verify-image \
  --source-uri github.com/konecta-ix/<your-service-repo> \
  --source-tag v1.2.3 \
  "${IMAGE%:*}@${DIGEST}"
```

The verifier confirms the image was produced by a reusable workflow trusted
under the SLSA L3 builder identity, from the specified source commit, on
GitHub-hosted infrastructure.

## Verifying programmatically (admission controllers)

For Kyverno, the relevant policy primitive is `verifyImages` with
`attestations` keyed on `vuln` and `cyclonedx`. The cosign identity to trust:

```yaml
keyless:
  identities:
    - issuer: https://token.actions.githubusercontent.com
      subjectRegExp: "^https://github\\.com/konecta-ix/.+/\\.github/workflows/.+@.+$"
```

That regex covers both KSCP itself (when running as a workflow_call source)
and any caller repo that invokes KSCP — both forms of the OIDC subject end up
matching the caller's `workflow@ref` path.
