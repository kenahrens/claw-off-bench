#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kube.sh
source "${script_dir}/lib/kube.sh"

wait_timeout="${WAIT_TIMEOUT:-30m}"
require_github_token="${REQUIRE_GITHUB_TOKEN:-false}"
validate_result="${VALIDATE_RESULT:-false}"

IFS=$'\t' read -r resolved_task_id resolved_task_instruction < <(
  TASK_REF="${TASK_REF:-}" TASK_ID="${TASK_ID:-}" TASK_INSTRUCTION="${TASK_INSTRUCTION:-}" ./scripts/resolve-task.sh
)

TASK_ID="${resolved_task_id}"
TASK_INSTRUCTION="${resolved_task_instruction}"
export TASK_ID TASK_INSTRUCTION
echo "[run-task] kube context=${KUBE_CONTEXT:-minikube}"

llm_key_b64="$(kctl get secret claw-secrets -n claw-bench -o jsonpath='{.data.llm_api_key}' 2>/dev/null || true)"
github_token_b64="$(kctl get secret claw-secrets -n claw-bench -o jsonpath='{.data.github_token}' 2>/dev/null || true)"

if [[ -z "${llm_key_b64}" || "${llm_key_b64}" == "ZHVtbXk=" || "${llm_key_b64}" == "UkVQTEFDRV9NRQ==" ]]; then
  echo "error: claw-secrets.llm_api_key is missing or placeholder; apply real credentials before running jobs" >&2
  exit 1
fi

if [[ "${require_github_token}" == "true" ]]; then
  if [[ -z "${github_token_b64}" || "${github_token_b64}" == "ZHVtbXk=" || "${github_token_b64}" == "UkVQTEFDRV9NRQ==" ]]; then
    echo "error: claw-secrets.github_token is missing or placeholder; apply real credentials before running jobs" >&2
    exit 1
  fi
fi

manifest="$(./scripts/render-job.sh)"
job_name="$(printf '%s\n' "${manifest}" | awk '/^  name:/ {print $2; exit}')"

printf '%s\n' "${manifest}" | kctl apply -f -
kctl wait --for=condition=complete --timeout="${wait_timeout}" "job/${job_name}" -n claw-bench || true
kctl logs "job/${job_name}" -n claw-bench --timestamps | tee "results/${job_name}.txt"

if [[ "${validate_result}" == "true" ]]; then
  if ! RUN_LOG_PATH="results/${job_name}.txt" python3 - <<'PY'
import os
import re
import sys

path = os.environ["RUN_LOG_PATH"]
text = open(path, encoding="utf-8", errors="replace").read()

hard_fail_markers = [
    "authentication_error",
    "Invalid API key",
    "LLM call failed",
    "error processing message",
    "Unsupported value:",
    "stopReason\": \"error\"",
]

for marker in hard_fail_markers:
    if marker in text:
        print(f"[run-task] detected error marker: {marker}", file=sys.stderr)
        sys.exit(1)

if re.search(r'"payloads"\s*:\s*\[\s*\]\s*,\s*"meta"', text):
    print("[run-task] detected empty payload result", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PY
  then
    echo "error: result validation failed for ${job_name}" >&2
    exit 1
  fi
fi

echo "saved logs to results/${job_name}.txt"
