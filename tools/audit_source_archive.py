#!/usr/bin/env python3
"""Inventory actual source-package bytes without extracting or inferring licenses."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile


def audit(archive, source=None):
    records, seen = [], set()
    total = 0
    with tarfile.open(archive, "r:gz") as package:
        for member in package:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or len(path.parts) < 1:
                raise ValueError(f"Unsafe archive path: {member.name}")
            if path.parts[0] != "fastPLS":
                raise ValueError("Expected the fastPLS source-package root")
            if member.isdir():
                continue
            if len(path.parts) < 2:
                raise ValueError("Package root must be a directory")
            if not member.isfile():
                raise ValueError(f"Non-regular archive member requires review: {member.name}")
            if path.as_posix() in seen:
                raise ValueError(f"Duplicate archive member: {member.name}")
            seen.add(path.as_posix())
            total += member.size
            if member.size > 64 * 1024**2 or total > 256 * 1024**2:
                raise ValueError("Source archive exceeds the audit size limit")
            raw = package.extractfile(member).read()
            relative = Path(*path.parts[1:])
            role = "source_review_pending"
            if relative.parts[0] == "data":
                role = "dataset_permissions_review"
            elif relative.parts[:2] == ("inst", "doc") or relative.parts[0] == "build":
                role = "generated_documentation_review"
            elif relative.suffix in {".so", ".dll", ".o", ".dylib"}:
                role = "unexpected_compiled_artifact"
            digest = hashlib.sha256(raw).hexdigest()
            current = source / relative if source else None
            same = None
            if current and current.is_file() and not current.is_symlink():
                same = hashlib.sha256(current.read_bytes()).hexdigest() == digest
            records.append({"path": str(relative), "bytes": len(raw),
                            "sha256": digest, "role": role,
                            "matches_current_source": same})
    if not any(row["path"] == "DESCRIPTION" for row in records):
        raise ValueError("Missing package DESCRIPTION")
    old_solver = {"src/irlba.c", "src/irlba.h", "src/irlba_workspace.h",
                  "src/svd_cpu_irlba.cpp"}
    return {"archive": str(archive.resolve()),
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            "files": records, "file_count": len(records), "unpacked_bytes": total,
            "bundled_irlba_sources": sorted(old_solver & {r["path"] for r in records}),
            "compiled_artifacts": [r["path"] for r in records if
                                   r["role"] == "unexpected_compiled_artifact"],
            "dataset_files": [r["path"] for r in records if
                              r["role"] == "dataset_permissions_review"],
            "mit_release_ready": False,
            "policy": "Actual archive inventory only. Matching source bytes, absent "
                      "GPL notices or absence of IRLBA do not prove MIT permissions."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = audit(args.archive, args.source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in (
        "file_count", "unpacked_bytes", "bundled_irlba_sources",
        "compiled_artifacts", "dataset_files", "mit_release_ready")}))
