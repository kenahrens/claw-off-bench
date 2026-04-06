FROM birdxs/zeroclaw:latest AS zeroclaw-bin

FROM ubuntu:24.04

RUN groupadd --system app && useradd --system --gid app --create-home app

COPY --from=zeroclaw-bin /usr/local/bin/zeroclaw /usr/local/bin/zeroclaw
RUN printf '%s\n' '#!/bin/sh' 'set -eu' 'if [ "$#" -ge 2 ] && [ "$1" = "run" ]; then' '  shift' '  exec /usr/local/bin/zeroclaw agent -m "$*"' 'fi' 'exec /usr/local/bin/zeroclaw "$@"' > /usr/local/bin/zero-claw \
  && chmod +x /usr/local/bin/zero-claw

USER app
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/zero-claw"]
