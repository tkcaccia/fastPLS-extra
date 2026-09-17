#!/usr/bin/env python3
"""Fail closed when publication evidence violates the release contract."""

from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path


SEQUENTIAL_FAMILIES = {"simpls", "opls", "kernelpls"}
ACCELERATORS = {"cuda", "metal"}
COMPONENT_PATH_DATASETS = {
    "cbmc_citeseq",
    "ccle",
    "cifar100",
    "gtex_v8",
    "metref",
    "prism",
    "retina",
    "tabula",
    "tcga_brca",
    "tcga_hnsc_methylation",
    "tcga_pan_cancer",
}
PACKAGE_PANEL_DATASETS = {
    "ccle",
    "cifar100",
    "gtex_v8",
    "metref",
    "retina",
    "tabula",
    "tcga_brca",
    "tcga_hnsc_methylation",
    "tcga_pan_cancer",
}
PACKAGE_PANEL_METHODS = {
    "fastpls_simpls_cpu_irlba",
    "fastpls_simpls_cpu_irlba_lda",
    "pls_simpls_fit",
    "plsgenomics_pls_lda",
    "mdatools_plsda_or_pls",
    "plsdepot_simpls",
    "pcv_simpls",
    "chemometrics_pls_eigen",
    "mixomics_plsda",
    "spls_splsda",
}


def normalized(value: object) -> str:
    return str(value or "").strip().lower()


def successful(row: dict[str, str]) -> bool:
    status = normalized(row.get("status", "success"))
    return status in {"", "ok", "success", "passed"}


def finite_integer(value: object) -> bool:
    try:
        number = float(str(value))
    except (TypeError, ValueError):
        return False
    return math.isfinite(number) and number >= 0 and number == int(number)


def finite_number(value: object, *, positive: bool = False) -> bool:
    try:
        number = float(str(value))
    except (TypeError, ValueError):
        return False
    if not math.isfinite(number):
        return False
    return number > 0 if positive else number >= 0


def first_integer(row: dict[str, str], names: tuple[str, ...]) -> bool:
    return any(finite_integer(row.get(name)) for name in names if name in row)


def identifies_fastpls(row: dict[str, str], fields: set[str]) -> bool:
    identity_fields = (
        "package",
        "implementation",
        "implementation_fastpls",
        "function_name",
        "function_name_fastpls",
    )
    observed = [normalized(row.get(name)) for name in identity_fields if name in fields]
    if not observed:
        return True
    return any("fastpls" in value for value in observed)


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def audit_csv(path: Path, version: str) -> tuple[int, list[str]]:
    rows = read_rows(path)
    if not rows:
        return 0, []
    fields = set(rows[0])
    errors: list[str] = []

    version_fields = (
        "package_version",
        "fastpls_version",
        "loaded_package_version",
    )
    for index, row in enumerate(rows, start=2):
        if not identifies_fastpls(row, fields):
            continue
        observed = {
            row.get(name, "").strip()
            for name in version_fields
            if name in fields and row.get(name, "").strip() not in {"", "NA"}
        }
        stale = observed - {version}
        if stale:
            errors.append(
                f"row {index} contains fastPLS versions {sorted(stale)}"
            )

    if {"backend_requested", "backend_reported"}.issubset(fields):
        for index, row in enumerate(rows, start=2):
            if not successful(row):
                continue
            requested = normalized(row.get("backend_requested"))
            reported = normalized(row.get("backend_reported"))
            if requested in ACCELERATORS and reported != requested:
                errors.append(
                    f"row {index} requested {requested} but reported "
                    f"{reported or 'no backend'}"
                )

    for index, row in enumerate(rows, start=2):
        if not successful(row):
            continue
        method = normalized(row.get("method") or row.get("family"))
        rule = normalized(row.get("direction_rule"))
        fresh = normalized(row.get("fresh_start"))
        if "warm" in rule:
            errors.append(f"row {index} contains forbidden direction rule {rule}")
        if (
            method in SEQUENTIAL_FAMILIES
            and fresh not in {"", "na"}
            and fresh not in {"true", "t", "1"}
        ):
            errors.append(f"row {index} reports a non-fresh {method} fit")

        solver = normalized(row.get("svd_method") or row.get("solver"))
        per_run = "replicate" in fields and "status" in fields
        if per_run and solver == "rsvd":
            controls = {
                "oversample": (
                    "oversample",
                    "rsvd_oversample",
                    "rsvd_effective_oversample",
                    "effective_oversample",
                ),
                "power": (
                    "power",
                    "rsvd_power",
                    "rsvd_effective_power",
                    "effective_power",
                ),
                "seed": ("seed", "fit_seed"),
            }
            for label, candidates in controls.items():
                if not first_integer(row, candidates):
                    errors.append(
                        f"row {index} lacks an executed integer rSVD {label}"
                    )

    return len(rows), errors


def require_file(root: Path, relative: str, errors: list[str]) -> Path:
    path = root / relative
    if not path.is_file() or path.stat().st_size == 0:
        errors.append(f"missing required evidence file: {relative}")
    return path


def require_glob(root: Path, pattern: str, errors: list[str]) -> list[Path]:
    paths = sorted(path for path in root.glob(pattern) if path.is_file())
    if not paths:
        errors.append(f"missing required evidence matching: {pattern}")
    elif any(path.stat().st_size == 0 for path in paths):
        errors.append(f"empty required evidence matching: {pattern}")
    return paths


def require_complete_campaign(root: Path, errors: list[str]) -> None:
    required = (
        "component_selection/selected_components.csv",
        "controlled_scaling/controlled_scaling_current_data.csv",
        "rsvd_qualification/rsvd_qualification_summary.csv",
        "simpls_exact/simpls_exact_reference_case_summary.csv",
        "simpls_ablation/simpls_multidataset_ablation_effects.csv",
        "simpls_vs_plssvd_shapes/simpls_vs_plssvd_shapes_paired.csv",
        "opls_kernel_estimator/opls_kernel_estimator_validation_summary.csv",
        "opls_kernel_settings/opls_kernel_setting_reliability_summary.csv",
        "multicore_scaling/multicore_scaling_summary.csv",
        "selected_backend_metal/matched_metal_paired.csv",
        "selected_backend_cuda/matched_cuda_paired.csv",
        "component_path_metal/component_path_summary.csv",
        "component_path_cuda/component_path_summary.csv",
        "external_simpls/external_simpls_timing_pairs.csv",
        "r_package_panel/pls_package_comparison_summary.csv",
        "r_package_panel/pls_package_comparison_status.csv",
        "r_package_panel/pls_package_comparison_current.png",
        "ikpls_cross_language_cpu/ikpls_cross_language_summary.csv",
        "ikpls_large_float32/ikpls_fastpls_large_float32_summary.csv",
        "nmr/figures/nmr_fixed165_summary.csv",
        "nmr/figures/nmr_selected_summary.csv",
        "imagenet/imagenet_current_summary.csv",
        "repeated_outer/metref/repeated_outer_raw.csv",
        "repeated_outer/gtex_v8/repeated_outer_raw.csv",
        "repeated_outer/retina/repeated_outer_raw.csv",
        "repeated_outer/nmr/repeated_outer_raw.csv",
    )
    for relative in required:
        require_file(root, relative, errors)

    for pattern in (
        "float32_cpu/float32_backend_agreement_cpu_*.csv",
        "**/float32_cuda/float32_backend_agreement_cuda_*.csv",
        "float32_metal/float32_backend_agreement_metal_*.csv",
        "cpu_smoke/backend_family_smoke_cpu.csv",
        "cuda_smoke/backend_family_smoke_cuda.csv",
        "metal_smoke/backend_family_smoke_metal.csv",
        "**/cv_compiled_vs_r_loop/cv_compiled_vs_r_loop_summary.csv",
    ):
        require_glob(root, pattern, errors)

    selection_path = root / required[0]
    if selection_path.is_file():
        rows = read_rows(selection_path)
        keys = {
            (normalized(row.get("dataset")), normalized(row.get("family")))
            for row in rows
        }
        if len(rows) != 44 or len(keys) != 44:
            errors.append(
                "component selection must contain exactly 44 unique "
                "dataset-family rows"
            )

    for accelerator in ("metal", "cuda"):
        paired = root / f"selected_backend_{accelerator}/matched_{accelerator}_paired.csv"
        if paired.is_file():
            rows = read_rows(paired)
            if len(rows) != 44:
                errors.append(
                    f"selected {accelerator} benchmark must contain 44 paired rows"
                )
            for row in rows:
                if not finite_number(row.get("cpu_ok"), positive=True):
                    errors.append(
                        f"selected {accelerator} benchmark lacks a successful CPU "
                        f"run for {row.get('dataset', '?')}/{row.get('method', '?')}"
                    )
                if not finite_number(row.get("accelerator_ok"), positive=True):
                    errors.append(
                        f"selected {accelerator} benchmark lacks a successful "
                        f"accelerator run for {row.get('dataset', '?')}/"
                        f"{row.get('method', '?')}"
                    )

        component_path = root / f"component_path_{accelerator}/component_path_summary.csv"
        if component_path.is_file():
            rows = read_rows(component_path)
            expected_backends = {"cpu", accelerator}
            combinations = {
                (
                    normalized(row.get("dataset")),
                    normalized(row.get("method")),
                    normalized(row.get("backend_requested")),
                )
                for row in rows
            }
            expected_pairs = {
                (dataset, method, backend)
                for dataset in COMPONENT_PATH_DATASETS
                for method in SEQUENTIAL_FAMILIES | {"plssvd"}
                for backend in expected_backends
            }
            missing = expected_pairs - combinations
            unexpected = combinations - expected_pairs
            if {item[0] for item in combinations} != COMPONENT_PATH_DATASETS:
                errors.append(
                    f"{accelerator} component path does not contain the exact "
                    "11-dataset publication panel"
                )
            if missing:
                errors.append(
                    f"{accelerator} component path lacks {len(missing)} "
                    "dataset-family-backend combinations"
                )
            if unexpected:
                errors.append(
                    f"{accelerator} component path contains {len(unexpected)} "
                    "unexpected dataset-family-backend combinations"
                )
            for row in rows:
                label = (
                    f"{row.get('dataset', '?')}/{row.get('method', '?')}/"
                    f"{row.get('backend_requested', '?')}/ncomp={row.get('ncomp', '?')}"
                )
                if not finite_number(row.get("n_ok"), positive=True):
                    errors.append(f"component path has no successful runs for {label}")
                if not finite_number(row.get("n_failed")):
                    errors.append(f"component path lacks a valid failure count for {label}")
                elif float(row["n_failed"]) != 0:
                    errors.append(f"component path contains failed runs for {label}")

    package_status = root / "r_package_panel/pls_package_comparison_status.csv"
    if package_status.is_file():
        rows = read_rows(package_status)
        observed = {
            (normalized(row.get("dataset")), normalized(row.get("method_id")))
            for row in rows
        }
        expected = {
            (dataset, method)
            for dataset in PACKAGE_PANEL_DATASETS
            for method in PACKAGE_PANEL_METHODS
        }
        missing = expected - observed
        if missing:
            errors.append(
                "independent-package panel lacks explicit status for "
                f"{len(missing)} displayed method-dataset cells"
            )

    qualification = root / "rsvd_qualification/rsvd_qualification_summary.csv"
    if qualification.is_file():
        rows = read_rows(qualification)
        backends = {normalized(row.get("backend")) for row in rows}
        if backends != {"cpu", "cuda", "metal"}:
            errors.append("rSVD qualification must contain CPU, CUDA, and Metal")
        for row in rows:
            comparisons = row.get("comparisons")
            within = row.get("comparisons_within_tolerance")
            if comparisons != within:
                errors.append(
                    f"rSVD qualification is incomplete for {row.get('backend', '?')}: "
                    f"{within}/{comparisons} comparisons within tolerance"
                )

    imagenet = root / "imagenet/imagenet_current_summary.csv"
    if imagenet.is_file():
        rows = [row for row in read_rows(imagenet) if successful(row)]
        expected_ncomp = set(range(100, 1001, 100))
        expected = {
            (classifier, ncomp)
            for classifier in {"argmax", "lda"}
            for ncomp in expected_ncomp
        }
        observed: set[tuple[str, int]] = set()
        for row in rows:
            try:
                ncomp = int(float(row.get("ncomp_requested", "")))
            except (TypeError, ValueError):
                continue
            if (
                normalized(row.get("dataset")) != "imagenet"
                or normalized(row.get("method")) != "simpls"
                or normalized(row.get("solver")) != "rsvd"
                or normalized(row.get("backend")) != "cuda"
                or normalized(row.get("precision")) != "float32"
            ):
                continue
            classifier = normalized(row.get("classifier"))
            observed.add((classifier, ncomp))
            label = f"ImageNet/{classifier}/ncomp={ncomp}"
            for field in (
                "fit_predict_time_sec",
                "top5_prediction_time_sec",
                "total_time_sec",
                "top1_accuracy",
                "top5_accuracy",
                "process_peak_rss_mb",
                "incremental_peak_rss_mb",
                "gpu_peak_mb",
                "gpu_incremental_peak_mb",
            ):
                if not finite_number(row.get(field)):
                    errors.append(f"{label} lacks finite {field}")
            for label_control, fields in {
                "oversample": ("effective_oversample", "oversample"),
                "power": ("effective_power", "power"),
                "seed": ("seed",),
            }.items():
                if not first_integer(row, fields):
                    errors.append(f"{label} lacks executed rSVD {label_control}")
        missing = expected - observed
        unexpected = observed - expected
        if missing:
            errors.append(
                f"ImageNet lacks {len(missing)} successful required "
                "classifier-component rows"
            )
        if unexpected:
            errors.append(
                f"ImageNet contains {len(unexpected)} unexpected successful "
                "classifier-component rows"
            )

    ikpls = root / "ikpls_large_float32/ikpls_fastpls_large_float32_summary.csv"
    if ikpls.is_file():
        rows = read_rows(ikpls)
        successful_fastpls_imagenet = [
            row for row in rows
            if normalized(row.get("dataset")) == "imagenet"
            and "fastpls" in normalized(row.get("implementation"))
            and successful(row)
        ]
        ikpls_datasets = {
            normalized(row.get("dataset"))
            for row in rows
            if "ikpls" in normalized(row.get("implementation"))
        }
        if not successful_fastpls_imagenet:
            errors.append("large float32 comparison lacks successful fastPLS ImageNet rows")
        if ikpls_datasets != {"imagenet", "nmr"}:
            errors.append("large float32 comparison must record IKPLS on ImageNet and NMR")

    nmr_fixed = root / "nmr/figures/nmr_fixed165_summary.csv"
    if nmr_fixed.is_file():
        rows = read_rows(nmr_fixed)
        labels = {normalized(row.get("label")) for row in rows}
        if "deposited pls-svd" not in labels:
            errors.append(
                "fixed-component NMR summary lacks the deposited PLS-SVD comparator"
            )

    repeated_expected = {
        "metref": 80,
        "gtex_v8": 80,
        "retina": 80,
        "nmr": 10,
    }
    for dataset, expected_rows in repeated_expected.items():
        path = root / f"repeated_outer/{dataset}/repeated_outer_raw.csv"
        if not path.is_file():
            continue
        rows = read_rows(path)
        keys = {
            (
                normalized(row.get("method")),
                normalized(row.get("classifier")),
                normalized(row.get("outer_seed")),
            )
            for row in rows
        }
        failed = [row for row in rows if not successful(row)]
        if len(rows) != expected_rows or len(keys) != expected_rows:
            errors.append(
                f"repeated outer-partition evidence for {dataset} must contain "
                f"exactly {expected_rows} unique rows"
            )
        if failed:
            errors.append(
                f"repeated outer-partition evidence for {dataset} contains "
                f"{len(failed)} failed rows"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--require-complete", action="store_true")
    arguments = parser.parse_args()

    root = arguments.root.resolve()
    if not root.is_dir():
        raise SystemExit(f"Evidence root does not exist: {root}")

    errors: list[str] = []
    row_count = 0
    csv_count = 0
    for path in sorted(root.rglob("*.csv")):
        csv_count += 1
        rows, file_errors = audit_csv(path, arguments.version)
        row_count += rows
        errors.extend(f"{path.relative_to(root)}: {error}" for error in file_errors)

    if arguments.require_complete:
        require_complete_campaign(root, errors)

    if errors:
        print("Release-evidence audit failed:")
        for error in errors:
            print(f"- {error}")
        raise SystemExit(1)

    mode = "complete" if arguments.require_complete else "available"
    print(
        f"Release-evidence audit passed ({mode} mode): "
        f"{csv_count} CSV files, {row_count} rows, version {arguments.version}."
    )


if __name__ == "__main__":
    main()
