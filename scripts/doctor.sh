#!/usr/bin/env bash
set -euo pipefail

profile_file="${EVAL_PROFILE_FILE:-config/eval.env}"

if [[ -f "${profile_file}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    if [[ -z "${!key+x}" ]]; then
      export "${key}=${value}"
    fi
  done < "${profile_file}"
fi

doctor_mode="${DOCTOR_MODE:-full}"
agent_filter="${AGENT_FILTER:-}"
require_github_token="${REQUIRE_GITHUB_TOKEN:-false}"
report_file="results/matrix-preflight.tsv"

if [[ "${doctor_mode}" == "full5" ]]; then
  doctor_mode="full"
fi

if ! [[ "${doctor_mode}" =~ ^(full|available)$ ]]; then
  echo "error: DOCTOR_MODE must be full or available" >&2
  exit 1
fi

if ! [[ "${require_github_token}" =~ ^(true|false)$ ]]; then
  echo "error: REQUIRE_GITHUB_TOKEN must be true or false" >&2
  exit 1
fi

blockers=()

echo "[doctor] mode=${doctor_mode}"

if ! kubectl config current-context >/dev/null 2>&1; then
  blockers+=("kubectl context is not configured")
else
  context="$(kubectl config current-context)"
  echo "[doctor] kubectl context=${context}"
fi

if ! REQUIRE_GITHUB_TOKEN="${require_github_token}" ./scripts/check-cluster-secrets.sh >/tmp/doctor-secrets.log 2>&1; then
  blockers+=("cluster secret check failed: $(tr '\n' ' ' < /tmp/doctor-secrets.log | sed -E 's/[[:space:]]+/ /g')")
else
  echo "[doctor] cluster secrets: ok"
fi

if [[ "${doctor_mode}" == "full" && -n "${agent_filter}" ]]; then
  blockers+=("DOCTOR_MODE=full requires AGENT_FILTER to be empty")
fi

preflight_filter="${agent_filter}"
if [[ "${doctor_mode}" == "full" ]]; then
  preflight_filter=""
fi

if AGENT_FILTER="${preflight_filter}" MATRIX_STRICT=false PREFLIGHT_ONLY=true ./scripts/run-matrix.sh >/tmp/doctor-preflight.log 2>&1; then
  echo "[doctor] matrix preflight: completed"
else
  blockers+=("matrix preflight failed: $(tr '\n' ' ' < /tmp/doctor-preflight.log | sed -E 's/[[:space:]]+/ /g')")
fi

if [[ -f "${report_file}" ]]; then
  selected_count="$(awk -F'\t' 'NR > 1 { count++ } END { print count + 0 }' "${report_file}")"
  unavailable_count="$(awk -F'\t' 'NR > 1 && $3 == "unavailable" { count++ } END { print count + 0 }' "${report_file}")"
  unavailable_agents="$(awk -F'\t' 'NR > 1 && $3 == "unavailable" { print $1 }' "${report_file}" | paste -sd ',' -)"

  echo "[doctor] preflight selected=${selected_count} unavailable=${unavailable_count}"

  configured_count="$(awk -F',' 'NR > 1 { count++ } END { print count + 0 }' config/agents.csv)"

  if [[ "${doctor_mode}" == "full" && "${selected_count}" -ne "${configured_count}" ]]; then
    blockers+=("full comparison requires ${configured_count} configured agents, found ${selected_count} in preflight report")
  fi

  if [[ "${unavailable_count}" -gt 0 ]]; then
    blockers+=("unavailable agent images: ${unavailable_agents}")
  fi
else
  blockers+=("preflight report missing: ${report_file}")
fi

if [[ "${#blockers[@]}" -eq 0 ]]; then
  echo "doctor: no blockers detected"
  exit 0
fi

echo "doctor: blockers detected"
for blocker in "${blockers[@]}"; do
  echo "- ${blocker}"
done

exit 1
