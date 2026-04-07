#!/usr/bin/env bash
set -euo pipefail

echo "[validate] shell syntax"
bash -n scripts/*.sh

echo "[validate] python syntax"
python3 -m py_compile scripts/*.py

echo "[validate] config integrity"
python3 - <<'PY'
import csv
import os
import subprocess
import sys
from pathlib import Path

root = Path(".")
agents_path = root / "config/agents.csv"
caps_path = root / "config/agents-capabilities.csv"
safety_path = root / "config/agents-safety.csv"

for path in (agents_path, caps_path, safety_path):
    if not path.exists():
        raise SystemExit(f"error: missing required config file: {path}")

with agents_path.open(newline="", encoding="utf-8") as f:
    agents_rows = list(csv.DictReader(f))
with caps_path.open(newline="", encoding="utf-8") as f:
    caps_rows = list(csv.DictReader(f))
with safety_path.open(newline="", encoding="utf-8") as f:
    safety_rows = list(csv.DictReader(f))

def agent_set(rows):
    return {r["agent"].strip() for r in rows if r.get("agent", "").strip()}

agents = agent_set(agents_rows)
caps = agent_set(caps_rows)
safety = agent_set(safety_rows)

if not agents:
    raise SystemExit("error: config/agents.csv has no agents")

if agents != caps:
    raise SystemExit(f"error: agents mismatch between agents.csv and agents-capabilities.csv: {agents ^ caps}")

if agents != safety:
    raise SystemExit(f"error: agents mismatch between agents.csv and agents-safety.csv: {agents ^ safety}")

for row in agents_rows:
    agent = row["agent"].strip()
    template = row["template"].strip()
    image = row["image"].strip()
    agent_bin = row["bin"].strip()
    if not template or not Path(template).exists():
        raise SystemExit(f"error: invalid template for {agent}: {template}")
    if not image:
        raise SystemExit(f"error: missing image for {agent}")
    if not agent_bin:
        raise SystemExit(f"error: missing bin for {agent}")

for row in safety_rows:
    agent = row["agent"].strip()
    wait_timeout = row["wait_timeout"].strip()
    approval_mode = row["approval_mode"].strip()
    max_iter = row["max_tool_iterations"].strip()
    cpu_request = row["cpu_request"].strip()
    cpu_limit = row["cpu_limit"].strip()
    memory_request = row["memory_request"].strip()
    memory_limit = row["memory_limit"].strip()
    if not wait_timeout:
        raise SystemExit(f"error: missing wait_timeout in agents-safety.csv for {agent}")
    if approval_mode not in {"default", "strict", "none"}:
        raise SystemExit(f"error: invalid approval_mode in agents-safety.csv for {agent}: {approval_mode}")
    if max_iter and (not max_iter.isdigit() or int(max_iter) < 1):
        raise SystemExit(f"error: invalid max_tool_iterations in agents-safety.csv for {agent}: {max_iter}")
    if not cpu_request or not cpu_limit or not memory_request or not memory_limit:
        raise SystemExit(f"error: missing resource policy in agents-safety.csv for {agent}")

for row in agents_rows:
    env = os.environ.copy()
    env.update(
        {
            "AGENT_NAME": row["agent"].strip(),
            "AGENT_IMAGE": row["image"].strip(),
            "AGENT_TEMPLATE": row["template"].strip(),
            "AGENT_BIN": row["bin"].strip(),
            "TASK_ID": "VALIDATE",
            "TASK_INSTRUCTION": "Validation canary",
        }
    )
    proc = subprocess.run(["./scripts/render-job.sh"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"error: render-job failed for {row['agent'].strip()}: {proc.stderr.strip()}")

print("config integrity ok")
PY

echo "[validate] tasks file"
task_count="$(awk '/^[[:space:]]*-[[:space:]]id:/{count++} END{print count+0}' tasks/tasks.yaml)"
if [[ "${task_count}" -lt 1 ]]; then
  echo "error: no tasks found in tasks/tasks.yaml" >&2
  exit 1
fi

echo "validate passed"
