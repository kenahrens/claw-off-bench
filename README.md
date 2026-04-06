# claw-off-bench

Kubernetes-first benchmark harness for the 2026 Claw runtime evaluation.

## Objective

Run a standardized autonomous-coding benchmark across the five April 2026 Claw runtimes while measuring:

- Performance
- Density
- Security

All runs execute with the same hard limits (`1 CPU`, `512Mi` memory), non-root security context, and network egress restrictions.

## Evaluation Matrix

The benchmark matrix is tracked in `config/agents.csv`.

| Agent | Stars | Runtime | Footprint | Use Case |
|:--|:--|:--|:--|:--|
| OpenClaw | 335k | Node.js | ~1.5GB | High-context legacy refactor |
| Claw Code | 72k | Python/Rust | ~200MB | General-purpose coding |
| ZeroClaw | 26k | Rust | <5MB | High-density factory work |
| NanoClaw | 21k | TypeScript/Wasm | ~50MB | Secure/untrusted modules |
| PicoClaw | 13k | Go | ~10MB | Fast edge execution |

## Repository Layout

- `config/agents.csv`: runtime matrix and image/template mapping.
- `tasks/tasks.yaml`: benchmark task suite.
- `k8s/base`: namespace, PVC, secrets template, baseline deny policy.
- `k8s/templates`: generic and ZeroClaw-compatible Job manifests.
- `scripts`: setup, policy generation, run orchestration, and log collection.
- `adapters/zeroclaw`: optional adapter image for restrictive runtime behavior.

## Security and Isolation

`k8s/base/networkpolicy.yaml` applies a baseline deny policy.

`scripts/apply-egress-policy.sh` applies a generated egress allowlist policy for:

- `api.anthropic.com`
- `api.openai.com`
- `github.com`
- `api.github.com`
- Optional: `pypi.org` and `registry.npmjs.org` when `ALLOW_PACKAGE_REGISTRIES=true`

The policy resolves current A records and restricts agent pods (`app=claw-runner`) to DNS + HTTPS on allowlisted destinations.

## Prereqs

- `kubectl`
- `minikube` (or another cluster/context)
- `bash`
- `envsubst` (from `gettext`)
- `dig` (for egress allowlist resolution)

## Quickstart

1. Set context with `kubectl config use-context minikube` and verify with `kubectl config current-context`.
2. Apply base resources with `make setup`, then copy `k8s/base/secrets.template.yaml` to `k8s/base/secrets.yaml`, fill real tokens, and apply it.
3. Apply the egress cage with `make setup-egress` (set `ALLOW_PACKAGE_REGISTRIES=true` only when dependency downloads are required).
4. Run one benchmark job with `make run` using `AGENT_NAME`, `AGENT_IMAGE`, `TASK_ID`, and `TASK_INSTRUCTION` env vars.
5. Run the full matrix with repeats using `REPEAT_COUNT=3 make run-matrix`.
6. Collect all run logs with `make collect`.

## Notes

- Use `k8s/templates/job-zeroclaw.yaml` when the default template fails due to stricter runtime assumptions.
- The ZeroClaw template keeps non-root and dropped caps but allows writable root filesystem when required.
- Logs are written to `results/*.txt` for post-run scoring and analysis.
