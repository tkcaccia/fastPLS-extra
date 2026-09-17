#!/usr/bin/env python3
"""Verify an installed native-header consumer without claiming package relicensing."""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--consumer-build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    prefix = args.prefix.resolve(strict=True)
    build = args.consumer_build.resolve(strict=True)
    own = prefix / "include/fastpls/native"
    originals = source / "inst/include/fastpls/native"
    records = []
    for header in sorted(originals.glob("*.hpp")):
        installed = own / header.name
        if installed.read_bytes() != header.read_bytes():
            raise RuntimeError(f"Installed header differs: {header.name}")
        records.append({"path": str(installed.relative_to(prefix)),
                        "sha256": hashlib.sha256(installed.read_bytes()).hexdigest()})
    if (prefix / "share/licenses/fastpls_native/LICENSE").read_bytes() != (
            originals / "LICENSE").read_bytes():
        raise RuntimeError("Installed MIT notice differs")
    manifests = list(build.glob("CMakeFiles/consumer.dir/*.o.d"))
    if len(manifests) != 1:
        raise RuntimeError("Expected one installed-consumer dependency manifest")
    text = manifests[0].read_text().replace("\\\n", " ")
    dependencies = {Path(p).resolve() for p in shlex.split(text.split(":", 1)[1])}
    installed_headers = set()
    for path in dependencies:
        if originals in path.parents:
            raise RuntimeError("Consumer compiled against the original source headers")
        if path.name in {"R.h", "Rconfig.h", "Rinternals.h", "Matrix.h"} or (
                path.name.startswith("Rcpp") or "R_ext" in path.parts):
            raise RuntimeError(f"R integration dependency detected: {path}")
        if own in path.parents:
            installed_headers.add(str(path.relative_to(prefix)))
    required = {f"include/fastpls/native/{name}.hpp" for name in
                ("simpls", "plssvd", "models", "opls", "kernels")}
    if not required.issubset(installed_headers):
        raise RuntimeError("Consumer did not use all installed PLS model headers")
    links = subprocess.check_output(["otool", "-L", str(build / "consumer")], text=True)
    if "libR." in links or "R.framework" in links or "libRblas" in links:
        raise RuntimeError("Consumer links to an R runtime")
    tests = subprocess.check_output(
        ["ctest", "--test-dir", str(build), "--output-on-failure"], text=True)
    report = {"scope": "installed CPU float32/float64 four-family PLS consumer on macOS",
              "source": str(source), "prefix": str(prefix), "build": str(build),
              "installed_native_headers": records,
              "consumer_native_headers": sorted(installed_headers),
              "links": links, "test_output": tests,
              "limitations": ["Not a full R-package or GPU license audit",
                              "External Armadillo/BLAS/SDK licenses remain separate",
                              "Header extraction coverage remains incomplete"]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("Installed consumer passed without original native headers or R dependencies")


if __name__ == "__main__":
    main()
