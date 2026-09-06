#!/usr/bin/env python3
"""Build and compare two current Metal candidates at an isolated queue boundary."""

import argparse
import os
from pathlib import Path
from companion_tools import companion_tool
import subprocess


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("/private/tmp/fastPLS_metal_host_workspace_20260905")
LIBRARY = Path("/private/tmp/fastpls_metal_host_workspace_lib")
BEFORE = Path("/private/tmp/fastpls_fold_reuse_lib")
OUT = ROOT / "benchmark_results/optimization_20260904/metal_host_workspace"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--library", type=Path, default=LIBRARY)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--before", type=Path, default=BEFORE)
    parser.add_argument("--float-operator", action="store_true")
    parser.add_argument("--float-backends", nargs="+", choices=("cpu", "metal"),
                        default=["metal"])
    parser.add_argument("--reverse", action="store_true")
    parser.add_argument("--nmr", type=Path,
                        help="After validation, measure Metal PLS-SVD on the masked NMR protocol")
    args = parser.parse_args()
    source, library, out = args.source, args.library, args.out
    before = args.before
    if any("frozen" in str(path).lower() for path in (before, library, source)):
        raise RuntimeError("This experiment runs current candidates only")
    if out.exists():
        raise RuntimeError("Use a new output directory for a repeated experiment")
    out.mkdir(parents=True)
    library.mkdir(exist_ok=True)
    env = dict(os.environ)
    dependency_paths = subprocess.check_output(
        ["Rscript", "-e", "cat(.libPaths(), sep='\\n')"], text=True).splitlines()
    env.update(LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8",
               R_LIBS=os.pathsep.join(dependency_paths),
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               FASTPLS_USE_METAL="1", FASTPLS_USE_ACCELERATE="1",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")

    def run(name, command):
        print(name, flush=True)
        with (out / (name + ".log")).open("w") as log:
            subprocess.run(list(map(str, command)), env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=900)

    run("install", ["R", "CMD", "INSTALL", "--no-multiarch", "--no-test-load", "-l", library, source])
    script = source / "benchmark/optimization/check_metal_host_workspace.R"
    run("before", ["Rscript", script, before, out / "before"])
    run("after", ["Rscript", script, library, out / "after", out / "before"])
    if args.reverse:
        run("after_reverse", ["Rscript", script, library, out / "after_reverse", out / "before"])
        run("before_reverse", ["Rscript", script, before, out / "before_reverse", out / "before"])
    if args.float_operator:
        script = source / "benchmark/optimization/check_metal_float_operator.R"
        for backend in args.float_backends:
            suffix = "" if backend == "metal" else "_" + backend
            old_output = out / ("float_before" + suffix)
            new_output = out / ("float_after" + suffix)
            run("float_before" + suffix, ["Rscript", script, before, old_output, "", backend])
            run("float_after" + suffix, ["Rscript", script, library, new_output, old_output, backend])
    run("tests", ["Rscript", companion_tool("run_candidate_tests.R"),
                  library, source / "tests/testthat", out / "tests.rds"])
    script = source / "benchmark/optimization/check_cv_workspace.R"
    for label, current_library in (("before", before), ("after", library)):
        env["FASTPLS_LIB"] = str(current_library)
        arguments = ["Rscript", script, "metal", out / (label + "_cv.rds")]
        if label == "after":
            arguments.append(out / "before_cv.rds")
        run(label + "_cv", arguments)
    print("Metal candidate tests and before/after numerical comparisons completed", flush=True)
    if args.nmr:
        run("nmr", ["python3", source / "benchmark/optimization/run_metal_nmr_workspace.py",
                    "--source", source, "--library", library, "--output", out / "nmr",
                    "--input", args.nmr, "--backend", "metal", "--family", "plssvd",
                    "--precision", "float64", "--components", "50", "165",
                    "--seeds", "123", "124", "125", "--replicates", "3", "--memory"])


if __name__ == "__main__":
    main()
