#!/usr/bin/env python3
"""Verify current prediction/data-handling changes against a preceding candidate."""
import argparse
import csv
import os
from pathlib import Path
from companion_tools import companion_tool
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "library", "before", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--allocation-before", type=Path,
                        help="Optional earlier current candidate for allocation-only comparison")
    args = parser.parse_args()
    if any("frozen" in str(x).lower() for x in
           (args.source, args.library, args.before, args.allocation_before)):
        raise ValueError("Only current candidates may execute")
    args.out.mkdir(parents=True, exist_ok=False)
    args.library.mkdir(parents=True, exist_ok=True)
    dependency_paths = subprocess.check_output(
        ["Rscript", "-e", "cat(.libPaths(), sep='\\n')"], text=True).splitlines()
    env = dict(os.environ, R_LIBS=os.pathsep.join(dependency_paths),
               LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8",
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")

    def run(name, command):
        print(name, flush=True)
        with (args.out / (name + ".log")).open("w") as log:
            subprocess.run(list(map(str, command)), env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=900)

    # Retain the preceding candidate's configured backend. R CMD INSTALL
    # rebuilds native objects when their source or wrapper has changed.
    run("install", ["R", "CMD", "INSTALL", "--no-configure", "--no-test-load",
                    "-l", args.library, args.source])
    scripts = args.source / "benchmark/optimization"
    run("tests", ["Rscript", companion_tool("run_candidate_tests.R"), args.library,
                  args.source / "tests/testthat", args.out / "tests.rds"])
    for backend in ("cpu", "metal"):
        before = args.out / ("before_" + backend)
        after = args.out / ("after_" + backend)
        run("prediction_before_" + backend, ["Rscript", scripts / "check_prediction_prefix_reuse.R",
            args.before, before, backend])
        run("prediction_after_" + backend, ["Rscript", scripts / "check_prediction_prefix_reuse.R",
            args.library, after, backend, before])
    for label, library in (("before", args.before), ("after", args.library)):
        previous = [args.out / "before_cv.rds"] if label == "after" else []
        env["FASTPLS_LIB"] = str(library)
        run(label + "_cv", ["Rscript", scripts / "check_cv_workspace.R", "metal",
                            args.out / (label + "_cv.rds"), *previous])
    libraries = [("before", args.before), ("after", args.library)]
    if args.allocation_before:
        libraries.insert(0, ("earlier", args.allocation_before))
    hashes = {}
    for label, library in libraries:
        allocation_out = args.out / ("allocations_" + label)
        run("allocations_" + label, ["Rscript", scripts / "check_float32_allocations.R",
                                    library, allocation_out])
        with (allocation_out / "summary.csv").open() as handle:
            rows = list(csv.DictReader(handle))
        current = {r["operation"]: r["output_bits_md5"] for r in rows}
        if set(current) != {"standardize", "zeros"} or (hashes and hashes != current):
            raise RuntimeError("Float32 allocation comparison changed output bits")
        hashes = current
    print("Prediction prefix candidate verified", flush=True)


if __name__ == "__main__":
    main()
