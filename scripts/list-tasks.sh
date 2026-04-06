#!/usr/bin/env bash
set -euo pipefail

awk '
  BEGIN { idx = 0 }
  /^[[:space:]]*-[[:space:]]id:/ {
    id = $3
    next
  }
  /^[[:space:]]*instruction:/ {
    idx += 1
    line = $0
    sub(/^[^:]*:[[:space:]]*/, "", line)
    printf "TASK_%d\t%s\t%s\n", idx, id, line
  }
' tasks/tasks.yaml
