#!/usr/bin/env python3
"""Run every R package-panel method on the corrected Tabula Muris task."""

import argparse
import csv
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def read_rows(path):
    with Path(path).open(newline="") as handle:
        return list(csv.DictReader(handle))


def family_for(method_id):
    value = method_id.lower()
    if "plssvd" in value:
        return "plssvd"
    if "kernel" in value:
        return "kernelpls"
    if "opls" in value or "oscores" in value:
        return "opls"
    return "simpls"


def add_memory(row, summary_path):
    if not summary_path.exists():
        return row
    summary = json.loads(summary_path.read_text())
    measurements = summary.get("measurements", [])
    if measurements:
        row.update(measurements[0])
    row["monitor_exit_code"] = summary.get("exit_code")
    row["monitor_timed_out"] = summary.get("timed_out")
    row["monitor_elapsed_sec"] = summary.get("elapsed_sec")
    return row


def hard_failure(status):
    return status in {
        "killed_timeout", "process_failure", "error", "memory_error",
        "unsupported", "unavailable",
    }


def write_combined(rows, path):
    columns = list(dict.fromkeys(key for row in rows for key in row))
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--tasks", required=True, type=Path)
    parser.add_argument("--selected", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--precision", choices=("float32", "float64"),
                        default="float32")
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--timeout", type=int, default=10000)
    parser.add_argument("--method-regex", default="")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.repetitions < 1 or args.timeout < 1:
        parser.error("repetitions and timeout must be positive")

    args.repo = args.repo.resolve()
    args.library = args.library.resolve()
    args.tasks = args.tasks.resolve()
    args.selected = args.selected.resolve()
    args.results = args.results.resolve()
    worker = args.repo / "benchmark" / "benchmark_pls_package_comparison.R"
    monitor = args.repo / "benchmark" / "optimization" / "monitor_process.py"
    selected = {
        row["family"]: int(float(row["selected_ncomp"]))
        for row in read_rows(args.selected)
        if row["dataset"].lower() == "tabula"
    }
    required = {"plssvd", "simpls", "opls", "kernelpls"}
    if set(selected) != required:
        parser.error("selected-component table must contain all four families")

    env = dict(os.environ)
    env.update({
        "FASTPLS_BENCH_LIB": str(args.library),
        "FASTPLS_TASK_ROOT": str(args.tasks),
        "FASTPLS_BENCH_PRECISION": args.precision,
        "OMP_NUM_THREADS": "1",
        "OPENBLAS_NUM_THREADS": "1",
        "MKL_NUM_THREADS": "1",
        "BLIS_NUM_THREADS": "1",
    })
    listed = subprocess.run(
        ["Rscript", str(worker), "--mode=list_methods", "--dataset=tabula"],
        env=env, check=True, text=True, capture_output=True,
    )
    method_ids = [line.strip() for line in listed.stdout.splitlines()
                  if line.strip()]
    if args.method_regex:
        method_ids = [value for value in method_ids
                      if re.search(args.method_regex, value)]
    if not method_ids:
        parser.error("method filter selected no package-panel methods")
    args.results.mkdir(parents=True, exist_ok=True)
    rows_dir = args.results / "rows"
    monitor_dir = args.results / "monitor"
    rows_dir.mkdir(exist_ok=True)
    monitor_dir.mkdir(exist_ok=True)

    results = []
    for method_id in method_ids:
        family = family_for(method_id)
        ncomp = selected[family]
        method_failure = ""
        related_timeout = False
        if method_id == "mixOmics_splsda" and not args.force:
            related_row = (
                rows_dir
                / f"tabula__mixOmics_plsda__n{ncomp}__rep1.csv"
            )
            if related_row.exists():
                prior = read_rows(related_row)[0]
                related_timeout = prior.get("status") == "killed_timeout"
        for replicate in range(1, args.repetitions + 1):
            stem = f"tabula__{method_id}__n{ncomp}__rep{replicate}"
            row_path = rows_dir / f"{stem}.csv"
            one_monitor = monitor_dir / stem
            if row_path.exists() and not args.force:
                row = read_rows(row_path)[0]
                results.append(add_memory(row, one_monitor / "summary.json"))
                if hard_failure(row.get("status", "")):
                    method_failure = row["status"]
                continue
            if related_timeout:
                row = {
                    "dataset": "tabula", "method_id": method_id,
                    "method_family": family, "ncomp_requested": ncomp,
                    "replicate": replicate,
                    "status": "skipped_after_related_timeout",
                    "error_message": (
                        "Not evaluated because mixOmics::plsda exceeded the "
                        "10000-second per-fit limit on the same task."
                    ),
                }
                write_combined([row], row_path)
                results.append(row)
                write_combined(
                    results,
                    args.results / "tabula_r_panel_progress.csv",
                )
                continue
            summary_path = one_monitor / "summary.json"
            if summary_path.exists() and not args.force:
                monitor_summary = json.loads(summary_path.read_text())
                if monitor_summary.get("timed_out"):
                    row = {
                        "dataset": "tabula", "method_id": method_id,
                        "method_family": family, "ncomp_requested": ncomp,
                        "replicate": replicate, "status": "killed_timeout",
                        "error_message": (
                            "Recovered timeout from the process-monitor record; "
                            "the worker did not produce a result row."
                        ),
                    }
                    row = add_memory(row, summary_path)
                    write_combined([row], row_path)
                    results.append(row)
                    method_failure = row["status"]
                    write_combined(
                        results,
                        args.results / "tabula_r_panel_progress.csv",
                    )
                    continue
            if method_failure:
                row = {
                    "dataset": "tabula", "method_id": method_id,
                    "method_family": family, "ncomp_requested": ncomp,
                    "replicate": replicate,
                    "status": "skipped_after_previous_failure",
                    "error_message": (
                        "Replicate skipped because a previous replicate ended "
                        f"with status '{method_failure}'."
                    ),
                }
                write_combined([row], row_path)
                results.append(row)
                write_combined(
                    results,
                    args.results / "tabula_r_panel_progress.csv",
                )
                continue
            command = [
                "Rscript", str(worker), "--mode=run_one", "--dataset=tabula",
                f"--ncomp={ncomp}", f"--method-id={method_id}",
                f"--replicate={replicate}", f"--row-out={row_path}",
            ]
            monitored = [
                sys.executable, str(monitor), f"--output={one_monitor}",
                f"--timeout={args.timeout}", "--interval=0.005", "--",
                *command,
            ]
            print(stem, flush=True)
            completed = subprocess.run(monitored, cwd=args.repo, env=env,
                                       check=False)
            if row_path.exists():
                row = read_rows(row_path)[0]
            else:
                summary_path = one_monitor / "summary.json"
                monitor_summary = (
                    json.loads(summary_path.read_text())
                    if summary_path.exists() else {}
                )
                status = (
                    "killed_timeout"
                    if monitor_summary.get("timed_out") else "process_failure"
                )
                row = {
                    "dataset": "tabula", "method_id": method_id,
                    "method_family": family, "ncomp_requested": ncomp,
                    "replicate": replicate, "status": status,
                    "error_message": f"worker exit code {completed.returncode}",
                }
                write_combined([row], row_path)
            results.append(add_memory(row, one_monitor / "summary.json"))
            if hard_failure(row.get("status", "")):
                method_failure = row["status"]
            write_combined(results, args.results / "tabula_r_panel_progress.csv")

    write_combined(results, args.results / "tabula_r_panel_all_runs.csv")


if __name__ == "__main__":
    main()
