#!/usr/bin/env python3
"""Compare CPU and accelerator predictions at selected component counts."""

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
    parser.add_argument("--backend", required=True, choices=("cuda", "metal"))
    parser.add_argument("--precision", required=True,
                        choices=("float32", "float64"))
    parser.add_argument("--oversample", default=32, type=int)
    parser.add_argument("--power", default=5, type=int)
    parser.add_argument("--seed", default=123, type=int)
    parser.add_argument("--datasets", help="Optional comma-separated dataset subset")
    args = parser.parse_args()

    requested = set(args.datasets.split(",")) if args.datasets else None
    with args.selections.open(newline="") as handle:
        selections = [
            row for row in csv.DictReader(handle)
            if requested is None or row["dataset"] in requested
        ]

    worker = args.source / "benchmark/optimization/validate_backend_precision_agreement.R"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    for index, selection in enumerate(selections, start=1):
        dataset = selection["dataset"]
        family = selection["family"]
        task = args.tasks / f"{dataset}_task.rds"
        row_path = args.output.parent / (
            f"{args.output.stem}__{dataset}__{family}.csv"
        )
        command = [
            "Rscript", str(worker), f"--task={task}",
            f"--library={args.library}", f"--output={row_path}",
            f"--backend={args.backend}", f"--precision={args.precision}",
            f"--families={family}", f"--ncomp={selection['selected_ncomp']}",
            f"--oversample={args.oversample}", f"--power={args.power}",
            f"--seed={args.seed}",
        ]
        completed = subprocess.run(command, text=True, capture_output=True)
        if completed.returncode == 0 and row_path.is_file():
            with row_path.open(newline="") as handle:
                rows.append(next(csv.DictReader(handle)))
        else:
            rows.append({
                "dataset": dataset,
                "family": family,
                "precision": args.precision,
                "candidate_backend": args.backend,
                "ncomp": selection["selected_ncomp"],
                "status": "worker_error",
                "error": (completed.stderr or completed.stdout)[-4000:],
            })
        with args.output.open("w", newline="") as handle:
            columns = sorted({key for row in rows for key in row})
            writer = csv.DictWriter(handle, fieldnames=columns)
            writer.writeheader()
            writer.writerows(rows)
        print(f"[{index}/{len(selections)}] {dataset} {family}", flush=True)


if __name__ == "__main__":
    main()
