#!/usr/bin/env bash
set -euo pipefail

: "${AGENT_NAME:?AGENT_NAME is required}"
: "${AGENT_IMAGE:?AGENT_IMAGE is required}"
: "${TASK_ID:?TASK_ID is required}"
: "${TASK_INSTRUCTION:?TASK_INSTRUCTION is required}"

if [[ -z "${AGENT_BIN:-}" ]]; then
  if [[ "${AGENT_NAME}" == "zeroclaw" ]]; then
    AGENT_BIN="zero-claw"
  else
    AGENT_BIN="claw-cli"
  fi
fi

AGENT_ACTION="${AGENT_ACTION:-run}"

if [[ "${AGENT_NAME}" == "zeroclaw" ]]; then
  DEFAULT_PROVIDER="${DEFAULT_PROVIDER:-openai}"
  DEFAULT_MODEL="${DEFAULT_MODEL:-gpt-5-mini}"
else
  DEFAULT_PROVIDER="${DEFAULT_PROVIDER:-}"
  DEFAULT_MODEL="${DEFAULT_MODEL:-}"
fi

sanitize_name_component() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9.-]+/-/g; s/^[^a-z0-9]+//; s/[^a-z0-9]+$//; s/-+/-/g; s/\.+/./g'
}

safe_agent_name="$(sanitize_name_component "${AGENT_NAME}")"
safe_task_id="$(sanitize_name_component "${TASK_ID}")"

if [[ -z "${safe_agent_name}" || -z "${safe_task_id}" ]]; then
  echo "error: AGENT_NAME and TASK_ID must contain at least one alphanumeric character" >&2
  exit 1
fi

JOB_NAME="${safe_agent_name}-${safe_task_id}-$(date +%s)"
export JOB_NAME AGENT_NAME AGENT_IMAGE TASK_ID TASK_INSTRUCTION AGENT_BIN AGENT_ACTION DEFAULT_PROVIDER DEFAULT_MODEL

if [[ -n "${AGENT_TEMPLATE:-}" ]]; then
  TEMPLATE="${AGENT_TEMPLATE}"
elif [[ "${AGENT_NAME}" == "zeroclaw" ]]; then
  TEMPLATE="k8s/templates/job-zeroclaw.yaml"
else
  TEMPLATE="k8s/templates/job.yaml"
fi

envsubst < "${TEMPLATE}"
