#!/usr/bin/env python3
"""Join candidate measurements with stored rows, never rerunning a baseline."""

import argparse
import csv
import json
import math
from pathlib import Path


def read(path):
    if isinstance(path, (list, tuple)):
        return [row for item in path for row in read(item)]
    if not path.is_file():
        return []
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError):
        return None


def canonical(value):
    if value in (None, "", "NA", "nan"):
        return ""
    numeric = number(value)
    return str(numeric) if numeric is not None else str(value).lower()


def join(candidate, baseline, keys, metrics, timing, context, time_comparable=True,
         metric_comparable=True):
    for label, rows in (("candidate", candidate), ("frozen", baseline)):
        missing = {field for row in rows for field in keys if field not in row}
        if missing:
            raise ValueError(f"Missing {label} comparison keys: {sorted(missing)}")
    index = {}
    for row in baseline:
        key = tuple(canonical(row.get(k)) for k in keys)
        index.setdefault(key, []).append(row)
    output = []
    for row in candidate:
        key = tuple(canonical(row.get(k)) for k in keys)
        matches = index.get(key, [])
        result = {k: row.get(k, "") for k in keys}
        result["comparison_context"] = context
        result["timing_comparable"] = time_comparable
        result["metric_comparable"] = metric_comparable
        result["candidate_status"] = row.get("status", "success")
        result["baseline_status"] = ""
        result["match_status"] = "matched" if len(matches) == 1 else (
            "missing_frozen_row" if not matches else "ambiguous_frozen_rows"
        )
        if len(matches) == 1:
            old = matches[0]
            result["baseline_status"] = old.get("status", "success")
            valid = all(result[k] in ("success", "ok", "passed", "")
                        for k in ("candidate_status", "baseline_status"))
            for field in (*metrics, *timing):
                new_value, old_value = number(row.get(field)), number(old.get(field))
                result["candidate_" + field] = new_value
                result["frozen_" + field] = old_value
                if valid and new_value is not None and old_value is not None:
                    if field in timing:
                        result["frozen_over_candidate_" + field] = (
                            old_value / new_value if new_value > 0 and time_comparable else None
                        )
                    elif metric_comparable:
                        result["difference_" + field] = new_value - old_value
            # A checksum is not a substitute for paired prediction agreement.
            result["prediction_agreement_status"] = "not_established_by_aggregate_metrics"
        output.append(result)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--accelerator", required=True, choices=("cuda", "metal"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--nmr-selection", type=Path,
                        help="Current corrected selection directory containing nmr_selection_FAMILY")
    args = parser.parse_args()
    root, old = args.candidate.resolve(), args.baseline.resolve()
    output = args.output.resolve()
    if output == old or old in output.parents:
        raise RuntimeError("Comparison output must not overwrite the frozen baseline")
    args.output.mkdir(parents=True, exist_ok=True)
    panels = []
    selection_path = root / "component_selection/component_selection_summary.csv"
    if not selection_path.exists():
        selection_path = root / "component_selection/component_selection_progress.csv"
    panels.append((
        "component_selection", selection_path,
        old / "component_selection/component_selection_summary.csv",
        ("dataset", "family", "task_type", "selection_metric", "grid_min", "grid_max",
         "intrinsic_limit", "kfold", "seed", "oversample", "power", "n_train", "p", "q"),
        ("selected_ncomp", "selected_metric"), (),
        "Numerical selection comparison only; stored selection host may differ",
    ))
    accelerator = args.accelerator
    backend_keys = ("dataset", "task_type", "method", "backend_requested", "svd_method",
                    "classifier", "precision", "ncomp", "n_train", "n_test", "p", "q",
                    "seed", "replicate", "requested_oversample", "requested_power",
                    "oversample", "power", "kernel", "north")
    panels.append((
        "selected_backend", root / f"selected_backend/matched_{accelerator}_raw.csv",
        old / f"selected_backend_{accelerator}/matched_{accelerator}_raw.csv",
        backend_keys, ("metric_value", "accuracy", "q2", "rmsd", "peak_rss_mb"),
        ("fit_sec", "prediction_sec", "total_sec"),
        "Same requested workflow and host panel; CPU BLAS/build changes remain part of the comparison",
    ))
    cv_keys = ("dataset", "task_type", "n", "p", "q", "method", "backend", "svd_method",
               "classifier", "ncomp", "kfold", "replicate", "oversample", "power", "seed")
    cv_directory = "cv_compiled_vs_r_loop_local" if accelerator == "metal" else "cv_compiled_vs_r_loop"
    panels.append((
        "cross_validation", root / "cv_compiled_vs_r_loop/cv_compiled_vs_r_loop_raw.csv",
        old / cv_directory / "cv_compiled_vs_r_loop_raw.csv", cv_keys,
        ("compiled_metric", "r_loop_metric", "prediction_agreement", "prediction_relative_error"),
        ("compiled_sec", "r_loop_sec"), "Matched protocol; inspect BLAS/build metadata before attributing speedup",
    ))
    panels.append((
        "component_paths", root / "component_paths/component_path_raw.csv",
        old / f"component_path_{accelerator}/component_path_raw.csv", backend_keys,
        ("metric_value", "accuracy", "q2", "rmsd", "baseline_rss_mb",
         "peak_rss_mb", "incremental_peak_rss_mb"),
        ("fit_sec", "prediction_sec", "total_sec"),
        "Matched per-component workflow; retain errors and inspect CPU BLAS differences",
    ))
    for backend in ("cpu", accelerator):
        panels.append((
            f"float32_{backend}", sorted((root / f"float32_{backend}").glob("*.csv")),
            sorted((old / f"float32_{backend}").glob("*.csv")),
            ("dataset", "task_type", "method", "classifier", "kernel", "backend",
             "n_train", "n_test", "p", "ncomp", "oversample", "power"),
            ("float64_metric", "float32_metric", "prediction_agreement", "relative_prediction_error"),
            ("float64_time_sec", "float32_time_sec"),
            "Within-run precision agreement is not candidate-versus-frozen prediction agreement; CPU host may differ",
            backend != "cpu",
        ))
    panels.append((
        "controlled_scaling", root / "controlled_scaling/controlled_scaling_raw.csv",
        old / ("controlled_scaling_cpu_metal" if accelerator == "metal" else
               "controlled_scaling_cuda_qualification") / "controlled_scaling_raw.csv",
        ("scenario_id", "task_type", "method", "route", "backend", "svd_method",
         "xprod_requested", "precision", "n_train", "n_test", "p", "q", "class_count",
         "latent_rank", "max_ncomp", "requested_prefixes", "replicate", "data_seed",
         "fit_seed", "oversample", "power"),
        ("rmsd", "q2", "accuracy", "prediction_relative_error", "label_agreement",
         "metric_absolute_difference", "baseline_rss_mb", "process_peak_rss_mb",
         "incremental_peak_rss_mb", "gpu_process_peak_mb", "gpu_total_incremental_mb"),
        ("fit_sec", "prediction_sec", "total_sec"),
        "Same dimensions and controls; record numerical failures independently of runtime",
    ))
    panels.append((
        "matched_shapes", root / "matched_shapes/simpls_vs_plssvd_shapes_raw.csv",
        old / "simpls_vs_plssvd_shapes/simpls_vs_plssvd_shapes_raw.csv", backend_keys,
        ("metric_value", "accuracy", "q2", "rmsd", "baseline_rss_mb",
         "peak_rss_mb", "incremental_peak_rss_mb"),
        ("fit_sec", "prediction_sec", "total_sec"),
        "Five-shape workflow; stored CPU/CUDA host does not establish matched Mac timing",
        accelerator == "cuda",
    ))
    panels.append((
        "simpls_ablation", root / "simpls_ablation/simpls_multidataset_ablation_raw.csv",
        old / "simpls_ablation/simpls_multidataset_ablation_raw.csv",
        ("dataset", "task_type", "n_train", "n_test", "p", "q", "ncomp", "method",
         "backend", "svd_method", "pair", "configuration", "optimized_value", "xprod", "replicate"),
        ("metric_value", "prediction_agreement", "max_abs_prediction_diff",
         "rss_before_fit_mb", "fit_window_peak_rss_mb", "incremental_peak_rss_mb"),
        ("fit_time_sec", "predict_time_sec", "total_time_sec"),
        "Ablation configurations are explicit; stored workstation CPU timing is not matched to Mac",
        accelerator == "cuda",
    ))
    panels.append((
        "simpls_exact", root / "simpls_exact/simpls_exact_reference_case_summary.csv",
        old / "simpls_exact/simpls_exact_reference_case_summary.csv",
        ("case", "condition", "task_type", "component_prefixes"),
        ("max_coefficient_relative_error", "max_fitted_value_relative_error",
         "max_prediction_relative_error", "max_score_subspace_angle_degrees",
         "max_loading_subspace_angle_degrees", "max_projection_subspace_angle_degrees",
         "max_score_orthogonality_residual", "max_deflation_basis_orthogonality_residual",
         "max_deflation_residual", "min_classification_label_agreement", "convergence_failures"), (),
        "Each run uses its own dense LAPACK oracle; error differences are not cross-run predictions",
    ))
    for dataset in ("metref", "gtex_v8", "retina", "nmr"):
        path = Path("repeated_outer") / dataset / "repeated_outer_raw.csv"
        panels.append((
            f"repeated_outer_{dataset}", root / path, old / path,
            ("dataset", "method", "classifier", "backend", "svd_method", "outer_index",
             "outer_seed", "n_total", "n_outer_train", "n_outer_test", "p", "q",
             "inner_kfold", "component_grid"),
            ("selected_ncomp", "metric_value", "accuracy", "RMSD", "Q2"),
            ("selection_time_sec", "final_fit_prediction_time_sec", "total_time_sec"),
            "Matched saved partition protocol; cross-host times are descriptive only", False,
        ))
    panels.append((
        "multicore_scaling", root / "multicore_scaling/multicore_scaling_raw.csv",
        old / "multicore_scaling/multicore_scaling_raw.csv",
        ("workload", "task", "method", "svd_method", "precision", "requested_cores",
         "active_openblas_threads", "replicate", "n_train", "n_test", "p", "q", "ncomp",
         "rsvd_oversample", "rsvd_power", "seed"),
        ("metric_value",), ("elapsed_sec",),
        "Stored multicore panel used Mac OpenBLAS; Linux results are an additional capability study",
        accelerator == "metal",
    ))
    nmr_keys = ("dataset", "input_sha256", "protocol_version", "canonical_input_verified",
                "water_columns_masked", "response_columns_scored", "family", "backend",
                "solver", "precision", "ncomp", "oversample", "power", "seed", "replicate")
    for family in ("plssvd", "simpls"):
        panels.append((
            f"nmr_selection_{family}",
            (args.nmr_selection / f"nmr_selection_{family}/nmr_component_selection_raw.csv"
             if args.nmr_selection else
             root / f"nmr/selection_{family}/nmr_component_selection_raw.csv"),
            old / f"nmr/selection_{family}/nmr_component_selection_raw.csv",
            ("split", "split_seed", "ncomp"), ("RMSD", "MAE", "Q2"),
            ("fit_time_sec", "score_time_sec"),
            ("Stored PLS-SVD selection used scores times Q-transpose without latent "
             "regression coefficients; neither accuracy nor selection timing is comparable"
             if family == "plssvd" else
             "Stored selection is CUDA; grid/output changes prevent a selection timing ratio"),
            False, family != "plssvd",
        ))
        for backend, solver in (("cpu", "irlba"), ("cpu", "rsvd"), (accelerator, "rsvd")):
            for components in sorted({5 if family == "plssvd" else 50, 50, 165}):
                label = f"nmr_{family}_{backend}_{solver}_{components}"
                prefix = "selected" if components == 5 else f"fixed{components}"
                saved = old / "nmr" / f"{prefix}_{family}_{backend}_{solver}_k{components}.csv"
                panels.append((
                    label, root / "nmr" / f"{label}.csv", saved, nmr_keys,
                    ("RMSD", "Q2", "MAE", "median_sample_RMSD", "p95_sample_RMSD",
                     "baseline_rss_mb", "after_fit_rss_mb"),
                    ("fit_time_sec", "predict_time_sec", "total_time_sec"),
                    "Masked-predictor NMR protocol, unchanged responses; local CPU times are not matched to Linux",
                    accelerator == "cuda" or backend == "metal",
                ))
    if accelerator == "cuda":
        panels.extend([
            ("external_simpls", root / "external_simpls/external_simpls_timing_raw.csv",
             old / "external_simpls/external_simpls_timing_raw.csv",
             ("dataset", "comparison_profile", "implementation", "estimator", "solver",
              "precision", "output_contract", "timing_mode", "measurement_scope",
              "phase_timing_enabled", "batch_iterations", "iteration", "split_seed",
              "replicate", "n_train", "n_test", "p", "q", "ncomp", "requested_ncomp"),
             ("accuracy", "fit_object_mb", "prediction_object_mb", "prefit_process_rss_mb",
              "process_peak_rss_mb", "baseline_corrected_peak_increment_mb"),
             ("fit_sec", "prediction_sec", "total_sec", "preprocess_crosscov_sec", "estimator_sec",
              "coefficient_path_sec", "fitted_values_sec", "model_assembly_sec", "cpp_total_sec"),
             "Candidate fastPLS rows only; independent-package observations remain stored inputs"),
            ("r_package_panel", root / "r_package_panel/pls_package_comparison_raw.csv",
             old / "r_package_panel/pls_package_comparison_raw.csv",
             ("dataset", "task_type", "split_seed", "n_train", "n_test", "p", "n_response",
              "input_precision", "execution_precision", "classifier", "ncomp_requested",
              "replicate", "method_id", "package", "function_name", "algorithm"),
             ("metric_value", "accuracy", "balanced_accuracy", "rmse", "q2", "peak_host_rss_mb"),
             ("total_runtime_ms",), "Only current fastPLS is executed; external rows are never rerun"),
            ("cross_language", root / "cross_language_fastpls/ikpls_cross_language_summary.csv",
             old / "ikpls_cross_language_cpu/ikpls_cross_language_summary.csv",
             ("dataset", "implementation", "algorithm", "solver", "precision", "ncomp", "repetitions"),
             ("accuracy", "median_peak_rss_mb", "median_incremental_peak_rss_mb"),
             ("median_fit_sec", "median_prediction_sec", "median_total_sec"),
             "Prepared matched inputs; IKPLS is a stored comparator, not an executed candidate"),
            ("imagenet", root / "imagenet/imagenet_current_summary.csv",
             old / "imagenet/imagenet_current_summary.csv",
             ("dataset", "train_n", "test_n", "p", "q", "method", "solver", "backend",
              "classifier", "precision", "ncomp_requested", "oversample", "power", "seed", "replicate"),
             ("ncomp_effective", "top1_accuracy", "top5_accuracy", "balanced_accuracy", "macro_f1",
              "rss_before_fit_mb", "process_peak_rss_mb", "incremental_peak_rss_mb", "gpu_peak_mb"),
             ("fit_time_sec", "fit_predict_time_sec", "top5_prediction_time_sec", "total_time_sec"),
             "Exploratory shared-maximal-fit component path; not independent fits at each prefix"),
        ])
    summary = []
    for panel in panels:
        name, candidate_path, baseline_path, keys, metrics, timing, context = panel[:7]
        candidate_rows, frozen_rows = read(candidate_path), read(baseline_path)
        schema_error = None
        try:
            rows = join(candidate_rows, frozen_rows, keys, metrics, timing, context,
                        time_comparable=panel[7] if len(panel) > 7 else True,
                        metric_comparable=panel[8] if len(panel) > 8 else True)
        except ValueError as error:
            rows, schema_error = [], str(error)
        if rows:
            fields = list(dict.fromkeys(key for row in rows for key in row))
            with (args.output / (name + ".csv")).open("w", newline="") as handle:
                writer = csv.DictWriter(handle, fields)
                writer.writeheader()
                writer.writerows(rows)
        summary.append({"panel": name, "candidate_source": str(candidate_path),
                        "frozen_source": str(baseline_path), "candidate_rows": len(candidate_rows),
                        "frozen_rows": len(frozen_rows), "schema_error": schema_error,
                        "matched_rows": sum(row["match_status"] == "matched" for row in rows),
                        "scope": context})
    (args.output / "comparison_status.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
