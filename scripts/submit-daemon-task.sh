#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kube.sh
source "${script_dir}/lib/kube.sh"

IFS=$'\t' read -r resolved_task_id resolved_task_instruction < <(
  TASK_REF="${TASK_REF:-}" TASK_ID="${TASK_ID:-}" TASK_INSTRUCTION="${TASK_INSTRUCTION:-}" ./scripts/resolve-task.sh
)

namespace="${NAMESPACE:-claw-bench}"
daemon_name="${DAEMON_NAME:-zeroclaw-daemon}"
daemon_port="${DAEMON_PORT:-8787}"
local_port="${DAEMON_LOCAL_PORT:-18787}"

token_b64="$(kctl get secret "${daemon_name}-auth" -n "${namespace}" -o jsonpath='{.data.bearer_token}' 2>/dev/null || true)"
if [[ -z "${token_b64}" ]]; then
  echo "error: daemon auth secret ${daemon_name}-auth not found; run ./scripts/deploy-daemon.sh first" >&2
  exit 1
fi

token="$(printf '%s' "${token_b64}" | base64 --decode)"
payload="$(TASK_INSTRUCTION="${resolved_task_instruction}" python3 -c 'import json,os; print(json.dumps({"message": os.environ["TASK_INSTRUCTION"]}))')"

pod_name="$(kctl get pods -n "${namespace}" -l app="${daemon_name}" -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "${pod_name}" ]]; then
  echo "error: no daemon pod found for ${daemon_name}; run ./scripts/deploy-daemon.sh first" >&2
  exit 1
fi

kctl port-forward -n "${namespace}" "pod/${pod_name}" "${local_port}:${daemon_port}" >/tmp/${daemon_name}-port-forward.log 2>&1 &
pf_pid=$!
trap 'kill ${pf_pid} >/dev/null 2>&1 || true' EXIT
sleep 2

response="$(curl -sS -X POST "http://127.0.0.1:${local_port}/webhook" \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  -d "${payload}")"

mkdir -p results/raw
task_suffix="$(printf '%s' "${resolved_task_id}" | tr '[:upper:]' '[:lower:]')"
out_file="results/raw/${daemon_name}-${task_suffix}-daemon-$(date +%s).json"
printf '%s\n' "${response}" > "${out_file}"

echo "saved daemon response to ${out_file}"
