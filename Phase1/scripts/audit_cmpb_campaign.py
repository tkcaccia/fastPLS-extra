#!/usr/bin/env python3
"""Audit completion and no-skip coverage for one frozen CMPB campaign."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import re


DATASETS = {
    "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
    "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer",
    "cbmc_citeseq", "prism", "nmr", "imagenet",
}
FAMILIES = {"plssvd", "simpls", "opls", "kernelpls"}


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
        if "skip" in row.get("status", "").lower()
    ]
    require(not skipped, f"{label} contains {len(skipped)} skipped rows", failures)


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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign_root", type=Path)
    args = parser.parse_args()
    root = args.campaign_root.resolve()
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
    timing = key_values(timing_path)
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
        require("Status: OK" in check_text, "R CMD check did not report OK", failures)

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
    imagenet_fastpls = rows(
        root / "results/figure1/imagenet_cpu/simpls_lda.csv"
    )
    require(
        len(imagenet_fastpls) == 1
        and imagenet_fastpls[0].get("status") == "success",
        "the fastPLS ImageNet Figure 1 row is not successful",
        failures,
    )

    independent = rows(
        root / "results/figure1/independent_r/figure1_r_packages_raw.csv"
    )
    require(len(independent) == 312, f"expected 312 independent-R rows, found {len(independent)}", failures)
    require_no_skips(independent, "independent R benchmark", failures)

    ikpls_standard = rows(
        root / "results/figure1/ikpls_standard/ikpls_panel_all_runs.csv"
    )
    ikpls_large = csv_files(
        root / "results/figure1/ikpls_large", "*_ikpls_f32_n*.csv"
    )
    require(len(ikpls_standard) == 110, "expected 110 standard IKPLS rows", failures)
    require(len(ikpls_large) == 2, "expected two large IKPLS rows", failures)
    require_no_skips(ikpls_standard + ikpls_large, "IKPLS benchmark", failures)

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

    cuda_software = rows(
        root / "results/supplement/cuda_software/cuda_software_comparison_all_runs.csv"
    )
    require(len(cuda_software) == 224, "expected 224 CUDA software rows", failures)
    require_no_skips(cuda_software, "CUDA software benchmark", failures)

    selected = rows(root / "results/figure2/selected_cpu_cuda.csv")
    require(len(selected) == 312, f"expected 312 CPU/CUDA rows, found {len(selected)}", failures)
    coverage = {
        (row.get("dataset"), row.get("family"), row.get("backend"))
        for row in selected
    }
    expected_coverage = {
        (dataset, family, backend)
        for dataset in DATASETS for family in FAMILIES
        for backend in ("cpu", "cuda")
    }
    require(coverage == expected_coverage, "CPU/CUDA route coverage is incomplete", failures)
    require_no_skips(selected, "CPU/CUDA fit-and-prediction benchmark", failures)

    cv_rows = csv_files(root / "results/figure2/cv_standard", "*.csv")
    cv_rows = [row for row in cv_rows if "elapsed_sec" in row]
    cv_image = csv_files(root / "results/figure2/cv_imagenet", "*.csv")
    cv_image = [row for row in cv_image if "elapsed_sec" in row]
    require(len(cv_rows) == 960, f"expected 960 ordinary CV rows, found {len(cv_rows)}", failures)
    require(len(cv_image) == 16, f"expected 16 ImageNet CV rows, found {len(cv_image)}", failures)
    require_no_skips(cv_rows + cv_image, "cross-validation benchmark", failures)

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
    nmr_paths = rows(root / "results/component_paths/nmr_cpu_cuda.csv")
    require(
        {row.get("family") for row in nmr_paths} == FAMILIES,
        "NMR component-path family coverage is incomplete",
        failures,
    )
    selection = rows(
        root / "results/component_selection/ordinary/selected_components.csv"
    )
    require(
        {(row.get("dataset"), row.get("family")) for row in selection}
        == {(dataset, family) for dataset in DATASETS - {"nmr", "imagenet"}
            for family in FAMILIES},
        "training-only component-selection coverage is incomplete",
        failures,
    )
    for family in ("plssvd", "simpls"):
        decision = rows(
            root / f"results/component_selection/nmr_{family}/nmr_component_selection_decision.csv"
        )
        require(len(decision) == 1, f"missing NMR {family} selection decision", failures)
    for backend in ("cpu", "cuda"):
        rsvd = rows(
            root / f"results/validation/rsvd_qualification_{backend}/rsvd_qualification_raw.csv"
        )
        require(
            len(rsvd) == 174,
            f"expected 174 {backend} rSVD comparisons, found {len(rsvd)}",
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
        "selected_cpu_cuda": len(selected),
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
