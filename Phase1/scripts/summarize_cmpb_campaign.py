#!/usr/bin/env python3
"""Create the Figure 2 source tables from one CMPB campaign."""

from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path
import statistics


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        raise RuntimeError(f"No rows available for {path.name}")
    fields = list(dict.fromkeys(key for row in rows for key in row))
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def number(value) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def median(rows: list[dict[str, str]], field: str) -> float | None:
    values = [number(row.get(field)) for row in rows]
    finite = [value for value in values if value is not None]
    return statistics.median(finite) if finite else None


def selected_ratios(raw_path: Path) -> list[dict]:
    groups: dict[tuple[str, str, str], list[dict[str, str]]] = {}
    for row in read_csv(raw_path):
        key = (row.get("dataset", ""), row.get("family", ""), row.get("backend", ""))
        groups.setdefault(key, []).append(row)
    summaries: dict[tuple[str, str, str], dict] = {}
    for key, rows in groups.items():
        success = [row for row in rows if row.get("status") == "success"]
        exemplar = success[0] if success else rows[0]
        summaries[key] = {
            "dataset": key[0],
            "family": key[1],
            "backend": key[2],
            "requested_ncomp": exemplar.get(
                "requested_ncomp", exemplar.get("ncomp", "")
            ),
            "status": "success" if success else "/".join(
                sorted({row.get("status", "failed") for row in rows})
            ),
            "median_total_sec": median(success, "total_sec"),
            "median_metric": median(success, "metric_value"),
            "median_incremental_rss_mib": median(
                success, "incremental_peak_rss_mib"
            ),
            "median_gpu_peak_mib": median(success, "gpu_peak_mib"),
        }
    output = []
    pairs = sorted({(dataset, family) for dataset, family, _ in summaries})
    for dataset, family in pairs:
        cpu = summaries.get((dataset, family, "cpu"))
        cuda = summaries.get((dataset, family, "cuda"))
        cpu_time = cpu and cpu["median_total_sec"]
        cuda_time = cuda and cuda["median_total_sec"]
        cpu_memory = cpu and cpu["median_incremental_rss_mib"]
        cuda_memory = cuda and cuda["median_incremental_rss_mib"]
        both = cpu and cuda and cpu["status"] == cuda["status"] == "success"
        output.append({
            "platform": "Intel/NVIDIA workstation",
            "dataset": dataset,
            "family": family,
            "accelerator": "CUDA",
            "requested_ncomp": (cpu or cuda or {}).get("requested_ncomp", ""),
            "status_cpu": cpu["status"] if cpu else "not_evaluated",
            "status_accelerator": cuda["status"] if cuda else "not_evaluated",
            "median_total_sec_cpu": cpu_time,
            "median_total_sec_accelerator": cuda_time,
            "runtime_ratio": (
                cpu_time / cuda_time
                if both and cpu_time is not None and cuda_time not in (None, 0)
                else None
            ),
            "median_incremental_rss_mib_cpu": cpu_memory,
            "median_incremental_rss_mib_accelerator": cuda_memory,
            "host_memory_ratio": (
                cuda_memory / cpu_memory
                if both and cuda_memory is not None and cpu_memory not in (None, 0)
                else None
            ),
            "median_gpu_peak_mib_accelerator": (
                cuda["median_gpu_peak_mib"] if cuda else None
            ),
            "metric_difference": (
                cuda["median_metric"] - cpu["median_metric"]
                if both and cpu["median_metric"] is not None
                and cuda["median_metric"] is not None else None
            ),
        })
    return output


def cv_rows(*directories: Path) -> list[dict[str, str]]:
    rows = []
    for directory in directories:
        for path in directory.rglob("*.csv"):
            if path.name == "configuration_manifest.csv":
                continue
            try:
                values = read_csv(path)
            except (OSError, csv.Error, UnicodeDecodeError):
                continue
            for row in values:
                if "elapsed_sec" in row:
                    rows.append(row)
    return rows


def cv_comparison(*directories: Path) -> list[dict]:
    raw = cv_rows(*directories)
    groups: dict[tuple[str, ...], list[dict[str, str]]] = {}
    fields = ("dataset", "method", "classifier", "backend", "workload")
    for row in raw:
        dataset = row.get("dataset", "").lower()
        if dataset.startswith("imagenet"):
            row["dataset"] = "imagenet"
        classifier = row.get("classifier", "").strip().lower()
        if classifier in {"", "na", "nan", "none"}:
            row["classifier"] = "regression"
        key = tuple(row.get(field, "") for field in fields)
        groups.setdefault(key, []).append(row)
    summary = {}
    for key, rows in groups.items():
        success = [
            row for row in rows
            if row.get("status") == "success"
            and number(row.get("elapsed_sec")) is not None
        ]
        observed_failures = sorted({
            row.get("status", "error")
            for row in rows
            if row not in success
        })
        if len(success) == len(rows):
            status = "success"
        elif success:
            status = "partial"
        elif observed_failures and set(observed_failures) == {"timeout"}:
            status = "timeout"
        else:
            status = "error"
        summary[key] = {
            "median_sec": median(success, "elapsed_sec"),
            "status": status,
            "failure_statuses": ";".join(observed_failures),
            "attempted": len(rows),
            "completed": len(success),
            "ncomp": (success or rows)[0].get("requested_ncomp", "") if rows else "",
        }
    output = []
    bases = sorted({key[:4] for key in summary})
    for dataset, method, classifier, backend in bases:
        fit = summary.get((dataset, method, classifier, backend, "fit_predict"))
        cv = summary.get((dataset, method, classifier, backend, "cv"))
        fit_sec = fit and fit["median_sec"]
        cv_sec = cv and cv["median_sec"]
        output.append({
            "platform": "linux_nvidia",
            "dataset": dataset,
            "method": method,
            "classifier": classifier or "regression",
            "backend": backend,
            "ncomp": (fit or cv or {}).get("ncomp", ""),
            "median_fit_predict_sec": fit_sec,
            "median_cv_sec": cv_sec,
            "cv_over_fit_predict": (
                cv_sec / fit_sec
                if fit_sec not in (None, 0) and cv_sec is not None else None
            ),
            "status_fit_predict": fit["status"] if fit else "not_evaluated",
            "status_cv": cv["status"] if cv else "not_evaluated",
            "failure_statuses_fit_predict": (
                fit["failure_statuses"] if fit else ""
            ),
            "failure_statuses_cv": cv["failure_statuses"] if cv else "",
            "attempted_fit_predict": fit["attempted"] if fit else 0,
            "completed_fit_predict": fit["completed"] if fit else 0,
            "attempted_cv": cv["attempted"] if cv else 0,
            "completed_cv": cv["completed"] if cv else 0,
        })
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign_root", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    result = args.campaign_root / "results"
    write_csv(
        args.output_dir / "figure2_cpu_cuda_ratios.csv",
        selected_ratios(result / "figure2" / "selected_cpu_cuda.csv"),
    )
    write_csv(
        args.output_dir / "figure2_cv_comparison.csv",
        cv_comparison(
            result / "figure2" / "cv_standard",
            result / "figure2" / "cv_imagenet",
        ),
    )


if __name__ == "__main__":
    main()
