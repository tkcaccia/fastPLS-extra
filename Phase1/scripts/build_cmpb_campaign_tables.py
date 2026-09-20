#!/usr/bin/env python3
"""Assemble the definitive CMPB main and supplementary table sources."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
import re
import shutil
from statistics import median


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


def key_values(path: Path, delimiter: str) -> dict[str, str]:
    return {
        row.get("field", ""): row.get("value", "")
        for row in read_csv_with_delimiter(path, delimiter)
    }


def read_csv_with_delimiter(path: Path, delimiter: str) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle, delimiter=delimiter))


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
    write_csv(output / "TableS3_independent_method_settings.csv", rows)
    copy_required(
        phase1 / "config/measurement_contract.csv",
        output / "TableS4_timing_memory_measurement.csv",
    )


def formal_table(phase1: Path, campaign: Path, output: Path) -> None:
    source = phase1 / "formal/lean/FastPLSFormal/Invariants.lean"
    text = source.read_text()
    pattern = re.compile(
        r"/--\s*(.*?)\s*-/\s*theorem\s+([A-Za-z0-9_]+)", re.DOTALL
    )
    area = {
        "implicit_crossCovariance": "PLS-SVD, SIMPLS-family and kernel PLS",
        "compact_prediction": "SIMPLS-family and linear kernel PLS",
        "plssvd_latent_normal_equation": "PLS-SVD",
        "simpls_deflation_orthogonal": "SIMPLS-family",
        "simpls_cached_gram_entry": "SIMPLS-family",
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
    write_csv(output / "TableS2_formal_invariants.csv", rows)


def finite_number(value: str) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number != number or number in (float("inf"), float("-inf")):
        return None
    return number


def extrema(rows: list[dict[str, str]], field: str, operation) -> str:
    values = [
        number for row in rows
        if (number := finite_number(row.get(field, ""))) is not None
    ]
    return "" if not values else f"{operation(values):.6g}"


def numerical_validation_table(campaign: Path, output: Path) -> None:
    """Create one compact CMPB table from the current validation campaign."""
    validation = campaign / "results/validation"
    rows: list[dict[str, str | int]] = []

    simpls_cases = read_csv(
        validation / "simpls_dense_reference/simpls_exact_reference_case_summary.csv"
    )
    simpls_failures = read_csv(
        validation / "simpls_dense_reference/simpls_exact_reference_failures.csv"
    )
    simpls_comparisons = sum(
        int(row["component_prefixes"]) for row in simpls_cases
    )
    rows.append({
        "validation_block": "Dense numerical reference",
        "route": "SIMPLS-family, float64 CPU",
        "attempted": simpls_comparisons,
        "completed": simpls_comparisons,
        "key_numerical_result": (
            "max prediction relative error "
            f"{extrema(simpls_cases, 'max_prediction_relative_error', max)}; "
            "min label agreement "
            f"{extrema(simpls_cases, 'min_classification_label_agreement', min)}"
        ),
        "failures": len(simpls_failures),
    })

    for backend in ("cpu", "cuda"):
        summary = read_csv(
            validation
            / f"rsvd_qualification_{backend}/rsvd_qualification_summary.csv"
        )[0]
        rows.append({
            "validation_block": "rSVD qualification",
            "route": f"rSVD {backend.upper()}",
            "attempted": summary["comparisons"],
            "completed": summary["successful"],
            "key_numerical_result": (
                f"{summary['met_tolerances']}/{summary['comparisons']} met "
                "tolerances; max prediction relative error "
                f"{summary['max_prediction_relative_error']}; min prediction "
                f"correlation {summary['min_prediction_correlation']}; min "
                f"label agreement {summary['min_label_agreement']}; max "
                f"metric difference {summary['max_metric_difference']}"
            ),
            "failures": int(summary["comparisons"]) - int(summary["successful"]),
        })

    estimator = read_csv(
        validation
        / "opls_kernel_estimator/opls_kernel_estimator_validation_summary.csv"
    )
    for summary in estimator:
        rows.append({
            "validation_block": "Independent estimator reference",
            "route": summary["family"],
            "attempted": summary["runs"],
            "completed": summary["successes"],
            "key_numerical_result": (
                f"{summary['passes_all']}/{summary['runs']} met tolerances; "
                "max prediction relative error "
                f"{summary['max_prediction_relative_error']}; min prediction "
                f"correlation {summary['min_prediction_correlation']}; min "
                f"label agreement {summary['min_label_agreement']}; max "
                "metric difference "
                f"{summary['max_metric_absolute_difference']}"
            ),
            "failures": summary["failures"],
        })

    for backend in ("cpu", "cuda"):
        precision_files = sorted(
            (validation / f"precision_{backend}").glob(
                f"float32_backend_agreement_{backend}_*.csv"
            )
        )
        if len(precision_files) != 1:
            raise RuntimeError(
                f"Expected one {backend} precision result; found "
                f"{len(precision_files)}"
            )
        precision = read_csv(precision_files[0])
        successful = [row for row in precision if row.get("status") == "ok"]
        classification = [
            row for row in successful
            if row.get("task_type") == "classification"
        ]
        rows.append({
            "validation_block": "float32 versus float64",
            "route": f"All tested families, {backend.upper()}",
            "attempted": len(precision),
            "completed": len(successful),
            "key_numerical_result": (
                "max regression prediction relative error "
                f"{extrema(successful, 'relative_prediction_error', max)}; "
                "min prediction agreement "
                f"{extrema(successful, 'prediction_agreement', min)}; min "
                "classification label agreement "
                f"{extrema(classification, 'prediction_agreement', min)}; "
                "max absolute metric difference "
                f"{extrema(successful, 'metric_delta_float32_minus_float64', lambda values: max(abs(value) for value in values))}"
            ),
            "failures": len(precision) - len(successful),
        })

    write_csv(output / "TableS1_numerical_validation.csv", rows)


def selected_tables(source: Path, output: Path) -> None:
    """Summarize replicate-level selected points into paired CPU/CUDA rows."""
    raw = read_csv(source)
    groups: dict[tuple[str, str, str], list[dict[str, str]]] = {}
    pair_order: list[tuple[str, str]] = []
    seen_pairs: set[tuple[str, str]] = set()
    for row in raw:
        pair = (row["dataset"], row["family"])
        if pair not in seen_pairs:
            seen_pairs.add(pair)
            pair_order.append(pair)
        groups.setdefault((*pair, row["backend"]), []).append(row)

    def median_field(rows: list[dict[str, str]], field: str) -> float | None:
        values = [
            value for row in rows
            if (value := finite_number(row.get(field, ""))) is not None
            and row.get("status") == "success"
        ]
        return None if not values else median(values)

    def show(value: float | None, digits: int = 6) -> str:
        return "" if value is None else f"{value:.{digits}g}"

    time_rows: list[dict[str, str]] = []
    memory_rows: list[dict[str, str]] = []
    for dataset, family in pair_order:
        cpu = groups.get((dataset, family, "cpu"), [])
        cuda = groups.get((dataset, family, "cuda"), [])
        if not cpu or not cuda:
            raise RuntimeError(
                f"Missing paired CPU/CUDA rows for {dataset}/{family}"
            )
        cpu_ok = [row for row in cpu if row.get("status") == "success"]
        cuda_ok = [row for row in cuda if row.get("status") == "success"]
        cpu_time = median_field(cpu, "total_sec")
        cuda_time = median_field(cuda, "total_sec")
        cpu_metric = median_field(cpu, "metric_value")
        cuda_metric = median_field(cuda, "metric_value")
        time_ratio = (
            None if cpu_time is None or cuda_time in (None, 0)
            else cpu_time / cuda_time
        )
        ncomp = (cpu or cuda)[0].get("requested_ncomp", "")
        precision = (cpu or cuda)[0].get("precision", "")
        metric_name = (cpu or cuda)[0].get("metric_name", "")
        time_rows.append({
            "dataset": dataset,
            "family": family,
            "components": ncomp,
            "precision": precision,
            "metric": metric_name,
            "cpu_time_seconds": show(cpu_time),
            "cuda_time_seconds": show(cuda_time),
            "cpu_cuda_time_ratio": show(time_ratio),
            "cpu_metric": show(cpu_metric),
            "cuda_metric": show(cuda_metric),
            "cpu_successful_replicates": str(len(cpu_ok)),
            "cuda_successful_replicates": str(len(cuda_ok)),
            "status": (
                "success" if cpu_ok and cuda_ok else
                f"cpu: {cpu[0].get('status', 'missing')}; "
                f"cuda: {cuda[0].get('status', 'missing')}"
            ),
        })

        cpu_baseline = median_field(cpu, "prefit_rss_mib")
        cuda_baseline = median_field(cuda, "prefit_rss_mib")
        cpu_increment = median_field(cpu, "incremental_peak_rss_mib")
        cuda_increment = median_field(cuda, "incremental_peak_rss_mib")
        gpu_peak = median_field(cuda, "gpu_peak_mib")
        memory_ratio = (
            None if cpu_increment is None or cpu_increment == 0
            or cuda_increment is None else cuda_increment / cpu_increment
        )
        memory_rows.append({
            "dataset": dataset,
            "family": family,
            "components": ncomp,
            "precision": precision,
            "cpu_baseline_rss_mib": show(cpu_baseline),
            "cuda_baseline_rss_mib": show(cuda_baseline),
            "cpu_incremental_peak_rss_mib": show(cpu_increment),
            "cuda_incremental_peak_rss_mib": show(cuda_increment),
            "cuda_cpu_increment_ratio": show(memory_ratio),
            "cuda_device_peak_mib": show(gpu_peak),
            "status": (
                "success" if cpu_ok and cuda_ok else
                f"cpu: {cpu[0].get('status', 'missing')}; "
                f"cuda: {cuda[0].get('status', 'missing')}"
            ),
        })

    write_csv(output / "TableS5_fit_prediction_cpu_cuda.csv", time_rows)
    write_csv(output / "TableS6_memory_cpu_cuda.csv", memory_rows)


def component_selection_evidence(
    phase1: Path, campaign: Path, output: Path
) -> None:
    """Merge every candidate grid with its training-only selection result."""
    grids = {
        row["dataset"]: row["components"]
        for row in read_csv(phase1 / "config/cmpb_selection_grids.csv")
    }
    ordinary = read_csv(
        campaign
        / "results/component_selection/ordinary/selected_components.csv"
    )
    evidence: list[dict[str, str]] = []
    for row in ordinary:
        dataset = row["dataset"]
        evidence.append({
            "dataset": dataset,
            "family": row["family"],
            "candidate_grid": grids[dataset],
            "selection_data": "training partition only",
            "selection_procedure": (
                f"{row['kfold']}-fold cross-validation; seed {row['seed']}"
            ),
            "selection_metric": row["selection_metric"],
            "selected_ncomp": row["selected_ncomp"],
            "eligible_ncomp": row["selected_ncomp"],
            "selection_status": row["selection_status"],
            "selection_threshold": "",
        })

    for family in ("plssvd", "simpls"):
        decision = read_csv(
            campaign
            / f"results/component_selection/nmr_{family}"
            / "nmr_component_selection_decision.csv"
        )
        if len(decision) != 1:
            raise RuntimeError(
                f"Expected one NMR {family} selection decision"
            )
        row = decision[0]
        evidence.append({
            "dataset": "nmr",
            "family": family,
            "candidate_grid": grids["nmr"],
            "selection_data": "training partition only",
            "selection_procedure": (
                f"{row['n_splits_successful']} paired 80/20 splits; "
                "smallest component count within one standard error of "
                "the minimum mean validation RMSD"
            ),
            "selection_metric": "RMSD",
            "selected_ncomp": row["selected_ncomp"],
            "eligible_ncomp": row["eligible_ncomp"],
            "selection_status": (
                "upper_grid_boundary" if row["upper_boundary_selected"]
                == "TRUE" else "lower_grid_boundary"
                if row["lower_boundary_selected"] == "TRUE" else "interior"
            ),
            "selection_threshold": row["one_se_threshold"],
        })

    write_csv(output / "component_selection_evidence.csv", evidence)
    copy_required(
        phase1 / "config/cmpb_selection_grids.csv",
        output / "component_selection_candidate_grids.csv",
    )
    copy_required(
        phase1 / "config/cmpb_component_contract.csv",
        output / "benchmark_component_contract.csv",
    )


def copy_validation(campaign: Path, output: Path) -> None:
    validation = campaign / "results/validation"
    matches = {
        "validation_dense_reference": "simpls_dense_reference",
        "validation_rsvd_qualification": "rsvd_qualification",
        "validation_precision_backend": "precision_",
        "validation_opls_kernel": "opls_kernel",
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


def imagenet_table(campaign: Path, output: Path) -> None:
    source = campaign / "results/figure4/imagenet_four_family_component_paths.csv"
    values = [
        row for row in read_csv(source)
        if row.get("method") == "simpls" and row.get("status") == "success"
    ]
    keep = (
        "classifier", "ncomp_requested", "top1_accuracy", "top5_accuracy",
        "fit_predict_time_sec", "top5_prediction_time_sec", "total_time_sec",
        "process_peak_rss_mb", "gpu_peak_mb",
    )
    write_csv(output / "TableS7_imagenet_simpls_component_path.csv", [
        {key: row.get(key, "") for key in keep} for row in values
    ])


def benchmark_platform_table(campaign: Path, output: Path) -> None:
    native = key_values(campaign / "provenance/native_runtime.tsv", "\t")
    runtime = key_values(campaign / "provenance/r_runtime.csv", ",")
    versions = {
        row["package"]: row.get("version", "")
        for row in read_csv(campaign / "provenance/r_package_versions.csv")
    }
    fastpls_version = versions.get("fastPLS", "")
    if fastpls_version != "0.3":
        raise RuntimeError(
            f"Expected fastPLS version 0.3; recorded {fastpls_version!r}"
        )
    rows = [
        {
            "item": "Package release",
            "configuration": f"fastPLS version {fastpls_version}",
        },
        {
            "item": "Operating system",
            "configuration": native.get("kernel", ""),
        },
        {
            "item": "Processor",
            "configuration": (
                f"{native.get('cpu_model', '')}; "
                f"{native.get('physical_cores', '')} physical cores, "
                f"{native.get('logical_cpus', '')} logical CPUs"
            ),
        },
        {
            "item": "R runtime",
            "configuration": (
                f"{runtime.get('R_version', '')}; "
                f"{runtime.get('platform', '')}"
            ),
        },
        {
            "item": "C++ compiler",
            "configuration": native.get("compiler", ""),
        },
        {
            "item": "CPU numerical library",
            "configuration": (
                f"{runtime.get('cpu_library', '')} "
                f"{runtime.get('cpu_library_version', '')}; "
                f"{runtime.get('cpu_library_core', '')}; "
                f"{runtime.get('cpu_library_parallel', '')}; "
                f"{runtime.get('cpu_library_threads', '')} thread"
            ),
        },
        {
            "item": "CUDA device",
            "configuration": (
                f"{native.get('gpu', '')}; driver "
                f"{native.get('cuda_driver', '')}"
            ),
        },
    ]
    write_csv(output / "TableS8_benchmark_platform.csv", rows)


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
    numerical_validation_table(campaign, output)
    formal_table(phase1, campaign, output)
    independent_contracts(phase1, campaign, output)
    selected_tables(
        campaign / "results/figure2/selected_cpu_cuda.csv", output
    )
    component_selection_evidence(phase1, campaign, output)
    imagenet_table(campaign, output)
    benchmark_platform_table(campaign, output)
    # Keep the complete four-family source for reproducibility even though
    # Table S7 and Figure 4 report the SIMPLS-family route.
    copy_required(
        campaign / "results/figure4/imagenet_four_family_component_paths.csv",
        output / "figure4_imagenet_component_paths.csv",
    )
    copy_validation(campaign, output)
    copy_required(
        campaign / "provenance/r_package_versions.csv",
        output / "provenance_r_package_versions.csv",
    )
    copy_required(
        campaign / "provenance/r_runtime.csv",
        output / "provenance_r_runtime.csv",
    )
    copy_required(
        campaign / "provenance/native_runtime.tsv",
        output / "provenance_native_runtime.tsv",
    )


if __name__ == "__main__":
    main()
