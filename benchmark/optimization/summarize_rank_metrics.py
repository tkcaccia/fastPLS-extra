#!/usr/bin/env python3
"""Summarize the matched metric microbenchmark, retaining its timing scope."""
import argparse
import csv
from collections import defaultdict
from pathlib import Path
import statistics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    with (args.directory / "after/rank_timings.csv").open() as handle:
        records = list(csv.DictReader(handle))
    groups = defaultdict(list)
    for row in records:
        groups[(int(row["n"]), row["ties"], row["method"])].append(row)
    summary = []
    for n, ties in sorted({(n, ties) for n, ties, _ in groups}):
        item = {"values": n, "ties": ties, "repetitions": 5,
                "scope": "Spearman metric only; not model fitting"}
        for method in ("reference", "compiled"):
            rows = groups[(n, ties, method)]
            if len(rows) != 5 or {int(row["replicate"]) for row in rows} != set(range(1, 6)):
                raise ValueError("Incomplete or duplicate timing replicates")
            times = [float(row["seconds"]) for row in rows]
            item[method + "_median_sec"] = statistics.median(times)
            quartiles = statistics.quantiles(times, n=4, method="inclusive")
            item[method + "_q1_sec"], item[method + "_q3_sec"] = quartiles[0], quartiles[2]
        item["max_absolute_error"] = max(float(row["absolute_error"]) for
            method in ("reference", "compiled") for row in groups[(n, ties, method)])
        item["reference_over_compiled"] = (
            item["reference_median_sec"] / item["compiled_median_sec"]
            if item["compiled_median_sec"] > 0.01 else "timer_resolution_limited")
        summary.append(item)
    with (args.directory / "rank_summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    print(len(summary), "matched metric summaries")


if __name__ == "__main__":
    main()
