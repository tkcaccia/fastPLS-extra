#!/usr/bin/env python3
"""Preserve publication code and tracked compact tables without running them."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


CODE_ROOTS = {"benchmark", "scripts", "tools"}
CODE_EXTENSIONS = {".R", ".py", ".sh", ".cpp", ".h", ".md", ".json", ".txt"}
TABLE_EXTENSIONS = {".csv", ".tsv", ".json", ".md", ".txt"}


def select_files(source):
    tracked = set(subprocess.check_output(
        ["git", "-C", str(source), "ls-files", "-z"], text=True).split("\0"))
    selected = set()
    for root in CODE_ROOTS:
        for path in (source / root).rglob("*"):
            relative = path.relative_to(source)
            if "__pycache__" in relative.parts or path.suffix not in CODE_EXTENSIONS:
                continue
            if path.is_symlink():
                raise ValueError(f"Review symlink before preserving: {relative}")
            if path.is_file():
                selected.add(relative)
    for name in tracked:
        relative = Path(name)
        if not relative.parts or relative.parts[0] != "publication_results":
            continue
        if relative.suffix not in TABLE_EXTENSIONS:
            continue
        path = source / relative
        if path.is_symlink():
            raise ValueError(f"Review table symlink: {relative}")
        if path.is_file():
            selected.add(relative)
    return sorted(selected), tracked


def preserve(source, out):
    source = source.resolve(strict=True)
    out = out.resolve()
    if source == out or source in out.parents:
        raise ValueError("The preservation directory must be outside the source tree")
    paths, tracked = select_files(source)
    # A compact archive must not silently absorb installed packages or matrices.
    if any((source / path).stat().st_size > 32 * 1024 * 1024 for path in paths):
        raise ValueError("A selected file exceeds 32 MiB; review its distribution scope")
    out.mkdir(parents=True, exist_ok=False)
    records = []
    for relative in paths:
        original = source / relative
        raw = original.read_bytes()
        target = out / "files" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target)
        digest = hashlib.sha256(raw).hexdigest()
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"Copy verification failed: {relative}")
        records.append({"path": str(relative), "bytes": len(raw), "sha256": digest,
                        "tracked": str(relative) in tracked,
                        "role": "stored_result" if relative.parts[0] ==
                        "publication_results" else "source_tool"})
    report = {
        "source": str(source),
        "base_commit": subprocess.check_output(
            ["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip(),
        "files": records,
        "policy": "Preservation only. Do not execute external or frozen comparators. "
                  "Recorded base commit does not identify the source that generated "
                  "each result. No old result is relabelled as current validation.",
        "excluded": ["untracked result trees", "installed packages", "model matrices",
                     "compiled objects", "cached Python bytecode"],
    }
    (out / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"files": len(records), "bytes": sum(r["bytes"] for r in records),
                      "archive": str(out)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    preserve(args.source, args.out)
