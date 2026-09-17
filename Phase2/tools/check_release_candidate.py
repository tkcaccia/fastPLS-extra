#!/usr/bin/env python3
"""Build and check an isolated current source snapshot, including its vignette."""
import argparse
import os
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    if "frozen" in str(source).lower():
        raise ValueError("Only the current candidate may be built")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    dependencies = subprocess.check_output(
        ["Rscript", "-e", "cat(.libPaths(), sep='\\n')"], text=True).splitlines()
    check_deps = Path("/private/tmp/fastpls_check_deps")
    if check_deps.is_dir():
        dependencies.insert(0, str(check_deps))
    env = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8",
               R_LIBS=os.pathsep.join(dict.fromkeys(dependencies)),
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               FASTPLS_USE_METAL="1", FASTPLS_USE_ACCELERATE="1",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1")

    def run(name, command, timeout=1800):
        print(name, flush=True)
        with (out / (name + ".log")).open("w") as log:
            subprocess.run(list(map(str, command)), env=env, cwd=out, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=timeout)

    run("build", ["R", "CMD", "build", source])
    archives = list(out.glob("fastPLS_*.tar.gz"))
    if len(archives) != 1:
        raise RuntimeError("Expected one newly built candidate archive")
    archive = archives[0]
    run("check_as_cran", ["R", "CMD", "check", "--as-cran", archive])
    run("bioccheck", ["Rscript", "-e",
        "BiocCheck::BiocCheck(commandArgs(TRUE)[[1L]])", archive])
    log = (out / "bioccheck.log").read_text()
    counts = re.findall(r"(\d+) ERRORS.*?(\d+) WARNINGS.*?(\d+) NOTES", log)
    if not counts or int(counts[-1][0]) != 0:
        raise RuntimeError("BiocCheck did not establish zero errors; inspect its log")
    print("BiocCheck errors/warnings/notes:", counts[-1], flush=True)
    print("Checks completed; retain and explain all reported warnings/notes", flush=True)


if __name__ == "__main__":
    main()
