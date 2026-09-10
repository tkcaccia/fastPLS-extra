#!/usr/bin/env python3
"""Run the fixed-component NMR benchmark in isolated monitored processes.

Results are written only to the requested external directory. Each repetition
starts a new R process, so accelerator context creation, data transfer,
synchronization, fitting, prediction, and result transfer share one timing
contract across CPU, CUDA, and Metal.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--platform", required=True, choices=("linux", "mac"))
    parser.add_argument("--backends", nargs="+", required=True,
                        choices=("cpu", "cuda", "metal"))
    parser.add_argument("--families", nargs="+", default=("plssvd", "simpls"),
                        choices=("plssvd", "simpls"))
    parser.add_argument("--precision", default="float32",
                        choices=("float32", "float64"))
    parser.add_argument("--ncomp", type=int, default=165)
    parser.add_argument("--seed", type=int, default=123)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("--interval", type=float, default=0.02)
    parser.add_argument("--rscript", default="Rscript")
    parser.add_argument("--workstation", required=True)
    parser.add_argument("--source-id", default="working-tree")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    here = Path(__file__).resolve().parent
    worker = here.parent / "benchmark_nmr_qualified_solver.R"
    monitor = here.parent / "optimization" / "monitor_process.py"
    input_path = Path(args.input).resolve(strict=True)
    library = Path(args.library).resolve(strict=True)
    root = Path(args.output_root).resolve()
    if root.exists():
        raise SystemExit(
            f"Output root already exists: {root}. Use a new evidence directory."
        )
    root.mkdir(parents=True)
    manifest = {
        "protocol": "nmr_fixed_workload_isolated_v1",
        "platform": args.platform,
        "workstation": args.workstation,
        "source_id": args.source_id,
        "precision": args.precision,
        "ncomp": args.ncomp,
        "seed": args.seed,
        "repetitions": args.repetitions,
        "families": args.families,
        "backends": args.backends,
        "timing_contract": (
            "fresh process; input conversion excluded; accelerator context, "
            "transfer, synchronization, fitting, prediction, and result "
            "transfer included"
        ),
        "input": str(input_path),
        "runs": [],
    }
    environment = dict(os.environ, FASTPLS_LIB=str(library))
    for family in args.families:
        for backend in args.backends:
            for replicate in range(1, args.repetitions + 1):
                run_dir = root / args.platform / f"{family}_{backend}" / (
                    f"replicate_{replicate:02d}"
                )
                run_dir.mkdir(parents=True)
                result = run_dir / "result.csv"
                prediction = run_dir / "prediction.rds"
                command = [
                    args.rscript,
                    str(worker),
                    f"--input={input_path}",
                    f"--output={result}",
                    f"--family={family}",
                    f"--backend={backend}",
                    "--solver=rsvd",
                    f"--precision={args.precision}",
                    f"--ncomp={args.ncomp}",
                    f"--seed={args.seed}",
                    "--replicates=1",
                ]
                if replicate == 1:
                    command.append(f"--prediction-output={prediction}")
                with (run_dir / "worker.log").open("w") as log:
                    completed = subprocess.run(
                        command, env=environment, check=False,
                        stdout=log, stderr=subprocess.STDOUT,
                        timeout=args.timeout,
                    )
                record = {
                    "family": family,
                    "backend": backend,
                    "replicate": replicate,
                    "result": str(result),
                    "prediction": str(prediction) if replicate == 1 else None,
                    "measurement_role": "timing",
                    "exit_code": completed.returncode,
                }
                manifest["runs"].append(record)
                (root / "run_manifest.json").write_text(
                    json.dumps(manifest, indent=2) + "\n"
                )
                if completed.returncode:
                    raise SystemExit(
                        f"{family}/{backend} replicate {replicate} failed with "
                        f"status {completed.returncode}; completed evidence was retained."
                    )
            memory_dir = root / args.platform / f"{family}_{backend}" / "memory"
            memory_dir.mkdir(parents=True)
            memory_command = [
                args.rscript,
                str(worker),
                f"--input={input_path}",
                f"--output={memory_dir / 'result.csv'}",
                f"--family={family}",
                f"--backend={backend}",
                "--solver=rsvd",
                f"--precision={args.precision}",
                f"--ncomp={args.ncomp}",
                f"--seed={args.seed}",
                "--replicates=1",
            ]
            monitored = [
                sys.executable,
                str(monitor),
                "--output", str(memory_dir / "monitor"),
                "--timeout", str(args.timeout),
                "--interval", str(args.interval),
                "--",
                *memory_command,
            ]
            completed = subprocess.run(monitored, env=environment, check=False)
            record = {
                "family": family,
                "backend": backend,
                "replicate": 1,
                "result": str(memory_dir / "result.csv"),
                "prediction": None,
                "monitor": str(memory_dir / "monitor" / "summary.json"),
                "measurement_role": "memory_only",
                "exit_code": completed.returncode,
            }
            manifest["runs"].append(record)
            (root / "run_manifest.json").write_text(
                json.dumps(manifest, indent=2) + "\n"
            )
            if completed.returncode:
                raise SystemExit(
                    f"{family}/{backend} memory run failed with status "
                    f"{completed.returncode}; timing evidence was retained."
                )


if __name__ == "__main__":
    main()
