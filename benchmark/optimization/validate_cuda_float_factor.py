#!/usr/bin/env python3
"""Isolated source-only CUDA candidate validation on the existing workstation."""
import argparse
import os
from pathlib import Path
from companion_tools import companion_tool
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "library", "before", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    if any("frozen" in str(x).lower() for x in (args.source, args.library, args.before)):
        raise RuntimeError("Only current candidate implementations may execute")
    args.out.mkdir(parents=True, exist_ok=False)
    args.library.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    dependency_paths = subprocess.check_output(
        ["Rscript", "-e", "cat(.libPaths(), sep='\\n')"], text=True, env=env).splitlines()
    env.update(FASTPLS_USE_CUDA="1", FASTPLS_USE_METAL="0",
               R_LIBS=os.pathsep.join(dependency_paths),
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", MKL_NUM_THREADS="1",
               LANG="C.UTF-8", LC_ALL="C.UTF-8")

    def run(name, command, timeout=900):
        print(name, flush=True)
        with (args.out / (name + ".log")).open("w") as log:
            subprocess.run(list(map(str, command)), env=env, stdout=log,
                           stderr=subprocess.STDOUT, timeout=timeout, check=True)

    run("install", ["R", "CMD", "INSTALL", "--preclean", "--no-test-load",
                    "-l", args.library, args.source])
    scripts = args.source / "benchmark/optimization"
    run("tests", ["Rscript", companion_tool("run_candidate_tests.R"), args.library,
                  args.source / "tests/testthat", args.out / "tests.rds"])
    for backend in ("cpu", "cuda"):
        run("coherence_" + backend, ["Rscript", scripts / "check_float32_score_coherence.R",
            args.library, args.out / ("score_coherence_" + backend + ".csv"), backend])
        run("products_" + backend, ["Rscript", scripts / "check_float_crosscov.R",
            args.library, args.source, args.out / ("products_" + backend), backend])
        for script, prefix in (("check_metal_float_operator.R", "small"),
                               ("check_float_implicit_models.R", "large")):
            old = args.out / (prefix + "_before_" + backend)
            new = args.out / (prefix + "_after_" + backend)
            for name, library, output, compare in (
                    ("before", args.before, old, ""),
                    ("after", args.library, new, old)):
                tail = [backend, compare] if prefix == "large" else [compare, backend]
                run(prefix + "_" + name + "_" + backend,
                    ["Rscript", scripts / script, library, output] + tail)
    print("CUDA factor candidate validation complete", flush=True)


if __name__ == "__main__":
    main()
