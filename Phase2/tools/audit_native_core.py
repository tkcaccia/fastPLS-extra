#!/usr/bin/env python3
"""Record the extracted core's build dependencies, not an overall MIT-release verdict."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    build = args.build.resolve(strict=True)
    headers = sorted((root / "inst/include/fastpls/native").glob("*.hpp"))
    records = []
    for header in headers:
        raw = header.read_bytes()
        text = raw.decode()
        if "SPDX-License-Identifier: MIT" not in text[:200]:
            raise RuntimeError(f"No scoped MIT notice: {header}")
        if re.search(r"#\s*include\s*[<\"](?:Rcpp|R_ext|Rinternals|Matrix\.h)|\birlba\b",
                     text, re.I):
            raise RuntimeError(f"R/GPL boundary requires inspection: {header}")
        records.append({"file": str(header.relative_to(root)),
                        "sha256": hashlib.sha256(raw).hexdigest(),
                        "license": "MIT", "owner": "Stefano Cacciatore"})
    dependencies = set()
    manifests = list(build.glob("CMakeFiles/test_native_*.dir/tests/*.o.d"))
    expected = len(list((root / "core/tests").glob("test_*.cpp")))
    if len(manifests) != expected:
        raise RuntimeError(f"Expected {expected} standalone test dependency manifests")
    for manifest in manifests:
        text = manifest.read_text().replace("\\\n", " ")
        dependencies.update(Path(p).resolve() for p in shlex.split(text.split(":", 1)[1]))
    apache = []
    for path in sorted(dependencies):
        if path.name.startswith(("Rcpp", "Rinternals", "Rconfig")) or "R_ext" in path.parts:
            raise RuntimeError(f"R interface header in standalone dependency closure: {path}")
        if path.name == "armadillo" or "armadillo_bits" in path.parts:
            raw = path.read_bytes()
            if b"SPDX-License-Identifier: Apache-2.0" not in raw[:200]:
                raise RuntimeError(f"Armadillo license requires manual review: {path}")
            apache.append({"file": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
                           "license": "Apache-2.0"})
    if not apache:
        raise RuntimeError("No independently licensed Armadillo dependencies found")
    links = {}
    for binary in sorted(build.glob("test_native_*")):
        if binary.is_file():
            links[binary.name] = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    tests = subprocess.run(["ctest", "--test-dir", str(build), "--output-on-failure"],
                           capture_output=True, text=True, check=True)
    report = {
        "scope": "extracted native headers and actual standalone build closure only",
        "overall_R_package_MIT_release_established": False,
        "ownership_evidence": "migration/OWNERSHIP.md",
        "source": str(root), "build": str(build), "own_headers": records,
        "external_Armadillo_headers": apache,
        "system_headers": "External C/C++ SDK terms apply; not relicensed as MIT",
        "links": links, "tests": tests.stdout,
        "limitations": ["R adapter and GPU migration remain incomplete",
                        "External BLAS/compiler/vendor runtime obligations remain separate",
                        "Not a complete source distribution or dependency audit"],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{len(records)} own MIT headers; {len(apache)} Apache-2.0 Armadillo headers; "
          f"{expected} standalone tests succeeded")


if __name__ == "__main__":
    main()
