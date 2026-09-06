#!/usr/bin/env python3
"""Inventory source evidence without inferring permission to relicense code."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


IRLBA_FILES = {
    "src/irlba.c", "src/irlba.h", "src/irlba_workspace.h",
    "src/svd_cpu_irlba.cpp",
}
SOURCE_DIRS = {"R", "src", "inst", "man", "tests", "vignettes", "data", "core"}
TEXT_SUFFIXES = {".R", ".Rd", ".Rmd", ".c", ".cpp", ".h", ".hpp", ".cu",
                 ".mm", ".in", ".py", ".sh", ".md", ".txt", ".json"}
CODE_SUFFIXES = {".R", ".c", ".cpp", ".h", ".hpp", ".cu", ".mm", ".in"}
INCLUDE = re.compile(r'^\s*#\s*include\s*[<"]([^>"\n]+)[>"]', re.MULTILINE)
SPDX = re.compile(r"SPDX-License-Identifier:\s*([^\r\n*]+)")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def package_fields(text):
    fields = {}
    key = None
    for line in text.splitlines():
        if line[:1].isspace() and key:
            fields[key] += " " + line.strip()
        elif ":" in line:
            key, value = line.split(":", 1)
            fields[key] = value.strip()
        else:
            key = None
    return fields


def inventory_paths(root):
    tracked = set(git(root, "ls-files", "-z").decode().split("\0")) - {""}
    untracked = set(git(root, "ls-files", "--others", "--exclude-standard", "-z")
                    .decode().split("\0")) - {""}
    # Untracked build/results trees are not source-distribution inputs.
    added = {p for p in untracked if Path(p).parts[0] in SOURCE_DIRS and
             (Path(p).suffix in TEXT_SUFFIXES or Path(p).name.startswith("Makevars") or
              Path(p).name in ("LICENSE", "COPYING", "NOTICE"))}
    return sorted(tracked | added), tracked


def inspect_file(root, relative, tracked):
    path = root / relative
    if path.is_symlink():
        return {"path": relative, "tracked": tracked,
                "decision": "symlink_requires_review", "license_evidence": []}
    if not path.is_file():
        return {"path": relative, "tracked": tracked, "decision": "removed",
                "license_evidence": []}
    raw = path.read_bytes()
    text = raw.decode("utf-8", errors="replace") if (
        path.suffix in TEXT_SUFFIXES or path.suffix == "" or
        path.name.startswith("Makevars")) else ""
    includes = INCLUDE.findall(text)
    markers = []
    for number, line in enumerate(text.splitlines(), 1):
        if re.search(r"SPDX-License-Identifier|copyright|licensed under|GNU General",
                     line, re.IGNORECASE):
            markers.append({"line": number, "text": line.strip()[:300]})
    findings = []
    if relative in IRLBA_FILES:
        findings.append("irlba_source_for_gpl_companion")
    elif path.suffix in CODE_SUFFIXES and re.search(r"\birlba\b|\birlb\b|IRLBA|irlba_", text):
        findings.append("contains_irlba_interface_or_implementation")
    if any(i.startswith(("Rcpp", "R_ext/", "Rinternals", "Rconfig", "R.h"))
           for i in includes):
        findings.append("r_interface_dependency_not_standalone_core")
    if "Matrix.h" in includes or "Matrix_stubs.c" in includes:
        findings.append("matrix_c_interface_dependency")
    if any(i.startswith("Eigen/") for i in includes):
        findings.append("eigen_notices_and_module_license_audit_required")
    if any(i.startswith(("cuda", "cublas", "cusolver", "curand", "Metal/",
                         "MetalPerformanceShaders/")) for i in includes):
        findings.append("external_gpu_sdk_terms_apply")
    return {
        "path": relative, "tracked": tracked, "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "decision": "gpl_companion" if relative in IRLBA_FILES else "ownership_review_pending",
        "spdx_headers": SPDX.findall(text), "license_evidence": markers,
        "includes": includes, "findings": findings,
    }


def audit(root):
    paths, tracked = inventory_paths(root)
    fields = package_fields((root / "DESCRIPTION").read_text())
    files = [inspect_file(root, p, p in tracked) for p in paths]
    return {
        "schema": 1, "source": str(root.resolve()),
        "base_commit": git(root, "rev-parse", "HEAD").decode().strip(),
        "package": {key: fields.get(key) for key in
                    ("Package", "Version", "License", "Depends", "Imports", "LinkingTo")},
        "scope": "tracked repository files plus untracked package source files; not an R CMD build manifest",
        "mit_release_ready": False,
        "permission_policy": "No authorship or license permission is inferred from Git history or absent notices.",
        "files": files,
        "counts": {"files": len(files), "unconfirmed": sum(
            f["decision"] not in ("removed", "mit_confirmed") for f in files)},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--require-mit", action="store_true")
    args = parser.parse_args()
    report = audit(args.source.resolve(strict=True))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), **report["counts"],
                      "mit_release_ready": report["mit_release_ready"]}))
    if args.require_mit and not report["mit_release_ready"]:
        raise SystemExit("MIT release not established: ownership/dependency review remains open.")


if __name__ == "__main__":
    main()
