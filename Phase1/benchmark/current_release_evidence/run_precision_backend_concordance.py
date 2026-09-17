#!/usr/bin/env python3
"""Run paired precision/backend numerical-concordance workers."""

import argparse
import csv
from pathlib import Path
import subprocess


def read_selection(path):
    selected = {}
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream):
            selected[(row["dataset"], "plssvd")] = int(row["plssvd_ncomp"])
            sequential = int(row["simpls_ncomp"])
            for family in ("simpls", "opls", "kernelpls"):
                selected[(row["dataset"], family)] = sequential
    return selected


def read_rows(path):
    if not path.exists():
        return []
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def write_aggregate(output_dir):
    rows = []
    for path in sorted(output_dir.glob("cells/*.csv")):
        rows.extend(read_rows(path))
    aggregate = output_dir / "precision_backend_concordance.csv"
    if not rows:
        return
    with aggregate.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rscript", default="Rscript")
    parser.add_argument("--library", required=True)
    parser.add_argument("--task-dir", required=True)
    parser.add_argument("--selected", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--modes", nargs="+", required=True)
    parser.add_argument("--reference-mode", required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--datasets", nargs="+")
    parser.add_argument(
        "--families", nargs="+",
        default=("plssvd", "simpls", "opls", "kernelpls"),
    )
    parser.add_argument("--timeout-sec", type=int, default=14400)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent
    worker = root / "precision_backend_concordance_worker.R"
    task_dir = Path(args.task_dir).resolve()
    output_dir = Path(args.output_dir).resolve()
    cells = output_dir / "cells"
    logs = output_dir / "logs"
    cells.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    selection = read_selection(Path(args.selected).resolve())
    datasets = args.datasets or sorted(
        path.name.removesuffix("_task.rds")
        for path in task_dir.glob("*_task.rds")
    )
    mode_string = ",".join(args.modes)
    for dataset in datasets:
        task = task_dir / f"{dataset}_task.rds"
        if not task.exists():
            raise FileNotFoundError(task)
        for family in args.families:
            ncomp = selection[(dataset, family)]
            output = cells / f"{dataset}__{family}.csv"
            log = logs / f"{dataset}__{family}.log"
            if args.resume and output.exists():
                continue
            command = [
                args.rscript, str(worker), args.library, str(task), family,
                str(ncomp), mode_string, args.reference_mode, str(output),
                args.expected_version,
            ]
            print(f"Running {dataset} {family} A={ncomp}", flush=True)
            with log.open("w") as stream:
                completed = subprocess.run(
                    command, stdout=stream, stderr=subprocess.STDOUT,
                    text=True, timeout=args.timeout_sec, check=False,
                )
            if completed.returncode:
                detail = log.read_text(errors="replace")[-3000:]
                raise RuntimeError(
                    f"Worker failed for {dataset}/{family}: {detail}"
                )
            write_aggregate(output_dir)
    write_aggregate(output_dir)


if __name__ == "__main__":
    main()
