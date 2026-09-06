#!/usr/bin/env python3
"""Run the large-case IKPLS float32 feasibility benchmark.

Prepared inputs are created by export_large_float32.R and, for ImageNet,
prepare_imagenet_float32.py. Conversion and preprocessing deliberately remain
outside model timing.
"""

import argparse
import csv
import os
from pathlib import Path
import resource
import subprocess
import sys


HERE = Path(__file__).resolve().parent
WORKER = HERE / "worker_ikpls_large_float32.py"


def component_list(value):
    try:
        values = [int(x) for x in value.split(",") if x.strip()]
    except ValueError as exc:
        raise argparse.ArgumentTypeError("components must be comma-separated integers") from exc
    if not values or any(x < 1 for x in values):
        raise argparse.ArgumentTypeError("components must contain positive integers")
    return values


def memory_guard(limit_gib):
    def apply_limit():
        if limit_gib is None:
            return
        limit = int(limit_gib * 1024**3)
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))

    return apply_limit


def failure_row(dataset, ncomp, message):
    return {
        "dataset": dataset,
        "implementation": "IKPLS_numpy_cross_product",
        "precision": "float32",
        "ncomp": ncomp,
        "status": "failed",
        "error": message,
    }


def write_failure(path, row):
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=row.keys())
        writer.writeheader()
        writer.writerow(row)


def run_case(dataset, data_dir, results_dir, ncomp, block, timeout, memory_limit_gib):
    stem = f"{dataset}_ikpls_f32_n{ncomp}"
    output = results_dir / f"{stem}.csv"
    log = results_dir / f"{stem}.log"
    command = [sys.executable, str(WORKER), str(data_dir), str(ncomp), str(output), str(block)]
    env = os.environ.copy()
    for key in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
        env[key] = "1"

    with log.open("w") as handle:
        handle.write("command=" + " ".join(command) + "\n")
        handle.write(f"memory_limit_gib={memory_limit_gib or 'none'}\n")
        handle.flush()
        try:
            completed = subprocess.run(
                command,
                stdout=handle,
                stderr=subprocess.STDOUT,
                env=env,
                timeout=timeout,
                check=False,
                preexec_fn=memory_guard(memory_limit_gib),
            )
            if completed.returncode != 0 and not output.exists():
                write_failure(output, failure_row(dataset, ncomp, f"worker exit code {completed.returncode}"))
        except subprocess.TimeoutExpired:
            write_failure(output, failure_row(dataset, ncomp, f"timeout after {timeout} seconds"))
    print(f"[{dataset}] ncomp={ncomp}: {output}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--datasets", default="nmr,imagenet")
    parser.add_argument("--nmr-components", type=component_list, default=[1, 5])
    parser.add_argument("--imagenet-components", type=component_list, default=[100, 200, 500, 1000])
    parser.add_argument("--block", type=int, default=2000)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--nmr-memory-limit-gib", type=float, default=10.0)
    args = parser.parse_args()

    datasets = [x.strip().lower() for x in args.datasets.split(",") if x.strip()]
    invalid = sorted(set(datasets) - {"nmr", "imagenet"})
    if invalid:
        parser.error("unsupported datasets: " + ", ".join(invalid))
    args.results.mkdir(parents=True, exist_ok=True)

    for dataset in datasets:
        data_dir = args.data_root / dataset
        if not (data_dir / "metadata.tsv").exists():
            parser.error(f"prepared metadata not found: {data_dir / 'metadata.tsv'}")
        components = args.nmr_components if dataset == "nmr" else args.imagenet_components
        memory_limit = args.nmr_memory_limit_gib if dataset == "nmr" else None
        for ncomp in components:
            run_case(dataset, data_dir, args.results, ncomp, args.block, args.timeout, memory_limit)


if __name__ == "__main__":
    main()
