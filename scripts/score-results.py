#!/usr/bin/env python3
import json
import math
import re
from collections import defaultdict
from datetime import datetime
from pathlib import Path


RESULTS_DIR = Path("results")
OUT_FILE = RESULTS_DIR / "score.json"


def parse_ts(value: str):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    rank = math.ceil((p / 100.0) * len(ordered)) - 1
    rank = max(0, min(rank, len(ordered) - 1))
    return ordered[rank]


def parse_job_result(path: Path):
    stem = path.stem
    m = re.match(r"(?P<agent>[a-z0-9-]+)-(?P<task>t[0-9]+(?:r[0-9]+)?)-[0-9]+$", stem)
    if not m:
        return None

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    timestamps = []
    for line in lines:
        first = line.split(" ", 1)[0]
        ts = parse_ts(first)
        if ts:
            timestamps.append(ts)

    duration = None
    if len(timestamps) >= 2:
        duration = (timestamps[-1] - timestamps[0]).total_seconds()

    text = "\n".join(lines)
    success = not re.search(r"\bError:|\berror:\b|ImagePullBackOff|failed", text)

    return {
        "agent": m.group("agent"),
        "mode": "job",
        "task": m.group("task"),
        "file": str(path),
        "duration_seconds": duration,
        "success": success,
    }


def parse_daemon_result(path: Path):
    stem = path.stem
    m = re.match(
        r"(?P<agent>[a-z0-9-]+)-(?P<task>t[0-9]+(?:r[0-9]+)?)-daemon-[0-9]+$", stem
    )
    if not m:
        return None

    payload = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    success = "error" not in payload

    return {
        "agent": m.group("agent"),
        "mode": "daemon",
        "task": m.group("task"),
        "file": str(path),
        "duration_seconds": None,
        "success": success,
    }


def main():
    RESULTS_DIR.mkdir(exist_ok=True)

    rows = []
    for path in RESULTS_DIR.glob("*.txt"):
        parsed = parse_job_result(path)
        if parsed:
            rows.append(parsed)

    for path in RESULTS_DIR.glob("*.json"):
        parsed = parse_daemon_result(path)
        if parsed:
            rows.append(parsed)

    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["agent"], row["mode"])].append(row)

    summary = []
    for (agent, mode), group in sorted(grouped.items()):
        durations = [
            x["duration_seconds"] for x in group if x["duration_seconds"] is not None
        ]
        successes = [x for x in group if x["success"]]
        summary.append(
            {
                "agent": agent,
                "mode": mode,
                "runs": len(group),
                "success_count": len(successes),
                "success_rate": round((len(successes) / len(group)) * 100, 2)
                if group
                else 0.0,
                "median_duration_seconds": percentile(durations, 50),
                "p95_duration_seconds": percentile(durations, 95),
            }
        )

    output = {"summary": summary, "runs": rows}
    OUT_FILE.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")

    if not summary:
        print("no benchmark results found in results/")
        return

    print("agent\tmode\truns\tsuccess_rate\tmedian_s\tp95_s")
    for item in summary:
        median = (
            "-"
            if item["median_duration_seconds"] is None
            else f"{item['median_duration_seconds']:.2f}"
        )
        p95 = (
            "-"
            if item["p95_duration_seconds"] is None
            else f"{item['p95_duration_seconds']:.2f}"
        )
        print(
            f"{item['agent']}\t{item['mode']}\t{item['runs']}\t"
            f"{item['success_rate']}%\t{median}\t{p95}"
        )


if __name__ == "__main__":
    main()
