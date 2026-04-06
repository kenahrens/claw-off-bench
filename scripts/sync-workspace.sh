#!/usr/bin/env bash
set -euo pipefail

namespace="${NAMESPACE:-claw-bench}"
pvc_name="${WORKSPACE_PVC_NAME:-claw-workspace}"
pod_name="workspace-sync-$(date +%s)"

manifest="$(mktemp)"
trap 'rm -f "${manifest}"' EXIT

cat > "${manifest}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${namespace}
spec:
  restartPolicy: Never
  containers:
    - name: sync
      image: alpine:3.20
      command: ["/bin/sh", "-lc", "sleep 3600"]
      volumeMounts:
        - name: workspace
          mountPath: /workspace
  volumes:
    - name: workspace
      persistentVolumeClaim:
        claimName: ${pvc_name}
EOF

kubectl apply -f "${manifest}" >/dev/null

cleanup() {
  kubectl delete pod "${pod_name}" -n "${namespace}" --ignore-not-found >/dev/null 2>&1 || true
}
trap 'cleanup; rm -f "${manifest}"' EXIT

kubectl wait --for=condition=Ready --timeout=120s "pod/${pod_name}" -n "${namespace}" >/dev/null

tar \
  --exclude='.git' \
  --exclude='results' \
  --exclude='.env' \
  --exclude='.env.*' \
  -cf - . | kubectl exec -i "${pod_name}" -n "${namespace}" -- /bin/sh -lc "rm -rf /workspace/* /workspace/.[!.]* /workspace/..?* 2>/dev/null || true; tar -xf - -C /workspace"

echo "synced repository contents to pvc ${pvc_name} in namespace ${namespace}"
