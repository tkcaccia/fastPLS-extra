#!/usr/bin/env python3
"""Validate the compiled metric without executing frozen or external PLS."""
import argparse
import json
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
    args = parser.parse_args()
    if any("frozen" in str(path).lower() for path in
           (args.source, args.library, args.before)):
        raise ValueError("Only current optimization candidates may be executed")
    args.out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1",
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null")
    scripts = args.source / "benchmark/optimization"
    (args.out / "manifest.json").write_text(json.dumps({
        "source": str(args.source.resolve()), "library": str(args.library.resolve()),
        "before": str(args.before.resolve()), "scope": "rank metrics and public outputs",
        "timings": "Five alternating-order repetitions against stats::cor; no external PLS fits",
    }, indent=2))

    def run(name, command, timeout=900):
        print(name, flush=True)
        with (args.out / (name + ".log")).open("w") as log:
            subprocess.run(list(map(str, command)), env=env, stdout=log,
                           stderr=subprocess.STDOUT, timeout=timeout, check=True)

    run("tests", ["Rscript", companion_tool("run_candidate_tests.R"), args.library,
                  args.source / "tests/testthat", args.out / "tests.rds"])
    run("before", ["Rscript", scripts / "check_rank_metrics.R", args.before,
                   args.out / "before"])
    run("after", ["Rscript", scripts / "check_rank_metrics.R", args.library,
                  args.out / "after", args.out / "before"])
    run("phases", ["Rscript", scripts / "profile_cpu_response_wide.R", args.library,
                   args.source, args.out / "phases"])


if __name__ == "__main__":
    main()
