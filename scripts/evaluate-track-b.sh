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
fixture_snapshot_dir="$(mktemp -d)"

cleanup() {
  kctl delete pod "${eval_pod}" -n "${namespace}" --ignore-not-found >/dev/null 2>&1 || true
  rm -f "${manifest}"
  rm -rf "${fixture_snapshot_dir}"
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
run_log_path="${raw_results_dir}/${job_name}.txt"

workspace_fixture_dir="${fixture_snapshot_dir}/workspace-fixture"
mkdir -p "${workspace_fixture_dir}"
set +e
kctl cp -n "${namespace}" -c evaluator "${eval_pod}:/workspace/${fixture_dir}/." "${workspace_fixture_dir}" >/dev/null 2>&1
snapshot_exit_code=$?
set -e
if [[ "${snapshot_exit_code}" -ne 0 ]]; then
  echo "error: unable to snapshot workspace fixture ${fixture_dir} for ${job_name}" >&2
  exit 1
fi

python3 - "${job_name}" "${base_task_id}" "${fixture_dir}" "${workspace_fixture_dir}" "${run_log_path}" "${public_result}" "${hidden_result}" "${quality_result}" <<'PY'
import json
import re
import sys
from pathlib import Path

job_name, task_id, fixture_dir, workspace_fixture_dir, run_log_path, public_raw, hidden_raw, quality_raw = sys.argv[1:]
public = json.loads(public_raw)
hidden = json.loads(hidden_raw)
quality = json.loads(quality_raw)
checks = [public, hidden, quality]

score = sum(1 for c in checks if c["passed"])
max_score = len(checks)
passed = score == max_score
failed_checks = [c["name"] for c in checks if not c["passed"]]

log_text = ""
run_log = Path(run_log_path)
if run_log.exists():
    log_text = run_log.read_text(encoding="utf-8", errors="replace")

check_text = ""
for check in checks:
    check_path = Path(check["output_file"])
    if check_path.exists():
        check_text += "\n" + check_path.read_text(encoding="utf-8", errors="replace")

combined = f"{log_text}\n{check_text}"
contract_marker_present = "track_b_done" in combined.lower()
if not contract_marker_present:
  passed = False
  if "contract" not in failed_checks:
    failed_checks.append("contract")

local_fixture = Path(fixture_dir)
workspace_fixture = Path(workspace_fixture_dir)


def compare_fixture_state(local_root: Path, workspace_root: Path):
    result = {
        "local_exists": local_root.exists(),
        "workspace_exists": workspace_root.exists(),
        "changed_files": [],
        "src_changed": False,
        "immutable_modified": False,
        "outside_allowed_modified": False,
        "details": "",
    }

    if not local_root.exists() or not workspace_root.exists():
        result["details"] = "fixture directory missing in local baseline or workspace snapshot"
        return result

    def should_ignore(rel: str) -> bool:
        parts = rel.split("/")
        if any(part == "__pycache__" for part in parts):
            return True
        if rel.endswith(".pyc"):
            return True
        if any(part.startswith("._") for part in parts):
            return True
        return False

    local_files = {
        str(path.relative_to(local_root)): path
        for path in local_root.rglob("*")
        if path.is_file() and not should_ignore(str(path.relative_to(local_root)))
    }
    workspace_files = {
        str(path.relative_to(workspace_root)): path
        for path in workspace_root.rglob("*")
        if path.is_file() and not should_ignore(str(path.relative_to(workspace_root)))
    }

    all_files = sorted(set(local_files) | set(workspace_files))
    changed = []
    for rel in all_files:
        left = local_files.get(rel)
        right = workspace_files.get(rel)
        if left is None or right is None:
            changed.append(rel)
            continue
        if left.read_bytes() != right.read_bytes():
            changed.append(rel)

    result["changed_files"] = changed
    result["src_changed"] = any(rel.startswith("src/") for rel in changed)
    result["immutable_modified"] = any(
        rel.startswith("tests/") or rel.startswith("hidden_tests/") for rel in changed
    )
    result["outside_allowed_modified"] = any(not rel.startswith("src/") for rel in changed)

    if result["immutable_modified"]:
        result["details"] = "tests or hidden_tests were modified"
    elif result["outside_allowed_modified"]:
        result["details"] = "files outside src/ were modified"
    elif not result["src_changed"]:
        result["details"] = "no src/ file changes detected"

    return result


fixture_state = compare_fixture_state(local_fixture, workspace_fixture)
if not fixture_state["local_exists"] or not fixture_state["workspace_exists"]:
    passed = False
    if "contract" not in failed_checks:
        failed_checks.append("contract")
elif fixture_state["immutable_modified"] or fixture_state["outside_allowed_modified"] or not fixture_state["src_changed"]:
    passed = False
    if "contract" not in failed_checks:
        failed_checks.append("contract")


def classify_failure():
    text = combined.lower()
    if passed:
        return "", ""

    if not contract_marker_present:
        return "contract mismatch", "missing TRACK_B_DONE completion marker"

    if not fixture_state["local_exists"] or not fixture_state["workspace_exists"]:
        return "contract mismatch", "fixture snapshot/baseline missing during evaluation"

    if fixture_state["immutable_modified"]:
        return "contract mismatch", "tests or hidden_tests were modified"

    if fixture_state["outside_allowed_modified"]:
        return "contract mismatch", "files outside src/ were modified"

    if not fixture_state["src_changed"]:
        return "contract mismatch", "no src/ file changes detected"

    if re.search(r"authentication_error|invalid api key|incorrect api key|missing or placeholder", text):
        return "auth/config", "credential/auth failure marker in logs"

    if re.search(r"unsupported value|unsupported parameter|unsupported model|temperature", text):
        return "model-parameter incompatibility", "provider/model parameter mismatch"

    if any(c["exit_code"] == 124 for c in checks) or re.search(r"timed out|deadline exceeded|out of memory|resource exhaustion|oom", text):
        return "timeout/resource exhaustion", "evaluation timeout or resource exhaustion"

    if re.search(
        r"permission denied|eisdir|media store not configured|elevated is not available|missing required property|no such file or directory|failed to create temp file|failed to create directory|unable to modify",
        text,
    ):
        return "contract mismatch", "agent runtime/file tool contract mismatch"

    return "output-quality/validation failure", "public/hidden/quality gates did not fully pass"


failure_category, failure_detail = classify_failure()

payload = {
    "job_name": job_name,
    "task_id": task_id,
    "fixture_dir": fixture_dir,
    "gate": {
        "passed": passed,
        "score": score,
        "max_score": max_score,
    },
    "failure_category": failure_category,
    "failure_detail": failure_detail,
    "contract_marker_present": contract_marker_present,
    "fixture_state": fixture_state,
    "failed_checks": failed_checks,
    "checks": checks,
}

out_path = Path("results/raw") / f"{job_name}-trackb-eval.json"
out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(f"wrote {out_path}")
print(f"track-b gate: {'pass' if passed else 'fail'} ({score}/{max_score})")
sys.exit(0 if passed else 1)
PY
