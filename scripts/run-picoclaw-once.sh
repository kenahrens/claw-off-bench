#!/usr/bin/env sh
set -eu

prompt="${TASK_PROMPT:-}"
provider="${DEFAULT_PROVIDER:-openai}"
model="${DEFAULT_MODEL:-gpt-5-mini}"
api_key="${LLM_API_KEY:-}"
temperature="${PICOCLAW_TEMPERATURE:-0}"

if [ -z "${prompt}" ]; then
  echo "error: TASK_PROMPT is required" >&2
  exit 1
fi

if [ -z "${api_key}" ]; then
  echo "error: LLM_API_KEY is required" >&2
  exit 1
fi

case "${temperature}" in
  0|0.0|1|1.0)
    ;;
  *)
    echo "error: PICOCLAW_TEMPERATURE must be 0, 0.0, 1, or 1.0" >&2
    exit 1
    ;;
esac

api_base="https://api.openai.com/v1"
if [ "${provider}" = "openrouter" ]; then
  api_base="https://openrouter.ai/api/v1"
fi

mkdir -p /home/picoclaw/.picoclaw
printf '{"agents":{"defaults":{"model_name":"bench","temperature":%s}},"model_list":[{"model_name":"bench","model":"%s/%s","api_key":"%s","api_base":"%s","temperature":%s}]}' \
  "${temperature}" "${provider}" "${model}" "${api_key}" "${api_base}" "${temperature}" > /home/picoclaw/.picoclaw/config.json

exec picoclaw agent --model bench -m "${prompt}"
