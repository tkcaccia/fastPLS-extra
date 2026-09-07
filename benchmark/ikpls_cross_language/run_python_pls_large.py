#!/usr/bin/env python3
"""Run guarded NMR and ImageNet feasibility tests for independent Python PLS."""

import argparse
import csv
import importlib.metadata
import os
from pathlib import Path
import platform
import resource
import subprocess
import sys

import pandas as pd


HERE = Path(__file__).resolve().parent
WORKER = HERE / "worker_python_pls_large.py"
IMPLEMENTATIONS = (
    "nirs4all_methods_simpls",
    "nirs4all_methods_rsvd",
    "sklearn_plsregression",
)


def write_environment(path: Path, memory_limit_gib: float) -> None:
    packages = ("numpy", "pandas", "psutil", "pls4all", "scikit-learn")
    rows = [
        ("python", sys.version.replace("\n", " ")),
        ("platform", platform.platform()),
        *[
            (package, importlib.metadata.version(package))
            for package in packages
        ],
        ("cpu_thread_contract", "one effective BLAS/OpenMP thread"),
        ("address_space_guard_gib", memory_limit_gib),
    ]
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(("item", "value"))
        writer.writerows(rows)


def components(value: str) -> list[int]:
    result = [int(item) for item in value.split(",") if item.strip()]
    if not result or any(item < 1 for item in result):
        raise argparse.ArgumentTypeError("components must be positive integers")
    return result


def memory_guard(limit_gib: float):
    def apply() -> None:
        limit = int(limit_gib * 1024**3)
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))

    return apply


def failure_row(dataset, implementation, ncomp, replicate, error):
    return {
        "dataset": dataset,
        "implementation": implementation,
        "ncomp": ncomp,
        "replicate": replicate,
        "status": "failed",
        "error": error,
    }


def write_row(path: Path, row: dict) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=row)
        writer.writeheader()
        writer.writerow(row)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--datasets", default="nmr,imagenet")
    parser.add_argument("--implementations", default=",".join(IMPLEMENTATIONS))
    parser.add_argument("--nmr-components", type=components, default=[50])
    parser.add_argument("--imagenet-components", type=components, default=[100])
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--block", type=int, default=2000)
    parser.add_argument("--timeout", type=int, default=10000)
    parser.add_argument("--memory-limit-gib", type=float, default=24.0)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    selected = [item.strip() for item in args.datasets.split(",") if item.strip()]
    if set(selected) - {"nmr", "imagenet"}:
        parser.error("datasets must contain only nmr and/or imagenet")
    implementations = [
        item.strip() for item in args.implementations.split(",") if item.strip()
    ]
    invalid_implementations = set(implementations) - set(IMPLEMENTATIONS)
    if invalid_implementations:
        parser.error(
            "unsupported implementations: "
            + ", ".join(sorted(invalid_implementations))
        )

    rows_dir = args.results / "rows"
    rows_dir.mkdir(parents=True, exist_ok=True)
    write_environment(
        args.results / "python_pls_environment.tsv",
        args.memory_limit_gib,
    )
    python = os.environ.get("PYTHON_PLS_BENCH_PYTHON", sys.executable)
    for dataset in selected:
        values = args.nmr_components if dataset == "nmr" else args.imagenet_components
        for implementation in implementations:
            for ncomp in values:
                for replicate in range(1, args.repetitions + 1):
                    stem = f"{dataset}__{implementation}__n{ncomp}__rep{replicate}"
                    output = rows_dir / f"{stem}.csv"
                    log = rows_dir / f"{stem}.log"
                    if output.exists() and not args.force:
                        continue
                    command = [
                        python,
                        str(WORKER),
                        str(args.data_root / dataset),
                        str(ncomp),
                        str(replicate),
                        implementation,
                        str(output),
                        str(args.block),
                    ]
                    env = os.environ.copy()
                    for name in (
                        "OMP_NUM_THREADS",
                        "OPENBLAS_NUM_THREADS",
                        "MKL_NUM_THREADS",
                        "NUMEXPR_NUM_THREADS",
                    ):
                        env[name] = "1"
                    print(dataset, implementation, ncomp, replicate, flush=True)
                    try:
                        with log.open("w") as stream:
                            guard = (
                                memory_guard(args.memory_limit_gib)
                                if platform.system() == "Linux"
                                else None
                            )
                            completed = subprocess.run(
                                command,
                                env=env,
                                stdout=stream,
                                stderr=subprocess.STDOUT,
                                timeout=args.timeout,
                                check=False,
                                preexec_fn=guard,
                            )
                        if completed.returncode != 0 and not output.exists():
                            log_lines = log.read_text(errors="replace").strip().splitlines()
                            detail = log_lines[-1] if log_lines else ""
                            write_row(
                                output,
                                failure_row(
                                    dataset,
                                    implementation,
                                    ncomp,
                                    replicate,
                                    f"worker exit code {completed.returncode}"
                                    + (f": {detail}" if detail else ""),
                                ),
                            )
                    except subprocess.TimeoutExpired:
                        write_row(
                            output,
                            failure_row(
                                dataset,
                                implementation,
                                ncomp,
                                replicate,
                                f"timeout after {args.timeout} seconds",
                            ),
                        )

    frames = [pd.read_csv(path) for path in sorted(rows_dir.glob("*.csv"))]
    if not frames:
        raise RuntimeError("No large-case Python PLS rows were generated")
    result = pd.concat(frames, ignore_index=True, sort=False)
    result.to_csv(args.results / "python_pls_large_all_runs.csv", index=False)
    print(result.to_string(index=False))


if __name__ == "__main__":
    main()
