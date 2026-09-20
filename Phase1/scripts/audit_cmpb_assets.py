#!/usr/bin/env python3
"""Verify the exact numbered CMPB asset inventory and core table dimensions."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import re
import struct


MAIN_FIGURES = [f"Figure{number}" for number in range(1, 5)]
SUPPLEMENT_FIGURES = [f"FigureS{number}" for number in range(1, 15)]
EXPECTED_FIGURES = {
    f"{stem}.{extension}"
    for stem in MAIN_FIGURES + SUPPLEMENT_FIGURES
    for extension in ("pdf", "png")
}
EXPECTED_TABLES = {
    "Table1_prepared_benchmark_dimensions.csv",
    *{
        name
        for name in (
            "TableS1_numerical_validation.csv",
            "TableS2_formal_invariants.csv",
            "TableS3_independent_method_settings.csv",
            "TableS4_timing_memory_measurement.csv",
            "TableS5_fit_prediction_cpu_cuda.csv",
            "TableS6_memory_cpu_cuda.csv",
            "TableS7_imagenet_simpls_component_path.csv",
            "TableS8_benchmark_platform.csv",
        )
    },
}
EXPECTED_TABLE_COUNTS = {
    "Table1_prepared_benchmark_dimensions.csv": 13,
    "TableS1_numerical_validation.csv": 8,
    "TableS2_formal_invariants.csv": 10,
    "TableS3_independent_method_settings.csv": 10,
    "TableS4_timing_memory_measurement.csv": 3,
    "TableS5_fit_prediction_cpu_cuda.csv": 52,
    "TableS6_memory_cpu_cuda.csv": 52,
    "TableS7_imagenet_simpls_component_path.csv": 22,
    "TableS8_benchmark_platform.csv": 7,
}
REQUIRED_TABLE_COLUMNS = {
    "Table1_prepared_benchmark_dimensions.csv": {
        "dataset", "task_type", "n_train", "n_test", "p", "q",
    },
    "TableS1_numerical_validation.csv": {
        "validation_block", "route", "attempted", "completed",
        "key_numerical_result", "failures",
    },
    "TableS2_formal_invariants.csv": {
        "lean_theorem", "implementation_area", "checked_statement",
        "lake_build_status",
    },
    "TableS3_independent_method_settings.csv": {
        "package", "version", "language_function", "estimator_task",
        "parameters", "prediction_contract",
    },
    "TableS4_timing_memory_measurement.csv": {
        "workflow", "benchmark_platform", "elapsed_time_measurement",
        "memory_measurement", "replication_summary",
    },
    "TableS5_fit_prediction_cpu_cuda.csv": {
        "dataset", "family", "components", "precision", "metric",
        "cpu_time_seconds", "cuda_time_seconds", "status",
    },
    "TableS6_memory_cpu_cuda.csv": {
        "dataset", "family", "components", "precision",
        "cpu_incremental_peak_rss_mib", "cuda_incremental_peak_rss_mib",
        "cuda_device_peak_mib", "status",
    },
    "TableS7_imagenet_simpls_component_path.csv": {
        "classifier", "ncomp_requested", "top1_accuracy", "top5_accuracy",
        "total_time_sec", "process_peak_rss_mb", "gpu_peak_mb",
    },
    "TableS8_benchmark_platform.csv": {"item", "configuration"},
}


def csv_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("assets", type=Path)
    args = parser.parse_args()
    assets = args.assets.resolve()
    figures = assets / "figures"
    tables = assets / "tables"
    failures: list[str] = []

    observed_figures = {
        path.name
        for path in figures.iterdir()
        if path.is_file()
        and re.fullmatch(r"Figure(?:S\d+|\d+)\.(?:pdf|png)", path.name)
    }
    observed_tables = {
        path.name
        for path in tables.iterdir()
        if path.is_file()
        and re.fullmatch(r"Table(?:S\d+|1)_.+\.csv", path.name)
    }
    require(
        observed_figures == EXPECTED_FIGURES,
        "numbered figure inventory differs: missing="
        f"{sorted(EXPECTED_FIGURES - observed_figures)}, extra="
        f"{sorted(observed_figures - EXPECTED_FIGURES)}",
        failures,
    )
    require(
        observed_tables == EXPECTED_TABLES,
        "numbered table inventory differs: missing="
        f"{sorted(EXPECTED_TABLES - observed_tables)}, extra="
        f"{sorted(observed_tables - EXPECTED_TABLES)}",
        failures,
    )

    for name in sorted(EXPECTED_FIGURES & observed_figures):
        path = figures / name
        require(path.stat().st_size > 1024, f"figure is unexpectedly small: {name}", failures)
        signature = path.read_bytes()[:8]
        if path.suffix == ".pdf":
            require(signature.startswith(b"%PDF-"), f"invalid PDF signature: {name}", failures)
        else:
            require(signature == b"\x89PNG\r\n\x1a\n", f"invalid PNG signature: {name}", failures)
            width, height = struct.unpack(">II", path.read_bytes()[16:24])
            require(
                width >= 1000 and height >= 800,
                f"PNG resolution is too small: {name} ({width}x{height})",
                failures,
            )

    table_counts: dict[str, int] = {}
    for name in sorted(EXPECTED_TABLES & observed_tables):
        values = csv_rows(tables / name)
        table_counts[name] = len(values)
        require(bool(values), f"table has no data rows: {name}", failures)
        observed_columns = set(values[0]) if values else set()
        required_columns = REQUIRED_TABLE_COLUMNS[name]
        require(
            required_columns <= observed_columns,
            f"{name} is missing columns: "
            f"{sorted(required_columns - observed_columns)}",
            failures,
        )

    for name, expected in EXPECTED_TABLE_COUNTS.items():
        if name in table_counts:
            require(
                table_counts[name] == expected,
                f"{name} has {table_counts[name]} rows; expected {expected}",
                failures,
            )

    nmr_decisions = tables / "nmr_training_selected_components.csv"
    require(nmr_decisions.is_file(), "NMR selection decisions are missing", failures)
    if nmr_decisions.is_file():
        decisions = {
            row.get("family", ""): row.get("selected_ncomp", "")
            for row in csv_rows(nmr_decisions)
        }
        require(
            decisions == {"plssvd": "75", "simpls": "50"},
            "NMR one-standard-error selections differ from 75/50",
            failures,
        )

    narrative = assets / "cmpb_narrative_summary.json"
    require(narrative.is_file(), "narrative summary is missing", failures)
    if narrative.is_file():
        try:
            json.loads(narrative.read_text())
        except json.JSONDecodeError as error:
            failures.append(f"narrative summary is invalid JSON: {error}")

    report = {
        "figures": sorted(observed_figures),
        "tables": sorted(observed_tables),
        "table_rows": table_counts,
        "failures": failures,
    }
    destination = assets / "asset_audit.json"
    destination.write_text(json.dumps(report, indent=2) + "\n")
    if failures:
        raise SystemExit("CMPB asset audit failed:\n- " + "\n- ".join(failures))
    print(f"CMPB asset audit passed: {destination}")


if __name__ == "__main__":
    main()
