#!/usr/bin/env python3
"""Run NMR component paths in monitored, isolated fastPLS processes."""

import argparse
import csv
import importlib.util
from pathlib import Path


def load_runner(path):
    spec = importlib.util.spec_from_file_location("fastpls_selected_runner", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_rows(path, fields, rows):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--backends", nargs="+", required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--precision", default="float32")
    parser.add_argument("--kernel", default="linear")
    parser.add_argument("--gamma", default="auto")
    parser.add_argument("--degree", type=int, default=3)
    parser.add_argument("--coef0", type=float, default=1.0)
    parser.add_argument(
        "--families", nargs="+",
        default=("plssvd", "simpls", "opls", "kernelpls"),
    )
    parser.add_argument(
        "--components", nargs="+", type=int,
        default=(1, 2, 3, 5, 8, 10, 25, 50, 75, 100, 125, 150,
                 165, 175, 200, 250, 300),
    )
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--timeout-sec", type=int, default=14400)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    runner = load_runner(
        root / "current_release_evidence" / "run_selected_backends.py"
    )
    worker = root / "current_release_evidence" / "selected_backend_worker.R"
    target = Path(args.output).resolve()
    work = target.parent / f"{target.stem}_workers"
    work.mkdir(parents=True, exist_ok=True)
    fields = tuple(runner.RESULT_FIELDS) + ("platform",)
    completed = {}
    rows = []
    if args.resume and target.exists():
        with target.open(newline="") as stream:
            for row in csv.DictReader(stream):
                if row.get("status") == "success":
                    key = (
                        row["family"], row["backend"],
                        int(row["requested_ncomp"]), int(row["replicate"]),
                    )
                    completed[key] = row

    for family in args.families:
        for backend in args.backends:
            for ncomp in args.components:
                for replicate in range(1, args.repetitions + 1):
                    key = (family, backend, ncomp, replicate)
                    if key in completed:
                        rows.append(completed[key])
                        continue
                    stem = f"nmr_{family}_{backend}_k{ncomp}_r{replicate}"
                    output = work / f"{stem}.csv"
                    ready = work / f"{stem}.ready"
                    go = work / f"{stem}.go"
                    log = work / f"{stem}.log"
                    for path in (output, ready, go, log):
                        if path.exists():
                            path.unlink()
                    command = [
                        "Rscript", str(worker), args.library, args.task,
                        family, backend, str(ncomp), str(replicate),
                        str(output), str(ready), str(go), args.source_id,
                        args.precision, args.expected_version, "argmax",
                        "linear", "auto", "3", "1",
                    ]
                    print(
                        f"{args.platform}: {family} {backend} "
                        f"components={ncomp} replicate={replicate}",
                        flush=True,
                    )
                    try:
                        row = runner.monitor(
                            command, ready, go, output, log,
                            backend == "cuda", args.timeout_sec,
                        )
                    except Exception as error:
                        row = runner.failure_row(
                            args, "nmr", family, backend, "argmax",
                            ncomp, replicate, error,
                        )
                    row["platform"] = args.platform
                    rows.append(row)
                    write_rows(target, fields, rows)

    write_rows(target, fields, rows)
    print(f"Wrote {len(rows)} NMR component-path rows to {target}")


if __name__ == "__main__":
    main()
