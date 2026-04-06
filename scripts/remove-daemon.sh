#!/usr/bin/env bash
set -euo pipefail

namespace="${NAMESPACE:-claw-bench}"
daemon_name="${DAEMON_NAME:-zeroclaw-daemon}"

kubectl delete deployment "${daemon_name}" -n "${namespace}" --ignore-not-found >/dev/null
kubectl delete service "${daemon_name}" -n "${namespace}" --ignore-not-found >/dev/null
kubectl delete secret "${daemon_name}-auth" -n "${namespace}" --ignore-not-found >/dev/null

echo "removed daemon resources for ${daemon_name}"
