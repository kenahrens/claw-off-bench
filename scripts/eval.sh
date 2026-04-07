#!/usr/bin/env bash
set -euo pipefail

profile_file="${EVAL_PROFILE_FILE:-config/eval.env}"

if [[ ! -f "${profile_file}" ]]; then
  echo "error: evaluation profile not found: ${profile_file}" >&2
  exit 1
fi

while IFS= read -r line; do
  [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

  key="${line%%=*}"
  value="${line#*=}"

  if [[ -z "${!key+x}" ]]; then
    export "${key}=${value}"
  fi
done < "${profile_file}"

target="${EVAL_TARGET:-easy-matrix}"

if [[ "${target}" != "easy" && "${target}" != "easy-matrix" ]]; then
  echo "error: EVAL_TARGET must be easy or easy-matrix (got ${target})" >&2
  exit 1
fi

if [[ -z "${LLM_API_KEY:-}" && -n "${OPENROUTER_API_KEY:-}" ]]; then
  export LLM_API_KEY="${OPENROUTER_API_KEY}"
fi

if [[ -z "${LLM_API_KEY:-}" ]]; then
  echo "error: set OPENROUTER_API_KEY (or LLM_API_KEY) before running make eval" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  export GITHUB_TOKEN="chat-only-not-used"
fi

echo "[eval] profile=${profile_file} target=${target}"
make "${target}"
