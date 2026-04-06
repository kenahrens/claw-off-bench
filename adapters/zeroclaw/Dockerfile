FROM birdxs/zeroclaw:latest AS zeroclaw-bin

FROM ubuntu:24.04

RUN mkdir -p /home/app /workspace && chown -R 1000:1000 /home/app /workspace

COPY --from=zeroclaw-bin /usr/local/bin/zeroclaw /usr/local/bin/zeroclaw
RUN printf '%s\n' '#!/bin/sh' 'set -eu' 'if [ "$#" -ge 2 ] && [ "$1" = "run" ]; then' '  shift' '  exec /usr/local/bin/zeroclaw agent -m "$*"' 'fi' 'exec /usr/local/bin/zeroclaw "$@"' > /usr/local/bin/zero-claw \
  && chmod +x /usr/local/bin/zero-claw

ENV HOME=/home/app
USER 1000
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/zero-claw"]
