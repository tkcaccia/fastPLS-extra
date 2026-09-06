#!/usr/bin/env python3
"""Test current CPU/IRLBA score reuse and current Metal NMR endpoints."""

import argparse
import os
from pathlib import Path
from companion_tools import companion_tool
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--nmr", type=Path)
    parser.add_argument("--timing-only", action="store_true",
                        help="Use already validated current installations for a timing rerun")
    parser.add_argument("--validation-only", action="store_true",
                        help="Check installed current libraries without repeating predictor timings")
    parser.add_argument("--reverse", action="store_true",
                        help="Repeat timings with after-before library order")
    parser.add_argument("--prediction-script", default="check_cpu_prediction_prefix.R",
                        choices=("check_cpu_prediction_prefix.R", "check_cpu_flash_weights.R"))
    args = parser.parse_args()
    if args.validation_only and (args.timing_only or args.nmr):
        raise ValueError("Validation-only cannot be combined with timing-only or NMR")
    if any("frozen" in str(p).lower() for p in (args.source, args.library, args.before)):
        raise ValueError("Current candidates only")
    args.out.mkdir(parents=True, exist_ok=False)
    args.library.mkdir(exist_ok=True)
    dependencies = subprocess.check_output(
        ["Rscript", "-e", "cat(.libPaths(), sep='\\n')"], text=True).splitlines()
    env = dict(os.environ, R_LIBS=os.pathsep.join(dependencies),
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1",
               FASTPLS_USE_METAL="1", FASTPLS_USE_ACCELERATE="1",
               LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")

    def run(name, command, timeout=900):
        print(name, flush=True)
        with (args.out / (name + ".log")).open("w") as log:
            subprocess.run(list(map(str, command)), env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=timeout)

    if args.timing_only and args.nmr:
        raise ValueError("The timing-only mode does not rerun NMR")
    if not args.timing_only and not args.validation_only:
        run("install", ["R", "CMD", "INSTALL", "--no-multiarch", "-l", args.library, args.source])
    scripts = args.source / "benchmark/optimization"
    if not args.timing_only:
        run("tests", ["Rscript", companion_tool("run_candidate_tests.R"), args.library,
                      args.source / "tests/testthat", args.out / "tests.rds"])
    sequence = [("before", args.before), ("after", args.library)]
    if args.reverse:
        sequence += [("after_reverse", args.library), ("before_reverse", args.before)]
    if args.validation_only:
        sequence = []
    for label, library in sequence:
        command = ["Rscript", scripts / args.prediction_script,
                   library, args.out / label]
        if label != "before":
            command.append(args.out / "before")
        run(label, command)
    if args.timing_only:
        return
    for backend in ("cpu", "metal"):
        for label, library in (("before", args.before), ("after", args.library)):
            env["FASTPLS_LIB"] = str(library)
            command = ["Rscript", scripts / "check_cv_workspace.R", backend,
                       args.out / (label + "_cv_" + backend + ".rds")]
            if label == "after":
                command.append(args.out / ("before_cv_" + backend + ".rds"))
            run(label + "_cv_" + backend, command)
    if args.nmr:
        run("nmr", ["python3", scripts / "run_metal_nmr_workspace.py",
            "--source", args.source, "--library", args.library,
            "--output", args.out / "nmr", "--input", args.nmr,
            "--backend", "metal", "--family", "plssvd", "simpls",
            "--precision", "float64", "--components", "50", "75", "165",
            "--seeds", "123", "124", "125", "--replicates", "3", "--memory"], 1500)


if __name__ == "__main__":
    main()
