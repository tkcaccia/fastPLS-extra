#!/usr/bin/env python3

import csv
import os
import pathlib
import re
import subprocess
import sys

import pandas as pd


HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = pathlib.Path(sys.argv[1])
INPUTS = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else OUT / "inputs"
ROWS = OUT / "rows"
ROWS.mkdir(parents=True, exist_ok=True)
PYTHON = os.environ.get("FASTPLS_IKPLS_PYTHON", "/private/tmp/fastpls_ikpls_venv/bin/python")


def run(command: list[str], row: pathlib.Path, log: pathlib.Path, extra_env=None):
    env = os.environ.copy()
    env.update(extra_env or {})
    env.update({
        "OMP_NUM_THREADS": "1",
        "OPENBLAS_NUM_THREADS": "1",
        "MKL_NUM_THREADS": "1",
    })
    with log.open("w") as handle:
        completed = subprocess.run(
            ["/usr/bin/time", "-v", *command], cwd=ROOT, env=env,
            stdout=handle, stderr=subprocess.STDOUT, check=False,
        )
    if completed.returncode != 0:
        raise RuntimeError(f"exit {completed.returncode}; see {log}")
    frame = pd.read_csv(row)
    text = log.read_text(errors="replace")
    match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", text)
    frame["peak_rss_mb"] = float(match.group(1)) / 1024 if match else float("nan")
    frame.to_csv(row, index=False)


implementations = (
    ("fastPLS_cuda_rsvd", "fastpls"),
    ("IKPLS_jax_cuda_alg1", "jax1"),
    ("IKPLS_jax_cuda_alg2", "jax2"),
)
for dataset in ("breast", "metref", "cifar100"):
    dataset_dir = INPUTS / dataset
    if not dataset_dir.is_dir():
        raise SystemExit(f"Missing exported input directory: {dataset_dir}")
    for implementation, kind in implementations:
        for replicate in range(1, 4):
            row = ROWS / f"{dataset}__{implementation}__rep{replicate}.csv"
            log = row.with_suffix(".log")
            print(dataset, implementation, replicate, flush=True)
            try:
                if kind == "fastpls":
                    command = [
                        "Rscript", str(HERE / "worker_fastpls.R"),
                        str(dataset_dir), "rsvd", str(replicate), str(row),
                    ]
                    extra = {
                        "FASTPLS_BENCH_BACKEND": "cuda",
                        "FASTPLS_BENCH_LIB": os.environ["FASTPLS_BENCH_LIB"],
                        "R_LIBS": os.environ["FASTPLS_BENCH_LIB"],
                        "R_LIBS_USER": os.environ["FASTPLS_BENCH_LIB"],
                    }
                else:
                    algorithm = "1" if kind == "jax1" else "2"
                    command = [
                        PYTHON, str(HERE / "worker_ikpls_jax.py"),
                        str(dataset_dir), algorithm, str(replicate), str(row),
                    ]
                    extra = {}
                run(command, row, log, extra)
            except Exception as error:
                with row.open("w", newline="") as handle:
                    writer = csv.DictWriter(
                        handle,
                        fieldnames=["dataset", "implementation", "replicate", "status", "error"],
                    )
                    writer.writeheader()
                    writer.writerow({
                        "dataset": dataset, "implementation": implementation,
                        "replicate": replicate, "status": "failed", "error": str(error),
                    })

frames = [pd.read_csv(path) for path in sorted(ROWS.glob("*.csv"))]
all_rows = pd.concat(frames, ignore_index=True, sort=False)
all_rows["status"] = all_rows.get(
    "status", pd.Series(index=all_rows.index, dtype=object)
).fillna("success")
all_rows.to_csv(OUT / "ikpls_cross_language_cuda_all_runs.csv", index=False)

success = all_rows[all_rows["status"] == "success"].copy()
success["reported_total_sec"] = success["cold_total_sec"].fillna(success["total_sec"])
success["reported_warm_total_sec"] = success["warm_total_sec"].fillna(success["total_sec"])
summary = success.groupby(
    ["dataset", "implementation", "package_version", "precision", "ncomp"],
    dropna=False,
).agg(
    repetitions=("replicate", "count"),
    accuracy=("accuracy", "median"),
    median_cold_total_sec=("reported_total_sec", "median"),
    iqr_cold_total_sec=("reported_total_sec", lambda x: x.quantile(.75) - x.quantile(.25)),
    median_warm_total_sec=("reported_warm_total_sec", "median"),
    median_peak_rss_mb=("peak_rss_mb", "median"),
).reset_index()
summary.to_csv(OUT / "ikpls_cross_language_cuda_summary.csv", index=False)
print(summary.to_string(index=False))
