#!/usr/bin/env python3
"""Run the complete component-matched IKPLS panel in isolated processes."""

import argparse
import csv
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time

import pandas as pd
import psutil


HERE = Path(__file__).resolve().parent
WORKER = HERE / "worker_ikpls_panel.py"


def failure_row(dataset: str, replicate: int, message: str) -> dict:
    return {
        "dataset": dataset,
        "implementation": "IKPLS_numpy_alg2",
        "precision": "float32",
        "replicate": replicate,
        "status": "failed",
        "error": message,
    }


def write_row(path: Path, row: dict) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=row.keys())
        writer.writeheader()
        writer.writerow(row)


def run_monitored(command: list[str], row_path: Path, log_path: Path, timeout: int) -> None:
    env = os.environ.copy()
    for name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
        env[name] = "1"
    timed_command = command
    if platform.system() == "Darwin":
        timed_command = ["/usr/bin/time", "-l", *command]
    elif platform.system() == "Linux":
        timed_command = ["/usr/bin/time", "-v", *command]
    with log_path.open("w") as log:
        process = subprocess.Popen(timed_command, env=env, stdout=log, stderr=subprocess.STDOUT)
        monitored = psutil.Process(process.pid)
        peak = 0
        started = time.monotonic()
        while process.poll() is None:
            if time.monotonic() - started > timeout:
                process.kill()
                process.wait()
                raise TimeoutError(f"timeout after {timeout} seconds")
            try:
                rss = monitored.memory_info().rss
                for child in monitored.children(recursive=True):
                    rss += child.memory_info().rss
                peak = max(peak, rss)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
            time.sleep(0.005)
    if process.returncode != 0:
        raise RuntimeError(f"worker exit code {process.returncode}")
    rows = pd.read_csv(row_path)
    log_text = log_path.read_text(errors="replace")
    if platform.system() == "Darwin":
        match = re.search(r"^\s*(\d+)\s+maximum resident set size$", log_text, re.MULTILINE)
        if match:
            peak = int(match.group(1))
    elif platform.system() == "Linux":
        match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", log_text)
        if match:
            peak = int(match.group(1)) * 1024
    rows["peak_rss_mib"] = peak / 1024**2
    rows["incremental_peak_rss_mib"] = rows["peak_rss_mib"] - rows["prefit_rss_mib"]
    rows.to_csv(row_path, index=False)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--timeout", type=int, default=10000)
    parser.add_argument("--datasets", default="")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.repetitions < 1 or args.timeout < 1:
        parser.error("repetitions and timeout must be positive")
    manifest = pd.read_csv(args.inputs / "manifest.csv")
    available = manifest["dataset"].tolist()
    datasets = available
    if args.datasets:
        datasets = [value.strip() for value in args.datasets.split(",") if value.strip()]
        unknown = sorted(set(datasets) - set(available))
        if unknown:
            parser.error("unknown datasets: " + ", ".join(unknown))
    args.results.mkdir(parents=True, exist_ok=True)
    rows_dir = args.results / "rows"
    rows_dir.mkdir(exist_ok=True)
    python = os.environ.get("IKPLS_PYTHON", sys.executable)

    for dataset in datasets:
        for replicate in range(1, args.repetitions + 1):
            row_path = rows_dir / f"{dataset}__IKPLS_numpy_alg2__rep{replicate}.csv"
            log_path = row_path.with_suffix(".log")
            if row_path.exists() and not args.force:
                continue
            command = [python, str(WORKER), str(args.inputs / dataset), str(replicate), str(row_path)]
            print(time.strftime("%Y-%m-%d %H:%M:%S"), dataset, replicate, flush=True)
            try:
                run_monitored(command, row_path, log_path, args.timeout)
            except Exception as error:
                write_row(row_path, failure_row(dataset, replicate, str(error)))

    frames = [pd.read_csv(path) for path in sorted(rows_dir.glob("*.csv"))]
    if not frames:
        raise RuntimeError("No IKPLS result rows were generated")
    results = pd.concat(frames, ignore_index=True, sort=False)
    results.to_csv(args.results / "ikpls_panel_all_runs.csv", index=False)
    success = results[results["status"] == "success"].copy()
    group_keys = [
        "dataset", "task_type", "implementation", "package_version",
        "algorithm", "precision", "ncomp",
    ]
    summary = success.groupby(group_keys, dropna=False).agg(
        repetitions=("replicate", "count"),
        accuracy=("accuracy", "median"),
        balanced_accuracy=("balanced_accuracy", "median"),
        top5_accuracy=("top5_accuracy", "median"),
        correct=("correct", "median"),
        test_total=("test_total", "median"),
        rmsd=("rmsd", "median"),
        q2=("q2", "median"),
        mae=("mae", "median"),
        median_fit_sec=("fit_sec", "median"),
        iqr_fit_sec=("fit_sec", lambda x: x.quantile(0.75) - x.quantile(0.25)),
        median_prediction_sec=("prediction_sec", "median"),
        median_total_sec=("total_sec", "median"),
        iqr_total_sec=("total_sec", lambda x: x.quantile(0.75) - x.quantile(0.25)),
        median_peak_rss_mib=("peak_rss_mib", "median"),
        median_incremental_peak_rss_mib=("incremental_peak_rss_mib", "median"),
    ).reset_index()
    summary.to_csv(args.results / "ikpls_panel_summary.csv", index=False)
    status = results.groupby(["dataset", "status"], dropna=False).size().reset_index(name="runs")
    status.to_csv(args.results / "ikpls_panel_status.csv", index=False)
    print(summary.to_string(index=False))
    print(status.to_string(index=False))


if __name__ == "__main__":
    main()
