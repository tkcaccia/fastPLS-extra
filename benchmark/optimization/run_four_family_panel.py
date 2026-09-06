#!/usr/bin/env python3
"""Run the current four-family fastPLS panel in isolated R processes."""

import argparse
import csv
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--tasks", required=True, type=Path)
    parser.add_argument("--selections", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--backend", default="cpu", choices=("cpu", "cuda", "metal"))
    parser.add_argument("--repetitions", default=5, type=int)
    parser.add_argument("--oversample", default=32, type=int)
    parser.add_argument("--power", default=5, type=int)
    parser.add_argument("--seed", default=123, type=int)
    parser.add_argument("--precision", default="input",
                        choices=("input", "float32", "float64"))
    parser.add_argument("--datasets", help="Optional comma-separated dataset subset")
    args = parser.parse_args()
    if args.repetitions < 1:
        raise ValueError("repetitions must be positive")
    requested = set(args.datasets.split(",")) if args.datasets else None
    with args.selections.open(newline="") as handle:
        selections = [row for row in csv.DictReader(handle)
                      if requested is None or row["dataset"] in requested]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    worker = args.source / "benchmark/optimization/benchmark_four_families_candidate.R"
    for selection in selections:
        dataset = selection["dataset"]
        family = selection["family"]
        task = args.tasks / f"{dataset}_task.rds"
        if not task.is_file():
            rows.append({
                "dataset": dataset, "family": family, "backend": args.backend,
                "ncomp": selection["selected_ncomp"], "status": "missing_task",
                "error": str(task),
            })
            continue
        for replicate in range(1, args.repetitions + 1):
            row_path = args.output.parent / (
                f"{args.output.stem}__{dataset}__{family}__r{replicate}.csv"
            )
            command = [
                "Rscript", str(worker), f"--task={task}",
                f"--library={args.library}", f"--output={row_path}",
                f"--backend={args.backend}", f"--families={family}",
                f"--ncomp={selection['selected_ncomp']}", "--repetitions=1",
                f"--oversample={args.oversample}", f"--power={args.power}",
                f"--seed={args.seed}", f"--precision={args.precision}",
            ]
            completed = subprocess.run(command, text=True, capture_output=True)
            if completed.returncode == 0 and row_path.is_file():
                with row_path.open(newline="") as handle:
                    row = next(csv.DictReader(handle))
                row["panel_replicate"] = replicate
                rows.append(row)
            else:
                rows.append({
                    "dataset": dataset, "family": family,
                    "backend": args.backend, "ncomp": selection["selected_ncomp"],
                    "panel_replicate": replicate, "status": "worker_error",
                    "error": (completed.stderr or completed.stdout)[-4000:],
                })
            with args.output.open("w", newline="") as handle:
                columns = sorted({key for row in rows for key in row})
                writer = csv.DictWriter(handle, fieldnames=columns)
                writer.writeheader()
                writer.writerows(rows)
            print(f"[{len(rows)}] {dataset} {family} replicate {replicate}", flush=True)


if __name__ == "__main__":
    main()
