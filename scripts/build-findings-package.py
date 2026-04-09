#!/usr/bin/env python3
import csv
import hashlib
import json
import re
import subprocess
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(".")
RESULTS_DIR = ROOT / "results"
RAW_RESULTS_DIR = RESULTS_DIR / "raw"
PROFILE_FILE = ROOT / "config" / "eval.env"
PORTABILITY_FILE = RESULTS_DIR / "portability-sweep.json"
FACTORY_FILE = RESULTS_DIR / "factory-summary.json"
TRACK_B_FILE = RESULTS_DIR / "track-b-summary.json"
SCORE_FILE = RESULTS_DIR / "score.json"

SNAPSHOT_FILE = RESULTS_DIR / "canonical-run-snapshot.json"
TABLE_CSV_FILE = RESULTS_DIR / "findings-table.csv"
TABLE_MD_FILE = RESULTS_DIR / "findings-table.md"
EXCERPTS_FILE = RESULTS_DIR / "findings-log-excerpts.md"
BLOG_DRAFT_FILE = RESULTS_DIR / "findings-blog-draft.md"
PACKAGE_FILE = RESULTS_DIR / "findings-package.json"


def read_json(path: Path):
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def file_sha256(path: Path):
    if not path.exists():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def parse_eval_profile(path: Path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def git_value(args, default="unknown"):
    try:
        return (
            subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)
            .strip()
            .strip()
        )
    except Exception:
        return default


def build_snapshot(profile):
    sources = {
        "eval_profile": str(PROFILE_FILE),
        "portability": str(PORTABILITY_FILE),
        "factory": str(FACTORY_FILE),
        "track_b": str(TRACK_B_FILE),
        "score": str(SCORE_FILE),
    }

    source_hashes = {}
    for key, source in sources.items():
        source_hashes[key] = file_sha256(ROOT / source)

    keep_keys = [
        "EVAL_TARGET",
        "DEFAULT_PROVIDER",
        "DEFAULT_MODEL",
        "ALLOW_PACKAGE_REGISTRIES",
        "AGENT_FILTER",
        "REPEAT_COUNT",
        "MATRIX_STRICT",
        "COMPARISON_MODE",
        "MAX_TOTAL_RUNS",
        "MAX_FAILED_RUNS",
        "MAX_WALL_CLOCK_MIN",
        "MAX_ANTHROPIC_RUNS",
        "AGENT_MATRIX_FILE",
        "AGENT_SAFETY_FILE",
        "REQUIRE_GITHUB_TOKEN",
    ]
    snapshot_settings = {k: profile.get(k, "") for k in keep_keys if k in profile}

    return {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "git": {
            "commit_sha": git_value(["git", "rev-parse", "HEAD"]),
            "branch": git_value(["git", "rev-parse", "--abbrev-ref", "HEAD"]),
            "describe": git_value(["git", "describe", "--always", "--dirty"]),
        },
        "settings": snapshot_settings,
        "source_hashes": source_hashes,
        "sources": sources,
    }


def summarize_portability(portability_payload):
    rows = []
    if not portability_payload:
        return rows

    grouped = defaultdict(list)
    for rec in portability_payload.get("results", []):
        grouped[(rec.get("agent", ""), rec.get("provider", ""))].append(rec)

    for (agent, provider), group in sorted(grouped.items()):
        passes = sum(1 for x in group if x.get("status") == "pass")
        failures = [x for x in group if x.get("status") != "pass"]
        failure_counts = Counter(
            x.get("failure_category", "") for x in failures if x.get("failure_category")
        )
        primary_failure = failure_counts.most_common(1)[0][0] if failure_counts else ""
        ttfs_values = [
            x.get("time_to_first_success_seconds")
            for x in group
            if x.get("time_to_first_success_seconds") is not None
        ]
        ttfs = round(sum(ttfs_values) / len(ttfs_values), 3) if ttfs_values else ""
        rows.append(
            {
                "track": "A",
                "subject": f"{agent}",
                "lane": provider,
                "runs": len(group),
                "success_rate_percent": round((passes / len(group)) * 100, 2)
                if group
                else 0.0,
                "median_duration_seconds": "",
                "p95_duration_seconds": "",
                "time_to_first_success_seconds": ttfs,
                "primary_failure_category": primary_failure,
                "notes": "provider portability sweep",
            }
        )
    return rows


def summarize_factory(factory_payload):
    rows = []
    if not factory_payload:
        return rows

    for agent in factory_payload.get("agents", []):
        job = agent.get("job", {})
        reasons = agent.get("failure_reasons", [])
        primary_failure = reasons[0]["reason"] if reasons else ""
        rows.append(
            {
                "track": "A",
                "subject": agent.get("agent", ""),
                "lane": "job",
                "runs": job.get("runs", 0),
                "success_rate_percent": job.get("success_rate", 0.0),
                "median_duration_seconds": job.get("median_duration_seconds", ""),
                "p95_duration_seconds": job.get("p95_duration_seconds", ""),
                "time_to_first_success_seconds": "",
                "primary_failure_category": primary_failure,
                "notes": f"preflight={agent.get('preflight_status', 'unknown')}",
            }
        )
    return rows


def summarize_score(score_payload):
    rows = []
    if not score_payload:
        return rows

    for item in score_payload.get("summary", []):
        if item.get("mode") != "job":
            continue
        rows.append(
            {
                "track": "A",
                "subject": item.get("agent", ""),
                "lane": "job",
                "runs": item.get("runs", 0),
                "success_rate_percent": item.get("success_rate", 0.0),
                "median_duration_seconds": item.get("median_duration_seconds", ""),
                "p95_duration_seconds": item.get("p95_duration_seconds", ""),
                "time_to_first_success_seconds": "",
                "primary_failure_category": "",
                "notes": "derived from score.json",
            }
        )
    return rows


def summarize_track_b(track_b_payload):
    rows = []
    if not track_b_payload:
        return rows

    for task in track_b_payload.get("summary", {}).get("tasks", []):
        rows.append(
            {
                "track": "B",
                "subject": task.get("task_id", ""),
                "lane": "deterministic-fixture",
                "runs": task.get("runs", 0),
                "success_rate_percent": task.get("pass_rate", 0.0),
                "median_duration_seconds": "",
                "p95_duration_seconds": "",
                "time_to_first_success_seconds": "",
                "primary_failure_category": "",
                "notes": f"check_pass_rate={task.get('check_pass_rate', 0.0)}%",
            }
        )
    return rows


def gather_log_excerpts(score_payload):
    records = []
    if score_payload:
        for run in score_payload.get("runs", []):
            path = Path(run.get("file", ""))
            if path.exists():
                records.append({"success": run.get("success", False), "path": path})

    if not records:
        for path in sorted(RAW_RESULTS_DIR.glob("*.txt")):
            text = path.read_text(encoding="utf-8", errors="replace")
            failed = bool(re.search(r"\berror\b|\bfailed\b", text, flags=re.IGNORECASE))
            records.append({"success": not failed, "path": path})

    if not records:
        for path in sorted(RESULTS_DIR.glob("*.txt")):
            text = path.read_text(encoding="utf-8", errors="replace")
            failed = bool(re.search(r"\berror\b|\bfailed\b", text, flags=re.IGNORECASE))
            records.append({"success": not failed, "path": path})

    success_records = [x for x in records if x["success"]][:2]
    fail_records = [x for x in records if not x["success"]][:3]

    def extract_snippet(path: Path, success: bool):
        text = path.read_text(encoding="utf-8", errors="replace")
        if success:
            marker_patterns = [
                r"HELLO_WORLD",
                r"SMOKE_OK",
                r"saved logs",
                r"done",
                r"pass",
            ]
        else:
            marker_patterns = [
                r"error:",
                r"failed",
                r"timed out",
                r"authentication_error",
                r"unsupported",
            ]

        idx = 0
        for pattern in marker_patterns:
            m = re.search(pattern, text, flags=re.IGNORECASE)
            if m:
                idx = m.start()
                break

        start = max(0, idx - 220)
        end = min(len(text), idx + 380)
        snippet = text[start:end].strip().replace("\r", "")
        return snippet

    lines = [
        "# Key Log Excerpts",
        "",
        "Decisive success/failure snippets for publication review.",
        "",
    ]

    if success_records:
        lines.append("## Success Signals")
        lines.append("")
        for entry in success_records:
            snippet = extract_snippet(entry["path"], success=True)
            lines.append(f"### `{entry['path']}`")
            lines.append("")
            lines.append("```text")
            lines.append(snippet)
            lines.append("```")
            lines.append("")

    else:
        lines.append("## Success Signals")
        lines.append("")
        lines.append("No decisive success logs found in current artifacts.")
        lines.append("")

    if fail_records:
        lines.append("## Failure Signals")
        lines.append("")
        for entry in fail_records:
            snippet = extract_snippet(entry["path"], success=False)
            lines.append(f"### `{entry['path']}`")
            lines.append("")
            lines.append("```text")
            lines.append(snippet)
            lines.append("```")
            lines.append("")

    else:
        lines.append("## Failure Signals")
        lines.append("")
        lines.append("No decisive failure logs found in current artifacts.")
        lines.append("")

    EXCERPTS_FILE.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")


def write_findings_table(rows):
    fieldnames = [
        "track",
        "subject",
        "lane",
        "runs",
        "success_rate_percent",
        "median_duration_seconds",
        "p95_duration_seconds",
        "time_to_first_success_seconds",
        "primary_failure_category",
        "notes",
    ]
    with TABLE_CSV_FILE.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)

    md_lines = [
        "# Findings Table",
        "",
        "| Track | Subject | Lane | Runs | Success % | Median s | P95 s | TTFS s | Primary Failure | Notes |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |",
    ]

    for row in rows:
        md_lines.append(
            "| {track} | {subject} | {lane} | {runs} | {success_rate_percent} | {median_duration_seconds} | {p95_duration_seconds} | {time_to_first_success_seconds} | {primary_failure_category} | {notes} |".format(
                **{k: ("" if v is None else v) for k, v in row.items()}
            )
        )

    TABLE_MD_FILE.write_text("\n".join(md_lines) + "\n", encoding="utf-8")


def write_blog_draft(snapshot, rows):
    track_a_rows = [r for r in rows if r.get("track") == "A"]
    track_b_rows = [r for r in rows if r.get("track") == "B"]

    avg_a = (
        round(
            sum(float(r.get("success_rate_percent") or 0) for r in track_a_rows)
            / len(track_a_rows),
            2,
        )
        if track_a_rows
        else 0.0
    )
    avg_b = (
        round(
            sum(float(r.get("success_rate_percent") or 0) for r in track_b_rows)
            / len(track_b_rows),
            2,
        )
        if track_b_rows
        else 0.0
    )

    text = f"""# Draft: Claw Benchmark Findings (M4)

## What We Measured

This benchmark now reports two tracks:

- Track A (operability/portability): can each agent execute under each provider lane with fixed constraints.
- Track B (coding skill): deterministic fixture outcomes with objective gate checks.

Canonical snapshot for this draft:

- commit: `{snapshot["git"]["commit_sha"]}`
- profile: `config/eval.env`
- generated findings table: `results/findings-table.csv` and `results/findings-table.md`
- key excerpts: `results/findings-log-excerpts.md`

## Current Signal

- Mean Track A success rate in this package: **{avg_a}%**
- Mean Track B success rate in this package: **{avg_b}%**

Interpretation: Track A and Track B should be compared separately. Provider friction, command-contract differences, and runtime limits are meaningful outcomes, not noise.

## Fairness and Limitations

- We use uniform CPU/memory constraints and non-root runtime defaults across agents.
- We do not treat completion alone as quality; Track B requires objective gate checks.
- Provider/model parity is not guaranteed across agent implementations and is reported explicitly.
- Results can shift with upstream image updates, API behavior, and cluster state.
- Findings should be interpreted as a snapshot at one commit and one run profile.

## Reproduce

1. Run benchmark workflows (`make portability-sweep`, `make track-b-baseline`, `make bench-report` as needed).
2. Run `make findings-package`.
3. Publish from `results/findings-table.csv`, `results/findings-log-excerpts.md`, and `results/canonical-run-snapshot.json`.
"""
    BLOG_DRAFT_FILE.write_text(text, encoding="utf-8")


def main():
    RESULTS_DIR.mkdir(exist_ok=True)

    profile = parse_eval_profile(PROFILE_FILE)
    portability = read_json(PORTABILITY_FILE)
    factory = read_json(FACTORY_FILE)
    track_b = read_json(TRACK_B_FILE)
    score = read_json(SCORE_FILE)

    snapshot = build_snapshot(profile)
    SNAPSHOT_FILE.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

    rows = []
    rows.extend(summarize_portability(portability))
    factory_rows = summarize_factory(factory)
    rows.extend(factory_rows)
    if not factory_rows:
        rows.extend(summarize_score(score))
    rows.extend(summarize_track_b(track_b))
    write_findings_table(rows)
    gather_log_excerpts(score)
    write_blog_draft(snapshot, rows)

    package = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "snapshot_file": str(SNAPSHOT_FILE),
        "findings_csv": str(TABLE_CSV_FILE),
        "findings_markdown": str(TABLE_MD_FILE),
        "log_excerpts": str(EXCERPTS_FILE),
        "blog_draft": str(BLOG_DRAFT_FILE),
        "row_count": len(rows),
    }
    PACKAGE_FILE.write_text(json.dumps(package, indent=2) + "\n", encoding="utf-8")

    print(f"wrote {SNAPSHOT_FILE}")
    print(f"wrote {TABLE_CSV_FILE}")
    print(f"wrote {TABLE_MD_FILE}")
    print(f"wrote {EXCERPTS_FILE}")
    print(f"wrote {BLOG_DRAFT_FILE}")
    print(f"wrote {PACKAGE_FILE}")


if __name__ == "__main__":
    main()
