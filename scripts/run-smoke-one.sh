#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kube.sh
source "${script_dir}/lib/kube.sh"

agent_name="${AGENT_NAME:?AGENT_NAME is required}"
provider="${SMOKE_PROVIDER:-openai}"
prompt="${SMOKE_PROMPT:-Reply with exactly: HELLO_WORLD}"
wait_timeout="${SMOKE_WAIT_TIMEOUT:-180s}"

case "${provider}" in
  openai)
    model_default="gpt-4o-mini"
    require_openai_key="true"
    require_anthropic_key="false"
    ;;
  anthropic)
    model_default="claude-3-5-sonnet-latest"
    require_openai_key="false"
    require_anthropic_key="true"
    ;;
  ollama)
    model_default="llama3.1:8b"
    require_openai_key="false"
    require_anthropic_key="false"
    ;;
  *)
    echo "error: unsupported SMOKE_PROVIDER=${provider}; use openai, anthropic, or ollama" >&2
    exit 1
    ;;
esac

model="${SMOKE_MODEL:-${model_default}}"
task_id="${SMOKE_TASK_ID:-hello-${provider}}"
resource_memory_request="${RESOURCE_MEMORY_REQUEST:-}"
resource_memory_limit="${RESOURCE_MEMORY_LIMIT:-}"

if [[ "${agent_name}" == "openclaw" ]]; then
  resource_memory_request="${resource_memory_request:-2Gi}"
  resource_memory_limit="${resource_memory_limit:-2Gi}"
fi

IFS=$'\t' read -r agent_image agent_template agent_bin < <(
  AGENT_NAME_LOOKUP="${agent_name}" python3 - <<'PY'
import csv
import os
import sys

agent = os.environ["AGENT_NAME_LOOKUP"]
with open("config/agents.csv", newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        if row["agent"].strip() == agent:
            print("\t".join([row["image"].strip(), row["template"].strip(), row["bin"].strip()]))
            sys.exit(0)
print(f"agent '{agent}' not found in config/agents.csv", file=sys.stderr)
sys.exit(1)
PY
)

echo "[smoke-one] agent=${agent_name} provider=${provider} model=${model}"

REQUIRE_OPENAI_KEY="${require_openai_key}" REQUIRE_ANTHROPIC_KEY="${require_anthropic_key}" ./scripts/check-cluster-secrets.sh

kctl delete jobs -n claw-bench -l app=claw-runner --ignore-not-found >/dev/null || true
kctl delete pods -n claw-bench -l app=claw-runner --ignore-not-found >/dev/null || true

AGENT_NAME="${agent_name}" \
AGENT_IMAGE="${agent_image}" \
AGENT_TEMPLATE="${agent_template}" \
AGENT_BIN="${agent_bin}" \
DEFAULT_PROVIDER="${provider}" \
DEFAULT_MODEL="${model}" \
RESOURCE_MEMORY_REQUEST="${resource_memory_request}" \
RESOURCE_MEMORY_LIMIT="${resource_memory_limit}" \
TASK_ID="${task_id}" \
TASK_INSTRUCTION="${prompt}" \
WAIT_TIMEOUT="${wait_timeout}" \
REQUIRE_GITHUB_TOKEN=false \
./scripts/run-task.sh

latest_log="$(AGENT_NAME_LOOKUP="${agent_name}" TASK_ID_LOOKUP="${task_id}" python3 - <<'PY'
import glob
import os

agent = os.environ["AGENT_NAME_LOOKUP"]
task_id = os.environ["TASK_ID_LOOKUP"]
matches = glob.glob(f"results/{agent}-{task_id}-*.txt")
if not matches:
    matches = glob.glob(f"results/raw/{agent}-{task_id}-*.txt")
if not matches:
    print("")
else:
    matches.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    print(matches[0])
PY
)"

if [[ -z "${latest_log}" ]]; then
  echo "error: no log file found for ${agent_name} ${task_id}" >&2
  exit 1
fi

LOG_PATH="${latest_log}" PROMPT_TEXT="${prompt}" python3 - <<'PY'
import os
import re
import sys

path = os.environ["LOG_PATH"]
prompt = os.environ["PROMPT_TEXT"]
text = open(path, encoding="utf-8", errors="replace").read()

hard_fail_markers = [
    "authentication_error",
    "Invalid API key",
    "LLM call failed",
    "error processing message",
    "Unsupported value: 'temperature'",
]
for marker in hard_fail_markers:
    if marker in text:
        print(f"[smoke-one] blocked ({marker}) log={path}")
        sys.exit(2)

sanitized = text.replace(prompt, "")
if re.search(r"(^|[^A-Z0-9_])HELLO_WORLD([^A-Z0-9_]|$)", sanitized):
    print(f"[smoke-one] ready log={path}")
    sys.exit(0)

print(f"[smoke-one] blocked (hello response missing) log={path}")
sys.exit(2)
PY
