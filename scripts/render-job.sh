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

JOB_NAME="${AGENT_NAME}-${TASK_ID}-$(date +%s)"
export JOB_NAME AGENT_NAME AGENT_IMAGE TASK_ID TASK_INSTRUCTION AGENT_BIN AGENT_ACTION

if [[ -n "${AGENT_TEMPLATE:-}" ]]; then
  TEMPLATE="${AGENT_TEMPLATE}"
elif [[ "${AGENT_NAME}" == "zeroclaw" ]]; then
  TEMPLATE="k8s/templates/job-zeroclaw.yaml"
else
  TEMPLATE="k8s/templates/job.yaml"
fi

envsubst < "${TEMPLATE}"
