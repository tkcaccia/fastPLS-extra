#!/usr/bin/env python3
"""Check the current GPL companion against an explicitly selected main library."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--main-library", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    library = args.main_library.resolve(strict=True)
    if "frozen" in str(source).lower() or "frozen" in str(library).lower():
        raise ValueError("Only current development sources and libraries are allowed")
    if not (library / "fastPLS" / "include" / "fastpls" / "native").is_dir():
        raise ValueError("The selected main library lacks the shared native headers")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    snapshot = out / "source" / "fastPLSextra"
    snapshot.mkdir(parents=True)
    manifest = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if relative.parts[0] not in {
            "DESCRIPTION", "NAMESPACE", ".Rbuildignore", "R", "src", "man",
            "tests", "inst", "README.md",
        }:
            continue
        if path.is_symlink():
            raise ValueError(f"Review source symlink before packaging: {relative}")
        if not path.is_file() or path.suffix in {".o", ".so", ".dll", ".pyc"}:
            continue
        if "__pycache__" in relative.parts or path.suffix == ".py":
            continue
        target = snapshot / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        manifest.append({"path": str(relative),
                         "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    (out / "source_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    env = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8",
               R_PROFILE_USER="/dev/null", R_ENVIRON_USER="/dev/null",
               R_LIBS=str(library) + os.pathsep + os.environ.get("R_LIBS", ""),
               OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1",
               VECLIB_MAXIMUM_THREADS="1")
    for name, command in [
        ("build", ["R", "CMD", "build", str(snapshot)]),
        ("check", ["R", "CMD", "check", "--as-cran", "fastPLSextra_0.0.1.tar.gz"]),
    ]:
        print(name, flush=True)
        with (out / (name + ".log")).open("w") as log:
            subprocess.run(command, cwd=out, env=env, stdout=log,
                           stderr=subprocess.STDOUT, timeout=1800, check=True)
    print("Companion check completed; inspect all reported notes", flush=True)


if __name__ == "__main__":
    main()
