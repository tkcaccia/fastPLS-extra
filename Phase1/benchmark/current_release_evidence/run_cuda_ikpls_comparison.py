#!/usr/bin/env python3
"""Run the matched float32 fastPLS/IKPLS CUDA comparison."""

import argparse
import csv
import os
from pathlib import Path
import subprocess
import time

import pandas as pd
import psutil


HERE = Path(__file__).resolve().parent


def read_contract(path: Path) -> list[dict]:
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    for row in rows:
        row["ncomp"] = int(row["simpls_ncomp"])
    return rows


def gpu_process_mib(pids: set[int]) -> float:
    query = subprocess.run(
        [
            "nvidia-smi",
            "--query-compute-apps=pid,used_memory",
            "--format=csv,noheader,nounits",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    total = 0.0
    for line in query.stdout.splitlines():
        fields = [field.strip() for field in line.split(",")]
        if len(fields) == 2 and fields[0].isdigit() and int(fields[0]) in pids:
            try:
                total += float(fields[1])
            except ValueError:
                pass
    return total


def failure_row(dataset: str, task_type: str, implementation: str,
                replicate: int, ncomp: int, error: str) -> dict:
    return {
        "dataset": dataset,
        "task_type": task_type,
        "implementation": implementation,
        "replicate": replicate,
        "ncomp_requested": ncomp,
        "status": "failed",
        "error": error,
    }


def run_monitored(command: list[str], output: Path, ready: Path, go: Path,
                  log: Path, timeout: int, env: dict[str, str]) -> dict:
    with log.open("w") as stream:
        process = subprocess.Popen(
            command,
            stdout=stream,
            stderr=subprocess.STDOUT,
            env=env,
        )
        deadline = time.monotonic() + timeout
        monitored = psutil.Process(process.pid)
        while not ready.exists() and process.poll() is None:
            if time.monotonic() >= deadline:
                process.kill()
                process.wait()
                raise TimeoutError("worker did not reach the timed boundary")
            time.sleep(0.02)
        if process.poll() is not None:
            raise RuntimeError("worker exited before the timed boundary")
        baseline = float(ready.read_text().strip())
        peak_rss = baseline
        peak_gpu = 0.0
        go.touch()
        while process.poll() is None:
            if time.monotonic() >= deadline:
                process.kill()
                process.wait()
                raise TimeoutError(f"timeout after {timeout} seconds")
            pids = {process.pid}
            try:
                children = monitored.children(recursive=True)
                pids.update(child.pid for child in children)
                rss = monitored.memory_info().rss
                rss += sum(child.memory_info().rss for child in children)
                peak_rss = max(peak_rss, rss / 1024**2)
            except (psutil.Error, OSError):
                pass
            peak_gpu = max(peak_gpu, gpu_process_mib(pids))
            time.sleep(0.01)
    if process.returncode != 0:
        tail = " | ".join(log.read_text(errors="replace").splitlines()[-8:])
        raise RuntimeError(f"worker exit {process.returncode}: {tail}")
    with output.open(newline="") as handle:
        row = next(csv.DictReader(handle))
    row["peak_rss_mib"] = f"{peak_rss:.9f}"
    row["incremental_peak_rss_mib"] = f"{max(0.0, peak_rss-baseline):.9f}"
    row["peak_gpu_process_mib"] = f"{peak_gpu:.9f}"
    return row


def write_row(path: Path, row: dict) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(row))
        writer.writeheader()
        writer.writerow(row)


def summarize(rows: pd.DataFrame) -> pd.DataFrame:
    success = rows[rows["status"] == "success"].copy()
    numeric = [
        "accuracy", "balanced_accuracy", "top5_accuracy", "rmsd", "q2",
        "mae", "cold_fit_sec", "cold_prediction_sec", "cold_total_sec",
        "warm_fit_sec", "warm_prediction_sec", "warm_total_sec",
        "peak_rss_mib", "incremental_peak_rss_mib", "peak_gpu_process_mib",
    ]
    for column in numeric:
        success[column] = pd.to_numeric(success.get(column), errors="coerce")
    keys = [
        "dataset", "task_type", "implementation", "package_version",
        "precision", "backend", "method", "classifier", "ncomp_requested",
    ]
    aggregations = {"replicate": "count"}
    for column in numeric:
        aggregations[column] = "median"
    if len(success):
        result = success.groupby(keys, dropna=False).agg(aggregations).reset_index()
        result = result.rename(columns={
            "replicate": "repetitions",
            **{column: f"median_{column}" for column in numeric},
        })
        result["status"] = "success"
        result["error"] = ""
    else:
        result = pd.DataFrame()

    completed = set()
    if len(result):
        completed = set(zip(result["dataset"], result["implementation"]))
    failed_rows = []
    failed = rows[rows["status"] != "success"].copy()
    for (dataset, implementation), group in failed.groupby(
        ["dataset", "implementation"], dropna=False
    ):
        if (dataset, implementation) in completed:
            continue
        first = group.iloc[0]
        row = {column: first.get(column, "") for column in keys}
        row.update({
            "repetitions": 0,
            "status": "memory_limit" if group["error"].astype(str).str.contains(
                "memory|RESOURCE_EXHAUSTED|out of memory|oom",
                case=False,
                regex=True,
            ).any() else "failed",
            "error": " | ".join(dict.fromkeys(group["error"].astype(str))),
        })
        for column in numeric:
            row[f"median_{column}"] = float("nan")
        failed_rows.append(row)
    if failed_rows:
        result = pd.concat([result, pd.DataFrame(failed_rows)], ignore_index=True)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--tasks", required=True, type=Path)
    parser.add_argument("--ikpls-inputs", required=True, type=Path)
    parser.add_argument("--component-contract", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--large-repetitions", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=10000)
    parser.add_argument("--oversample", type=int, default=32)
    parser.add_argument("--power", type=int, default=5)
    parser.add_argument("--datasets", default="")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    contract = read_contract(args.component_contract)
    if args.datasets:
        selected = {item.strip() for item in args.datasets.split(",") if item.strip()}
        contract = [row for row in contract if row["dataset"] in selected]
    args.output.mkdir(parents=True, exist_ok=True)
    rows_dir = args.output / "rows"
    rows_dir.mkdir(exist_ok=True)
    all_rows = []
    env = os.environ.copy()
    env.update({
        "OMP_NUM_THREADS": "1",
        "OPENBLAS_NUM_THREADS": "1",
        "MKL_NUM_THREADS": "1",
        "XLA_PYTHON_CLIENT_PREALLOCATE": "false",
        "XLA_PYTHON_CLIENT_ALLOCATOR": "platform",
        "JAX_PLATFORMS": "cuda",
    })
    env["PYTHONPATH"] = os.pathsep.join(filter(None, [
        env.get("IKPLS_CUDA_PYTHONPATH", ""), env.get("PYTHONPATH", "")
    ]))

    for item in contract:
        dataset = item["dataset"]
        repetitions = (
            args.large_repetitions if dataset in {"nmr", "imagenet"}
            else args.repetitions
        )
        for implementation in ("fastPLS_cuda", "IKPLS_jax_cuda_alg2"):
            for replicate in range(1, repetitions + 1):
                stem = f"{dataset}__{implementation}__rep{replicate}"
                row_path = rows_dir / f"{stem}.csv"
                log_path = rows_dir / f"{stem}.log"
                ready_path = rows_dir / f"{stem}.ready"
                go_path = rows_dir / f"{stem}.go"
                if row_path.exists() and not args.force:
                    with row_path.open(newline="") as handle:
                        all_rows.append(next(csv.DictReader(handle)))
                    continue
                for path in (row_path, ready_path, go_path):
                    if path.exists():
                        path.unlink()
                if implementation == "fastPLS_cuda":
                    task = args.tasks / f"{dataset}_task.rds"
                    command = [
                        "Rscript", str(HERE / "figure_s_cuda_worker.R"),
                        args.library, str(task), dataset, str(item["ncomp"]),
                        str(replicate), str(row_path), str(ready_path),
                        str(go_path), str(args.oversample), str(args.power),
                        args.package_version,
                    ]
                else:
                    dataset_dir = args.ikpls_inputs / dataset
                    command = [
                        args.python,
                        str(HERE / "figure_s_ikpls_cuda_worker.py"),
                        str(dataset_dir), str(replicate), str(row_path),
                        str(ready_path), str(go_path),
                    ]
                print(time.strftime("%F %T"), dataset, implementation,
                      replicate, flush=True)
                try:
                    row = run_monitored(
                        command, row_path, ready_path, go_path, log_path,
                        args.timeout, env,
                    )
                except Exception as error:
                    row = failure_row(
                        dataset, item["task_type"], implementation,
                        replicate, item["ncomp"], str(error),
                    )
                write_row(row_path, row)
                all_rows.append(row)

    frame = pd.DataFrame(all_rows)
    frame.to_csv(args.output / "cuda_software_comparison_all_runs.csv", index=False)
    summary = summarize(frame)
    summary.to_csv(args.output / "cuda_software_comparison_summary.csv", index=False)
    failures = frame[frame["status"] != "success"]
    failures.to_csv(args.output / "cuda_software_comparison_failures.csv", index=False)
    print(summary.to_string(index=False))
    if len(failures):
        print("\nFailures:\n" + failures[[
            "dataset", "implementation", "replicate", "error"
        ]].to_string(index=False))


if __name__ == "__main__":
    main()
