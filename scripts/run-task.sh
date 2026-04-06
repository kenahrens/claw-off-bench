#!/usr/bin/env bash
set -euo pipefail

wait_timeout="${WAIT_TIMEOUT:-30m}"

IFS=$'\t' read -r resolved_task_id resolved_task_instruction < <(
  TASK_REF="${TASK_REF:-}" TASK_ID="${TASK_ID:-}" TASK_INSTRUCTION="${TASK_INSTRUCTION:-}" ./scripts/resolve-task.sh
)

TASK_ID="${resolved_task_id}"
TASK_INSTRUCTION="${resolved_task_instruction}"
export TASK_ID TASK_INSTRUCTION
if [[ "$(kubectl config current-context)" != "minikube" ]]; then
  echo "warning: current kubectl context is not minikube"
fi

llm_key_b64="$(kubectl get secret claw-secrets -n claw-bench -o jsonpath='{.data.llm_api_key}' 2>/dev/null || true)"
github_token_b64="$(kubectl get secret claw-secrets -n claw-bench -o jsonpath='{.data.github_token}' 2>/dev/null || true)"

if [[ -z "${llm_key_b64}" || "${llm_key_b64}" == "ZHVtbXk=" || "${llm_key_b64}" == "UkVQTEFDRV9NRQ==" ]]; then
  echo "error: claw-secrets.llm_api_key is missing or placeholder; apply real credentials before running jobs" >&2
  exit 1
fi

if [[ -z "${github_token_b64}" || "${github_token_b64}" == "ZHVtbXk=" || "${github_token_b64}" == "UkVQTEFDRV9NRQ==" ]]; then
  echo "error: claw-secrets.github_token is missing or placeholder; apply real credentials before running jobs" >&2
  exit 1
fi

manifest="$(./scripts/render-job.sh)"
job_name="$(printf '%s\n' "${manifest}" | awk '/^  name:/ {print $2; exit}')"

printf '%s\n' "${manifest}" | kubectl apply -f -
kubectl wait --for=condition=complete --timeout="${wait_timeout}" "job/${job_name}" -n claw-bench || true
kubectl logs "job/${job_name}" -n claw-bench --timestamps | tee "results/${job_name}.txt"

echo "saved logs to results/${job_name}.txt"
