#!/usr/bin/env python3

from pathlib import Path

import pandas as pd


ROOT = Path("/Users/stefano/Documents/GPUPLS/fastPLS_fresh_github")
BASE = ROOT / "benchmark_results" / "imagenet_faiss_matched_1m_20260725"
EVIDENCE = (
    ROOT
    / "benchmark_results"
    / "manuscript_revision_cycle13_20260725"
)


def read_peak(path):
    values = []
    if path.exists():
        for token in path.read_text().split():
            try:
                values.append(float(token))
            except ValueError:
                pass
    return max(values) if values else float("nan")


def base_rows():
    data = pd.read_csv(BASE / "imagenet_faiss_matched_summary.csv")
    data = data[
        data["feature_space"].isin(["pls_scores", "pca_scores"])
        & data["faiss_method"].eq("exact")
    ].copy()
    rows = []
    for _, row in data.iterrows():
        rows.append(
            {
                "representation": (
                    "PLS-SVD/rSVD" if row["feature_space"] == "pls_scores"
                    else "PCA-rSVD"
                ),
                "seed": 123,
                "n_features": int(row["n_features"]),
                "compression_ratio": row["compression_ratio"],
                "top1_accuracy": row["top1_accuracy"],
                "top5_accuracy": row["top5_accuracy"],
                "balanced_accuracy": row["balanced_accuracy"],
                "transformation_time_sec": row["transformation_time_sec"],
                "inference_time_sec": row["inference_time_median_sec"],
                "end_to_end_time_sec": row["end_to_end_time_median_sec"],
                "peak_host_rss_mb": row["peak_host_rss_mb"],
                "peak_gpu_mem_mb": row["peak_gpu_mem_mb"],
                "train_n": int(row["train_n"]),
                "eval_n": int(row["eval_n"]),
                "status": row["status"],
            }
        )
    return rows


def repeated_rows(seed):
    folder = EVIDENCE / f"imagenet_seed{seed}"
    rows = []
    for prefix, label in (("pls", "PLS-SVD/rSVD"), ("pca", "PCA-rSVD")):
        preparation_gpu = read_peak(folder / f"prepare_{prefix}_peak_gpu_mb.txt")
        for n_features in (50, 100, 200):
            path = folder / (
                f"{prefix}_n1000000_k{n_features}_eval281167_cuda_exact.csv"
            )
            row = pd.read_csv(path).iloc[0]
            query_gpu = read_peak(
                folder / f"{prefix}_k{n_features}_exact_peak_gpu_mb.txt"
            )
            rows.append(
                {
                    "representation": label,
                    "seed": seed,
                    "n_features": int(row["n_features"]),
                    "compression_ratio": row["compression_ratio"],
                    "top1_accuracy": row["top1_accuracy"],
                    "top5_accuracy": row["top5_accuracy"],
                    "balanced_accuracy": row["balanced_accuracy"],
                    "transformation_time_sec": row["transformation_time_sec"],
                    "inference_time_sec": row["inference_time_sec"],
                    "end_to_end_time_sec": row["end_to_end_time_sec"],
                    "peak_host_rss_mb": max(
                        row["preparation_peak_host_rss_mb"],
                        row["search_peak_host_rss_mb"],
                    ),
                    "peak_gpu_mem_mb": max(preparation_gpu, query_gpu),
                    "train_n": int(row["train_n"]),
                    "eval_n": int(row["eval_n"]),
                    "status": row["status"],
                }
            )
    return rows


def main():
    rows = base_rows()
    rows.extend(repeated_rows(456))
    rows.extend(repeated_rows(789))
    raw = pd.DataFrame(rows).sort_values(
        ["representation", "n_features", "seed"]
    )
    raw.to_csv(EVIDENCE / "imagenet_repeated_fit_summary.csv", index=False)

    aggregate = (
        raw.groupby(["representation", "n_features"], as_index=False)
        .agg(
            fits=("seed", "count"),
            top1_median=("top1_accuracy", "median"),
            top1_min=("top1_accuracy", "min"),
            top1_max=("top1_accuracy", "max"),
            top5_median=("top5_accuracy", "median"),
            top5_min=("top5_accuracy", "min"),
            top5_max=("top5_accuracy", "max"),
            transform_median_sec=("transformation_time_sec", "median"),
            inference_median_sec=("inference_time_sec", "median"),
            end_to_end_median_sec=("end_to_end_time_sec", "median"),
            host_rss_median_mb=("peak_host_rss_mb", "median"),
            gpu_mem_median_mb=("peak_gpu_mem_mb", "median"),
        )
        .sort_values(["representation", "n_features"])
    )
    aggregate.to_csv(
        EVIDENCE / "imagenet_repeated_fit_aggregate.csv", index=False
    )
    print(raw.to_string(index=False))
    print()
    print(aggregate.to_string(index=False))


if __name__ == "__main__":
    main()
