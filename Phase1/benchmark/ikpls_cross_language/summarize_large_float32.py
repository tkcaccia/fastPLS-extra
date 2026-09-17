#!/usr/bin/env python3

import argparse
import csv
from pathlib import Path


root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument(
    "results",
    type=Path,
)
parser.add_argument(
    "--fastpls-imagenet",
    type=Path,
    required=True,
)
args = parser.parse_args()
out = args.results
rows = []

fields = [
    "dataset",
    "implementation",
    "precision",
    "ncomp",
    "fit_sec",
    "predict_sec",
    "model_total_sec",
    "preprocess_sec",
    "total_including_preprocess_sec",
    "top1_accuracy",
    "top5_accuracy",
    "rmsd",
    "peak_process_rss_mib",
    "status",
    "notes",
]


def read_rows(path):
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def read_first(path):
    values = read_rows(path)
    if not values:
        raise SystemExit(f"No rows found in {path}")
    return values[0]


def number(row, name):
    value = row.get(name)
    return None if value in (None, "", "NA") else float(value)


preprocess = {}
with (out / "preprocessing.tsv").open(
    newline="", encoding="utf-8"
) as handle:
    for row in csv.reader(handle, delimiter="\t"):
        if len(row) >= 2:
            preprocess[row[0]] = row[1]
preprocess_sec = float(preprocess["preprocess_sec"])

for path in sorted(out.glob("imagenet_ikpls_f32_n*.csv")):
    row = read_first(path)
    total_sec = number(row, "total_sec")
    rows.append({
        "dataset": "ImageNet",
        "implementation": "IKPLS 6.1.2 cross-product",
        "precision": "float32",
        "ncomp": int(number(row, "ncomp")),
        "fit_sec": number(row, "fit_sec"),
        "predict_sec": number(row, "predict_sec"),
        "model_total_sec": total_sec,
        "preprocess_sec": preprocess_sec,
        "total_including_preprocess_sec": total_sec + preprocess_sec,
        "top1_accuracy": number(row, "top1_accuracy_or_rmsd"),
        "top5_accuracy": number(row, "top5_accuracy"),
        "rmsd": None,
        "peak_process_rss_mib": number(row, "peak_rss_mib"),
        "status": row["status"],
        "notes": (
            "IKPLS cross-product formulation; one CPU thread; centred "
            "float32 arrays; blocked prediction"
        ),
    })

if args.fastpls_imagenet.exists():
    fast = read_rows(args.fastpls_imagenet)
    input_fields = set(fast[0]) if fast else set()
    component_column = (
        "ncomp_requested" if "ncomp_requested" in input_fields else "ncomp"
    )
    prediction_column = (
        "top5_prediction_time_sec"
        if "top5_prediction_time_sec" in input_fields
        else "predict_time_sec"
    )
    rss_column = (
        "process_peak_rss_mb"
        if "process_peak_rss_mb" in input_fields
        else "rss_peak_predict_mb"
    )
    selected = [
        row for row in fast
        if row.get("classifier") == "argmax"
        and row.get("status") == "success"
        and int(number(row, component_column)) in {100, 200, 500, 1000}
    ]
    for row in selected:
        package_version = row.get("loaded_package_version", "0.99.39")
        rows.append({
            "dataset": "ImageNet",
            "implementation": (
                f"fastPLS {package_version} SIMPLS CUDA-rSVD argmax"
            ),
            "precision": "float32",
            "ncomp": int(number(row, component_column)),
            "fit_sec": number(row, "fit_time_sec"),
            "predict_sec": number(row, prediction_column),
            "model_total_sec": number(row, "total_time_sec"),
            "preprocess_sec": None,
            "total_including_preprocess_sec": number(row, "total_time_sec"),
            "top1_accuracy": number(row, "top1_accuracy"),
            "top5_accuracy": number(row, "top5_accuracy"),
            "rmsd": None,
            "peak_process_rss_mib": number(row, rss_column),
            "status": row["status"],
            "notes": (
                "One maximal 1000-component fit supplied all prefixes; timing "
                "is shared and is not a per-prefix refit"
            ),
        })

for path in sorted(out.glob("nmr_ikpls_f32_n*.csv")):
    row = read_first(path)
    rows.append({
        "dataset": "NMR",
        "implementation": "IKPLS 6.1.2 cross-product",
        "precision": "float32",
        "ncomp": int(number(row, "ncomp")),
        "fit_sec": number(row, "fit_sec"),
        "predict_sec": number(row, "predict_sec"),
        "model_total_sec": number(row, "total_sec"),
        "preprocess_sec": None,
        "total_including_preprocess_sec": number(row, "total_sec"),
        "top1_accuracy": None,
        "top5_accuracy": None,
        "rmsd": number(row, "top1_accuracy_or_rmsd"),
        "peak_process_rss_mib": number(row, "peak_rss_mib"),
        "status": row["status"],
        "notes": (
            row.get("error", "")
            if row["status"] != "success"
            else "First component collapsed under the IKPLS float32 stability criterion"
        ),
    })

if not rows:
    raise SystemExit(f"No benchmark rows found in {out}")
rows.sort(key=lambda row: (row["dataset"], row["implementation"], row["ncomp"]))
with (out / "ikpls_fastpls_large_float32_summary.csv").open(
    "w", newline="", encoding="utf-8"
) as handle:
    writer = csv.DictWriter(handle, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)

with (out / "README.md").open("w", encoding="utf-8") as handle:
    handle.write("# IKPLS large-case float32 benchmark\n\n")
    handle.write("IKPLS 6.1.2 NumPy cross-product was tested with one CPU thread. ")
    handle.write("ImageNet centring and dense centred one-hot construction took ")
    handle.write(
        f"{preprocess_sec:.2f} s and are reported separately from model timing.\n\n"
    )
    handle.write(
        "NMR at one component completed but collapsed to the training-mean "
        "prediction; five components failed under a 10 GiB virtual-memory guard. "
        "The selected 50-component NMR model would require 68.66 GiB for IKPLS's "
        "retained B tensor alone.\n\n"
    )
    handle.write(
        "ImageNet fastPLS timings come from one maximal 1000-component path, so "
        "the same fit and prediction time is attached to every prefix and is not "
        "a per-prefix refit comparison. IKPLS and fastPLS implement different PLS "
        "estimators.\n"
    )
