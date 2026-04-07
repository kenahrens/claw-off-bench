#!/usr/bin/env bash
set -euo pipefail

namespace="${NAMESPACE:-claw-bench}"
require_github_token="${REQUIRE_GITHUB_TOKEN:-false}"

if ! [[ "${require_github_token}" =~ ^(true|false)$ ]]; then
  echo "error: REQUIRE_GITHUB_TOKEN must be true or false" >&2
  exit 1
fi

llm_key_b64="$(kubectl get secret claw-secrets -n "${namespace}" -o jsonpath='{.data.llm_api_key}' 2>/dev/null || true)"
github_token_b64="$(kubectl get secret claw-secrets -n "${namespace}" -o jsonpath='{.data.github_token}' 2>/dev/null || true)"

if [[ -z "${llm_key_b64}" || "${llm_key_b64}" == "ZHVtbXk=" || "${llm_key_b64}" == "UkVQTEFDRV9NRQ==" ]]; then
  echo "error: secret claw-secrets.llm_api_key missing or placeholder in namespace ${namespace}" >&2
  exit 1
fi

if [[ "${require_github_token}" == "true" ]]; then
  if [[ -z "${github_token_b64}" || "${github_token_b64}" == "ZHVtbXk=" || "${github_token_b64}" == "UkVQTEFDRV9NRQ==" ]]; then
    echo "error: secret claw-secrets.github_token missing or placeholder in namespace ${namespace}" >&2
    exit 1
  fi
fi

echo "verified claw-secrets in namespace ${namespace}"
