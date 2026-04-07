#!/usr/bin/env bash
set -euo pipefail

namespace="${NAMESPACE:-claw-bench}"
daemon_name="${DAEMON_NAME:-zeroclaw-daemon}"
daemon_port="${DAEMON_PORT:-8787}"
local_port="${DAEMON_LOCAL_PORT:-18787}"
agent_image="${AGENT_IMAGE:-zeroclaw-adapter:latest}"
default_provider="${DEFAULT_PROVIDER:-openai}"
default_model="${DEFAULT_MODEL:-gpt-5-mini}"

export DAEMON_NAME="${daemon_name}" DAEMON_PORT="${daemon_port}" AGENT_IMAGE="${agent_image}" DEFAULT_PROVIDER="${default_provider}" DEFAULT_MODEL="${default_model}"

envsubst < k8s/templates/deployment-zeroclaw-daemon.yaml | kubectl apply -f -
envsubst < k8s/templates/service-zeroclaw-daemon.yaml | kubectl apply -f -

kubectl rollout status "deployment/${daemon_name}" -n "${namespace}" --timeout=180s

pod_name="$(kubectl get pods -n "${namespace}" -l app="${daemon_name}" -o jsonpath='{.items[0].metadata.name}')"
pair_code="$(kubectl logs "${pod_name}" -n "${namespace}" 2>&1 | perl -ne 'if(/X-Pairing-Code: ([0-9]+)/){print $1; exit}')"

if [[ -z "${pair_code}" ]]; then
  echo "error: unable to find daemon pairing code in pod logs" >&2
  exit 1
fi

kubectl port-forward -n "${namespace}" "pod/${pod_name}" "${local_port}:${daemon_port}" >/tmp/${daemon_name}-port-forward.log 2>&1 &
pf_pid=$!
trap 'kill ${pf_pid} >/dev/null 2>&1 || true' EXIT
sleep 2

pair_response="$(curl -sS -X POST "http://127.0.0.1:${local_port}/pair" -H "X-Pairing-Code: ${pair_code}")"
token="$(printf '%s' "${pair_response}" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("token", ""))')"

if [[ -z "${token}" ]]; then
  echo "error: failed to pair daemon. response: ${pair_response}" >&2
  exit 1
fi

kubectl create secret generic "${daemon_name}-auth" \
  -n "${namespace}" \
  --from-literal=bearer_token="${token}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "deployed ${daemon_name} and stored auth token in secret ${daemon_name}-auth"
