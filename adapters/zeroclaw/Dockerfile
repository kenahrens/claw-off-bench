FROM birdxs/zeroclaw:latest AS zeroclaw-bin

FROM ubuntu:24.04

RUN mkdir -p /home/app /workspace && chown -R 1000:1000 /home/app /workspace

COPY --from=zeroclaw-bin /usr/local/bin/zeroclaw /usr/local/bin/zeroclaw
RUN printf '%s\n' '#!/bin/sh' 'set -eu' 'provider="${ZEROCLAW_DEFAULT_PROVIDER:-openrouter}"' 'model="${ZEROCLAW_DEFAULT_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}"' 'api_key="${ZEROCLAW_API_KEY:-${API_KEY:-${OPENROUTER_API_KEY:-}}}"' 'config_dir="${ZEROCLAW_CONFIG_DIR:-$HOME/.zeroclaw}"' 'mkdir -p "$config_dir"' '{' '  printf "default_provider = \"%s\"\\n" "$provider"' '  printf "default_model = \"%s\"\\n" "$model"' '  if [ -n "$api_key" ]; then printf "api_key = \"%s\"\\n" "$api_key"; fi' '} > "$config_dir/config.toml"' 'if [ "$#" -ge 2 ] && [ "$1" = "run" ]; then' '  shift' '  exec /usr/local/bin/zeroclaw --config-dir "$config_dir" agent -p "$provider" --model "$model" -m "$*"' 'fi' 'exec /usr/local/bin/zeroclaw --config-dir "$config_dir" "$@"' > /usr/local/bin/zero-claw \
  && chmod +x /usr/local/bin/zero-claw

ENV HOME=/home/app
USER 1000
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/zero-claw"]
