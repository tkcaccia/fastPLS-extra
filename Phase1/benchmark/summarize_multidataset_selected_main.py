#!/usr/bin/env python3

from pathlib import Path
import argparse

import numpy as np
import pandas as pd


METHOD_ORDER = ["plssvd", "simpls", "opls", "kernelpls"]
DATASET_ORDER = [
    "metref",
    "ccle",
    "tcga_brca",
    "tcga_hnsc_methylation",
    "gtex_v8",
    "tcga_pan_cancer",
    "singlecell",
    "cifar100",
    "cbmc_citeseq",
    "prism",
    "nmr",
    "imagenet",
]


def median_or_nan(values):
    values = pd.to_numeric(values, errors="coerce")
    return float(np.nanmedian(values)) if np.isfinite(values).any() else np.nan


def summarize_selected(raw):
    keys = [
        "dataset",
        "task_type",
        "method_panel",
        "variant_name",
        "engine",
        "backend",
        "classifier",
        "requested_ncomp",
        "effective_ncomp",
        "precision",
        "execution_precision",
        "metric_name",
    ]
    rows = []
    for key, group in raw.groupby(keys, dropna=False):
        rec = dict(zip(keys, key))
        ok = group[group["status"].eq("ok")]
        rec.update(
            n_repetitions=int(len(group)),
            n_success=int(len(ok)),
            metric_value=median_or_nan(ok["metric_value"]),
            total_time_sec=median_or_nan(ok["total_time_ms"]) / 1000,
            peak_host_rss_mb=median_or_nan(ok["peak_host_rss_mb"]),
            peak_gpu_mem_mb=median_or_nan(ok["peak_gpu_mem_mb"]),
            execution_status="ok" if len(ok) else "|".join(sorted(group["status"].dropna().unique())),
            comparison_scope="estimator_matched",
            selection_source="five_fold_training_cv",
            notes="CPU/CUDA rSVD comparison uses the same split, response, component count, and argmax/regression prediction rule.",
        )
        rows.append(rec)
    return pd.DataFrame(rows)


def add_nmr(rows, nmr_reference, nmr_simpls):
    for _, row in nmr_reference.iterrows():
        if not str(row["variant"]).startswith("fastpls_"):
            continue
        rows.append(
            {
                "dataset": "nmr",
                "task_type": "regression",
                "method_panel": "plssvd",
                "variant_name": row["variant"],
                "engine": str(row["backend"]).upper(),
                "backend": f'{row["backend"]}_{row["svd_method"]}',
                "classifier": "not_applicable",
                "requested_ncomp": 100,
                "effective_ncomp": 100,
                "precision": row["precision"],
                "execution_precision": row["precision"],
                "metric_name": "rmsd",
                "n_repetitions": int(row["n_repetitions"]),
                "n_success": int(row["n_repetitions"]),
                "metric_value": row["RMSD_median"],
                "total_time_sec": row["total_time_sec_median"],
                "peak_host_rss_mb": row["host_rss_mb_median"],
                "peak_gpu_mem_mb": row["gpu_peak_mb_median"],
                "execution_status": "ok",
                "comparison_scope": "estimator_matched",
                "selection_source": "five_repeated_training_splits",
                "notes": "NMR component count selected by the interior minimum of median training-only validation RMSD.",
            }
        )
    for _, row in nmr_simpls.iterrows():
        rows.append(
            {
                "dataset": "nmr",
                "task_type": "regression",
                "method_panel": "simpls",
                "variant_name": f'fastpls_simpls_{str(row["backend"]).lower()}_rsvd',
                "engine": row["backend"],
                "backend": f'{str(row["backend"]).lower()}_rsvd',
                "classifier": "not_applicable",
                "requested_ncomp": 100,
                "effective_ncomp": 100,
                "precision": "float64",
                "execution_precision": "float64",
                "metric_name": "rmsd",
                "n_repetitions": int(row["n_repetitions"]),
                "n_success": int(row["n_repetitions"]),
                "metric_value": row["RMSD_median"],
                "total_time_sec": row["total_time_sec_median"],
                "peak_host_rss_mb": row["host_rss_mb_median"],
                "peak_gpu_mem_mb": row["gpu_peak_mb_median"],
                "execution_status": "ok",
                "comparison_scope": "estimator_matched",
                "selection_source": "five_repeated_training_splits",
                "notes": "NMR component count selected by the interior minimum of median training-only validation RMSD.",
            }
        )
    for method in ("opls", "kernelpls"):
        rows.append(
            {
                "dataset": "nmr",
                "task_type": "regression",
                "method_panel": method,
                "variant_name": "",
                "engine": "",
                "backend": "",
                "classifier": "not_applicable",
                "requested_ncomp": 100,
                "effective_ncomp": np.nan,
                "precision": "float64",
                "execution_precision": "float64",
                "metric_name": "rmsd",
                "n_repetitions": 0,
                "n_success": 0,
                "metric_value": np.nan,
                "total_time_sec": np.nan,
                "peak_host_rss_mb": np.nan,
                "peak_gpu_mem_mb": np.nan,
                "execution_status": "not_run_nmr_protocol",
                "comparison_scope": "workflow_not_evaluated",
                "selection_source": "not_selected",
                "notes": "Not included in the prespecified NMR reference comparison.",
            }
        )


def add_imagenet(rows, imagenet):
    argmax = imagenet[
        imagenet["classifier"].eq("argmax")
        & imagenet["backend"].eq("cuda")
        & imagenet["status"].eq("ok")
    ].sort_values(["accuracy", "ncomp"], ascending=[False, True])
    if len(argmax):
        row = argmax.iloc[0]
        rows.append(
            {
                "dataset": "imagenet",
                "task_type": "classification",
                "method_panel": "simpls",
                "variant_name": "requested_cuda_simpls_rsvd_argmax",
                "engine": "CUDA",
                "backend": "cuda_rsvd",
                "classifier": "argmax",
                "requested_ncomp": int(row["ncomp"]),
                "effective_ncomp": int(row["ncomp"]),
                "precision": "float64",
                "execution_precision": "float64",
                "metric_name": "accuracy",
                "n_repetitions": 1,
                "n_success": 1,
                "metric_value": row["accuracy"],
                "total_time_sec": row["total_fit_predict_sec"],
                "peak_host_rss_mb": row["peak_host_rss_mb"],
                "peak_gpu_mem_mb": row["peak_gpu_compute_apps_mb"],
                "execution_status": "exploratory_single_run",
                "comparison_scope": "workflow_exploratory",
                "selection_source": "outer_grid_max_not_training_selected",
                "notes": "ImageNet is a scalability stress test. This point is not used as an unbiased estimator-selected comparison.",
            }
        )
    for method in ("plssvd", "opls", "kernelpls"):
        rows.append(
            {
                "dataset": "imagenet",
                "task_type": "classification",
                "method_panel": method,
                "variant_name": "",
                "engine": "",
                "backend": "",
                "classifier": "argmax",
                "requested_ncomp": np.nan,
                "effective_ncomp": np.nan,
                "precision": "float64",
                "execution_precision": "float64",
                "metric_name": "accuracy",
                "n_repetitions": 0,
                "n_success": 0,
                "metric_value": np.nan,
                "total_time_sec": np.nan,
                "peak_host_rss_mb": np.nan,
                "peak_gpu_mem_mb": np.nan,
                "execution_status": "not_run_full_scale",
                "comparison_scope": "workflow_not_evaluated",
                "selection_source": "not_selected",
                "notes": "No complete full-scale selected-point run was available for this model family.",
            }
        )


def choose_main_rows(summary):
    out = []
    for dataset in DATASET_ORDER:
        for method in METHOD_ORDER:
            group = summary[
                summary["dataset"].eq(dataset)
                & summary["method_panel"].eq(method)
            ]
            ok = group[group["n_success"].gt(0) & np.isfinite(group["total_time_sec"])]
            if len(ok):
                out.append(ok.sort_values("total_time_sec").iloc[0].to_dict())
            elif len(group):
                out.append(group.iloc[0].to_dict())
            else:
                out.append(
                    {
                        "dataset": dataset,
                        "method_panel": method,
                        "execution_status": "missing",
                        "comparison_scope": "not_evaluated",
                    }
                )
    return pd.DataFrame(out)


def make_wide(main):
    records = []
    for dataset in DATASET_ORDER:
        row = {"dataset": dataset}
        for method in METHOD_ORDER:
            hit = main[
                main["dataset"].eq(dataset)
                & main["method_panel"].eq(method)
            ].iloc[0]
            prefix = method
            for field in [
                "backend",
                "effective_ncomp",
                "metric_name",
                "metric_value",
                "total_time_sec",
                "peak_host_rss_mb",
                "peak_gpu_mem_mb",
                "execution_precision",
                "execution_status",
                "comparison_scope",
                "selection_source",
            ]:
                row[f"{prefix}_{field}"] = hit.get(field, np.nan)
        records.append(row)
    return pd.DataFrame(records)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True)
    parser.add_argument("--nmr-reference", required=True)
    parser.add_argument("--nmr-simpls", required=True)
    parser.add_argument("--imagenet", required=True)
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    raw = pd.read_csv(args.raw)
    summary = summarize_selected(raw)
    rows = summary.to_dict("records")
    add_nmr(rows, pd.read_csv(args.nmr_reference), pd.read_csv(args.nmr_simpls))
    add_imagenet(rows, pd.read_csv(args.imagenet))
    full = pd.DataFrame(rows)
    full["dataset"] = pd.Categorical(full["dataset"], DATASET_ORDER, ordered=True)
    full["method_panel"] = pd.Categorical(full["method_panel"], METHOD_ORDER, ordered=True)
    full = full.sort_values(["dataset", "method_panel", "total_time_sec"], na_position="last")
    main_rows = choose_main_rows(full)
    wide = make_wide(main_rows)

    full.to_csv(out_dir / "multidataset_selected_backend_summary.csv", index=False)
    main_rows.to_csv(out_dir / "multidataset_selected_main_rows.csv", index=False)
    wide.to_csv(out_dir / "multidataset_selected_main_wide.csv", index=False)


if __name__ == "__main__":
    main()
