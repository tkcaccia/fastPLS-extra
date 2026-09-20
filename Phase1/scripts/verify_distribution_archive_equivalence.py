#!/usr/bin/env python3
"""Verify that a vignette-enabled archive preserves benchmarked package code."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import tarfile
from pathlib import Path


GENERATED_PREFIXES = ("inst/doc/", "build/")
REQUIRED_DISTRIBUTION_FILES = {
    "inst/doc/fastPLS.Rmd",
    "inst/doc/fastPLS.html",
    "inst/doc/installation.Rmd",
    "inst/doc/installation.html",
    "build/vignette.rds",
}


def archive_files(path: Path) -> dict[str, bytes]:
    values: dict[str, bytes] = {}
    with tarfile.open(path, "r:gz") as archive:
        members = [member for member in archive.getmembers() if member.isfile()]
        roots = {member.name.split("/", 1)[0] for member in members}
        if len(roots) != 1:
            raise RuntimeError(f"{path} does not contain one package root")
        root = roots.pop() + "/"
        for member in members:
            relative = member.name.removeprefix(root)
            stream = archive.extractfile(member)
            if stream is None:
                raise RuntimeError(f"Could not read {member.name} from {path}")
            values[relative] = stream.read()
    return values


def normalized_code(files: dict[str, bytes]) -> dict[str, bytes]:
    values = {
        name: content for name, content in files.items()
        if not name.startswith(GENERATED_PREFIXES)
    }
    description = values.get("DESCRIPTION")
    if description is None:
        raise RuntimeError("Archive has no DESCRIPTION file")
    text = description.decode("utf-8")
    text = re.sub(r"^Packaged:.*\n", "", text, flags=re.MULTILINE)
    values["DESCRIPTION"] = text.encode("utf-8")
    return values


def digest(values: dict[str, bytes]) -> str:
    hasher = hashlib.sha256()
    for name in sorted(values):
        hasher.update(name.encode("utf-8") + b"\0")
        hasher.update(values[name])
    return hasher.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("benchmark_archive", type=Path)
    parser.add_argument("distribution_archive", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    benchmark = archive_files(args.benchmark_archive)
    distribution = archive_files(args.distribution_archive)
    benchmark_code = normalized_code(benchmark)
    distribution_code = normalized_code(distribution)

    missing = sorted(set(benchmark_code) - set(distribution_code))
    added = sorted(set(distribution_code) - set(benchmark_code))
    changed = sorted(
        name for name in set(benchmark_code) & set(distribution_code)
        if benchmark_code[name] != distribution_code[name]
    )
    generated = {
        name for name in distribution if name.startswith(GENERATED_PREFIXES)
    }
    missing_generated = sorted(REQUIRED_DISTRIBUTION_FILES - generated)
    report = {
        "benchmark_archive": str(args.benchmark_archive.resolve()),
        "distribution_archive": str(args.distribution_archive.resolve()),
        "benchmark_code_digest": digest(benchmark_code),
        "distribution_code_digest": digest(distribution_code),
        "missing_code_files": missing,
        "added_code_files": added,
        "changed_code_files": changed,
        "missing_required_generated_files": missing_generated,
        "equivalent": not (missing or added or changed or missing_generated),
    }
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not report["equivalent"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
