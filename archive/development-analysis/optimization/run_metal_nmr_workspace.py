#!/usr/bin/env python3
"""Isolated NMR evidence for current CPU/CUDA/Metal candidates only."""

import argparse
import csv
import json
import math
import os
from pathlib import Path
import subprocess
import time


def verify_table(path, precision, count, repetitions, backend="metal",
                 family=None, solver=None, seed=None):
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != repetitions or {int(row["replicate"]) for row in rows} != set(range(1, repetitions + 1)):
        raise ValueError("Incomplete or duplicated NMR replicates")
    for row in rows:
        if (row["status"] != "success" or row["backend"] != backend or
                row["precision"] != precision or int(row["ncomp"]) != count or
                row["protocol_version"] != "nmr_matched_v2" or
                row.get("profiled") == "TRUE" or
                row["conversion_in_fit_time"] != "FALSE"):
            raise ValueError("Unexpected NMR protocol or execution status")
        for field, expected in (("family", family), ("solver", solver), ("seed", seed)):
            if expected is not None and row.get(field) != str(expected):
                raise ValueError(f"Unexpected NMR {field}")
        for field in ("fit_time_sec", "predict_time_sec", "total_time_sec", "RMSD", "Q2"):
            if not math.isfinite(float(row[field])):
                raise ValueError(f"Nonfinite NMR result: {field}")
    return len(rows)


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=Path("/private/tmp/fastPLS_metal_host_workspace_v2_20260905"))
    parser.add_argument("--library", type=Path,
                        default=Path("/private/tmp/fastpls_metal_host_workspace_v2_lib"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--precision", nargs="+", choices=("float32", "float64"),
                        default=["float64", "float32"])
    parser.add_argument("--components", nargs="+", type=int, default=[50, 165])
    parser.add_argument("--replicates", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--backend", nargs="+", choices=("cpu", "cuda", "metal"), default=["metal"])
    parser.add_argument("--family", nargs="+", choices=("simpls", "plssvd"), default=["simpls"])
    parser.add_argument("--solver", nargs="+", choices=("rsvd", "irlba"), default=["rsvd"])
    parser.add_argument("--seeds", nargs="+", type=int, default=[123])
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--memory", action="store_true", help="Add separate one-replicate memory workers")
    args = parser.parse_args()
    source, library, output = args.source, args.library, args.output
    if "frozen" in str(source).lower() or "frozen" in str(library).lower():
        raise RuntimeError("Only current candidates may be executed")
    if min(args.components) < 1 or args.replicates < 1 or args.timeout < 1:
        raise ValueError("Components, repetitions and timeout must be positive")
    if any(len(values) != len(set(values)) for values in (
            args.components, args.seeds, args.backend, args.family, args.solver, args.precision)):
        raise ValueError("Duplicated benchmark settings would overwrite evidence")
    args.input.resolve(strict=True)
    if output.exists():
        raise RuntimeError("Refusing to overwrite an existing experiment")
    output.mkdir(parents=True)
    env = dict(os.environ)
    dependency_paths = subprocess.check_output(
        ["Rscript", "-e", "cat(.libPaths(), sep='\\n')"], text=True, env=env).splitlines()
    library_paths = os.pathsep.join(dict.fromkeys([str(library), *dependency_paths]))
    env.update(LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", FASTPLS_LIB=str(library),
               FASTPLS_BENCH_LIB=str(library),
               R_LIBS=library_paths, R_LIBS_USER=library_paths,
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")
    worker = source / "benchmark/benchmark_nmr_qualified_solver.R"
    statuses = []
    import itertools
    grid = itertools.product(args.backend, args.family, args.solver, args.precision,
                             args.components, args.seeds)
    for backend, family, solver, precision, count, seed in grid:
        prefix = f"{family}_{backend}_{precision}_{count}"
        if solver != "rsvd" or len(args.solver) > 1:
            prefix += "_" + solver
        if seed != 123 or len(args.seeds) > 1:
            prefix += f"_seed{seed}"
        for measurement in ("timing", "memory") if args.memory else ("timing",):
            name = prefix + ("_memory" if measurement == "memory" else "")
            repetitions = 1 if measurement == "memory" else args.replicates
            command = ["Rscript", str(worker), f"--input={args.input.resolve()}",
                       f"--family={family}", f"--backend={backend}", f"--solver={solver}", f"--precision={precision}",
                       f"--ncomp={count}", f"--seed={seed}", f"--replicates={repetitions}",
                       f"--output={output / (name + '.csv')}"]
            if measurement == "memory":
                command = ["python3", str(source / "benchmark/optimization/monitor_process.py"),
                           "--output", str(output / name), "--timeout", str(args.timeout),
                           "--", *command]
            print(name, flush=True)
            env["FASTPLS_MEASUREMENT_EVENTS"] = str(output / (name + "_events.csv"))
            started = time.monotonic()
            row = dict(case=name, command=command, library=str(library), source=str(source),
                       timeout_seconds=args.timeout, repetitions_requested=repetitions,
                       measurement=measurement)
            with (output / (name + ".log")).open("w") as handle:
                try:
                    completed = subprocess.run(command, env=env, stdout=handle, stderr=subprocess.STDOUT,
                                               timeout=args.timeout + (30 if measurement == "memory" else 0), check=False)
                    row.update(status="finished" if completed.returncode == 0 else "error",
                               returncode=completed.returncode)
                    if completed.returncode == 0:
                        try:
                            row["repetitions_verified"] = verify_table(
                                output / (name + ".csv"), precision, count, repetitions,
                                backend, family, solver, seed)
                        except (OSError, ValueError, KeyError) as error:
                            row.update(status="invalid_results", error=str(error))
                except subprocess.TimeoutExpired:
                    row.update(status="timeout", returncode=None)
            row["worker_elapsed_seconds"] = time.monotonic() - started
            statuses.append(row)
            (output / "worker_status.json").write_text(json.dumps(statuses, indent=2) + "\n")
            print(row["status"], name, flush=True)
    print("NMR candidate timings complete; compare only matching stored protocols", flush=True)
    if any(row["status"] != "finished" for row in statuses):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
