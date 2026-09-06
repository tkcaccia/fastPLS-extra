#!/usr/bin/env python3
"""Plan candidate-selected workloads separately from equal-component timings."""

import argparse
import csv
import json
from pathlib import Path


def selections(path):
    with path.open() as handle:
        rows = list(csv.DictReader(handle))
    index = {}
    for row in rows:
        key = (row["dataset"].lower(), row.get("family", row.get("method", "")).lower())
        if key in index or row.get("status", "success") != "success":
            raise ValueError("Duplicate or failed component selection")
        count = int(row.get("selected_ncomp", row.get("ncomp", "")))
        if count < 1:
            raise ValueError("Component count must be positive")
        index[key] = count
    if len(index) != 44:
        raise ValueError("All 44 dataset-family selections are required")
    return index


def changes(current, equal_workload):
    if current.keys() != equal_workload.keys():
        raise ValueError("The candidate and equal-workload panels differ")
    return [dict(dataset=key[0], family=key[1], candidate_selected=current[key],
                 matched_workload_ncomp=equal_workload[key], requires_new_fit=current[key] != equal_workload[key])
            for key in sorted(current)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-selection", type=Path, required=True)
    parser.add_argument("--matched-selection", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rows = changes(selections(args.candidate_selection), selections(args.matched_selection))
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / "selected_point_update_plan.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    keys = [row["dataset"] + "/" + row["family"] for row in rows if row["requires_new_fit"]]
    plan = {"new_fit_keys": keys, "unchanged_points": 44 - len(keys),
            "environment": {"FASTPLS_SELECTED_COMPONENTS_CSV": str(args.candidate_selection.resolve()),
                            "FASTPLS_MATCHED_ONLY_KEYS": ",".join(keys)},
            "execute": bool(keys),
            "interpretation": "Changed-component results are not equal-workload speed comparisons",
            "source_policy": "Execute current fastPLS only; retain original provenance for unchanged current rows"}
    (args.output / "selected_point_update_plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    print(json.dumps(plan, indent=2))


if __name__ == "__main__":
    main()
