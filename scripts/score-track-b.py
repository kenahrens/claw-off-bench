#!/usr/bin/env python3
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


RESULTS_DIR = Path("results")
RAW_RESULTS_DIR = RESULTS_DIR / "raw"
OUT_FILE = RESULTS_DIR / "track-b-summary.json"
RUN_SCOPE_FILE = RESULTS_DIR / "current-run-jobs.txt"


def load_scoped_jobs():
    if not RUN_SCOPE_FILE.exists():
        return set()
    return {
        line.strip()
        for line in RUN_SCOPE_FILE.read_text(
            encoding="utf-8", errors="replace"
        ).splitlines()
        if line.strip()
    }


def load_rows(scoped_jobs):
    rows = []
    for path in sorted(RAW_RESULTS_DIR.glob("*-trackb-eval.json")):
        stem = path.name[: -len("-trackb-eval.json")]
        if scoped_jobs and stem not in scoped_jobs:
            continue
        payload = json.loads(path.read_text(encoding="utf-8"))
        payload["file"] = str(path)
        rows.append(payload)
    if not rows:
        for path in sorted(RESULTS_DIR.glob("*-trackb-eval.json")):
            stem = path.name[: -len("-trackb-eval.json")]
            if scoped_jobs and stem not in scoped_jobs:
                continue
            payload = json.loads(path.read_text(encoding="utf-8"))
            payload["file"] = str(path)
            rows.append(payload)
    return rows


def summarize(rows):
    by_task = defaultdict(list)
    for row in rows:
        by_task[row.get("task_id", "unknown")].append(row)

    task_summary = []
    for task_id, group in sorted(by_task.items()):
        pass_count = sum(1 for item in group if item.get("gate", {}).get("passed"))
        check_pass_count = 0
        check_total = 0
        for item in group:
            checks = item.get("checks", [])
            check_total += len(checks)
            check_pass_count += sum(1 for check in checks if check.get("passed"))

        task_summary.append(
            {
                "task_id": task_id,
                "runs": len(group),
                "pass_count": pass_count,
                "pass_rate": round((pass_count / len(group)) * 100, 2)
                if group
                else 0.0,
                "check_pass_rate": round((check_pass_count / check_total) * 100, 2)
                if check_total
                else 0.0,
            }
        )

    overall_runs = len(rows)
    overall_pass = sum(1 for item in rows if item.get("gate", {}).get("passed"))
    return {
        "overall": {
            "runs": overall_runs,
            "pass_count": overall_pass,
            "pass_rate": round((overall_pass / overall_runs) * 100, 2)
            if overall_runs
            else 0.0,
        },
        "tasks": task_summary,
    }


def main():
    RESULTS_DIR.mkdir(exist_ok=True)
    RAW_RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    rows = load_rows(load_scoped_jobs())
    summary = summarize(rows)

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "summary": summary,
        "runs": rows,
    }
    OUT_FILE.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    print("task_id\truns\tpass_rate\tcheck_pass_rate")
    for row in summary["tasks"]:
        print(
            f"{row['task_id']}\t{row['runs']}\t{row['pass_rate']}%\t{row['check_pass_rate']}%"
        )
    print(f"wrote {OUT_FILE}")


if __name__ == "__main__":
    main()
