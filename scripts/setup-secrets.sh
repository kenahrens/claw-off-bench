#!/usr/bin/env bash
set -euo pipefail

namespace="${NAMESPACE:-claw-bench}"
llm_api_key="${LLM_API_KEY:-${OPENROUTER_API_KEY:-}}"
github_token="${GITHUB_TOKEN:-}"

if [[ -z "${llm_api_key}" ]]; then
  echo "error: set LLM_API_KEY (or OPENROUTER_API_KEY) before running setup-secrets" >&2
  exit 1
fi

if [[ -z "${github_token}" ]]; then
  echo "error: set GITHUB_TOKEN before running setup-secrets" >&2
  exit 1
fi

if [[ "${llm_api_key}" == "dummy" || "${llm_api_key}" == "REPLACE_ME" ]]; then
  echo "error: LLM_API_KEY cannot be a placeholder value" >&2
  exit 1
fi

if [[ "${github_token}" == "dummy" || "${github_token}" == "REPLACE_ME" ]]; then
  echo "error: GITHUB_TOKEN cannot be a placeholder value" >&2
  exit 1
fi

kubectl create secret generic claw-secrets \
  -n "${namespace}" \
  --from-literal=llm_api_key="${llm_api_key}" \
  --from-literal=github_token="${github_token}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "applied claw-secrets in namespace ${namespace}"
