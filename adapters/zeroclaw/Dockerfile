FROM birdxs/zeroclaw:latest AS zeroclaw-bin

FROM ubuntu:24.04

RUN mkdir -p /home/app /workspace && chown -R 1000:1000 /home/app /workspace

COPY --from=zeroclaw-bin /usr/local/bin/zeroclaw /usr/local/bin/zeroclaw
RUN printf '%s\n' '#!/bin/sh' 'set -eu' 'provider="${ZEROCLAW_DEFAULT_PROVIDER:-openai}"' 'model="${ZEROCLAW_DEFAULT_MODEL:-gpt-5-mini}"' 'api_key="${ZEROCLAW_API_KEY:-${API_KEY:-${OPENAI_API_KEY:-${OPENROUTER_API_KEY:-}}}}"' 'max_tool_iterations="${ZEROCLAW_MAX_TOOL_ITERATIONS:-40}"' 'approval_mode="${ZEROCLAW_APPROVAL_MODE:-default}"' 'config_dir="${ZEROCLAW_CONFIG_DIR:-$HOME/.zeroclaw}"' 'case "$approval_mode" in' '  default) auto_approve="[\"shell\", \"file_read\", \"memory_recall\", \"web_search_tool\", \"web_fetch\", \"calculator\", \"glob_search\", \"content_search\", \"image_info\", \"weather\"]" ;;' '  strict) auto_approve="[\"file_read\", \"memory_recall\", \"glob_search\", \"content_search\"]" ;;' '  none) auto_approve="[]" ;;' '  *) echo "error: unsupported ZEROCLAW_APPROVAL_MODE=$approval_mode" >&2; exit 1 ;;' 'esac' 'mkdir -p "$config_dir"' '{' '  printf "default_provider = \"%s\"\\n" "$provider"' '  printf "default_model = \"%s\"\\n" "$model"' '  if [ -n "$api_key" ]; then printf "api_key = \"%s\"\\n" "$api_key"; fi' '  printf "[agent]\\n"' '  printf "max_tool_iterations = %s\\n" "$max_tool_iterations"' '  printf "[autonomy]\\n"' '  printf "auto_approve = %s\\n" "$auto_approve"' '} > "$config_dir/config.toml"' 'chmod 600 "$config_dir/config.toml"' 'if [ "$#" -ge 2 ] && [ "$1" = "run" ]; then' '  shift' '  exec /usr/local/bin/zeroclaw --config-dir "$config_dir" agent -p "$provider" --model "$model" -m "$*"' 'fi' 'exec /usr/local/bin/zeroclaw --config-dir "$config_dir" "$@"' > /usr/local/bin/zero-claw \
  && chmod +x /usr/local/bin/zero-claw

ENV HOME=/home/app
USER 1000
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/zero-claw"]
