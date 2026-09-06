#!/usr/bin/env python3
"""Preserve current IRLBA files before extraction; never overwrite an archive."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


FILES = ("src/irlba.c", "src/irlba.h", "src/irlba_workspace.h",
         "src/svd_cpu_irlba.cpp")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--gpl-text", type=Path, required=True)
    parser.add_argument("--integration", action="store_true",
                        help="Also preserve mixed integration sources before removing IRLBA sections")
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    if args.output.exists():
        raise SystemExit("Preservation destination already exists; refusing overwrite")
    files = FILES + (("src/fastPLS.cpp", "src/svd_iface.cpp", "src/svd_iface.h",
                      "inst/include/fastPLS.h", "R/main.R", "R/RcppExports.R",
                      "src/RcppExports.cpp", "src/Makevars.in",
                      "src/Makevars.win.in", "configure", "configure.win")
                     if args.integration else ())
    if args.integration:
        files += tuple(str(p.relative_to(root)) for folder in ("tests", "man", "vignettes")
                       for p in sorted((root / folder).rglob("*"))
                       if p.is_file() and p.suffix in (".R", ".Rd", ".Rmd"))
    paths = [root / name for name in files]
    if any(not p.is_file() or p.is_symlink() for p in paths):
        raise SystemExit("Expected current solver source missing or symlinked")
    license_text = args.gpl_text.read_text()
    if "GNU GENERAL PUBLIC LICENSE" not in license_text or "Version 3" not in license_text:
        raise SystemExit("Supplied text is not recognizable as GPL version 3")
    args.output.mkdir(parents=True)
    records = []
    for path, relative in zip(paths, files):
        target = args.output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        original = hashlib.sha256(path.read_bytes()).hexdigest()
        if hashlib.sha256(target.read_bytes()).hexdigest() != original:
            raise RuntimeError("Preserved source differs: " + relative)
        records.append({"path": relative, "sha256": original,
                        "license_basis": "GPL-3 package distribution; upstream notice audit pending"})
    shutil.copyfile(root / "DESCRIPTION", args.output / "SOURCE_DESCRIPTION")
    shutil.copyfile(args.gpl_text, args.output / "COPYING")
    manifest = {
        "source": str(root),
        "base_commit": subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
        "scope": "current working solver files, preserved only; not an installable duplicate PLS package",
        "files": records,
    }
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "verified_files": len(records)}))


if __name__ == "__main__":
    main()
