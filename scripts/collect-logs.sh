#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kube.sh
source "${script_dir}/lib/kube.sh"

mkdir -p results/raw

jobs="$(kctl get jobs -n claw-bench -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [[ -z "${jobs}" ]]; then
  echo "no jobs found in claw-bench namespace"
  exit 0
fi

while IFS= read -r job; do
  [[ -z "${job}" ]] && continue
  kctl logs "job/${job}" -n claw-bench --timestamps > "results/raw/${job}.txt" || true
done <<< "${jobs}"

echo "collected logs under results/raw/"
