#!/usr/bin/env python3
"""Install the current extraction and compare with saved current-code outputs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT_FILES = ("DESCRIPTION", "NAMESPACE", "INSTALL", "NEWS.md", "README.md",
              ".Rbuildignore", "configure", "configure.win", "cleanup")
SOURCE_DIRS = ("R", "src", "inst", "man", "tests", "vignettes", "data", "core")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--stored-metrics", type=Path, required=True)
    parser.add_argument("--openblas", type=Path, required=True)
    parser.add_argument("--prepare-only", action="store_true",
                        help="Prepare a source snapshot for separate full package checks")
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    if "frozen" in str(root).lower():
        raise SystemExit("Only current working sources may be executed")
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = output / "source"
    source.mkdir()
    for name in ROOT_FILES:
        shutil.copy2(root / name, source / name)
    for name in SOURCE_DIRS:
        shutil.copytree(root / name, source / name, ignore=shutil.ignore_patterns(
            "*.o", "*.so", "*.dll", "symbols.rds", "__pycache__"))
    for name in ("src/Makevars", "src/Makevars.win", "src/svd_metal_backend.mm"):
        (source / name).unlink(missing_ok=True)
    files = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(source.rglob("*")) if p.is_file()}
    (output / "source_manifest.json").write_text(json.dumps({
        "source": str(root), "files": files,
        "stored_metrics": str(args.stored_metrics.resolve()),
        "scope": "current-code extraction regression; no frozen or external PLS executed",
    }, indent=2) + "\n")
    if args.prepare_only:
        print("Prepared source snapshot only; no build or tests run", flush=True)
        return
    library = output / "library"
    library.mkdir()
    env = dict(os.environ, LC_ALL="en_US.UTF-8", LANG="en_US.UTF-8",
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1",
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               FASTPLS_USE_CUDA="0", FASTPLS_USE_METAL="1",
               FASTPLS_USE_OPENBLAS="1", OPENBLAS_ROOT=str(args.openblas))

    def run(name, command, timeout):
        print(name, flush=True)
        with (output / (name + ".log")).open("w") as stream:
            subprocess.run(list(map(str, command)), stdout=stream,
                           stderr=subprocess.STDOUT, env=env,
                           timeout=timeout, check=True)

    run("install", ["R", "CMD", "INSTALL", "--no-multiarch", "-l", library, source], 1800)
    run("tests", ["Rscript", Path(__file__).with_name("run_candidate_tests.R"),
                  library, source / "tests/testthat", output / "tests.rds"], 900)
    run("public_metrics", ["Rscript", Path(__file__).with_name("check_native_public.R"),
                           library, args.stored_metrics, output], 300)
    (output / "completed.json").write_text(json.dumps({
        "install": "success", "tests": "success", "stored_public_metrics": "matched",
        "note": "not a complete license audit, GPU migration, or manuscript rerun",
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
