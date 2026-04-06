#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-claw-bench}"
ALLOW_PACKAGE_REGISTRIES="${ALLOW_PACKAGE_REGISTRIES:-false}"

domains=(
  "api.anthropic.com"
  "api.openai.com"
  "github.com"
  "api.github.com"
)

if [[ "${ALLOW_PACKAGE_REGISTRIES}" == "true" ]]; then
  domains+=("pypi.org" "registry.npmjs.org")
fi

if ! command -v dig >/dev/null 2>&1; then
  echo "error: dig is required to resolve allowlisted domains" >&2
  exit 1
fi

ips=()
for domain in "${domains[@]}"; do
  while IFS= read -r ip; do
    [[ -z "${ip}" ]] && continue
    ips+=("${ip}")
  done < <(dig +short A "${domain}")
done

if [[ "${#ips[@]}" -eq 0 ]]; then
  echo "error: no IPs resolved from allowlisted domains" >&2
  exit 1
fi

mapfile -t unique_ips < <(printf '%s\n' "${ips[@]}" | sort -u)

manifest="$(mktemp)"
trap 'rm -f "${manifest}"' EXIT

{
  cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: claw-egress-allowlist
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: claw-runner
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF

  for ip in "${unique_ips[@]}"; do
    cat <<EOF
    - to:
        - ipBlock:
            cidr: ${ip}/32
      ports:
        - protocol: TCP
          port: 443
EOF
  done
} > "${manifest}"

kubectl apply -f "${manifest}"
echo "applied claw-egress-allowlist in namespace ${NAMESPACE} (${#unique_ips[@]} IPs)"
