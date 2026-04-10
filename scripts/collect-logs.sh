#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kube.sh
source "${script_dir}/lib/kube.sh"

mkdir -p results/raw

collect_selector="${COLLECT_LABEL_SELECTOR:-app=claw-runner}"
collect_request_timeout="${COLLECT_REQUEST_TIMEOUT:-20s}"

if ! [[ "${collect_request_timeout}" =~ ^[0-9]+s$ ]]; then
  echo "error: COLLECT_REQUEST_TIMEOUT must use seconds format like 20s" >&2
  exit 1
fi

jobs="$(kctl get jobs -n claw-bench -l "${collect_selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [[ -z "${jobs}" ]]; then
  echo "no jobs found in claw-bench namespace for selector ${collect_selector}"
  exit 0
fi

while IFS= read -r job; do
  [[ -z "${job}" ]] && continue
  out_file="results/raw/${job}.txt"
  if [[ -f "${out_file}" ]]; then
    continue
  fi
  kctl logs "job/${job}" -n claw-bench --timestamps --pod-running-timeout=10s --request-timeout="${collect_request_timeout}" > "${out_file}" 2>/dev/null || true
done <<< "${jobs}"

echo "collected logs under results/raw/"
