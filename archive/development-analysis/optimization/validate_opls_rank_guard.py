#!/usr/bin/env python3
"""Validate OPLS rank errors and unchanged valid-prefix predictions."""
import argparse
import csv
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("source", "library", "before-library", "task", "config", "out"):
        parser.add_argument("--" + option, type=Path, required=True)
    args = parser.parse_args()
    if any("frozen" in str(path).lower() for path in
           (args.source, args.library, args.before_library)):
        raise ValueError("Only current candidates may be executed")
    source = args.source.resolve(strict=True)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1",
               VECLIB_MAXIMUM_THREADS="1")

    def run(label, command):
        print(label, flush=True)
        with (out / (label + ".log")).open("w") as log:
            subprocess.run(list(map(str, command)), env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=1800)

    run("tests", ["Rscript", "-e", """
args <- commandArgs(TRUE)
.libPaths(unique(c(args[[1]], .libPaths())))
suppressPackageStartupMessages(library(fastPLS))
x <- testthat::test_dir(args[[2]], reporter="summary", stop_on_failure=FALSE)
saveRDS(x, args[[3]])
tab <- as.data.frame(x)
stopifnot(sum(tab$failed)==0L, !any(tab$error), sum(tab$warning)==0L)
cat("Assertions:", sum(tab$nb), "\n")
""", args.library.resolve(), source / "tests/testthat", out / "tests.rds"])
    helper = Path(__file__).resolve().with_name("inspect_opls_endpoint.R")
    for name, library in (("before", args.before_library), ("after", args.library)):
        run(name, ["Rscript", helper, library.resolve(), args.task.resolve(),
                   args.config.resolve(), out / name])
    with (out / "after/endpoint_diagnostics.csv").open() as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 16:
        raise RuntimeError("Incomplete endpoint diagnostic")
    for row in rows:
        expected = "error" if row["ncomp"] == "50" else "success"
        if row["status"] != expected:
            raise RuntimeError("Unexpected OPLS endpoint status: " + str(row))
        if expected == "error" and "at most 49 remain" not in row["error"]:
            raise RuntimeError("Endpoint failed for an unrelated reason")
    run("agreement", ["Rscript", "-e", """
args <- commandArgs(TRUE)
before <- readRDS(args[[1]])
after <- readRDS(args[[2]])
stopifnot(length(after)==12L, all(names(after) %in% names(before)))
agreement <- vapply(names(after), function(k) {
    stopifnot(identical(before[[k]], after[[k]]))
    mean(before[[k]] == after[[k]])
}, numeric(1))
print(agreement)
""", out / "before/predictions.rds", out / "after/predictions.rds"])
    print("All 12 valid endpoints unchanged; all four rank-50 requests rejected", flush=True)


if __name__ == "__main__":
    main()
