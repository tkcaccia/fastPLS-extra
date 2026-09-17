#!/usr/bin/env python3
"""Attach GNU-time peak RSS to completed ImageNet Figure 1 rows."""

import argparse
import csv
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    rows = []
    for path in sorted(args.results.glob("*.csv")):
        with path.open(newline="") as handle:
            row = next(csv.DictReader(handle))
        timing = path.with_suffix(".time.log")
        if timing.is_file():
            match = re.search(
                r"Maximum resident set size \(kbytes\):\s*(\d+)",
                timing.read_text(errors="replace"),
            )
            if match:
                row["peak_rss_mib"] = str(int(match.group(1)) / 1024)
        rows.append(row)
    if not rows:
        raise RuntimeError(f"No completed ImageNet rows in {args.results}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
