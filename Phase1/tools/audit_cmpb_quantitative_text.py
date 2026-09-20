#!/usr/bin/env python3
"""Check that the assembled CMPB prose reflects its audited result summary."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from docx import Document


def number(value) -> float:
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"Non-finite quantitative value: {value!r}")
    return result


def implementation(rows: list[dict], fragment: str) -> dict:
    matches = [row for row in rows if fragment in row["implementation"]]
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one NMR row containing {fragment!r}; found {len(matches)}"
        )
    return matches[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manuscript", type=Path)
    parser.add_argument("narrative", type=Path)
    args = parser.parse_args()

    document = Document(args.manuscript)
    paragraphs = [paragraph.text for paragraph in document.paragraphs]
    text = "\n".join(paragraphs)
    facts = json.loads(args.narrative.read_text())
    failures: list[str] = []

    image = facts["figure1"]["per_dataset"]["imagenet"]
    expected = {
        f"{number(image['fastpls']['total_sec']):.3f} s":
            "current ImageNet fastPLS time",
        f"{number(image['ikpls']['total_sec']):.3f} s":
            "current ImageNet IKPLS time",
    }
    nmr_rows = facts["figure3_nmr"]
    for fragment, label in (
        ("PLS-SVD\nCUDA", "current NMR CUDA PLS-SVD time"),
        ("SIMPLS-family\nCUDA", "current NMR CUDA SIMPLS-family time"),
        ("Deposited PLS-SVD", "deposited NMR time"),
    ):
        row = implementation(nmr_rows, fragment)
        expected[f"{number(row['total_time_sec']):.3f} s"] = label

    cv = facts["figure2"]["cv_over_fit_prediction"]
    for backend in ("cpu", "cuda"):
        expected[f"{number(cv[backend]['median']):.2f} times"] = (
            f"current {backend.upper()} median CV ratio"
        )

    for token, label in expected.items():
        if token not in text:
            failures.append(f"Missing {label}: {token!r}")

    forbidden = {
        "fastPLS 0.99": "obsolete package version",
        "48 of 48 CPU and 48 of 48 CUDA": "obsolete CV completion claim",
        "warm-started rank-one": "removed direction-initialization terminology",
        "warm-start": "ambiguous direction-initialization terminology",
    }
    for token, label in forbidden.items():
        if token in text:
            failures.append(f"Found {label}: {token!r}")

    results_paragraphs = sum(value.startswith("Results:") for value in paragraphs)
    if results_paragraphs != 1:
        failures.append(
            f"Expected one abstract Results paragraph; found {results_paragraphs}"
        )

    if failures:
        raise SystemExit(
            "CMPB quantitative-text audit failed:\n- " + "\n- ".join(failures)
        )
    print("CMPB quantitative-text audit: PASS")


if __name__ == "__main__":
    main()
