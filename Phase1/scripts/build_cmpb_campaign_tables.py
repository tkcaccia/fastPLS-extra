#!/usr/bin/env python3
"""Assemble the definitive CMPB main and supplementary table sources."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
import re
import shutil


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        raise RuntimeError(f"No rows available for {path.name}")
    fields = list(dict.fromkeys(key for row in rows for key in row))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def copy_required(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(source)
    shutil.copy2(source, destination)


def table1(campaign: Path, output: Path) -> None:
    rows = read_csv(campaign / "inputs/tasks/prepared_task_manifest.csv")
    keep = ("dataset", "task_type", "n_train", "n_test", "p", "q")
    write_csv(output / "Table1_prepared_benchmark_dimensions.csv", [
        {key: row[key] for key in keep} for row in rows
    ])


def independent_contracts(phase1: Path, campaign: Path, output: Path) -> None:
    versions = {
        row["package"]: row.get("version", "")
        for row in read_csv(campaign / "provenance/r_package_versions.csv")
    }
    python_freeze = campaign / "python_requirements_frozen.txt"
    if not python_freeze.is_file():
        raise FileNotFoundError(python_freeze)
    for line in python_freeze.read_text().splitlines():
        if "==" in line:
            package, version = line.split("==", 1)
            versions[package.lower()] = version
    rows = read_csv(phase1 / "config/independent_method_contract.csv")
    for row in rows:
        lookup = {
            "IKPLS": "ikpls",
            "scikit-learn": "scikit-learn",
        }.get(row["package"], row["package"])
        row["version"] = versions.get(lookup, "")
    write_csv(output / "TableS2_independent_method_settings.csv", rows)
    copy_required(
        phase1 / "config/measurement_contract.csv",
        output / "TableS3_timing_memory_measurement.csv",
    )


def formal_table(phase1: Path, campaign: Path, output: Path) -> None:
    source = phase1 / "formal/lean/FastPLSFormal/Invariants.lean"
    text = source.read_text()
    pattern = re.compile(
        r"/--\s*(.*?)\s*-/\s*theorem\s+([A-Za-z0-9_]+)", re.DOTALL
    )
    area = {
        "implicit_crossCovariance": "PLS-SVD, SIMPLS family and kernel PLS",
        "compact_prediction": "SIMPLS family and linear kernel PLS",
        "plssvd_latent_normal_equation": "PLS-SVD",
        "simpls_deflation_orthogonal": "SIMPLS family",
        "simpls_cached_gram_entry": "SIMPLS family",
        "linear_kernel_symmetric": "Kernel PLS",
        "double_centering_preserves_symmetry": "Nonlinear kernel PLS",
        "opls_weight_is_orthogonal": "OPLS",
        "centered_gram_entry": "Centred response and kernel products",
        "training_statistic_by_subtraction": "Cross-validation",
    }
    rows = []
    for statement, theorem in pattern.findall(text):
        rows.append({
            "lean_theorem": theorem,
            "implementation_area": area.get(theorem, "Unmapped"),
            "checked_statement": " ".join(statement.split()),
            "lake_build_status": "success",
        })
    if len(rows) != 10 or any(row["implementation_area"] == "Unmapped" for row in rows):
        raise RuntimeError("The Lean theorem inventory is incomplete")
    with (campaign / "stage_status.tsv").open(newline="") as handle:
        stage_rows = list(csv.DictReader(handle, delimiter="\t"))
    formal = [row for row in stage_rows if row.get("stage") == "formal_invariants"]
    if not formal or formal[-1].get("exit_status") != "0":
        raise RuntimeError("The formal-invariants campaign stage did not pass")
    write_csv(output / "TableS1_formal_invariants.csv", rows)


def selected_tables(source: Path, output: Path) -> None:
    rows = read_csv(source)
    write_csv(output / "TableS4_fit_prediction_cpu_cuda.csv", rows)
    memory_fields = (
        "dataset", "family", "backend", "precision", "requested_ncomp",
        "replicate", "baseline_rss_mib", "incremental_peak_rss_mib",
        "gpu_baseline_mib", "gpu_peak_mib", "status",
    )
    write_csv(output / "TableS5_memory_cpu_cuda.csv", [
        {key: row.get(key, "") for key in memory_fields} for row in rows
    ])


def copy_validation(campaign: Path, output: Path) -> None:
    validation = campaign / "results/validation"
    matches = {
        "TableS7_dense_reference": "simpls_dense_reference",
        "TableS8_rsvd_qualification": "rsvd_qualification",
        "TableS9_precision_backend": "precision_",
        "TableS10_opls_kernel": "opls_kernel",
    }
    for prefix, pattern in matches.items():
        files = sorted(
            path for path in validation.rglob("*.csv")
            if pattern in str(path.relative_to(validation))
        )
        if not files:
            raise FileNotFoundError(f"No validation tables matched {pattern}")
        for index, source in enumerate(files, 1):
            copy_required(
                source,
                output / f"{prefix}_{index:02d}_{source.name}",
            )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign_root", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    campaign = args.campaign_root.resolve()
    output = args.output_directory.resolve()
    phase1 = Path(__file__).resolve().parent.parent
    output.mkdir(parents=True, exist_ok=True)

    table1(campaign, output)
    formal_table(phase1, campaign, output)
    independent_contracts(phase1, campaign, output)
    selected_tables(
        campaign / "results/figure2/selected_cpu_cuda.csv", output
    )
    copy_required(
        campaign / "results/figure4/imagenet_four_family_component_paths.csv",
        output / "TableS6_imagenet_top5_component_paths.csv",
    )
    copy_validation(campaign, output)
    copy_required(
        campaign / "provenance/r_package_versions.csv",
        output / "TableS11_r_package_versions.csv",
    )
    copy_required(
        campaign / "provenance/r_runtime.csv",
        output / "TableS11_r_runtime.csv",
    )
    copy_required(
        campaign / "provenance/native_runtime.tsv",
        output / "TableS11_native_runtime.tsv",
    )


if __name__ == "__main__":
    main()
