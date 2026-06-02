# Test fixtures

`Dockerfile.simple` is a deliberately minimal Dockerfile used by the
`test-air-gapped.yml` and `test-e2e.yml` workflows to exercise the pipeline.
It pins specific package versions so reruns produce comparable scan results.
