#!/usr/bin/env python3
"""Run the fixed-component Figure 1 R-package workflows in fresh processes."""

import argparse
import csv
import json
import os
from pathlib import Path
import signal
import shutil
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
METHOD_PACKAGES = {
    "pls_simpls_fit": "pls",
    "plsgenomics_pls_lda": "plsgenomics",
    "plsgenomics_pls_regression": "plsgenomics",
    "mdatools_plsda_or_pls": "mdatools",
    "plsdepot_simpls": "plsdepot",
    "pcv_simpls": "pcv",
    "chemometrics_pls_eigen": "chemometrics",
    "mixOmics_plsda": "mixOmics",
    "mixOmics_pls": "mixOmics",
    "spls_splsda": "spls",
    "spls_spls": "spls",
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


def latest_monitor_summary(monitor_dir, stem):
    """Return the newest monitor summary recorded for one benchmark row."""
    candidates = []
    for path in monitor_dir.glob(f"{stem}*"):
        summary = path / "summary.json"
        if path.is_dir() and summary.is_file():
            candidates.append(summary)
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def has_monitor_evidence(row):
    """Whether a failed row records a bounded fresh-process attempt."""
    status = row.get("status", "").lower()
    if status in {"ok", "success"}:
        return True
    elapsed = row.get("monitor_elapsed_sec", "")
    exit_code = row.get("monitor_exit_code", "")
    try:
        return float(elapsed) >= 0 and str(exit_code) != ""
    except (TypeError, ValueError):
        return False


def succeeded(row):
    return row.get("status", "").lower() in {"ok", "success"}


def suppressed_after_first_failure(row):
    return (
        row.get("status", "").lower()
        == "not_repeated_after_first_failure"
        and str(row.get("source_replicate", "")) == "1"
        and str(row.get("first_attempt_status", "")) != ""
    )


def first_attempt_row(rows_dir, monitor_dir, dataset, method_id, ncomp):
    stem = f"{dataset}__{method_id}__n{ncomp}__rep1"
    path = rows_dir / f"{stem}.csv"
    if not path.is_file():
        return None
    row = read_rows(path)[0]
    summary = latest_monitor_summary(monitor_dir, stem)
    if summary is not None:
        row = attach_memory(row, summary)
    return row


def suppressed_repeat(dataset_row, method_id, ncomp, replicate, first):
    return {
        "dataset": dataset_row["dataset"],
        "task_type": dataset_row["task_type"],
        "method_id": method_id,
        "package": METHOD_PACKAGES[method_id],
        "ncomp_requested": ncomp,
        "replicate": replicate,
        "status": "not_repeated_after_first_failure",
        "error_message": (
            "repetitions after the first failed attempt were not run"
        ),
        "source_replicate": 1,
        "first_attempt_status": first.get("status", ""),
        "first_attempt_monitor_timed_out": first.get(
            "monitor_timed_out", ""
        ),
        "first_attempt_monitor_elapsed_sec": first.get(
            "monitor_elapsed_sec", ""
        ),
        "first_attempt_monitor_exit_code": first.get(
            "monitor_exit_code", ""
        ),
    }


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


def unused_path(path):
    """Return path or a numbered sibling without overwriting evidence."""
    if not path.exists():
        return path
    counter = 2
    while True:
        candidate = path.with_name(f"{path.name}__{counter}")
        if not candidate.exists():
            return candidate
        counter += 1


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
        "--memory-limit-mib",
        type=int,
        default=28672,
        help=(
            "Per-process address-space limit. This permits a real attempt "
            "while protecting the benchmark host from complete exhaustion."
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
    placeholder_dir = args.results.resolve() / "placeholder_history"
    rows_dir.mkdir(parents=True, exist_ok=True)
    monitor_dir.mkdir(parents=True, exist_ok=True)
    placeholder_dir.mkdir(parents=True, exist_ok=True)
    raw_path = args.results.resolve() / "figure1_r_packages_raw.csv"
    existing_rows = {}
    if raw_path.is_file():
        for row in read_rows(raw_path):
            key = (
                row.get("dataset", ""), row.get("method_id", ""),
                row.get("ncomp_requested", ""), row.get("replicate", ""),
            )
            existing_rows[key] = row
    worker = repo / "benchmark/benchmark_pls_package_comparison.R"
    monitor = repo / "benchmark/current_release_evidence/monitor_process.py"
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
            for replicate in range(1, args.repetitions + 1):
                stem = f"{dataset}__{method_id}__n{ncomp}__rep{replicate}"
                row_path = rows_dir / f"{stem}.csv"
                one_monitor = monitor_dir / stem
                first = first_attempt_row(
                    rows_dir, monitor_dir, dataset, method_id, ncomp
                )
                if replicate > 1 and first is not None and not succeeded(first):
                    existing_evidence = False
                    if row_path.is_file():
                        existing = read_rows(row_path)[0]
                        summary = latest_monitor_summary(monitor_dir, stem)
                        if summary is not None:
                            existing = attach_memory(existing, summary)
                        existing_evidence = (
                            suppressed_after_first_failure(existing)
                            or has_monitor_evidence(existing)
                        )
                        if not existing_evidence:
                            archived = unused_path(
                                placeholder_dir / row_path.name
                            )
                            shutil.move(str(row_path), str(archived))
                    if not existing_evidence:
                        row = suppressed_repeat(
                            dataset_row, method_id, ncomp, replicate, first
                        )
                        write_rows(row_path, [row])
                        all_rows.append(row)
                        write_rows(
                            args.results.resolve()
                            / "figure1_r_packages_progress.csv",
                            all_rows,
                        )
                        print(stem, row.get("status"), flush=True)
                        continue
                if row_path.is_file():
                    summary = latest_monitor_summary(monitor_dir, stem)
                    row = read_rows(row_path)[0]
                    if summary is not None:
                        row = attach_memory(row, summary)
                    if suppressed_after_first_failure(row):
                        all_rows.append(row)
                        continue
                    if row.get("status", "").lower().startswith(
                        "not_evaluated"
                    ):
                        # Placeholder exclusions are not evidence. Replace each
                        # with its own bounded fresh-process attempt while
                        # retaining the original record for provenance.
                        archived = unused_path(placeholder_dir / row_path.name)
                        shutil.move(str(row_path), str(archived))
                        one_monitor = unused_path(
                            monitor_dir / f"{stem}__actual_attempt"
                        )
                    elif not has_monitor_evidence(row):
                        archived = unused_path(placeholder_dir / row_path.name)
                        shutil.move(str(row_path), str(archived))
                        one_monitor = unused_path(
                            monitor_dir / f"{stem}__actual_attempt"
                        )
                    else:
                        all_rows.append(row)
                        continue
                else:
                    key = (dataset, method_id, str(ncomp), str(replicate))
                    row = existing_rows.get(key)
                    if row is not None:
                        if suppressed_after_first_failure(row):
                            all_rows.append(row)
                            continue
                        if row.get("status", "").lower().startswith(
                            "not_evaluated"
                        ):
                            archived = unused_path(placeholder_dir / row_path.name)
                            write_rows(archived, [row])
                            one_monitor = unused_path(
                                monitor_dir / f"{stem}__actual_attempt"
                            )
                        elif not has_monitor_evidence(row):
                            archived = unused_path(
                                placeholder_dir / row_path.name
                            )
                            write_rows(archived, [row])
                            one_monitor = unused_path(
                                monitor_dir / f"{stem}__actual_attempt"
                            )
                        else:
                            all_rows.append(row)
                            continue
                if one_monitor.exists():
                    one_monitor = unused_path(
                        monitor_dir / f"{stem}__resumed_attempt"
                    )
                command = [
                    "Rscript", str(worker), "--mode=run_one",
                    f"--dataset={dataset}", f"--ncomp={ncomp}",
                    f"--method-id={method_id}", f"--replicate={replicate}",
                    f"--row-out={row_path}",
                ]
                monitored = [
                    "python3", str(monitor), f"--output={one_monitor}",
                    f"--timeout={args.timeout}",
                    f"--memory-limit-mib={args.memory_limit_mib}",
                    "--interval=0.005", "--",
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
                        "package": METHOD_PACKAGES[method_id],
                        "ncomp_requested": ncomp,
                        "replicate": replicate,
                        "status": "process_failure",
                        "error_message": f"worker exit code {returncode}",
                    }
                    write_rows(row_path, [row])
                row = attach_memory(row, one_monitor / "summary.json")
                write_rows(row_path, [row])
                all_rows.append(row)
                write_rows(
                    args.results.resolve() / "figure1_r_packages_progress.csv",
                    all_rows,
                )
                print(stem, row.get("status"), flush=True)

    write_rows(raw_path, all_rows)


if __name__ == "__main__":
    main()
