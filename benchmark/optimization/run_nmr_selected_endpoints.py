#!/usr/bin/env python3
"""Run current NMR endpoints at verified training-only one-SE selections."""

import argparse
import csv
import json
import math
from pathlib import Path
import subprocess


def read_selection(folder):
    with (folder / "nmr_component_selection_decision.csv").open() as handle:
        decisions = list(csv.DictReader(handle))
    with (folder / "nmr_component_selection_summary.csv").open() as handle:
        summary = list(csv.DictReader(handle))
    if len(decisions) != 1 or not summary:
        raise ValueError("Missing or ambiguous NMR training selection")
    decision = decisions[0]
    requested = int(decision["n_splits_requested"])
    if requested < 2 or int(decision["n_splits_successful"]) != requested:
        raise ValueError("The selected-endpoint panel requires every training split")
    counts = [int(row["ncomp"]) for row in summary]
    if counts != sorted(set(counts)) or min(counts) < 1:
        raise ValueError("Invalid NMR selection grid")
    for row in summary:
        if int(row["n_success"]) != requested or any(
                not math.isfinite(float(row[key])) or float(row[key]) < 0
                for key in ("RMSD_mean", "RMSD_se")):
            raise ValueError("Incomplete or nonfinite NMR selection curve")
    best = min(summary, key=lambda row: float(row["RMSD_mean"]))
    threshold = float(best["RMSD_mean"]) + float(best["RMSD_se"])
    eligible = [int(row["ncomp"]) for row in summary
                if float(row["RMSD_mean"]) <= threshold]
    selected = int(decision["selected_ncomp"])
    if (selected != min(eligible) or
            int(decision["minimum_mean_ncomp"]) != int(best["ncomp"]) or
            [int(x) for x in decision["eligible_ncomp"].split(",")] != eligible or
            not math.isclose(float(decision["one_se_threshold"]), threshold,
                             rel_tol=1e-12, abs_tol=1e-16)):
        raise ValueError("NMR one-standard-error decision disagrees with its curve")
    return dict(selected_ncomp=selected, eligible=eligible, grid=counts,
                splits=requested, threshold=threshold, selection_directory=str(folder),
                scope="training-only selected predictive endpoint; not fixed-count benchmark")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--selections", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--accelerator", choices=("cuda", "metal"), required=True)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if any("frozen" in str(p).lower() for p in (args.source, args.library, args.selections)):
        raise ValueError("Current source, library and training selections are required")
    args.out.mkdir(parents=True, exist_ok=False)
    plan = []
    for family in ("plssvd", "simpls"):
        selected = read_selection(args.selections / ("selection_" + family))
        for backend, solver in (("cpu", "irlba"), ("cpu", "rsvd"),
                                (args.accelerator, "rsvd")):
            name = f"{family}_{backend}_{solver}"
            command = ["python3", args.source / "benchmark/optimization/run_metal_nmr_workspace.py",
                       "--source", args.source, "--library", args.library,
                       "--output", args.out / name, "--input", args.input,
                       "--family", family, "--backend", backend, "--solver", solver,
                       "--components", selected["selected_ncomp"], "--precision",
                       "float64", "float32", "--seeds", "123", "--replicates", "3",
                       "--memory", "--timeout", "10000"]
            plan.append(dict(name=name, family=family, selection=selected,
                             command=list(map(str, command))))
    (args.out / "selected_endpoint_plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    if args.prepare_only:
        return
    status = []
    for stage in plan:
        print(stage["name"], "selected components", stage["selection"]["selected_ncomp"], flush=True)
        with (args.out / (stage["name"] + ".log")).open("w") as handle:
            result = subprocess.run(stage["command"], stdout=handle, stderr=subprocess.STDOUT)
        status.append(dict(name=stage["name"], exit_code=result.returncode))
        (args.out / "selected_endpoint_status.json").write_text(json.dumps(status, indent=2) + "\n")
    if any(row["exit_code"] for row in status):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
