#!/usr/bin/env python3
"""Validate the isolated float32 operator candidate, never frozen estimators."""
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
    parser.add_argument("--no-install", action="store_true")
    parser.add_argument("--nmr", action="store_true")
    args = parser.parse_args()
    if any("frozen" in str(x).lower() for x in (args.library, args.before)):
        raise RuntimeError("Only current candidate implementations may run")
    env = dict(os.environ)
    dependency_libs = os.environ.get("FASTPLS_DEPENDENCY_LIBS", "")
    env.update(LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8",
               R_LIBS=dependency_libs,
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")
    if args.no_install:
        args.out.mkdir(parents=True, exist_ok=False)
        with (args.out / "tests.log").open("w") as log:
            subprocess.run(["Rscript", str(companion_tool("run_candidate_tests.R")),
                str(args.library), str(args.source / "tests/testthat"), str(args.out / "tests.rds")],
                env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
        for label, library in (("before", args.before), ("after", args.library)):
            cv_env = dict(env, FASTPLS_LIB=str(library))
            command = ["Rscript", str(args.source / "benchmark/optimization/check_cv_workspace.R"),
                       "metal", str(args.out / (label + "_cv.rds"))]
            if label == "after":
                command.append(str(args.out / "before_cv.rds"))
            with (args.out / (label + "_cv.log")).open("w") as log:
                subprocess.run(command, env=cv_env, stdout=log,
                    stderr=subprocess.STDOUT, check=True, timeout=900)
    else:
        subprocess.run(["python3", str(args.source / "benchmark/optimization/validate_metal_host_workspace.py"),
            "--source", str(args.source), "--library", str(args.library),
            "--before", str(args.before), "--out", str(args.out),
            "--float-operator", "--float-backends", "cpu", "metal"], env=env, check=True)
    for backend in ("cpu", "metal"):
        commands = [("products_" + backend, ["Rscript",
            args.source / "benchmark/optimization/check_float_crosscov.R",
            args.library, args.source, args.out / ("products_" + backend), backend])]
        before_output = args.out / ("implicit_before_" + backend)
        after_output = args.out / ("implicit_after_" + backend)
        for label, library, output, compare in (
                ("before", args.before, before_output, ""),
                ("after", args.library, after_output, before_output)):
            commands.append(("implicit_" + label + "_" + backend, ["Rscript",
                args.source / "benchmark/optimization/check_float_implicit_models.R",
                library, output, backend, compare]))
        for name, command in commands:
            print(name, flush=True)
            with (args.out / (name + ".log")).open("w") as log:
                subprocess.run(list(map(str, command)), env=env, stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=900)
    with (args.out / "nmr_prefix_scoring.log").open("w") as log:
        subprocess.run(["Rscript", str(args.source / "benchmark/optimization/check_nmr_prefix_scoring.R"),
            str(args.library), str(args.source)], env=env, stdout=log,
            stderr=subprocess.STDOUT, check=True, timeout=120)
    if args.nmr:
        subprocess.run(["python3", str(args.source / "benchmark/optimization/run_metal_nmr_workspace.py"),
            "--source", str(args.source), "--library", str(args.library),
            "--output", str(args.out / "nmr"), "--precision", "float32",
            "--components", "1", "50", "165", "--replicates", "1", "--timeout", "300"],
            env=env, check=True, timeout=1000)


if __name__ == "__main__":
    main()
