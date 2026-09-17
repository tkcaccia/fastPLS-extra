#!/usr/bin/env python3
"""Compare current NMR timing records to stored results without rerunning them."""
import argparse
import csv
import json
from pathlib import Path

from compare_candidate import join, read


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True,
                        help="timing_replicates.csv from summarize_nmr_workspace.py")
    parser.add_argument("--baseline", type=Path, required=True,
                        help="Stored publication nmr directory")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--same-cpu-host", action="store_true",
                        help="Use only after verifying the stored CPU hardware and runtime")
    args = parser.parse_args()
    if args.output.resolve() == args.baseline.resolve() or args.baseline.resolve() in args.output.resolve().parents:
        raise ValueError("Must not overwrite baseline evidence")
    keys = ("dataset", "family", "backend", "solver", "precision", "ncomp",
            "protocol_version", "water_columns_masked", "response_columns_scored",
            "oversample", "power", "seed", "replicate")
    results = []
    for row in read(args.candidate):
        path = args.baseline / (
            f"fixed{row['ncomp']}_{row['family']}_{row['backend']}_{row['solver']}_k{row['ncomp']}.csv")
        comparable = row["backend"] != "cpu" or args.same_cpu_host
        context = "Same NMR preprocessing and requested workload; old estimators are not executed. "
        context += ("CPU timing comparison explicitly enabled after host verification." if args.same_cpu_host else
                    "CPU time ratios are withheld because stored CPU hardware/runtime are not verified as matched.")
        compared = join([row], read(path), keys, ("RMSD", "Q2", "MAE"),
                        ("fit_time_sec", "predict_time_sec", "total_time_sec"), context,
                        time_comparable=comparable)
        results.append(dict(compared[0], candidate_source=row["source"], baseline_source=str(path)))
    args.output.mkdir(parents=True, exist_ok=True)
    if results:
        fields = list(dict.fromkeys(field for row in results for field in row))
        with (args.output / "nmr_candidate_vs_stored.csv").open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            writer.writerows(results)
    counts = {status: sum(row["match_status"] == status for row in results)
              for status in sorted({row["match_status"] for row in results})}
    (args.output / "comparison_status.json").write_text(json.dumps(counts, indent=2) + "\n")
    print(json.dumps(counts, indent=2))


if __name__ == "__main__":
    main()
