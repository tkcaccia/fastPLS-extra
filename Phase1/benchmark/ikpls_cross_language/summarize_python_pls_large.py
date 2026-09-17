#!/usr/bin/env python3
"""Combine guarded NMR/ImageNet Python PLS rows without refitting."""

import argparse
from pathlib import Path

import pandas as pd


def failure_detail(path: Path) -> str:
    log = path.with_suffix(".log")
    if not log.exists():
        return ""
    lines = [
        line.strip()
        for line in log.read_text(errors="replace").splitlines()
        if "Error:" in line or "failed]" in line or "MemoryError" in line
    ]
    return " | ".join(dict.fromkeys(lines[-3:]))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rows", required=True, nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    frames = []
    for root in args.rows:
        rows_dir = root / "rows" if (root / "rows").is_dir() else root
        for path in sorted(rows_dir.glob("*.csv")):
            frame = pd.read_csv(path)
            if len(frame) and frame.iloc[0].get("status") != "success":
                detail = failure_detail(path)
                error = str(frame.iloc[0].get("error", ""))
                if detail and (not error or error.startswith("worker exit code")):
                    frame["error"] = detail
            frames.append(frame)
    if not frames:
        raise RuntimeError("No guarded Python PLS rows were found")

    result = pd.concat(frames, ignore_index=True, sort=False)
    result = result.drop_duplicates(
        subset=["dataset", "implementation", "ncomp", "replicate"],
        keep="last",
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result.to_csv(args.output, index=False)
    print(result.to_string(index=False))


if __name__ == "__main__":
    main()
