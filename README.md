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

Single command (job mode, task 1):

`OPENROUTER_API_KEY=... make easy`

Single command (matrix mode, default all configured agents, 1 repeat):

`OPENROUTER_API_KEY=... make easy-matrix`

Optional overrides:

- `TASK_REF=TASK_2 make easy`
- `EASY_MODE=daemon TASK_REF=TASK_1 make easy`
- `DEFAULT_MODEL=nvidia/nemotron-3-super-120b-a12b:free make easy`
- `AGENT_FILTER=zeroclaw REPEAT_COUNT=3 make easy-matrix`
- `MATRIX_STRICT=true make easy-matrix` (fail if any configured agent is unavailable)

1. Set context with `kubectl config use-context minikube` and verify with `kubectl config current-context`.
2. Apply base resources with `make setup`.
3. Apply credentials with `make setup-secrets` after exporting `LLM_API_KEY` (or `OPENROUTER_API_KEY`) and `GITHUB_TOKEN`.
4. Sync repository contents into the workspace PVC with `make sync-workspace`.
5. Apply the egress cage with `make setup-egress` (set `ALLOW_PACKAGE_REGISTRIES=true` only when dependency downloads are required).
6. Build the ZeroClaw adapter image into the Minikube image store with `make build-zeroclaw-adapter`.
7. List standard benchmark aliases with `make tasks`.
8. Run one benchmark job with `make run-task-1` (or `make run-task-2`, etc.) after setting `AGENT_NAME` and `AGENT_IMAGE`; set `WAIT_TIMEOUT` to cap wait duration per run.
9. You can still run with explicit task fields using `make run` and `TASK_REF`, or `TASK_ID` + `TASK_INSTRUCTION`.
10. Run the full matrix with repeats using `REPEAT_COUNT=3 make run-matrix` (set `AGENT_FILTER=zeroclaw` to run a subset).
11. Collect all run logs with `make collect`.
12. Score current artifacts with `make score` (writes `results/score.json`).

Matrix notes:

- `scripts/run-matrix.sh` performs image preflight and writes `results/matrix-preflight.tsv`.
- Unavailable agents are skipped by default so available agents still run.
- Set `MATRIX_STRICT=true` to fail when any configured agent is unavailable.
- Use `make matrix-preflight` to run only the availability check.
- To compare all 5 agents, ensure every image in `config/agents.csv` is pullable from your environment.

## Daemon Mode (ZeroClaw)

Use daemon mode as a separate benchmark track for steady-state service behavior.

1. Deploy and pair the daemon with `make deploy-daemon`.
2. Submit a task over HTTP with `make daemon-task-1` (or `make daemon-task-2`, etc.).
3. Repeat task submissions as needed; each response is stored under `results/`.
4. Tear down daemon resources with `make remove-daemon`.

Notes:

- Daemon mode preserves runtime state between requests; do not mix its results with cold-start job runs.
- Daemon auth token is stored in Kubernetes secret `${DAEMON_NAME:-zeroclaw-daemon}-auth`.

## Notes

- Use `k8s/templates/job-zeroclaw.yaml` when the default template fails due to stricter runtime assumptions.
- The ZeroClaw template keeps non-root and dropped caps but allows writable root filesystem when required.
- Logs are written to `results/*.txt` for post-run scoring and analysis.
