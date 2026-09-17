#!/usr/bin/env python3
"""Validate compact Metal paths, then rerun training-only NMR selection."""

import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--nmr", type=Path)
    args = parser.parse_args()
    if any("frozen" in str(p).lower() for p in (args.source, args.library, args.before)):
        raise ValueError("Only current candidates may be executed")
    validator = args.source / "benchmark/optimization/validate_metal_host_workspace.py"
    subprocess.run(["python3", str(validator), "--source", str(args.source),
                    "--library", str(args.library), "--before", str(args.before),
                    "--out", str(args.out)], check=True)
    dependencies = subprocess.check_output(
        ["Rscript", "-e", "cat(.libPaths(), sep='\\n')"], text=True).splitlines()
    env = dict(os.environ, FASTPLS_LIB=str(args.library),
               R_LIBS=os.pathsep.join(dependencies), R_PROFILE_USER="/dev/null",
               R_ENVIRON_USER="/dev/null", OPENBLAS_NUM_THREADS="1",
               OMP_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1",
               LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")

    def run(name, command):
        print(name, flush=True)
        with (args.out / (name + ".log")).open("w") as log:
            subprocess.run(list(map(str, command)), check=True, env=env,
                           stdout=log, stderr=subprocess.STDOUT, timeout=900)

    run("prefix_scoring", ["Rscript", args.source /
        "benchmark/optimization/check_nmr_prefix_scoring.R", args.library, args.source])
    if args.nmr:
        for family in ("plssvd", "simpls"):
            run("nmr_selection_" + family, ["Rscript", args.source /
                "benchmark/benchmark_nmr_component_selection.R",
                "--input=" + str(args.nmr),
                "--out=" + str(args.out / ("nmr_selection_" + family)),
                "--backend=metal", "--method=" + family,
                "--seeds=123,456,789,1011,2027", "--fit_seed=123"])


if __name__ == "__main__":
    main()
