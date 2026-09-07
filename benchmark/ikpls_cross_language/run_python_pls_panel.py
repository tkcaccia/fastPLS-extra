#!/usr/bin/env python3
"""Run component-matched nirs4all-methods and scikit-learn PLS panels."""

import argparse
import csv
import importlib.metadata
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
WORKER = HERE / "worker_python_pls_panel.py"
DEFAULT_IMPLEMENTATIONS = (
    "nirs4all_methods_simpls",
    "nirs4all_methods_rsvd",
    "sklearn_plsregression",
)


def write_environment(path: Path) -> None:
    packages = ("numpy", "pandas", "psutil", "pls4all", "scikit-learn")
    rows = [
        ("python", sys.version.replace("\n", " ")),
        ("platform", platform.platform()),
        *[
            (package, importlib.metadata.version(package))
            for package in packages
        ],
        ("cpu_thread_contract", "one effective BLAS/OpenMP thread"),
    ]
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(("item", "value"))
        writer.writerows(rows)


def failure_row(
    dataset: str,
    replicate: int,
    implementation: str,
    message: str,
) -> dict:
    return {
        "dataset": dataset,
        "implementation": implementation,
        "replicate": replicate,
        "status": "failed",
        "error": message,
    }


def write_row(path: Path, row: dict) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=row.keys())
        writer.writeheader()
        writer.writerow(row)


def run_monitored(
    command: list[str],
    row_path: Path,
    log_path: Path,
    timeout: int,
) -> None:
    env = os.environ.copy()
    for name in (
        "OMP_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "MKL_NUM_THREADS",
        "NUMEXPR_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS",
    ):
        env[name] = "1"
    timed_command = command
    if platform.system() == "Linux":
        timed_command = ["/usr/bin/time", "-v", *command]
    with log_path.open("w") as log:
        process = subprocess.Popen(
            timed_command,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
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
            except (psutil.Error, OSError):
                pass
            time.sleep(0.005)
    if process.returncode != 0:
        log_text = log_path.read_text(errors="replace")
        tail = " | ".join(log_text.strip().splitlines()[-3:])
        raise RuntimeError(
            f"worker exit code {process.returncode}"
            + (f": {tail}" if tail else "")
        )
    rows = pd.read_csv(row_path)
    log_text = log_path.read_text(errors="replace")
    if peak <= 0:
        peak = float(rows["prefit_rss_mib"].iloc[0]) * 1024**2
    if "warning_count" not in rows:
        convergence_warnings = log_text.count("ConvergenceWarning")
        rows["warning_count"] = convergence_warnings
        rows["warnings"] = (
            "scikit-learn component iteration limit reached"
            if convergence_warnings
            else ""
        )
    if platform.system() == "Linux":
        match = re.search(
            r"Maximum resident set size \(kbytes\):\s*(\d+)",
            log_text,
        )
        if match:
            peak = int(match.group(1)) * 1024
    rows["peak_rss_mib"] = peak / 1024**2
    rows["incremental_peak_rss_mib"] = (
        rows["peak_rss_mib"] - rows["prefit_rss_mib"]
    )
    rows.to_csv(row_path, index=False)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--timeout", type=int, default=10000)
    parser.add_argument("--datasets", default="")
    parser.add_argument(
        "--implementations",
        default=",".join(DEFAULT_IMPLEMENTATIONS),
    )
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.repetitions < 1 or args.timeout < 1:
        parser.error("repetitions and timeout must be positive")

    implementations = [
        value.strip()
        for value in args.implementations.split(",")
        if value.strip()
    ]
    unknown_implementations = sorted(
        set(implementations) - set(DEFAULT_IMPLEMENTATIONS)
    )
    if unknown_implementations:
        parser.error(
            "unknown implementations: "
            + ", ".join(unknown_implementations)
        )

    manifest = pd.read_csv(args.inputs / "manifest.csv")
    available = manifest["dataset"].tolist()
    datasets = available
    if args.datasets:
        datasets = [
            value.strip()
            for value in args.datasets.split(",")
            if value.strip()
        ]
        unknown = sorted(set(datasets) - set(available))
        if unknown:
            parser.error("unknown datasets: " + ", ".join(unknown))

    args.results.mkdir(parents=True, exist_ok=True)
    write_environment(args.results / "python_pls_environment.tsv")
    rows_dir = args.results / "rows"
    rows_dir.mkdir(exist_ok=True)
    python = os.environ.get("PYTHON_PLS_BENCH_PYTHON", sys.executable)

    for dataset in datasets:
        for implementation in implementations:
            for replicate in range(1, args.repetitions + 1):
                stem = f"{dataset}__{implementation}__rep{replicate}"
                row_path = rows_dir / f"{stem}.csv"
                log_path = rows_dir / f"{stem}.log"
                if row_path.exists() and not args.force:
                    continue
                command = [
                    python,
                    str(WORKER),
                    str(args.inputs / dataset),
                    str(replicate),
                    implementation,
                    str(row_path),
                ]
                print(
                    time.strftime("%Y-%m-%d %H:%M:%S"),
                    dataset,
                    implementation,
                    replicate,
                    flush=True,
                )
                try:
                    run_monitored(command, row_path, log_path, args.timeout)
                except Exception as error:
                    write_row(
                        row_path,
                        failure_row(
                            dataset,
                            replicate,
                            implementation,
                            str(error),
                        ),
                    )

    frames = [
        pd.read_csv(path)
        for path in sorted(rows_dir.glob("*.csv"))
    ]
    if not frames:
        raise RuntimeError("No Python PLS result rows were generated")
    results = pd.concat(frames, ignore_index=True, sort=False)
    results.to_csv(
        args.results / "python_pls_panel_all_runs.csv",
        index=False,
    )
    success = results[results["status"] == "success"].copy()
    group_keys = [
        "dataset",
        "task_type",
        "implementation",
        "package",
        "package_version",
        "algorithm",
        "solver_controls",
        "precision",
        "ncomp",
    ]
    if len(success):
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
            iqr_fit_sec=(
                "fit_sec",
                lambda x: x.quantile(0.75) - x.quantile(0.25),
            ),
            median_prediction_sec=("prediction_sec", "median"),
            median_total_sec=("total_sec", "median"),
            iqr_total_sec=(
                "total_sec",
                lambda x: x.quantile(0.75) - x.quantile(0.25),
            ),
            median_peak_rss_mib=("peak_rss_mib", "median"),
            median_incremental_peak_rss_mib=(
                "incremental_peak_rss_mib",
                "median",
            ),
            runs_with_warnings=("warning_count", lambda x: (x > 0).sum()),
        ).reset_index()
    else:
        summary = pd.DataFrame(columns=group_keys)
    summary.to_csv(
        args.results / "python_pls_panel_summary.csv",
        index=False,
    )
    status = results.groupby(
        ["dataset", "implementation", "status"],
        dropna=False,
    ).agg(
        runs=("replicate", "count"),
        detail=(
            "error",
            lambda x: " | ".join(
                dict.fromkeys(str(value) for value in x if pd.notna(value))
            ),
        ),
    ).reset_index()
    status.to_csv(
        args.results / "python_pls_panel_status.csv",
        index=False,
    )
    print(summary.to_string(index=False))
    print(status.to_string(index=False))


if __name__ == "__main__":
    main()
