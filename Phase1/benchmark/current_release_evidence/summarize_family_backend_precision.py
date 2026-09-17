#!/usr/bin/env python3
"""Summarize the matched family/backend/precision audit without rerunning fits."""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd


KEYS = [
    "dataset", "family", "backend", "precision", "classifier", "kernel",
    "requested_ncomp", "effective_ncomp", "status",
]


def read_fastpls(paths):
    frames = []
    for path in paths:
        frame = pd.read_csv(path)
        if "requested_ncomp" not in frame and "ncomp" in frame:
            frame["requested_ncomp"] = frame["ncomp"]
        if "effective_ncomp" not in frame:
            frame["effective_ncomp"] = frame["requested_ncomp"]
        for column, value in (
            ("kernel", "linear"), ("classifier", "argmax"),
            ("status", "success"), ("gpu_peak_mib", np.nan),
            ("incremental_peak_rss_mib", np.nan),
        ):
            if column not in frame:
                frame[column] = value
        frame["kernel"] = frame["kernel"].fillna("")
        frame.loc[frame["family"] != "kernelpls", "kernel"] = ""
        frame.loc[
            (frame["family"] == "kernelpls") & (frame["kernel"] == ""),
            "kernel",
        ] = "linear"
        frame["implementation"] = "fastPLS"
        frame["evidence_file"] = str(Path(path).resolve())
        frames.append(frame)
    if not frames:
        raise ValueError("at least one fastPLS result file is required")
    return pd.concat(frames, ignore_index=True, sort=False)


def summarize_fastpls(raw):
    numeric = {
        "fit_sec": "median_fit_sec",
        "prediction_sec": "median_prediction_sec",
        "total_sec": "median_total_sec",
        "metric_value": "median_metric",
        "peak_rss_mib": "median_peak_rss_mib",
        "incremental_peak_rss_mib": "median_incremental_peak_rss_mib",
        "gpu_peak_mib": "median_gpu_peak_mib",
    }
    successful = raw[raw["status"].eq("success")].copy()
    grouped = successful.groupby(KEYS, dropna=False)
    summary = grouped[list(numeric)].median().rename(columns=numeric)
    summary["iqr_total_sec"] = grouped["total_sec"].quantile(.75) - grouped[
        "total_sec"
    ].quantile(.25)
    summary["successful_repetitions"] = grouped.size()
    summary = summary.reset_index()
    summary["implementation"] = "fastPLS"

    failed = raw[~raw["status"].eq("success")].copy()
    if not failed.empty:
        failed = failed.drop_duplicates(KEYS)[KEYS + ["error_message"]]
        failed["implementation"] = "fastPLS"
        failed["successful_repetitions"] = 0
        summary = pd.concat([summary, failed], ignore_index=True, sort=False)
    return summary


def read_ikpls(path):
    data = pd.read_csv(path)
    data = data[data["algorithm"].str.contains("Improved Kernel PLS", na=False)]
    output = pd.DataFrame({
        "dataset": data["dataset"],
        "family": "simpls",
        "backend": "cpu",
        "precision": data["precision"],
        "classifier": np.where(data["task_type"].eq("classification"),
                               "argmax", "regression"),
        "kernel": "",
        "requested_ncomp": data["ncomp"],
        "effective_ncomp": data["ncomp"],
        "status": np.where(data["median_total_sec"].notna(),
                           "success", "failed"),
        "median_fit_sec": data["median_fit_sec"],
        "median_prediction_sec": data["median_prediction_sec"],
        "median_total_sec": data["median_total_sec"],
        "iqr_total_sec": data["iqr_total_sec"],
        "median_metric": np.where(data["task_type"].eq("classification"),
                                  data["accuracy"], data["rmsd"]),
        "median_peak_rss_mib": data["median_peak_rss_mib"],
        "median_incremental_peak_rss_mib": data[
            "median_incremental_peak_rss_mib"
        ],
        "successful_repetitions": data["repetitions"],
        "implementation": "IKPLS",
    })
    return output


def attach_reference_differences(summary):
    reference = summary[
        summary["implementation"].eq("fastPLS")
        & summary["backend"].eq("cpu")
        & summary["precision"].eq("float64")
        & summary["status"].eq("success")
    ][["dataset", "family", "classifier", "kernel", "median_metric"]].copy()
    reference = reference.rename(columns={"median_metric": "cpu_f64_metric"})
    merged = summary.merge(
        reference,
        on=["dataset", "family", "classifier", "kernel"],
        how="left",
    )
    merged["metric_difference_from_cpu_f64"] = (
        merged["median_metric"] - merged["cpu_f64_metric"]
    )
    return merged


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fastpls", nargs="+", required=True)
    parser.add_argument("--ikpls")
    parser.add_argument("--raw-output", required=True)
    parser.add_argument("--summary-output", required=True)
    args = parser.parse_args()

    raw = read_fastpls(args.fastpls)
    summary = summarize_fastpls(raw)
    if args.ikpls:
        summary = pd.concat(
            [summary, read_ikpls(args.ikpls)], ignore_index=True, sort=False
        )
    summary = attach_reference_differences(summary)

    raw_target = Path(args.raw_output).resolve()
    summary_target = Path(args.summary_output).resolve()
    raw_target.parent.mkdir(parents=True, exist_ok=True)
    summary_target.parent.mkdir(parents=True, exist_ok=True)
    raw.to_csv(raw_target, index=False)
    summary.sort_values(
        ["dataset", "family", "classifier", "implementation", "backend",
         "precision"]
    ).to_csv(summary_target, index=False)


if __name__ == "__main__":
    main()
