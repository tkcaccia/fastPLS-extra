#!/usr/bin/env python3
"""Combine Linux/CUDA and macOS/Metal metric-concordance evidence."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path


ROUTE_LABELS = {
    ("linux", "cpu", "float64"): "Linux CPU float64",
    ("linux", "cpu", "float32"): "Linux CPU float32",
    ("linux", "cuda", "float64"): "CUDA float64",
    ("linux", "cuda", "float32"): "CUDA float32",
    ("mac", "cpu", "float64"): "Mac CPU float64",
    ("mac", "cpu", "float32"): "Mac CPU float32",
    ("mac", "metal", "float32"): "Metal float32",
}
ROUTE_ORDER = list(ROUTE_LABELS.values())

PAIRWISE_COMPARISONS = (
    ("Linux CPU float32", "Linux CPU float64", "Linux precision effect"),
    ("CUDA float64", "Linux CPU float64", "CUDA backend effect, float64"),
    ("CUDA float32", "Linux CPU float32", "CUDA backend effect, float32"),
    ("CUDA float32", "CUDA float64", "CUDA precision effect"),
    ("Mac CPU float32", "Mac CPU float64", "Mac precision effect"),
    ("Metal float32", "Mac CPU float32", "Metal backend effect, float32"),
    ("Mac CPU float64", "Linux CPU float64", "CPU platform effect, float64"),
    ("Mac CPU float32", "Linux CPU float32", "CPU platform effect, float32"),
)


def read_rows(path, platform):
    with Path(path).open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    for row in rows:
        row["platform"] = platform
        key = (platform, row["backend"], row["precision"])
        row["route_label"] = ROUTE_LABELS[key]
    return rows


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def write_csv(path, rows, fields=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        raise ValueError(f"No rows for {path}")
    fields = fields or list(rows[0])
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--linux", required=True)
    parser.add_argument("--mac", required=True)
    parser.add_argument("--mac-imagenet", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    rows = (
        read_rows(args.linux, "linux") +
        read_rows(args.mac, "mac") +
        read_rows(args.mac_imagenet, "mac")
    )
    output = Path(args.output_dir)
    write_csv(output / "precision_backend_metrics_long.csv", rows)

    grouped = defaultdict(dict)
    metadata = {}
    for row in rows:
        key = (row["dataset"], row["family"])
        grouped[key][row["route_label"]] = row
        metadata[key] = row

    matrix_rows = []
    comparison_rows = []
    for key in sorted(grouped):
        dataset, family = key
        available = grouped[key]
        baseline = available.get("Linux CPU float64")
        if baseline is None or baseline["status"] != "success":
            raise ValueError(f"Missing Linux CPU float64 baseline for {key}")
        baseline_metric = number(baseline["metric_value"])
        meta = metadata[key]
        matrix = {
            "dataset": dataset,
            "family": family,
            "ncomp": meta["ncomp"],
            "task_type": meta["task_type"],
            "metric_name": meta["metric_name"],
        }
        metric_changes = []
        for route in ROUTE_ORDER:
            row = available.get(route)
            field = route.lower().replace(" ", "_")
            matrix[field] = "" if row is None else row["metric_value"]
            if row is None or row["status"] != "success":
                continue
            metric = number(row["metric_value"])
            if meta["task_type"] == "classification":
                signed_change = metric - baseline_metric
                tolerance = 0.005
                display_change = 100 * signed_change
                display_unit = "percentage points"
                metric_concordant = abs(signed_change) <= tolerance
            else:
                signed_change = (metric - baseline_metric) / baseline_metric
                tolerance = 0.01
                display_change = 100 * signed_change
                display_unit = "percent"
                metric_concordant = abs(signed_change) <= tolerance
            metric_changes.append(abs(signed_change))
            comparison_rows.append({
                "dataset": dataset,
                "family": family,
                "ncomp": meta["ncomp"],
                "task_type": meta["task_type"],
                "metric_name": meta["metric_name"],
                "route": route,
                "reference_route": "Linux CPU float64",
                "reference_metric": baseline_metric,
                "metric_value": metric,
                "signed_metric_change": signed_change,
                "display_change": display_change,
                "display_unit": display_unit,
                "tolerance": tolerance,
                "tolerance_fraction": abs(signed_change) / tolerance,
                "metric_concordant": metric_concordant,
                "within_host_reference": row["reference_mode"],
                "within_host_label_agreement": row["label_agreement"],
                "within_host_relative_prediction_error":
                    row["relative_prediction_error"],
                "within_host_prediction_correlation":
                    row["prediction_correlation"],
                "oversample": row.get("oversample", ""),
                "power": row.get("power", ""),
                "seed": row.get("seed", ""),
                "control_profile": row.get("control_profile", ""),
                "execution_route": row["execution_route"],
                "status": row["status"],
            })
        if meta["task_type"] == "classification":
            matrix["maximum_change"] = max(metric_changes) if metric_changes else ""
            matrix["maximum_change_unit"] = "accuracy proportion"
            matrix["all_metrics_concordant"] = all(
                abs(change) <= 0.005 for change in metric_changes
            )
        else:
            matrix["maximum_change"] = max(metric_changes) if metric_changes else ""
            matrix["maximum_change_unit"] = "relative RMSD"
            matrix["all_metrics_concordant"] = all(
                abs(change) <= 0.01 for change in metric_changes
            )
        matrix_rows.append(matrix)

    write_csv(output / "precision_backend_metric_matrix.csv", matrix_rows)
    write_csv(output / "precision_backend_metric_comparisons.csv", comparison_rows)

    summary_rows = []
    for route in ROUTE_ORDER:
        for task_type in ("classification", "regression"):
            current = [
                row for row in comparison_rows
                if row["route"] == route and row["task_type"] == task_type
            ]
            if not current:
                continue
            changes = [abs(float(row["signed_metric_change"])) for row in current]
            summary_rows.append({
                "route": route,
                "task_type": task_type,
                "comparisons": len(current),
                "maximum_absolute_accuracy_difference":
                    max(changes) if task_type == "classification" else "",
                "maximum_relative_RMSD_difference":
                    max(changes) if task_type == "regression" else "",
                "metric_tolerance_failures": sum(
                    row["metric_concordant"] is False for row in current
                ),
            })
    write_csv(output / "precision_backend_route_summary.csv", summary_rows)

    pairwise_rows = []
    pairwise_summary = []
    for candidate_route, reference_route, contrast in PAIRWISE_COMPARISONS:
        for key in sorted(grouped):
            dataset, family = key
            available = grouped[key]
            candidate = available.get(candidate_route)
            reference = available.get(reference_route)
            if candidate is None or reference is None:
                continue
            if candidate["status"] != "success" or reference["status"] != "success":
                continue
            candidate_metric = number(candidate["metric_value"])
            reference_metric = number(reference["metric_value"])
            task_type = candidate["task_type"]
            if task_type == "classification":
                signed_change = candidate_metric - reference_metric
                tolerance = 0.005
                display_change = 100 * signed_change
                display_unit = "percentage points"
            else:
                signed_change = (
                    (candidate_metric - reference_metric) / reference_metric
                )
                tolerance = 0.01
                display_change = 100 * signed_change
                display_unit = "percent"
            pairwise_rows.append({
                "contrast": contrast,
                "dataset": dataset,
                "family": family,
                "ncomp": candidate["ncomp"],
                "task_type": task_type,
                "metric_name": candidate["metric_name"],
                "candidate_route": candidate_route,
                "reference_route": reference_route,
                "candidate_metric": candidate_metric,
                "reference_metric": reference_metric,
                "signed_metric_change": signed_change,
                "display_change": display_change,
                "display_unit": display_unit,
                "tolerance": tolerance,
                "metric_concordant": abs(signed_change) <= tolerance,
            })
    write_csv(output / "precision_backend_pairwise_comparisons.csv", pairwise_rows)

    for candidate_route, reference_route, contrast in PAIRWISE_COMPARISONS:
        for task_type in ("classification", "regression"):
            current = [
                row for row in pairwise_rows
                if row["contrast"] == contrast and row["task_type"] == task_type
            ]
            if not current:
                continue
            changes = [abs(float(row["signed_metric_change"])) for row in current]
            pairwise_summary.append({
                "contrast": contrast,
                "candidate_route": candidate_route,
                "reference_route": reference_route,
                "task_type": task_type,
                "comparisons": len(current),
                "maximum_absolute_accuracy_difference":
                    max(changes) if task_type == "classification" else "",
                "maximum_relative_RMSD_difference":
                    max(changes) if task_type == "regression" else "",
                "metric_tolerance_failures": sum(
                    row["metric_concordant"] is False for row in current
                ),
            })
    write_csv(output / "precision_backend_pairwise_summary.csv", pairwise_summary)

    exceptions = [row for row in comparison_rows if row["metric_concordant"] is False]
    if exceptions:
        write_csv(output / "precision_backend_metric_exceptions.csv", exceptions)


if __name__ == "__main__":
    main()
