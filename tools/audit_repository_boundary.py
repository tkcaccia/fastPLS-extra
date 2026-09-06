#!/usr/bin/env python3
"""Reject generated evidence tracked by a fastPLS source repository."""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess


GENERATED_ROOTS = {
    "artifacts",
    "benchmark_results",
    "output",
    "outputs",
    "publication_results",
    "results",
    "validation",
}
GENERATED_SUFFIXES = {
    ".docx", ".log", ".pdf", ".png", ".rda", ".rdata", ".rds",
    ".rout", ".tar.gz", ".xlsx",
}
ALLOWED_TABLES = {"benchmark/MANIFEST.csv"}
ALLOWED_PACKAGE_DATA = {"data/breast.rda", "data/colon.rda"}


def tracked_files(repository: Path) -> list[str]:
    output = subprocess.check_output(
        ["git", "ls-files"], cwd=repository, text=True
    )
    return [line for line in output.splitlines() if line]


def is_generated(path: str) -> bool:
    if path in ALLOWED_PACKAGE_DATA:
        return False
    parts = Path(path).parts
    if parts and parts[0] in GENERATED_ROOTS:
        return True
    lower = path.lower()
    if any(lower.endswith(suffix) for suffix in GENERATED_SUFFIXES):
        return True
    return lower.endswith((".csv", ".tsv")) and path not in ALLOWED_TABLES


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", nargs="+", type=Path)
    args = parser.parse_args()
    failures: list[str] = []
    for repository in args.repository:
        repository = repository.resolve(strict=True)
        for path in tracked_files(repository):
            if is_generated(path):
                failures.append(f"{repository}: {path}")
    if failures:
        raise SystemExit(
            "Generated evidence is tracked by a source repository:\n" +
            "\n".join(failures)
        )
    print("Repository boundary audit passed.")


if __name__ == "__main__":
    main()
