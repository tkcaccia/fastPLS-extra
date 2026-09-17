#!/usr/bin/env python3
"""Summarize isolated predictor timings and separate process-memory probes."""

import argparse
import collections
import csv
import json
from pathlib import Path
import statistics


def quantile(values, probability):
    values = sorted(values)
    position = (len(values) - 1) * probability
    low = int(position)
    high = min(low + 1, len(values) - 1)
    return values[low] + (position - low) * (values[high] - values[low])


def write_table(path, rows):
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timings", type=Path, required=True)
    parser.add_argument("--memory", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    groups = collections.defaultdict(lambda: collections.defaultdict(list))
    agreements = []
    for label in ("before", "after", "after_reverse", "before_reverse"):
        directory = args.timings / label
        with (directory / "prediction_timings.csv").open() as handle:
            rows = list(csv.DictReader(handle))
        for row in rows:
            groups[row["case"]]["before" if label.startswith("before") else "after"].append(row)
        if label != "before":
            with (directory / "agreement.csv").open() as handle:
                agreements.extend(csv.DictReader(handle))
    errors = collections.defaultdict(list)
    for row in agreements:
        errors[row["case"]].append(row)
    timing_summary = []
    for case, candidates in sorted(groups.items()):
        if set(candidates) != {"before", "after"} or len(errors[case]) != 3:
            raise ValueError("Incomplete candidate/ordering comparisons")
        records = candidates["before"] + candidates["after"]
        for key in ("n_train", "n_test", "p", "q", "maximum_components", "requested_prefixes",
                    "iterations", "scope", "family", "solver", "representation"):
            if len({row[key] for row in records}) != 1:
                raise ValueError(f"Mismatched timing protocol: {case} {key}")
        values = {label: [float(row["seconds_per_prediction"]) for row in rows]
                  for label, rows in candidates.items()}
        if any(len(rows) != 40 or min(values[label]) <= 0 for label, rows in candidates.items()):
            raise ValueError("Expected forty positive batch timings per candidate")
        example = records[0]
        result = {key: example[key] for key in ("case", "dataset", "family", "solver", "representation", "scope")}
        for label, times in values.items():
            result[label + "_median_sec"] = statistics.median(times)
            result[label + "_iqr_sec"] = quantile(times, 0.75) - quantile(times, 0.25)
            result[label + "_batches"] = len(times)
        result["before_over_after_ratio"] = result["before_median_sec"] / result["after_median_sec"]
        result["max_relative_prediction_error"] = max(float(row["prediction_relative_error"]) for row in errors[case])
        result["max_relative_projection_error"] = max(float(row["projection_relative_error"]) for row in errors[case])
        metrics = [float(row["metric"]) for row in records]
        result["metric_range"] = max(metrics) - min(metrics)
        timing_summary.append(result)
    memory_groups = collections.defaultdict(list)
    for row in json.loads((args.memory / "memory_summary.json").read_text()):
        memory_groups[(row["family"], row["label"])].append(row)
    memory_summary = []
    for (family, label), rows in sorted(memory_groups.items()):
        if {row["worker_replicate"] for row in rows} != {1, 2, 3} or len(rows) != 3:
            raise ValueError("Incomplete memory workers")
        result = dict(family=family, candidate=label, workers=len(rows),
                      scope="sampled complete-process prediction memory; not isolated allocation")
        for field in ("baseline_rss_mib", "peak_rss_mib", "incremental_rss_mib"):
            values = [row[field] for row in rows]
            result["median_" + field] = statistics.median(values)
            result["min_" + field] = min(values)
            result["max_" + field] = max(values)
        memory_summary.append(result)
    args.out.mkdir(parents=True, exist_ok=False)
    write_table(args.out / "prediction_summary.csv", timing_summary)
    write_table(args.out / "memory_summary.csv", memory_summary)


if __name__ == "__main__":
    main()
