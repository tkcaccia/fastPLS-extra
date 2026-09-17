#!/usr/bin/env python3
"""Reconcile CMPB NMR displays to the dedicated component-path benchmark."""

import argparse
import csv
from pathlib import Path
from statistics import median


def read_rows(path):
    with Path(path).open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_rows(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def indexed_summary(rows):
    return {
        (row["family"], row["backend"]): row
        for row in rows
        if row["family"] in {"plssvd", "simpls"}
        and row["backend"] in {"cpu", "cuda"}
    }


def reconcile_figure1(rows, summary, raw_rows):
    cpu = summary[("simpls", "cpu")]
    peaks = [
        float(row["peak_rss_mib"])
        for row in raw_rows
        if row["dataset"] == "nmr"
        and row["family"] == "simpls"
        and row["backend"] == "cpu"
        and row["requested_ncomp"] == "50"
        and row["status"] == "success"
    ]
    if not peaks:
        raise RuntimeError("No current NMR SIMPLS CPU peak-RSS records found.")
    matched = 0
    for row in rows:
        if row["dataset"] == "nmr" and row["implementation"] == "fastPLS SIMPLS":
            row.update({
                "source": "component_paths_0.99.66_20260913/nmr_backend_paths/nmr_linux_cpu_cuda.csv",
                "ncomp_requested": cpu["ncomp"],
                "ncomp": cpu["ncomp"],
                "rmsd": cpu["RMSD"],
                "total_sec": cpu["total_time_sec"],
                "peak_rss_mib": f"{median(peaks):.9f}",
                "repetitions": cpu["repetitions"],
            })
            matched += 1
    if matched != 1:
        raise RuntimeError(f"Expected one Figure 1 NMR fastPLS row, found {matched}.")
    return rows


def reconcile_figure2(rows, summary):
    matched = set()
    for row in rows:
        family = row["family"]
        if (row["platform"] != "Intel/NVIDIA workstation"
                or row["dataset"] != "nmr"
                or family not in {"plssvd", "simpls"}):
            continue
        cpu = summary[(family, "cpu")]
        cuda = summary[(family, "cuda")]
        row.update({
            "requested_ncomp": cpu["ncomp"],
            "median_total_sec_cpu": cpu["total_time_sec"],
            "iqr_total_sec_cpu": str(
                float(cpu["time_q3_sec"]) - float(cpu["time_q1_sec"])
            ),
            "median_metric_cpu": cpu["RMSD"],
            "median_incremental_rss_mib_cpu": cpu["incremental_rss_mib"],
            "median_total_sec_accelerator": cuda["total_time_sec"],
            "iqr_total_sec_accelerator": str(
                float(cuda["time_q3_sec"]) - float(cuda["time_q1_sec"])
            ),
            "median_metric_accelerator": cuda["RMSD"],
            "median_incremental_rss_mib_accelerator": cuda["incremental_rss_mib"],
            "median_gpu_peak_mib_accelerator": cuda["gpu_peak_mib"],
            "runtime_ratio": str(
                float(cpu["total_time_sec"]) / float(cuda["total_time_sec"])
            ),
            "host_memory_ratio": str(
                float(cuda["incremental_rss_mib"])
                / float(cpu["incremental_rss_mib"])
            ),
            "metric_difference": str(float(cuda["RMSD"]) - float(cpu["RMSD"])),
        })
        matched.add(family)
    if matched != {"plssvd", "simpls"}:
        raise RuntimeError(f"Incomplete Figure 2 NMR reconciliation: {matched}.")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--figure1-input", required=True)
    parser.add_argument("--figure2-input", required=True)
    parser.add_argument("--nmr-summary", required=True)
    parser.add_argument("--nmr-raw", required=True)
    parser.add_argument("--figure1-output", required=True)
    parser.add_argument("--figure2-output", required=True)
    args = parser.parse_args()

    summary = indexed_summary(read_rows(args.nmr_summary))
    expected = {
        ("plssvd", "cpu"), ("plssvd", "cuda"),
        ("simpls", "cpu"), ("simpls", "cuda"),
    }
    if set(summary) != expected:
        raise RuntimeError("NMR summary does not contain the four required rows.")

    write_rows(
        args.figure1_output,
        reconcile_figure1(
            read_rows(args.figure1_input), summary, read_rows(args.nmr_raw)
        ),
    )
    write_rows(
        args.figure2_output,
        reconcile_figure2(read_rows(args.figure2_input), summary),
    )


if __name__ == "__main__":
    main()
