#!/usr/bin/env python3
"""Summarize isolated Figure 1 R-package benchmark rows."""

import argparse
import csv
import math
from pathlib import Path
import statistics


def number(value):
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def median(rows, key, scale=1.0):
    values = [number(row.get(key)) for row in rows]
    values = [value for value in values if value is not None]
    return statistics.median(values) * scale if values else ""


def median_first(rows, keys, scale=1.0):
    for key in keys:
        value = median(rows, key, scale)
        if value != "":
            return value
    return ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with args.raw.open(newline="") as handle:
        raw = list(csv.DictReader(handle))

    groups = {}
    for row in raw:
        key = (
            row.get("dataset", ""), row.get("task_type", ""),
            row.get("method_id", ""), row.get("ncomp_requested", ""),
        )
        groups.setdefault(key, []).append(row)

    output = []
    for key, rows in sorted(groups.items()):
        completed = [row for row in rows if row.get("status") in {"ok", "success"}]
        statuses = sorted({row.get("status", "") for row in rows})
        messages = sorted({
            row.get("error_message", "") for row in rows
            if row.get("error_message", "")
        })
        output.append({
            "dataset": key[0],
            "task_type": key[1],
            "method_id": key[2],
            "ncomp": key[3],
            "package": completed[0].get("package", "") if completed else "",
            "package_version": completed[0].get("package_version", "") if completed else "",
            "execution_precision": completed[0].get("execution_precision", "") if completed else "",
            "repetitions_requested": len(rows),
            "repetitions_completed": len(completed),
            "accuracy": median(completed, "accuracy"),
            "balanced_accuracy": median(completed, "balanced_accuracy"),
            "rmsd": median(completed, "rmse"),
            "q2": median(completed, "q2"),
            "mae": median(completed, "mae"),
            "median_total_sec": median(completed, "total_runtime_ms", 0.001),
            "median_peak_rss_mib": median_first(
                completed, ("peak_rss_mib", "peak_host_rss_mb")
            ),
            "status": "success" if completed else ";".join(statuses),
            "error": " | ".join(messages),
        })

    args.output.parent.mkdir(parents=True, exist_ok=True)
    columns = list(output[0]) if output else []
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(output)


if __name__ == "__main__":
    main()
