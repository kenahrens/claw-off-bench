#!/usr/bin/env python3
import csv
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESULTS_DIR = ROOT / "results"
AGENTS_FILE = ROOT / "config" / "agents.csv"
PREFLIGHT_FILE = RESULTS_DIR / "matrix-preflight.tsv"
OUT_JSON = RESULTS_DIR / "portability-sweep.json"
OUT_TSV = RESULTS_DIR / "portability-sweep.tsv"


def parse_filter(value):
    if not value:
        return set()
    return {item.strip() for item in value.split(",") if item.strip()}


def run(cmd, env=None):
    return subprocess.run(
        cmd,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def load_agents(selected):
    with AGENTS_FILE.open(newline="", encoding="utf-8") as f:
        rows = [row for row in csv.DictReader(f)]
    if selected:
        rows = [row for row in rows if row.get("agent", "").strip() in selected]
    return rows


def load_preflight():
    rows = {}
    if not PREFLIGHT_FILE.exists():
        return rows
    with PREFLIGHT_FILE.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            agent = row.get("agent", "").strip()
            if not agent:
                continue
            rows[agent] = {
                "status": row.get("status", "unknown").strip() or "unknown",
                "reason": row.get("reason", "").strip(),
                "image": row.get("image", "").strip(),
            }
    return rows


def classify_failure(text):
    checks = [
        (
            "auth/config",
            [
                r"authentication_error",
                r"invalid api key",
                r"incorrect api key",
                r"missing or placeholder",
                r"cluster secret check failed",
                r"no preflight row",
                r"image unavailable",
                r"pull access denied",
                r"manifest unknown",
            ],
        ),
        (
            "model-parameter incompatibility",
            [
                r"unsupported value",
                r"unsupported parameter",
                r"unsupported model",
                r"temperature",
            ],
        ),
        (
            "timeout/resource exhaustion",
            [
                r"timed out",
                r"deadline exceeded",
                r"out of memory",
                r"reached heap limit",
                r"oom",
                r"evicted",
            ],
        ),
        (
            "contract mismatch",
            [
                r"executable file not found",
                r"command not found",
                r"unsupported smoke_provider",
                r"agent '.*' not found",
                r"missing bin/template",
            ],
        ),
        (
            "output-quality/validation failure",
            [
                r"hello response missing",
                r"result validation failed",
                r"\[smoke-one\] blocked",
                r"detected empty payload result",
            ],
        ),
    ]

    for label, patterns in checks:
        for pattern in patterns:
            if re.search(pattern, text, flags=re.IGNORECASE):
                return label

    if re.search(r"\berror\b|\bfailed\b", text, flags=re.IGNORECASE):
        return "output-quality/validation failure"
    return "output-quality/validation failure"


def summarize(records):
    by_provider = {}
    by_category = {}
    for rec in records:
        provider = rec["provider"]
        by_provider.setdefault(provider, {"total": 0, "pass": 0, "fail": 0})
        by_provider[provider]["total"] += 1
        if rec["status"] == "pass":
            by_provider[provider]["pass"] += 1
        else:
            by_provider[provider]["fail"] += 1
            key = rec["failure_category"]
            by_category[key] = by_category.get(key, 0) + 1

    return {
        "provider_totals": by_provider,
        "failure_category_totals": by_category,
    }


def main():
    RESULTS_DIR.mkdir(exist_ok=True)

    selected_agents = parse_filter(os.environ.get("AGENT_FILTER", ""))
    providers = [
        p.strip()
        for p in os.environ.get("PORTABILITY_PROVIDERS", "openai,anthropic").split(",")
        if p.strip()
    ]
    attempts = int(os.environ.get("PORTABILITY_ATTEMPTS", "1"))
    wait_timeout = os.environ.get("PORTABILITY_WAIT_TIMEOUT", "180s")
    prompt = os.environ.get("PORTABILITY_PROMPT", "Reply with exactly: HELLO_WORLD")

    if attempts < 1:
        raise SystemExit("error: PORTABILITY_ATTEMPTS must be >= 1")

    if not providers:
        raise SystemExit(
            "error: PORTABILITY_PROVIDERS must contain at least one provider"
        )

    agents = load_agents(selected_agents)
    if not agents:
        raise SystemExit("error: no agents selected for portability sweep")

    preflight_env = os.environ.copy()
    preflight_env["PREFLIGHT_ONLY"] = "true"
    if selected_agents:
        preflight_env["AGENT_FILTER"] = ",".join(sorted(selected_agents))
    preflight_proc = run(["./scripts/run-matrix.sh"], env=preflight_env)

    preflight_rows = load_preflight()
    records = []

    for row in agents:
        agent = row.get("agent", "").strip()
        pre = preflight_rows.get(
            agent,
            {
                "status": "unknown",
                "reason": "no preflight row",
                "image": row.get("image", ""),
            },
        )

        for provider in providers:
            record = {
                "agent": agent,
                "provider": provider,
                "image": row.get("image", "").strip(),
                "preflight_status": pre.get("status", "unknown"),
                "status": "fail",
                "attempts": attempts,
                "time_to_first_success_seconds": None,
                "failure_category": "",
                "failure_detail": "",
            }

            if pre.get("status") != "available":
                reason = pre.get("reason", "image unavailable") or "image unavailable"
                record["failure_category"] = "auth/config"
                record["failure_detail"] = reason
                records.append(record)
                continue

            elapsed = 0.0
            last_output = ""
            for attempt in range(1, attempts + 1):
                env = os.environ.copy()
                env.update(
                    {
                        "AGENT_NAME": agent,
                        "SMOKE_PROVIDER": provider,
                        "SMOKE_PROMPT": prompt,
                        "SMOKE_WAIT_TIMEOUT": wait_timeout,
                    }
                )

                started = time.monotonic()
                proc = run(["./scripts/run-smoke-one.sh"], env=env)
                elapsed += time.monotonic() - started
                last_output = proc.stdout or ""

                if proc.returncode == 0:
                    record["status"] = "pass"
                    record["attempts"] = attempt
                    record["time_to_first_success_seconds"] = round(elapsed, 3)
                    break

            if record["status"] != "pass":
                record["failure_category"] = classify_failure(last_output)
                detail_line = ""
                for line in reversed(last_output.splitlines()):
                    if "error:" in line.lower() or "[smoke-one] blocked" in line:
                        detail_line = line.strip()
                        break
                record["failure_detail"] = (
                    detail_line[:220] if detail_line else "smoke check failed"
                )

            records.append(record)

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "providers": providers,
        "attempts": attempts,
        "wait_timeout": wait_timeout,
        "prompt": prompt,
        "preflight_command_succeeded": preflight_proc.returncode == 0,
        "summary": summarize(records),
        "results": records,
    }
    OUT_JSON.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    with OUT_TSV.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "agent",
                "provider",
                "preflight_status",
                "status",
                "attempts",
                "time_to_first_success_seconds",
                "failure_category",
                "failure_detail",
            ],
            delimiter="\t",
        )
        writer.writeheader()
        for rec in records:
            writer.writerow(
                {
                    "agent": rec["agent"],
                    "provider": rec["provider"],
                    "preflight_status": rec["preflight_status"],
                    "status": rec["status"],
                    "attempts": rec["attempts"],
                    "time_to_first_success_seconds": rec[
                        "time_to_first_success_seconds"
                    ],
                    "failure_category": rec["failure_category"],
                    "failure_detail": rec["failure_detail"],
                }
            )

    print("agent\tprovider\tpreflight\tstatus\tcategory\ttime_to_first_success_s")
    for rec in records:
        print(
            f"{rec['agent']}\t{rec['provider']}\t{rec['preflight_status']}\t"
            f"{rec['status']}\t{rec['failure_category'] or '-'}\t"
            f"{rec['time_to_first_success_seconds'] if rec['time_to_first_success_seconds'] is not None else '-'}"
        )
    print(f"wrote {OUT_TSV}")
    print(f"wrote {OUT_JSON}")


if __name__ == "__main__":
    main()
