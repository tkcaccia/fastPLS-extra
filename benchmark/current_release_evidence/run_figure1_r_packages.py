#!/usr/bin/env python3
"""Run the fixed-component Figure 1 R-package workflows in fresh processes."""

import argparse
import csv
import json
import os
from pathlib import Path
import signal
import subprocess


CLASSIFICATION_METHODS = (
    "pls_simpls_fit",
    "plsgenomics_pls_lda",
    "mdatools_plsda_or_pls",
    "plsdepot_simpls",
    "pcv_simpls",
    "chemometrics_pls_eigen",
    "mixOmics_plsda",
    "spls_splsda",
)
REGRESSION_METHODS = (
    "pls_simpls_fit",
    "plsgenomics_pls_regression",
    "mdatools_plsda_or_pls",
    "plsdepot_simpls",
    "pcv_simpls",
    "chemometrics_pls_eigen",
    "mixOmics_pls",
    "spls_spls",
)
STRUCTURAL_SKIP = {
    "imagenet": "not evaluated: previously established scale/resource limit",
    "nmr": "not evaluated: dense coefficient path exceeds the 32-GiB host",
}


def read_rows(path):
    with Path(path).open(newline="") as handle:
        return list(csv.DictReader(handle))


def write_rows(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    columns = list(dict.fromkeys(key for row in rows for key in row))
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def attach_memory(row, summary_path):
    if not summary_path.is_file():
        return row
    summary = json.loads(summary_path.read_text())
    measurements = summary.get("measurements", [])
    if measurements:
        row.update(measurements[0])
    row["monitor_exit_code"] = summary.get("exit_code")
    row["monitor_timed_out"] = summary.get("timed_out")
    row["monitor_elapsed_sec"] = summary.get("elapsed_sec")
    return row


def run_interruptibly(command, cwd, env):
    """Forward interruption to the monitor and every process it launched."""
    process = subprocess.Popen(command, cwd=cwd, env=env, start_new_session=True)
    previous_handlers = {}

    def forward_signal(signum, _frame):
        if process.poll() is None:
            os.killpg(process.pid, signum)
        raise SystemExit(128 + signum)

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, forward_signal)
    try:
        return process.wait()
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--tasks", required=True, type=Path)
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=10000)
    parser.add_argument(
        "--repeat-time-limit",
        type=float,
        default=300.0,
        help=(
            "After one successful run exceeds this many seconds, retain that "
            "measurement and do not launch redundant repetitions."
        ),
    )
    parser.add_argument("--datasets", default="")
    args = parser.parse_args()
    requested = {
        value.strip() for value in args.datasets.split(",") if value.strip()
    }
    contract = [
        row for row in read_rows(args.contract)
        if not requested or row["dataset"] in requested
    ]
    if not contract:
        parser.error("the selected Figure 1 contract is empty")

    repo = args.repo.resolve()
    rows_dir = args.results.resolve() / "rows"
    monitor_dir = args.results.resolve() / "monitor"
    rows_dir.mkdir(parents=True, exist_ok=True)
    monitor_dir.mkdir(parents=True, exist_ok=True)
    worker = repo / "benchmark/benchmark_pls_package_comparison.R"
    monitor = repo / "benchmark/optimization/monitor_process.py"
    env = dict(os.environ)
    env.update({
        "FASTPLS_BENCH_LIB": str(args.library.resolve()),
        "FASTPLS_TASK_ROOT": str(args.tasks.resolve()),
        "FASTPLS_BENCH_PRECISION": "float32",
        "OPENBLAS_NUM_THREADS": "1",
        "OMP_NUM_THREADS": "1",
        "MKL_NUM_THREADS": "1",
        "BLIS_NUM_THREADS": "1",
    })

    all_rows = []
    for dataset_row in contract:
        dataset = dataset_row["dataset"]
        task_type = dataset_row["task_type"]
        ncomp = int(dataset_row["external_ncomp"])
        methods = (
            CLASSIFICATION_METHODS
            if task_type == "classification"
            else REGRESSION_METHODS
        )
        for method_id in methods:
            prior_failure = ""
            prior_long_run = ""
            for replicate in range(1, args.repetitions + 1):
                stem = f"{dataset}__{method_id}__n{ncomp}__rep{replicate}"
                row_path = rows_dir / f"{stem}.csv"
                one_monitor = monitor_dir / stem
                if row_path.is_file():
                    row = attach_memory(read_rows(row_path)[0], one_monitor / "summary.json")
                    all_rows.append(row)
                    if row.get("status") not in {"ok", "success"}:
                        prior_failure = row.get("error_message", row["status"])
                    elif (
                        float(row.get("monitor_elapsed_sec") or 0)
                        > args.repeat_time_limit
                    ):
                        prior_long_run = (
                            "first successful run exceeded the repeat-time limit "
                            f"of {args.repeat_time_limit:g} seconds"
                        )
                    continue
                if dataset in STRUCTURAL_SKIP:
                    row = {
                        "dataset": dataset,
                        "task_type": task_type,
                        "method_id": method_id,
                        "ncomp_requested": ncomp,
                        "replicate": replicate,
                        "status": "not_evaluated_known_scale_limit",
                        "error_message": STRUCTURAL_SKIP[dataset],
                    }
                    write_rows(row_path, [row])
                    all_rows.append(row)
                    continue
                if prior_failure:
                    row = {
                        "dataset": dataset,
                        "task_type": task_type,
                        "method_id": method_id,
                        "ncomp_requested": ncomp,
                        "replicate": replicate,
                        "status": "not_repeated_after_failure",
                        "error_message": prior_failure,
                    }
                    write_rows(row_path, [row])
                    all_rows.append(row)
                    continue
                if prior_long_run:
                    row = {
                        "dataset": dataset,
                        "task_type": task_type,
                        "method_id": method_id,
                        "ncomp_requested": ncomp,
                        "replicate": replicate,
                        "status": "not_repeated_long_runtime",
                        "error_message": prior_long_run,
                    }
                    write_rows(row_path, [row])
                    all_rows.append(row)
                    continue
                command = [
                    "Rscript", str(worker), "--mode=run_one",
                    f"--dataset={dataset}", f"--ncomp={ncomp}",
                    f"--method-id={method_id}", f"--replicate={replicate}",
                    f"--row-out={row_path}",
                ]
                monitored = [
                    "python3", str(monitor), f"--output={one_monitor}",
                    f"--timeout={args.timeout}", "--interval=0.005", "--",
                    *command,
                ]
                returncode = run_interruptibly(monitored, cwd=repo, env=env)
                if row_path.is_file():
                    row = read_rows(row_path)[0]
                else:
                    row = {
                        "dataset": dataset,
                        "task_type": task_type,
                        "method_id": method_id,
                        "ncomp_requested": ncomp,
                        "replicate": replicate,
                        "status": "process_failure",
                        "error_message": f"worker exit code {returncode}",
                    }
                    write_rows(row_path, [row])
                row = attach_memory(row, one_monitor / "summary.json")
                if row.get("status") not in {"ok", "success"}:
                    prior_failure = row.get("error_message", row["status"])
                elif (
                    float(row.get("monitor_elapsed_sec") or 0)
                    > args.repeat_time_limit
                ):
                    prior_long_run = (
                        "first successful run exceeded the repeat-time limit "
                        f"of {args.repeat_time_limit:g} seconds"
                    )
                all_rows.append(row)
                write_rows(args.results.resolve() / "figure1_r_packages_progress.csv", all_rows)
                print(stem, row.get("status"), flush=True)

    write_rows(args.results.resolve() / "figure1_r_packages_raw.csv", all_rows)


if __name__ == "__main__":
    main()
