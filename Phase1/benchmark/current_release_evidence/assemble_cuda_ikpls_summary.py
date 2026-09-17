#!/usr/bin/env python3
"""Combine disjoint CUDA comparison summaries without altering raw evidence."""

import argparse
import csv
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    rows = []
    fieldnames = []
    seen = set()
    for path in args.input:
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                key = (row["dataset"], row["implementation"])
                if key in seen:
                    raise RuntimeError(f"Duplicate CUDA summary row: {key}")
                seen.add(key)
                rows.append(row)
                for field in row:
                    if field not in fieldnames:
                        fieldnames.append(field)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
