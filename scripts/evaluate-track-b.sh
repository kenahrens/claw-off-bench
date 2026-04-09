#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kube.sh
source "${script_dir}/lib/kube.sh"

task_id="${TASK_ID:?TASK_ID is required}"
job_name="${JOB_NAME:?JOB_NAME is required}"
fixtures_file="${TRACK_B_FIXTURES_FILE:-config/track-b-fixtures.csv}"
namespace="${NAMESPACE:-claw-bench}"
workspace_pvc="${WORKSPACE_PVC_NAME:-claw-workspace}"
evaluator_image="${TRACK_B_EVAL_IMAGE:-python:3.12-alpine}"
run_timeout="${TRACK_B_EVAL_TIMEOUT:-180s}"
raw_results_dir="results/raw"

mkdir -p "${raw_results_dir}"

if [[ ! -f "${fixtures_file}" ]]; then
  echo "error: Track B fixtures file not found: ${fixtures_file}" >&2
  exit 1
fi

if ! [[ "${run_timeout}" =~ ^[0-9]+s$ ]]; then
  echo "error: TRACK_B_EVAL_TIMEOUT must use seconds format like 180s" >&2
  exit 1
fi

base_task_id="${task_id}"
if [[ "${task_id}" =~ ^([A-Za-z0-9-]+)r[0-9]+$ ]]; then
  base_task_id="${BASH_REMATCH[1]}"
fi

fixture_row="$(awk -F',' -v task="${base_task_id}" 'NR > 1 && $1 == task { print $0; exit }' "${fixtures_file}")"
if [[ -z "${fixture_row}" ]]; then
  echo "error: no Track B fixture mapping for task ${base_task_id} in ${fixtures_file}" >&2
  exit 1
fi

IFS=',' read -r _mapped_task fixture_dir public_check hidden_check quality_check <<< "${fixture_row}"

for value in "${fixture_dir}" "${public_check}" "${hidden_check}" "${quality_check}"; do
  if [[ -z "${value}" ]]; then
    echo "error: invalid fixture row for ${base_task_id} in ${fixtures_file}" >&2
    exit 1
  fi
done

eval_pod="trackb-eval-${job_name}"
manifest="$(mktemp)"

cleanup() {
  kctl delete pod "${eval_pod}" -n "${namespace}" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "${manifest}"
}
trap cleanup EXIT

cat > "${manifest}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${eval_pod}
  namespace: ${namespace}
spec:
  restartPolicy: Never
  containers:
    - name: evaluator
      image: ${evaluator_image}
      command: ["/bin/sh", "-lc", "sleep 3600"]
      volumeMounts:
        - name: workspace
          mountPath: /workspace
  volumes:
    - name: workspace
      persistentVolumeClaim:
        claimName: ${workspace_pvc}
EOF

kctl apply -f "${manifest}" >/dev/null
kctl wait --for=condition=Ready --timeout=120s "pod/${eval_pod}" -n "${namespace}" >/dev/null

run_check() {
  local check_name="$1"
  local check_cmd="$2"
  local output_file="${raw_results_dir}/${job_name}-trackb-${check_name}.txt"
  local started="$(python3 - <<'PY'
import time
print(time.time())
PY
)"

  set +e
  kctl exec "${eval_pod}" -n "${namespace}" -- /bin/sh -lc "cd /workspace/${fixture_dir} && ${check_cmd}" > "${output_file}" 2>&1
  local exit_code=$?
  set -e

  local ended="$(python3 - <<'PY'
import time
print(time.time())
PY
)"

  python3 - "$check_name" "$check_cmd" "$output_file" "$exit_code" "$started" "$ended" <<'PY'
import json
import sys

name, command, output_path, code, started, ended = sys.argv[1:]
payload = {
    "name": name,
    "command": command,
    "output_file": output_path,
    "exit_code": int(code),
    "passed": int(code) == 0,
    "duration_seconds": round(float(ended) - float(started), 3),
}
print(json.dumps(payload))
PY
}

public_result="$(run_check public "timeout ${run_timeout} ${public_check}")"
hidden_result="$(run_check hidden "timeout ${run_timeout} ${hidden_check}")"
quality_result="$(run_check quality "timeout ${run_timeout} ${quality_check}")"

python3 - "${job_name}" "${base_task_id}" "${fixture_dir}" "${public_result}" "${hidden_result}" "${quality_result}" <<'PY'
import json
import sys
from pathlib import Path

job_name, task_id, fixture_dir, public_raw, hidden_raw, quality_raw = sys.argv[1:]
public = json.loads(public_raw)
hidden = json.loads(hidden_raw)
quality = json.loads(quality_raw)
checks = [public, hidden, quality]

score = sum(1 for c in checks if c["passed"])
max_score = len(checks)
passed = score == max_score

payload = {
    "job_name": job_name,
    "task_id": task_id,
    "fixture_dir": fixture_dir,
    "gate": {
        "passed": passed,
        "score": score,
        "max_score": max_score,
    },
    "checks": checks,
}

out_path = Path("results/raw") / f"{job_name}-trackb-eval.json"
out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(f"wrote {out_path}")
print(f"track-b gate: {'pass' if passed else 'fail'} ({score}/{max_score})")
sys.exit(0 if passed else 1)
PY
