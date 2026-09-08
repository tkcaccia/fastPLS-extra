#!/usr/bin/env python3
"""Reject unexplained CIFAR-100 numerical or runtime regressions."""

import argparse
import csv
import math
import statistics
from pathlib import Path


PROTOCOL_FIELDS = (
    "dataset",
    "backend",
    "precision",
    "ncomp",
    "oversample",
    "power",
    "seed",
    "algorithm_variant",
    "refresh_block",
)


def read_rows(path: Path):
    files = sorted(path.glob("*.csv")) if path.is_dir() else [path]
    rows = []
    for item in files:
        with item.open(newline="") as handle:
            rows.extend(csv.DictReader(handle))
    if not rows:
        raise ValueError(f"No benchmark rows found at {path}")
    return rows


def unique_value(rows, field):
    values = {row.get(field, "") for row in rows}
    if len(values) != 1:
        raise ValueError(f"{field} is not constant: {sorted(values)}")
    return values.pop()


def finite_values(rows, field):
    values = [float(row[field]) for row in rows]
    if not all(math.isfinite(value) for value in values):
        raise ValueError(f"{field} contains a non-finite value")
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--max-slowdown", type=float, default=1.10)
    parser.add_argument("--accuracy-tolerance", type=float, default=1e-12)
    args = parser.parse_args()

    candidate = read_rows(args.candidate)
    baseline = read_rows(args.baseline)
    for field in PROTOCOL_FIELDS:
        candidate_value = unique_value(candidate, field)
        baseline_value = unique_value(baseline, field)
        if candidate_value != baseline_value:
            raise SystemExit(
                f"FAIL: protocol field {field} changed from "
                f"{baseline_value!r} to {candidate_value!r}"
            )

    candidate_accuracy = statistics.median(
        finite_values(candidate, "accuracy")
    )
    baseline_accuracy = statistics.median(finite_values(baseline, "accuracy"))
    if abs(candidate_accuracy - baseline_accuracy) > args.accuracy_tolerance:
        raise SystemExit(
            "FAIL: accuracy changed from "
            f"{baseline_accuracy:.12g} to {candidate_accuracy:.12g}"
        )

    candidate_checksum = unique_value(candidate, "prediction_checksum")
    baseline_checksum = unique_value(baseline, "prediction_checksum")
    if candidate_checksum != baseline_checksum:
        raise SystemExit(
            "FAIL: prediction checksum changed from "
            f"{baseline_checksum} to {candidate_checksum}"
        )

    candidate_time = statistics.median(finite_values(candidate, "total_sec"))
    baseline_time = statistics.median(finite_values(baseline, "total_sec"))
    slowdown = candidate_time / baseline_time
    if slowdown > args.max_slowdown:
        raise SystemExit(
            f"FAIL: median runtime regressed by {(slowdown - 1) * 100:.1f}% "
            f"({baseline_time:.6g}s to {candidate_time:.6g}s)"
        )

    print(
        "PASS: matched CIFAR-100 gate; "
        f"accuracy={candidate_accuracy:.6f}, checksum={candidate_checksum}, "
        f"median={candidate_time:.6g}s, baseline={baseline_time:.6g}s, "
        f"ratio={slowdown:.3f}"
    )


if __name__ == "__main__":
    main()
