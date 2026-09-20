#!/usr/bin/env python3
"""Audit completion and no-skip coverage for one frozen CMPB campaign."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
import re


DATASETS = {
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer",
    "cbmc_citeseq", "prism", "nmr", "imagenet",
}
FAMILIES = {"plssvd", "simpls", "opls", "kernelpls"}
CLASSIFICATION_DATASETS = {
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer", "imagenet",
}
EXPECTED_COMPONENT_CONTRACT = {
    "ccle": (17, 50, 50, 50, 50),
    "cifar100": (99, 99, 99, 99, 99),
    "gtex_v8": (30, 50, 50, 50, 50),
    "metref": (21, 50, 50, 50, 50),
    "retina": (10, 10, 10, 10, 10),
    "tabula": (31, 31, 31, 31, 31),
    "tcga_brca": (3, 3, 3, 3, 3),
    "tcga_hnsc_methylation": (2, 2, 2, 2, 2),
    "tcga_pan_cancer": (31, 100, 100, 100, 100),
    "cbmc_citeseq": (31, 44, 44, 44, 44),
    "prism": (6, 6, 6, 6, 6),
    "nmr": (100, 50, 50, 50, 50),
    "imagenet": (1000, 1000, 1000, 1000, 1000),
}


def truthy(value: str) -> bool:
    return value.strip().lower() in {"true", "t", "1", "yes"}


def finite(value: str) -> bool:
    try:
        return math.isfinite(float(value))
    except (TypeError, ValueError):
        return False


def integer(value: str) -> int:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0


def rows(path: Path, delimiter: str = ",") -> list[dict[str, str]]:
    if not path.is_file():
        raise FileNotFoundError(path)
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle, delimiter=delimiter))


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def require_no_skips(values: list[dict[str, str]], label: str,
                     failures: list[str]) -> None:
    skipped = [
        row for row in values
        if (
            "skip" in row.get("status", "").lower()
            or row.get("status", "").lower().startswith("not_evaluated")
            or (
                row.get("status", "").lower().startswith("not_repeated")
                and row.get("status", "").lower()
                != "not_repeated_after_first_failure"
            )
        )
    ]
    require(not skipped, f"{label} contains {len(skipped)} skipped rows", failures)


def require_one_attempt_per_workflow(values: list[dict[str, str]], label: str,
                                     failures: list[str]) -> None:
    grouped: dict[tuple[str, str], list[dict[str, str]]] = {}
    for row in values:
        key = (row.get("dataset", ""), row.get("method_id", ""))
        grouped.setdefault(key, []).append(row)
    missing = []
    for key, group in grouped.items():
        attempted = [
            row for row in group
            if not row.get("status", "").lower().startswith(
                ("not_evaluated", "not_repeated")
            )
        ]
        if not attempted:
            missing.append("/".join(key))
    require(
        not missing,
        f"{label} lacks a real attempt for: {', '.join(sorted(missing))}",
        failures,
    )


def require_complete_repetitions(
    values: list[dict[str, str]],
    label: str,
    group_fields: tuple[str, ...],
    expected: int,
    failures: list[str],
) -> None:
    """Require every workflow to contain each requested repetition once."""
    grouped: dict[tuple[str, ...], list[dict[str, str]]] = {}
    for row in values:
        key = tuple(row.get(field, "") for field in group_fields)
        grouped.setdefault(key, []).append(row)
    required = set(range(1, expected + 1))
    incomplete = []
    for key, group in grouped.items():
        observed = set()
        for row in group:
            try:
                observed.add(int(row.get("replicate", "")))
            except (TypeError, ValueError):
                pass
        if len(group) != expected or observed != required:
            incomplete.append(
                f"{'/'.join(key)} rows={len(group)} repetitions="
                f"{','.join(map(str, sorted(observed)))}"
            )
    require(
        not incomplete,
        f"{label} has incomplete repetition sets: "
        + "; ".join(sorted(incomplete)),
        failures,
    )


def csv_files(directory: Path, pattern: str) -> list[dict[str, str]]:
    values: list[dict[str, str]] = []
    for path in sorted(directory.glob(pattern)):
        values.extend(rows(path))
    return values


def key_values(path: Path, delimiter: str = "\t") -> dict[str, str]:
    return {
        row.get("field", ""): row.get("value", "")
        for row in rows(path, delimiter)
    }


def plain_key_values(path: Path, delimiter: str = "\t") -> dict[str, str]:
    """Read a two-column key/value file without assuming a header row."""
    if not path.is_file():
        raise FileNotFoundError(path)
    values: dict[str, str] = {}
    with path.open(newline="") as handle:
        for row in csv.reader(handle, delimiter=delimiter):
            if len(row) >= 2:
                values[row[0]] = row[1]
    return values


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign_root", type=Path)
    args = parser.parse_args()
    root = args.campaign_root.resolve()
    phase1 = Path(__file__).resolve().parent.parent
    failures: list[str] = []
    report: dict[str, object] = {}

    stages = rows(root / "stage_status.tsv", "\t")
    report["stages"] = stages
    required_stages = {
        "verify_source", "prepare_dependencies", "install_package",
        "package_test_suite",
        "prepare_tasks", "prepare_python", "record_environment",
        "figure1_fastpls", "figure1_imagenet", "figure1_independent_r",
        "figure1_ikpls", "figure1_python", "supplementary_cuda_software",
        "figure2_selected_backends", "figure2_cross_validation",
        "supplementary_component_paths", "training_component_selection",
        "nmr_selection_plssvd", "nmr_selection_simpls", "figure3_nmr",
        "figure4_imagenet",
        "validation_simpls_dense", "validation_rsvd_cpu",
        "validation_rsvd_cuda",
        "validation_opls_kernel_estimator",
        "validation_opls_kernel_settings", "validation_precision_cpu",
        "validation_precision_cuda", "formal_invariants",
    }
    latest = {row.get("stage"): row for row in stages}
    missing_stages = sorted(required_stages - set(latest))
    require(not missing_stages, "missing stages: " + ", ".join(missing_stages), failures)
    for name in sorted(required_stages & set(latest)):
        stage = latest[name]
        require(
            stage.get("exit_status") == "0",
            f"stage {name} exited {stage.get('exit_status')}",
            failures,
        )

    timing_path = root / "package_check/testthat_timing.tsv"
    timing = plain_key_values(timing_path)
    testthat_elapsed = int(timing.get("elapsed_seconds", "999999"))
    require(
        timing.get("exit_status") == "0" and testthat_elapsed <= 180,
        f"compact testthat suite took {testthat_elapsed} seconds or failed",
        failures,
    )
    package_log = (root / "logs/package_test_suite.log").read_text()
    require(
        bool(re.search(r"FAIL\s+0.*WARN\s+0.*SKIP\s+0", package_log)),
        "compact testthat summary is not clean",
        failures,
    )
    check_logs = list((root / "package_check").glob("*.Rcheck/00check.log"))
    require(len(check_logs) == 1, "R CMD check log is missing", failures)
    if check_logs:
        check_text = check_logs[0].read_text()
        if "Status: OK" not in check_text:
            warning_checks = re.findall(
                r"^\* checking .* \.\.\. WARNING$", check_text, re.MULTILINE
            )
            known_vignette_warning = (
                warning_checks == [
                    "* checking files in ‘vignettes’ ... WARNING",
                    "* checking package vignettes ... WARNING",
                ]
                and "Status: 2 WARNINGs" in check_text
                and " ERROR" not in check_text
                and "no files in 'inst/doc'" in check_text
                and "Directory 'inst/doc' does not exist." in check_text
            )
            require(
                known_vignette_warning,
                "benchmark-archive R CMD check has unexpected warnings or errors",
                failures,
            )

            equivalence_path = root / "distribution_check/archive_equivalence.json"
            require(
                equivalence_path.is_file(),
                "distribution archive equivalence report is missing",
                failures,
            )
            if equivalence_path.is_file():
                equivalence = json.loads(equivalence_path.read_text())
                require(
                    equivalence.get("equivalent") is True,
                    "distribution archive differs from benchmarked package code",
                    failures,
                )
                report["distribution_archive_equivalence"] = equivalence

            distribution_logs = sorted(
                (root / "distribution_check").glob("check*/*.Rcheck/00check.log")
            )
            successful_distribution_logs = [
                path for path in distribution_logs
                if "Status: OK" in path.read_text()
            ]
            require(
                bool(successful_distribution_logs),
                "no distribution-archive R CMD check reported Status: OK",
                failures,
            )
            report["distribution_check_logs"] = [
                str(path.relative_to(root)) for path in distribution_logs
            ]
            report["successful_distribution_check_logs"] = [
                str(path.relative_to(root))
                for path in successful_distribution_logs
            ]

    native = key_values(root / "provenance/native_runtime.tsv")
    runtime = key_values(root / "provenance/r_runtime.csv", ",")
    require(
        native.get("benchmark_host_id") == "chiamaka",
        "campaign was not identified as a Chiamaka run",
        failures,
    )
    require(
        "Linux" in native.get("kernel", ""),
        "campaign kernel is not Linux",
        failures,
    )
    require(bool(native.get("gpu", "").strip()), "CUDA GPU was not recorded", failures)
    require(
        "linux" in runtime.get("platform", "").lower(),
        "R platform is not Linux",
        failures,
    )
    require(
        runtime.get("cpu_library") == "OpenBLAS",
        "fastPLS was not compiled against OpenBLAS",
        failures,
    )

    forbidden_platform_rows: list[str] = []
    for result_file in (root / "results").rglob("*.csv"):
        try:
            result_rows = rows(result_file)
        except (UnicodeDecodeError, csv.Error):
            continue
        for row in result_rows:
            value = row.get("platform", "").lower()
            if any(token in value for token in ("darwin", "macos", "metal")):
                forbidden_platform_rows.append(str(result_file))
                break
    require(
        not forbidden_platform_rows,
        "Mac/Metal rows found in CMPB results: "
        + ", ".join(sorted(set(forbidden_platform_rows))),
        failures,
    )

    fastpls = rows(root / "results/figure1/fastpls_cpu_raw.csv")
    component_contract = {
        row["dataset"]: row
        for row in rows(phase1 / "config/cmpb_component_contract.csv")
    }
    observed_component_contract = {
        dataset: tuple(
            integer(component_contract.get(dataset, {}).get(field, "0"))
            for field in (
                "plssvd_ncomp", "simpls_ncomp", "opls_ncomp",
                "kernelpls_ncomp", "external_ncomp",
            )
        )
        for dataset in EXPECTED_COMPONENT_CONTRACT
    }
    require(
        observed_component_contract == EXPECTED_COMPONENT_CONTRACT,
        "the frozen CMPB component-count contract has changed",
        failures,
    )
    require(len(fastpls) == 120, f"expected 120 fastPLS Figure 1 rows, found {len(fastpls)}", failures)
    require(
        {row.get("dataset") for row in fastpls} == DATASETS - {"imagenet"},
        "fastPLS Figure 1 dataset coverage is incomplete",
        failures,
    )
    require_no_skips(fastpls, "fastPLS Figure 1", failures)
    require(
        all(row.get("status") == "success" for row in fastpls),
        "fastPLS Figure 1 contains failed or timed-out rows",
        failures,
    )
    require(
        all(
            integer(row.get("ncomp_requested", "0"))
            == integer(
                component_contract.get(row.get("dataset", ""), {}).get(
                    "simpls_ncomp", "0"
                )
            )
            for row in fastpls
        ),
        "fastPLS Figure 1 violates the component-count contract",
        failures,
    )
    imagenet_fastpls = rows(
        root / "results/figure1/imagenet_cpu/simpls_lda.csv"
    )
    require(
        len(imagenet_fastpls) == 1
        and imagenet_fastpls[0].get("status") == "success",
        "the fastPLS ImageNet Figure 1 row is not successful",
        failures,
    )
    if len(imagenet_fastpls) == 1:
        require(
            integer(imagenet_fastpls[0].get("ncomp_requested", "0"))
            == integer(component_contract["imagenet"]["simpls_ncomp"]),
            "the fastPLS ImageNet row violates the component-count contract",
            failures,
        )

    independent_raw = (
        root / "results/figure1/independent_r/figure1_r_packages_raw.csv"
    )
    if independent_raw.is_file():
        independent = rows(independent_raw)
        require(
            len(independent) == 312,
            f"expected 312 independent-R rows, found {len(independent)}",
            failures,
        )
    else:
        independent = rows(
            root / "results/figure1/independent_r/figure1_r_packages_summary.csv"
        )
        require(
            len(independent) == 104,
            f"expected 104 finalized independent-R rows, found {len(independent)}",
            failures,
        )
        final_figure1 = rows(
            root / "results/figure1/final/figure1_data.csv"
        )
        require(
            len(final_figure1) == 143,
            f"expected 143 finalized Figure 1 rows, found {len(final_figure1)}",
            failures,
        )
    require_no_skips(independent, "independent R benchmark", failures)
    require_one_attempt_per_workflow(
        independent, "independent R benchmark", failures
    )
    require_complete_repetitions(
        independent,
        "independent R benchmark",
        ("dataset", "method_id"),
        3,
        failures,
    )
    independent_terminal = {
        "ok", "success", "timeout", "error", "failed", "process_failure",
        "not_repeated_after_first_failure",
    }
    require(
        all(
            row.get("status", "").lower() in independent_terminal
            for row in independent
        ),
        "independent R benchmark contains a nonterminal status",
        failures,
    )
    independent_failures = [
        row for row in independent
        if row.get("status", "").lower() not in {"ok", "success"}
    ]
    require(
        all(
            (
                finite(row.get("monitor_elapsed_sec", ""))
                and row.get("monitor_exit_code", "") != ""
            )
            or (
                row.get("status", "").lower()
                == "not_repeated_after_first_failure"
                and row.get("source_replicate", "") == "1"
                and row.get("first_attempt_status", "") != ""
                and finite(row.get("first_attempt_monitor_elapsed_sec", ""))
                and row.get("first_attempt_monitor_exit_code", "") != ""
            )
            for row in independent_failures
        ),
        "an independent-R failure lacks monitor evidence of a real attempt",
        failures,
    )
    first_attempts = {
        (row.get("dataset", ""), row.get("method_id", "")): row
        for row in independent
        if integer(row.get("replicate", "0")) == 1
    }
    for row in independent_failures:
        if (
            row.get("status", "").lower()
            != "not_repeated_after_first_failure"
        ):
            continue
        key = (row.get("dataset", ""), row.get("method_id", ""))
        first = first_attempts.get(key)
        require(
            integer(row.get("replicate", "0")) in {2, 3},
            f"suppressed repetition is not 2 or 3 for {'/'.join(key)}",
            failures,
        )
        require(
            first is not None
            and first.get("status", "").lower() not in {"ok", "success"},
            f"suppressed repetition lacks a failed first attempt for {'/'.join(key)}",
            failures,
        )
        if first is None:
            continue
        require(
            row.get("first_attempt_status", "").lower()
            == first.get("status", "").lower(),
            f"suppressed repetition has the wrong first status for {'/'.join(key)}",
            failures,
        )
        require(
            row.get("first_attempt_monitor_exit_code", "")
            == first.get("monitor_exit_code", ""),
            f"suppressed repetition has the wrong monitor exit code for {'/'.join(key)}",
            failures,
        )
        try:
            elapsed_matches = math.isclose(
                float(row.get("first_attempt_monitor_elapsed_sec", "nan")),
                float(first.get("monitor_elapsed_sec", "nan")),
                rel_tol=0,
                abs_tol=1e-9,
            )
        except (TypeError, ValueError):
            elapsed_matches = False
        require(
            elapsed_matches,
            f"suppressed repetition has the wrong monitor duration for {'/'.join(key)}",
            failures,
        )
    require(
        all(
            integer(row.get("ncomp_requested", "0"))
            == integer(
                component_contract.get(row.get("dataset", ""), {}).get(
                    "external_ncomp", "0"
                )
            )
            for row in independent
        ),
        "an independent-R row violates the component-count contract",
        failures,
    )

    ikpls_standard = rows(
        root / "results/figure1/ikpls_standard/ikpls_panel_all_runs.csv"
    )
    ikpls_large = csv_files(
        root / "results/figure1/ikpls_large", "*_ikpls_f32_n*.csv"
    )
    require(len(ikpls_standard) == 110, "expected 110 standard IKPLS rows", failures)
    require(len(ikpls_large) == 2, "expected two large IKPLS rows", failures)
    require_no_skips(ikpls_standard + ikpls_large, "IKPLS benchmark", failures)
    require(
        all(
            integer(row.get("ncomp", "0"))
            == integer(
                component_contract.get(row.get("dataset", ""), {}).get(
                    "external_ncomp", "0"
                )
            )
            for row in ikpls_standard + ikpls_large
        ),
        "an IKPLS row violates the component-count contract",
        failures,
    )

    python_standard = rows(
        root / "results/figure1/python_standard/python_pls_panel_all_runs.csv"
    )
    python_large = rows(
        root / "results/figure1/python_large/python_pls_large_all_runs.csv"
    )
    require(len(python_standard) == 110, "expected 110 standard scikit-learn rows", failures)
    require(len(python_large) == 2, "expected two large scikit-learn rows", failures)
    require_no_skips(
        python_standard + python_large, "scikit-learn benchmark", failures
    )
    require(
        all(
            integer(row.get("ncomp", "0"))
            == integer(
                component_contract.get(row.get("dataset", ""), {}).get(
                    "external_ncomp", "0"
                )
            )
            for row in python_standard + python_large
        ),
        "a scikit-learn row violates the component-count contract",
        failures,
    )

    cuda_software = rows(
        root / "results/supplement/cuda_software/cuda_software_comparison_all_runs.csv"
    )
    require(len(cuda_software) == 224, "expected 224 CUDA software rows", failures)
    require_no_skips(cuda_software, "CUDA software benchmark", failures)

    selected_backend_rows = rows(root / "results/figure2/selected_cpu_cuda.csv")
    require(
        len(selected_backend_rows) == 312,
        f"expected 312 CPU/CUDA rows, found {len(selected_backend_rows)}",
        failures,
    )
    coverage = {
        (row.get("dataset"), row.get("family"), row.get("backend"))
        for row in selected_backend_rows
    }
    expected_coverage = {
        (dataset, family, backend)
        for dataset in DATASETS for family in FAMILIES
        for backend in ("cpu", "cuda")
    }
    require(coverage == expected_coverage, "CPU/CUDA route coverage is incomplete", failures)
    require_complete_repetitions(
        selected_backend_rows,
        "CPU/CUDA fit-and-prediction benchmark",
        ("dataset", "family", "backend"),
        3,
        failures,
    )
    require_no_skips(
        selected_backend_rows,
        "CPU/CUDA fit-and-prediction benchmark",
        failures,
    )
    allowed_terminal_status = {
        "success", "ok", "timeout", "error", "failed", "process_failure",
    }
    require(
        all(
            row.get("status", "").lower() in allowed_terminal_status
            for row in selected_backend_rows
        ),
        "CPU/CUDA fit-and-prediction benchmark contains a nonterminal status",
        failures,
    )
    successful_selected = [
        row for row in selected_backend_rows
        if row.get("status", "").lower() in {"success", "ok"}
    ]
    require(
        all(
            0 < integer(row.get("effective_ncomp", "0"))
            <= integer(row.get("requested_ncomp", "0"))
            for row in successful_selected
        ),
        "a successful CPU/CUDA row has an invalid effective component count",
        failures,
    )
    imagenet_success = [
        row for row in successful_selected if row.get("dataset") == "imagenet"
    ]
    require(
        all(
            integer(row.get("effective_ncomp", "0"))
            == (999 if row.get("family") == "plssvd" else 1000)
            for row in imagenet_success
        ),
        (
            "ImageNet effective component counts do not match the fixed "
            "workload contract; CUDA refresh-block width must not be treated "
            "as the effective component count"
        ),
        failures,
    )

    cv_rows = csv_files(root / "results/figure2/cv_standard", "*.csv")
    cv_rows = [row for row in cv_rows if "elapsed_sec" in row]
    cv_image = csv_files(root / "results/figure2/cv_imagenet", "*.csv")
    cv_image = [row for row in cv_image if "elapsed_sec" in row]
    require(len(cv_rows) == 960, f"expected 960 ordinary CV rows, found {len(cv_rows)}", failures)
    require(len(cv_image) == 16, f"expected 16 ImageNet CV rows, found {len(cv_image)}", failures)
    require_no_skips(cv_rows + cv_image, "cross-validation benchmark", failures)
    ordinary_cv_coverage = {
        (
            row.get("dataset"), row.get("method"), row.get("backend"),
            row.get("workload"), integer(row.get("replicate", "0")),
        )
        for row in cv_rows
    }
    expected_ordinary_cv_coverage = {
        (dataset, family, backend, workload, replicate)
        for dataset in DATASETS - {"imagenet"}
        for family in FAMILIES
        for backend in ("cpu", "cuda")
        for workload in ("fit_predict", "cv")
        for replicate in range(1, 6)
    }
    require(
        ordinary_cv_coverage == expected_ordinary_cv_coverage,
        "ordinary cross-validation route or repetition coverage is incomplete",
        failures,
    )
    imagenet_cv_coverage = {
        (
            row.get("dataset"), row.get("method"), row.get("backend"),
            row.get("workload"), integer(row.get("replicate", "0")),
        )
        for row in cv_image
    }
    expected_imagenet_cv_coverage = {
        ("imagenet", family, backend, workload, 1)
        for family in FAMILIES
        for backend in ("cpu", "cuda")
        for workload in ("fit_predict", "cv")
    }
    require(
        imagenet_cv_coverage == expected_imagenet_cv_coverage,
        "ImageNet cross-validation route coverage is incomplete",
        failures,
    )
    cv_terminal_statuses = {
        "success", "timeout", "error", "failed", "process_failure",
    }
    require(
        all(
            row.get("status", "").lower() in cv_terminal_statuses
            for row in cv_rows + cv_image
        ),
        "cross-validation benchmark contains a nonterminal status",
        failures,
    )
    successful_cv = [
        row for row in cv_rows + cv_image
        if row.get("status", "").lower() == "success"
    ]
    require(
        all(
            finite(row.get("elapsed_sec", ""))
            and float(row.get("elapsed_sec", "0")) > 0
            and finite(row.get("metric_value", ""))
            for row in successful_cv
        ),
        "a successful cross-validation row has a nonfinite metric or time",
        failures,
    )
    require(
        all(
            row.get("precision") == "float32"
            and integer(row.get("folds", "0")) == 10
            for row in successful_cv
        ),
        "a successful cross-validation row violates the precision or fold contract",
        failures,
    )
    require(
        all(
            row.get("classifier") == "lda"
            for row in cv_rows + cv_image
            if row.get("dataset") in CLASSIFICATION_DATASETS
        ),
        "a classification CV timing route did not use LDA",
        failures,
    )
    cv_fold_signatures: dict[tuple[str, str, str], set[str]] = {}
    for row in successful_cv:
        if row.get("workload") != "cv":
            continue
        key = (
            row.get("dataset", ""), row.get("method", ""),
            row.get("replicate", ""),
        )
        cv_fold_signatures.setdefault(key, set()).add(
            row.get("fold_signature", "")
        )
    require(
        all(
            len(signatures) == 1 and "" not in signatures
            for signatures in cv_fold_signatures.values()
        ),
        "CPU and CUDA cross-validation rows do not share one fold signature",
        failures,
    )

    image = rows(
        root / "results/figure4/imagenet_four_family_component_paths.csv"
    )
    image_coverage = {
        (row.get("method"), row.get("classifier")) for row in image
    }
    require(
        image_coverage == {
            (family, classifier) for family in FAMILIES
            for classifier in ("argmax", "lda")
        },
        "ImageNet four-family/head coverage is incomplete",
        failures,
    )
    require(
        all(row.get("status") == "success" for row in image),
        "ImageNet component paths contain failed rows",
        failures,
    )

    component_paths = rows(
        root / "results/component_paths/standard/component_path_raw.csv"
    )
    require(
        {row.get("dataset") for row in component_paths} == DATASETS - {"nmr", "imagenet"},
        "ordinary component-path dataset coverage is incomplete",
        failures,
    )
    require(
        {row.get("method") for row in component_paths} == FAMILIES,
        "ordinary component-path family coverage is incomplete",
        failures,
    )
    require_no_skips(component_paths, "ordinary component paths", failures)
    require(
        all(row.get("status") in {"success", "ok"} for row in component_paths),
        "ordinary component paths contain failed rows",
        failures,
    )
    nmr_paths = rows(root / "results/component_paths/nmr_cpu_cuda.csv")
    require(
        {row.get("family") for row in nmr_paths} == FAMILIES,
        "NMR component-path family coverage is incomplete",
        failures,
    )
    require_no_skips(nmr_paths, "NMR component paths", failures)
    require(
        all(row.get("status") in {"success", "ok"} for row in nmr_paths),
        "NMR component paths contain failed rows",
        failures,
    )
    expected_nmr_predictions = {
        root / "results/figure3/plssvd_cpu_prediction.rds",
        root / "results/figure3/plssvd_cuda_prediction.rds",
        root / "results/figure3/simpls_cpu_prediction.rds",
        root / "results/figure3/simpls_cuda_prediction.rds",
        root
        / "results/figure3/deposited/"
        "deposited_plssvd_cpu_irlba_k165_rep1_prediction.rds",
    }
    missing_nmr_predictions = sorted(
        str(path) for path in expected_nmr_predictions if not path.is_file()
    )
    require(
        not missing_nmr_predictions,
        "NMR prediction evidence is missing: "
        + ", ".join(missing_nmr_predictions),
        failures,
    )
    selection = rows(
        root / "results/component_selection/ordinary/selected_components.csv"
    )
    grid_rows = rows(
        phase1 / "config/cmpb_selection_grids.csv"
    )
    candidate_grids = {
        row["dataset"]: {
            int(value) for value in row["components"].split(",")
        }
        for row in grid_rows
    }
    require(
        {(row.get("dataset"), row.get("family")) for row in selection}
        == {(dataset, family) for dataset in DATASETS - {"nmr", "imagenet"}
            for family in FAMILIES},
        "training-only component-selection coverage is incomplete",
        failures,
    )
    require(
        all(row.get("selection_status") not in {"", "failed"}
            for row in selection),
        "training-only component selection contains failed rows",
        failures,
    )
    require(
        all(
            finite(row.get("selected_ncomp"))
            and finite(row.get("grid_min"))
            and finite(row.get("grid_max"))
            and float(row["grid_min"]) <= float(row["selected_ncomp"])
            <= float(row["grid_max"])
            for row in selection
        ),
        "a selected component count falls outside its evaluated grid",
        failures,
    )
    require(
        all(
            finite(row.get("selected_ncomp"))
            and int(float(row["selected_ncomp"]))
            in candidate_grids.get(row.get("dataset", ""), set())
            for row in selection
        ),
        "a selected component count is absent from its declared candidate grid",
        failures,
    )
    expected_nmr_selection = {"plssvd": "75", "simpls": "50"}
    for family in ("plssvd", "simpls"):
        decision = rows(
            root / f"results/component_selection/nmr_{family}/nmr_component_selection_decision.csv"
        )
        require(len(decision) == 1, f"missing NMR {family} selection decision", failures)
        if len(decision) == 1:
            selected_ncomp = decision[0].get("selected_ncomp", "")
            eligible = {
                value.strip()
                for value in decision[0].get("eligible_ncomp", "").split(",")
                if value.strip()
            }
            require(
                selected_ncomp in eligible,
                f"NMR {family} selection is not in its one-SE eligible set",
                failures,
            )
            require(
                selected_ncomp == expected_nmr_selection[family],
                f"NMR {family} selection changed from the frozen decision",
                failures,
            )
            require(
                decision[0].get("n_splits_successful") == "5",
                f"NMR {family} selection did not complete five splits",
                failures,
            )
    for backend in ("cpu", "cuda"):
        rsvd = rows(
            root / f"results/validation/rsvd_qualification_{backend}/rsvd_qualification_raw.csv"
        )
        require(
            len(rsvd) == 174,
            f"expected 174 {backend} rSVD comparisons, found {len(rsvd)}",
            failures,
        )
        require(
            all(row.get("status") == "success" for row in rsvd),
            f"{backend} rSVD qualification contains failed rows",
            failures,
        )
        require(
            all(truthy(row.get("met_prespecified_numerical_tolerances", ""))
                for row in rsvd),
            f"{backend} rSVD qualification contains rows outside tolerances",
            failures,
        )

    simpls_failures = rows(
        root
        / "results/validation/simpls_dense_reference/"
        "simpls_exact_reference_failures.csv"
    )
    require(
        not simpls_failures,
        f"dense SIMPLS numerical reference contains {len(simpls_failures)} failures",
        failures,
    )
    simpls_prefixes = rows(
        root
        / "results/validation/simpls_dense_reference/"
        "simpls_exact_reference_prefix_results.csv"
    )
    require(
        len(simpls_prefixes) == 82,
        f"expected 82 dense SIMPLS prefix checks, found {len(simpls_prefixes)}",
        failures,
    )
    require(
        all(
            row.get("exact_reference_status") == "converged"
            and row.get("compiled_solver_status") == "converged"
            for row in simpls_prefixes
        ),
        "dense SIMPLS reference contains a non-converged prefix",
        failures,
    )
    for column, bound in (
        ("coefficient_relative_error", 0.001),
        ("fitted_value_relative_error", 0.001),
        ("prediction_relative_error", 0.001),
        ("score_subspace_max_angle_degrees", 0.1),
        ("loading_subspace_max_angle_degrees", 0.1),
        ("projection_subspace_max_angle_degrees", 0.1),
        ("score_orthogonality_residual", 1e-10),
        ("deflation_basis_orthogonality_residual", 1e-10),
        ("deflation_residual", 1e-10),
    ):
        require(
            all(finite(row.get(column, "")) and float(row[column]) <= bound
                for row in simpls_prefixes),
            f"dense SIMPLS {column} exceeds {bound:g}",
            failures,
        )
    classification_agreements = [
        float(row["classification_label_agreement"])
        for row in simpls_prefixes
        if finite(row.get("classification_label_agreement", ""))
    ]
    require(
        classification_agreements
        and min(classification_agreements) >= 0.995,
        "dense SIMPLS classification agreement is below 0.995",
        failures,
    )
    estimator = rows(
        root
        / "results/validation/opls_kernel_estimator/"
        "opls_kernel_estimator_validation_raw.csv"
    )
    require(
        len(estimator) == 18,
        f"expected 18 OPLS/kernel estimator checks, found {len(estimator)}",
        failures,
    )
    require(
        all(row.get("status") == "success" and truthy(row.get("passes_all", ""))
            for row in estimator),
        "OPLS/kernel estimator validation contains failed or out-of-tolerance rows",
        failures,
    )
    setting_root = root / "results/validation/opls_kernel_settings"
    setting_raw = rows(setting_root / "opls_kernel_setting_reliability_raw.csv")
    setting_selection = rows(
        setting_root / "opls_kernel_setting_selection_summary.csv"
    )
    setting_folds = rows(
        setting_root / "opls_kernel_setting_selection_fold_raw.csv"
    )
    require(
        len(setting_raw) == 66
        and all(
            row.get("status") == "success" and truthy(row.get("passes_all", ""))
            for row in setting_raw
        ),
        "OPLS/kernel setting reliability did not pass all 66 cases",
        failures,
    )
    require(
        len(setting_selection) == 66
        and all(
            truthy(row.get("selected_component_agreement", ""))
            and integer(row.get("failed_folds", "")) == 0
            for row in setting_selection
        ),
        "OPLS/kernel component selection did not agree in all 66 cases",
        failures,
    )
    require(
        len(setting_folds) == 1540
        and all(row.get("status") == "success" for row in setting_folds),
        "OPLS/kernel fold-level validation is incomplete or contains failures",
        failures,
    )
    for backend in ("cpu", "cuda"):
        precision_files = sorted(
            (root / f"results/validation/precision_{backend}").glob(
                f"float32_backend_agreement_{backend}_*.csv"
            )
        )
        require(
            len(precision_files) == 1,
            f"expected one {backend} float32/float64 agreement table",
            failures,
        )
        if len(precision_files) == 1:
            precision = rows(precision_files[0])
            require(
                all(row.get("status") == "ok" for row in precision),
                f"{backend} float32/float64 agreement contains failed rows",
                failures,
            )

    report["counts"] = {
        "testthat_elapsed_seconds": testthat_elapsed,
        "fastpls_figure1": len(fastpls),
        "independent_r": len(independent),
        "ikpls_standard": len(ikpls_standard),
        "ikpls_large": len(ikpls_large),
        "scikit_standard": len(python_standard),
        "scikit_large": len(python_large),
        "cuda_software": len(cuda_software),
        "selected_cpu_cuda": len(selected_backend_rows),
        "cross_validation_standard": len(cv_rows),
        "cross_validation_imagenet": len(cv_image),
        "imagenet_paths": len(image),
        "ordinary_component_paths": len(component_paths),
        "nmr_component_paths": len(nmr_paths),
        "ordinary_component_selections": len(selection),
    }
    report["failures"] = failures
    destination = root / "campaign_audit.json"
    destination.write_text(json.dumps(report, indent=2) + "\n")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"Campaign audit passed: {destination}")


if __name__ == "__main__":
    main()
