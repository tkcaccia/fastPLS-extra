#!/usr/bin/env python3
"""Extract manuscript-ready quantitative facts from one audited asset set."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from statistics import median


R_IMPLEMENTATIONS = {
    "fastPLS SIMPLS / LDA",
    "fastPLS SIMPLS",
    "pls / SIMPLS",
    "plsgenomics / PLS-LDA",
    "plsgenomics / PLS regression",
    "mdatools / PLS-DA",
    "mdatools / PLS",
    "plsdepot / SIMPLS",
    "pcv / SIMPLS",
    "chemometrics / PLS eigen",
    "mixOmics / PLS-DA",
    "mixOmics / PLS",
    "spls / sPLS-DA",
    "spls / sPLS",
}


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def number(value: str | None) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def successful(row: dict[str, str]) -> bool:
    return row.get("status", "success").lower() in {"success", "ok"}


def selected_fields(row: dict[str, str], fields: tuple[str, ...]) -> dict:
    """Keep manuscript-relevant values while preserving their CSV spelling."""
    return {field: row.get(field, "") for field in fields if field in row}


def figure1_facts(rows: list[dict[str, str]]) -> dict:
    by_dataset: dict[str, list[dict[str, str]]] = {}
    for row in rows:
        by_dataset.setdefault(row["dataset"], []).append(row)

    fastest_r = []
    fastpls_peak = []
    fastpls_vs_ikpls = {}
    per_dataset = {}
    for dataset, values in sorted(by_dataset.items()):
        completed_r = [
            row for row in values
            if row["implementation"] in R_IMPLEMENTATIONS
            and successful(row) and number(row.get("total_sec")) is not None
        ]
        fastpls = next(
            (row for row in completed_r
             if row["implementation"].startswith("fastPLS")), None
        )
        if fastpls is not None:
            best = min(number(row["total_sec"]) for row in completed_r)
            if math.isclose(number(fastpls["total_sec"]), best,
                            rel_tol=1e-9, abs_tol=5e-4):
                fastest_r.append(dataset)
            peak = number(fastpls.get("peak_rss_mib"))
            if peak is not None:
                fastpls_peak.append((dataset, peak))
        ikpls = next(
            (row for row in values if row["implementation"] == "IKPLS"
             and successful(row) and number(row.get("total_sec")) is not None),
            None,
        )
        if fastpls is not None and ikpls is not None:
            fastpls_vs_ikpls[dataset] = (
                number(ikpls["total_sec"]) / number(fastpls["total_sec"])
            )
        per_dataset[dataset] = {
            "fastpls": (
                selected_fields(
                    fastpls,
                    (
                        "task_type", "implementation", "family", "classifier",
                        "ncomp_requested", "ncomp", "status", "accuracy",
                        "balanced_accuracy", "rmsd", "q2", "total_sec",
                        "peak_rss_mib", "repetitions", "precision",
                    ),
                ) if fastpls is not None else None
            ),
            "ikpls": (
                selected_fields(
                    ikpls,
                    (
                        "task_type", "implementation", "family", "classifier",
                        "ncomp_requested", "ncomp", "status", "accuracy",
                        "balanced_accuracy", "rmsd", "q2", "total_sec",
                        "peak_rss_mib", "repetitions", "precision",
                    ),
                ) if ikpls is not None else None
            ),
            "fastest_completed_r_implementation": (
                min(
                    completed_r,
                    key=lambda row: number(row["total_sec"]),
                )["implementation"] if completed_r else None
            ),
            "completed_r_implementations": [
                row["implementation"] for row in completed_r
            ],
            "all_statuses": {
                row["implementation"]: row.get("status", "") for row in values
            },
        }

    tabula = by_dataset.get("tabula", [])
    tabula_accuracy = {
        row["implementation"]: number(row.get("accuracy"))
        for row in tabula if successful(row)
        and row["implementation"] in {"fastPLS SIMPLS / LDA", "IKPLS"}
    }
    largest = sorted(
        fastpls_vs_ikpls.items(), key=lambda item: item[1], reverse=True
    )
    return {
        "datasets": len(by_dataset),
        "fastpls_fastest_completed_r_datasets": fastest_r,
        "fastpls_fastest_completed_r_count": len(fastest_r),
        "fastpls_max_absolute_peak_rss_mib": (
            max(fastpls_peak, key=lambda item: item[1]) if fastpls_peak else None
        ),
        "fastpls_to_ikpls_speed_advantage": fastpls_vs_ikpls,
        "largest_fastpls_to_ikpls_advantages": largest[:5],
        "tabula_accuracy": tabula_accuracy,
        "per_dataset": per_dataset,
    }


def figure2_facts(cpu_cuda: list[dict[str, str]], cv: list[dict[str, str]]) -> dict:
    paired = [
        row for row in cpu_cuda
        if row.get("status_cpu") == row.get("status_accelerator") == "success"
        and number(row.get("runtime_ratio")) is not None
    ]
    faster = [row for row in paired if number(row["runtime_ratio"]) > 1]
    host_ratios = [
        number(row.get("host_memory_ratio")) for row in paired
        if number(row.get("host_memory_ratio")) is not None
    ]
    cv_by_backend = {}
    for backend in ("cpu", "cuda"):
        values = [
            number(row.get("cv_over_fit_predict")) for row in cv
            if row.get("backend") == backend
            and row.get("status_fit_predict") == "success"
            and row.get("status_cv") == "success"
            and number(row.get("cv_over_fit_predict")) is not None
        ]
        cv_by_backend[backend] = {
            "count": len(values),
            "median": median(values) if values else None,
            "minimum": min(values) if values else None,
            "maximum": max(values) if values else None,
        }
    return {
        "paired_routes": len(paired),
        "cuda_faster_routes": len(faster),
        "maximum_cpu_cuda_runtime_ratio": max(
            (number(row["runtime_ratio"]) for row in paired), default=None
        ),
        "median_cuda_cpu_host_memory_ratio": (
            median(host_ratios) if host_ratios else None
        ),
        "cuda_host_memory_increase_count": sum(value > 1 for value in host_ratios),
        "cv_over_fit_prediction": cv_by_backend,
        "cpu_cuda_routes": [
            selected_fields(
                row,
                (
                    "dataset", "family", "requested_ncomp", "status_cpu",
                    "status_accelerator", "median_total_sec_cpu",
                    "median_total_sec_accelerator", "runtime_ratio",
                    "median_incremental_rss_mib_cpu",
                    "median_incremental_rss_mib_accelerator",
                    "host_memory_ratio", "median_gpu_peak_mib_accelerator",
                    "metric_difference",
                ),
            )
            for row in cpu_cuda
        ],
        "cross_validation_routes": [
            selected_fields(
                row,
                (
                    "dataset", "method", "classifier", "backend", "ncomp",
                    "median_fit_predict_sec", "median_cv_sec",
                    "cv_over_fit_predict", "status_fit_predict", "status_cv",
                    "attempted_fit_predict", "completed_fit_predict",
                    "attempted_cv", "completed_cv",
                ),
            )
            for row in cv
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("assets", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    tables = args.assets / "tables"
    facts = {
        "figure1": figure1_facts(read_csv(tables / "figure1_six_panel_data.csv")),
        "figure2": figure2_facts(
            read_csv(tables / "figure2_cpu_cuda_ratios.csv"),
            read_csv(tables / "figure2_cv_comparison.csv"),
        ),
        "figure3_nmr": read_csv(
            tables / "figure3_nmr_family_components_summary.csv"
        ),
        "figure4_imagenet": read_csv(
            args.assets / "figures/Figure4_plotted_values.csv"
        ),
        "cuda_software": read_csv(
            tables / "cuda_software_comparison_summary.csv"
        ),
        "numerical_validation": read_csv(
            tables / "TableS1_numerical_validation.csv"
        ),
        "component_selection": read_csv(
            tables / "component_selection_evidence.csv"
        ),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(facts, indent=2) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
