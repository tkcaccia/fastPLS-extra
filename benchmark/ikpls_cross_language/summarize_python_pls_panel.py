#!/usr/bin/env python3
"""Combine Python PLS worker rows without rerunning fitted models."""

import argparse
from pathlib import Path

import pandas as pd


GROUP_KEYS = [
    "dataset",
    "task_type",
    "implementation",
    "package",
    "package_version",
    "algorithm",
    "solver_controls",
    "precision",
    "ncomp",
]


def log_detail(path: Path) -> tuple[int, str]:
    log = path.with_suffix(".log")
    if not log.exists():
        return 0, ""
    text = log.read_text(errors="replace")
    warning_count = text.count("ConvergenceWarning")
    exception_lines = [
        line.strip()
        for line in text.splitlines()
        if "Error:" in line or "failed]" in line
    ]
    return warning_count, " | ".join(dict.fromkeys(exception_lines[-3:]))


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
            warning_count, detail = log_detail(path)
            if "warning_count" not in frame:
                frame["warning_count"] = warning_count
            else:
                frame["warning_count"] = frame["warning_count"].fillna(
                    warning_count
                )
            warning_detail = (
                "scikit-learn component iteration limit reached"
                if warning_count
                else ""
            )
            if "warnings" not in frame:
                frame["warnings"] = warning_detail
            else:
                frame["warnings"] = frame["warnings"].fillna(warning_detail)
            if "solver_controls" not in frame:
                is_nirs_rsvd = (
                    frame.get("implementation", pd.Series(dtype=str))
                    == "nirs4all_methods_rsvd"
                )
                frame["solver_controls"] = "package defaults"
                if len(frame) and bool(is_nirs_rsvd.iloc[0]):
                    frame["solver_controls"] = (
                        "package defaults; randomized controls not exposed "
                        "by binding"
                    )
            current_error = (
                ""
                if "error" not in frame or not len(frame)
                else str(frame["error"].fillna("").iloc[0])
            )
            if detail and (
                not current_error or current_error.startswith("worker exit code")
            ):
                frame["error"] = detail
            frames.append(frame)
    if not frames:
        raise RuntimeError("No worker CSV files were found")

    results = pd.concat(frames, ignore_index=True, sort=False)
    results = results.drop_duplicates(
        subset=["dataset", "implementation", "replicate"], keep="last"
    )
    args.output.mkdir(parents=True, exist_ok=True)
    results.to_csv(args.output / "python_pls_panel_all_runs.csv", index=False)

    success = results[results["status"] == "success"].copy()
    if len(success):
        summary = success.groupby(GROUP_KEYS, dropna=False).agg(
            repetitions=("replicate", "count"),
            accuracy=("accuracy", "median"),
            balanced_accuracy=("balanced_accuracy", "median"),
            top5_accuracy=("top5_accuracy", "median"),
            correct=("correct", "median"),
            test_total=("test_total", "median"),
            rmsd=("rmsd", "median"),
            q2=("q2", "median"),
            mae=("mae", "median"),
            median_fit_sec=("fit_sec", "median"),
            iqr_fit_sec=(
                "fit_sec",
                lambda x: x.quantile(0.75) - x.quantile(0.25),
            ),
            median_prediction_sec=("prediction_sec", "median"),
            median_total_sec=("total_sec", "median"),
            iqr_total_sec=(
                "total_sec",
                lambda x: x.quantile(0.75) - x.quantile(0.25),
            ),
            median_peak_rss_mib=("peak_rss_mib", "median"),
            median_incremental_peak_rss_mib=(
                "incremental_peak_rss_mib",
                "median",
            ),
            runs_with_warnings=("warning_count", lambda x: (x > 0).sum()),
        ).reset_index()
    else:
        summary = pd.DataFrame(columns=GROUP_KEYS)
    summary.to_csv(args.output / "python_pls_panel_summary.csv", index=False)

    status = results.groupby(
        ["dataset", "implementation", "status"], dropna=False
    ).agg(
        runs=("replicate", "count"),
        detail=(
            "error",
            lambda x: " | ".join(
                dict.fromkeys(str(value) for value in x if pd.notna(value))
            ),
        ),
    ).reset_index()
    status.to_csv(args.output / "python_pls_panel_status.csv", index=False)
    print(summary.to_string(index=False))
    print(status.to_string(index=False))


if __name__ == "__main__":
    main()
