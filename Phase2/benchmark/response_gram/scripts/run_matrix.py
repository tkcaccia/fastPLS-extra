#!/usr/bin/env python3
"""Run each response-Gram executable in a fresh process and retain raw rows."""

from __future__ import annotations

import argparse
import csv
import json
import os
import pathlib
import subprocess
import sys


DEFAULT_SHAPES = (
    (20, 32), (20, 1000), (20, 28355),
    (50, 128), (50, 2048), (50, 28355),
    (100, 128), (100, 1000), (100, 8192), (100, 28355),
    (200, 512), (200, 2048), (200, 8192), (200, 28355),
    (500, 512), (500, 2048), (500, 8192), (500, 28355),
    (1000, 512), (1000, 2048), (1000, 8192), (1000, 28355),
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--threads", default="1,2,4,8")
    parser.add_argument(
        "--pad-to", default="1",
        help="Comma-separated leading-dimension padding multiples.",
    )
    parser.add_argument("--physical-cores", type=int)
    parser.add_argument("--repetitions", type=int, default=7)
    parser.add_argument(
        "--process-repetitions", type=int, default=1,
        help="Repeat each setting in a fresh process this many times.",
    )
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--minimum-sample-seconds", type=float, default=0.01)
    parser.add_argument("--full", action="store_true")
    parser.add_argument(
        "--operation", choices=("sample_gram", "crossprod"),
        default="sample_gram",
    )
    parser.add_argument("--shape", action="append", default=[])
    parser.add_argument("--backend", action="append", default=[])
    parser.add_argument(
        "--affinity-map", type=pathlib.Path,
        help="Optional JSON object mapping thread counts to Linux CPU lists.",
    )
    parser.add_argument(
        "--adaptive-repetitions", action="store_true",
        help="Use fewer repetitions for shapes with more than 1e9 useful FLOPs.",
    )
    args = parser.parse_args()

    shapes = list(DEFAULT_SHAPES)
    if args.shape:
        shapes = [tuple(map(int, item.lower().split("x"))) for item in args.shape]
    threads = sorted({int(value) for value in args.threads.split(",")})
    padding = sorted({int(value) for value in args.pad_to.split(",")})
    if any(value < 1 for value in padding):
        raise SystemExit("--pad-to values must be positive")
    if args.physical_cores:
        threads = sorted(set(threads + [args.physical_cores]))
    affinity_map: dict[str, str] = {}
    if args.affinity_map:
        affinity_map = {
            str(key): str(value)
            for key, value in json.loads(args.affinity_map.read_text()).items()
        }

    executables = sorted(
        path for path in args.build_dir.glob("gram_*")
        if path.is_file() and os.access(path, os.X_OK)
    )
    if args.backend:
        requested = set(args.backend)
        executables = [path for path in executables if path.name in requested]
    if not executables:
        raise SystemExit(f"no gram_* executables found in {args.build_dir}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, str]] = []
    failures: list[dict[str, str]] = []
    for executable in executables:
        backend_threads = threads
        if executable.name in {
            "gram_accelerate_syrk", "gram_blasfeo", "gram_libxsmm"
        }:
            backend_threads = [1]
        for n, q in shapes:
            for precision in ("float32", "float64"):
                useful_flops = n * (n + 1) * q
                repetitions = args.repetitions
                warmups = args.warmups
                if args.adaptive_repetitions and useful_flops > 10_000_000_000:
                    repetitions = 1
                    warmups = min(warmups, 1)
                elif args.adaptive_repetitions and useful_flops > 1_000_000_000:
                    repetitions = min(repetitions, 3)
                    warmups = min(warmups, 1)
                for thread_count in backend_threads:
                    for pad_to in padding:
                        for process_repetition in range(
                            1, args.process_repetitions + 1
                        ):
                            command = [
                                str(executable), "--n", str(n), "--q", str(q),
                                "--pad-to", str(pad_to),
                                "--precision", precision,
                                "--threads", str(thread_count),
                                "--repetitions", str(repetitions),
                                "--warmups", str(warmups), "--output",
                                "full" if args.full else "triangle",
                                "--operation", args.operation,
                                "--minimum-sample-seconds",
                                str(args.minimum_sample_seconds),
                            ]
                            affinity = affinity_map.get(str(thread_count), "")
                            if affinity and sys.platform.startswith("linux"):
                                command = ["taskset", "-c", affinity, *command]
                            environment = os.environ.copy()
                            for variable in (
                                "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS",
                                "MKL_NUM_THREADS", "BLIS_NUM_THREADS",
                            ):
                                environment[variable] = str(thread_count)
                            environment["OMP_DYNAMIC"] = "FALSE"
                            environment["MKL_DYNAMIC"] = "FALSE"
                            completed = subprocess.run(
                                command, text=True, capture_output=True,
                                env=environment
                            )
                            if completed.returncode:
                                failures.append({
                                    "executable": executable.name,
                                    "n": str(n), "q": str(q),
                                    "precision": precision,
                                    "pad_to": str(pad_to),
                                    "threads": str(thread_count),
                                    "process_repetition": str(
                                        process_repetition
                                    ),
                                    "affinity": affinity,
                                    "returncode": str(completed.returncode),
                                    "stderr": completed.stderr.strip(),
                                })
                                continue
                            lines = [
                                line for line in completed.stdout.splitlines()
                                if line.strip()
                            ]
                            if len(lines) != 2:
                                raise RuntimeError(
                                    "unexpected output from "
                                    f"{executable}: {completed.stdout}"
                                )
                            parsed = list(csv.DictReader(lines))
                            for row in parsed:
                                row["process_repetition"] = str(
                                    process_repetition
                                )
                                row["affinity"] = affinity
                            rows.extend(parsed)

    with args.output.open("w", newline="") as stream:
        if rows:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    failure_path = args.output.with_name(args.output.stem + "_failures.csv")
    with failure_path.open("w", newline="") as stream:
        if failures:
            writer = csv.DictWriter(stream, fieldnames=list(failures[0]))
            writer.writeheader()
            writer.writerows(failures)
    print(f"wrote {len(rows)} measurements to {args.output}")
    print(f"wrote {len(failures)} failures to {failure_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
