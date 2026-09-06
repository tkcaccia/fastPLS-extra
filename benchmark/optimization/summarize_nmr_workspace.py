#!/usr/bin/env python3
"""Summarize completed candidate NMR runs; never execute a fitted estimator."""

import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path
import statistics


def write_csv(path, rows):
    if not rows:
        return
    fields = list(dict.fromkeys(field for row in rows for field in row))
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-workers", type=int, required=True)
    args = parser.parse_args()
    if "frozen" in str(args.output).lower() or args.input.resolve() == args.output.resolve():
        raise ValueError("Summary must not overwrite original evidence")
    args.output.mkdir(parents=True, exist_ok=True)
    workers = json.loads((args.input / "worker_status.json").read_text())
    groups = defaultdict(list)
    memories = defaultdict(list)
    keys = ("family", "backend", "solver", "precision", "ncomp", "oversample", "power",
            "direction_rule", "control_profile", "protocol_version", "water_columns_masked",
            "response_columns_scored")
    raw = []
    for worker in workers:
        if worker["status"] != "finished":
            continue
        path = args.input / (worker["case"] + ".csv")
        with path.open(newline="") as handle:
            rows = list(csv.DictReader(handle))
        if len(rows) != worker["repetitions_verified"]:
            raise ValueError("Changed or incomplete worker evidence")
        for row in rows:
            if row["status"] != "success" or row["conversion_in_fit_time"] != "FALSE":
                raise ValueError("Unexpected worker protocol")
            key = tuple(row[field] for field in keys)
            if worker["measurement"] == "timing":
                groups[key].append(row)
                raw.append(dict(row, source=str(path), library=worker["library"]))
            else:
                measurement = json.loads((args.input / worker["case"] / "summary.json").read_text())
                memories[key].extend(measurement["measurements"])
    summary = []
    for key, rows in groups.items():
        item = dict(zip(keys, key))
        times = [float(row["total_time_sec"]) for row in rows]
        quartiles = statistics.quantiles(times, n=4, method="inclusive") if len(times) > 1 else [times[0]] * 3
        item.update(timing_repetitions=len(rows), seeds=",".join(sorted({row["seed"] for row in rows})),
                    median_total_sec=statistics.median(times), iqr_total_sec=quartiles[2] - quartiles[0])
        for metric in ("RMSD", "Q2"):
            values = [float(row[metric]) for row in rows]
            item.update({"median_" + metric: statistics.median(values),
                         "min_" + metric: min(values), "max_" + metric: max(values)})
        item["memory_repetitions"] = len(memories[key])
        for kind in ("rss_mib", "gpu_mib"):
            for stage in ("baseline", "peak", "incremental"):
                field = stage + "_" + kind
                values = [row[field] for row in memories[key] if row[field] is not None]
                item["median_" + field] = statistics.median(values) if values else None
        summary.append(item)
    write_csv(args.output / "timing_replicates.csv", raw)
    write_csv(args.output / "summary.csv", summary)
    status = dict(expected_workers=args.expected_workers, recorded_workers=len(workers),
                  unsuccessful_workers=[row["case"] for row in workers if row["status"] != "finished"],
                  all_workers_complete=len(workers) == args.expected_workers and
                  all(row["status"] == "finished" for row in workers),
                  memory_units="MiB; sampled process increments, not isolated allocations")
    (args.output / "summary_status.json").write_text(json.dumps(status, indent=2) + "\n")
    print(json.dumps(status, indent=2))


if __name__ == "__main__":
    main()
