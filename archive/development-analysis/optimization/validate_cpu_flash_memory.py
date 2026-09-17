#!/usr/bin/env python3
"""Sample current CPU predictor RSS in independent, non-timing workers."""

import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if any("frozen" in str(p).lower() for p in (args.before, args.after)):
        raise ValueError("Only current candidates may be executed")
    args.out.mkdir(parents=True, exist_ok=False)
    scripts = Path(__file__).parent
    env = dict(os.environ, R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", VECLIB_MAXIMUM_THREADS="1",
               LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    rows = []
    for replicate in range(1, 4):
        order = [("before", args.before), ("after", args.after)]
        if replicate % 2 == 0:
            order.reverse()
        for label, library in order:
            for family in ("simpls", "plssvd"):
                name = f"{label}_{family}_{replicate}"
                print(name, flush=True)
                command = ["python3", scripts / "monitor_process.py", "--output",
                           args.out / name, "--interval", "0.005", "--timeout", "120", "--",
                           "Rscript", scripts / "check_cpu_flash_memory.R", library,
                           family, args.out / (name + ".csv")]
                with (args.out / (name + ".log")).open("w") as log:
                    subprocess.run(list(map(str, command)), env=env, stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=150)
                result = json.loads((args.out / name / "summary.json").read_text())
                if len(result["measurements"]) != 1:
                    raise RuntimeError("Missing prediction memory interval")
                measurement = result["measurements"][0]
                if measurement["samples"] < 1 or measurement["peak_rss_mib"] is None:
                    raise RuntimeError("No memory samples in prediction interval")
                rows.append(dict(label=label, family=family, worker_replicate=replicate,
                                 **measurement))
    (args.out / "memory_summary.json").write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
