#!/usr/bin/env python3
"""Compare current Metal model-storage candidates without rerunning frozen code."""

import argparse
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
        raise ValueError("Current candidates only")
    args.out.mkdir(parents=True, exist_ok=False)
    dependencies = subprocess.check_output(
        ["Rscript", "-e", "cat(.libPaths(), sep='\\n')"], text=True).splitlines()
    env = dict(os.environ, R_LIBS=os.pathsep.join(dependencies),
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1",
               VECLIB_MAXIMUM_THREADS="1", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    script = Path(__file__).with_name("check_metal_component_storage.R")
    for label, library in (("before", args.before), ("after", args.after)):
        command = ["Rscript", str(script), str(library), str(args.out / label)]
        if label == "after":
            command.append(str(args.out / "before"))
        with (args.out / (label + ".log")).open("w") as log:
            subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=300)


if __name__ == "__main__":
    main()
