#!/usr/bin/env python3
"""Compare candidate numerical replays locally, without executing any model."""

import argparse
import csv
import json
from pathlib import Path

from compare_candidate import canonical, number, read


def aggregate_folds(rows, keys, expected_folds=5):
    grouped = {}
    for row in rows:
        key = tuple(canonical(row[k]) for k in keys)
        grouped.setdefault(key, []).append(row)
    curves = []
    for group in grouped.values():
        record = {key: group[0][key] for key in keys}
        values = [number(row.get("candidate_metric")) for row in group]
        complete = (len(group) == expected_folds and
                    {number(row.get("fold")) for row in group} == set(range(1, expected_folds + 1)) and
                    all(row.get("status") == "success" for row in group) and
                    all(value is not None for value in values))
        record.update(candidate_cv_metric=sum(values) / expected_folds if complete else None,
                      status="success" if complete else "error",
                      error="" if complete else "Missing, duplicate, failed, or nonfinite folds")
        curves.append(record)
    return curves


def write_rows(path, rows):
    if not rows:
        return
    fields = list(dict.fromkeys(key for row in rows for key in row))
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fields)
        writer.writeheader()
        writer.writerows(rows)


def compare(candidate, baseline, keys, current_metric, frozen_metric, external_metric=None):
    for label, rows in (("candidate", candidate), ("stored", baseline)):
        missing = {key for row in rows for key in keys if key not in row}
        if missing:
            raise ValueError(f"Missing {label} protocol fields: {sorted(missing)}")
    index = {}
    for row in baseline:
        key = tuple(canonical(row[k]) for k in keys)
        index.setdefault(key, []).append(row)
    output = []
    for row in candidate:
        key = tuple(canonical(row[k]) for k in keys)
        matches = index.get(key, [])
        result = {k: row[k] for k in keys}
        result.update(candidate_status=row.get("status", row.get("complete", "")),
                      candidate_error=row.get("error", ""),
                      candidate_value=number(row.get(current_metric)),
                      frozen_value=None, stored_external_value=None,
                      candidate_minus_frozen=None, candidate_minus_stored_external=None,
                      match_status="matched" if len(matches) == 1 else
                      "missing_stored_row" if not matches else "ambiguous_stored_rows",
                      prediction_agreement="not_recomputed; reference vectors unavailable",
                      reference_execution="none")
        if len(matches) == 1:
            old = matches[0]
            result["frozen_status"] = old.get("status", "")
            result["frozen_value"] = number(old.get(frozen_metric))
            result["stored_external_value"] = number(old.get(external_metric)) if external_metric else None
            for name in ("frozen", "stored_external"):
                current, previous = result["candidate_value"], result[name + "_value"]
                if current is not None and previous is not None:
                    result["candidate_minus_" + name] = current - previous
        output.append(result)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--opls-kernel", type=Path)
    parser.add_argument("--simpls", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    baseline, output = args.baseline.resolve(), args.out.resolve()
    if baseline == output or baseline in output.parents:
        raise RuntimeError("Do not overwrite the stored baseline")
    output.mkdir(parents=True, exist_ok=True)
    panels = []
    if args.opls_kernel:
        root = args.opls_kernel
        old = baseline / "opls_kernel_settings"
        keys = ("case", "family", "setting")
        panels.extend([
            ("opls_kernel_endpoints", root / "endpoint_replay.csv",
             old / "opls_kernel_setting_reliability_raw.csv", (*keys, "task", "ncomp"),
             "candidate_metric", "fast_metric", "reference_metric"),
            ("opls_kernel_folds", root / "fold_replay.csv",
             old / "opls_kernel_setting_selection_fold_raw.csv", (*keys, "component", "fold"),
             "candidate_metric", "fast_metric", "reference_metric"),
            ("opls_kernel_selection", root / "selection_replay.csv",
             old / "opls_kernel_setting_selection_summary.csv", keys,
             "candidate_selected", "fast_selected_ncomp", "reference_selected_ncomp"),
        ])
    if args.simpls:
        root = args.simpls
        old = baseline / "simpls_preservation"
        keys = ("dataset", "seed", "solver", "randomized_seed")
        curve_keys = (*keys, "ncomp", "rsvd_oversample", "rsvd_power")
        curves = aggregate_folds(read(root / "fold_replay.csv"), curve_keys)
        curve_path = output / "simpls_candidate_cv_curves.csv"
        write_rows(curve_path, curves)
        panels.extend([
            ("simpls_endpoints", root / "endpoint_replay.csv",
             old / "simpls_estimator_preservation_all_endpoints.csv",
             (*keys, "ncomp", "n_train", "n_test", "p", "q", "rsvd_oversample", "rsvd_power"),
             "candidate_metric", "fastpls_metric", "reference_metric"),
            ("simpls_cv_curves", curve_path,
             old / "simpls_estimator_preservation_cv_curves.csv", curve_keys,
             "candidate_cv_metric", "fastpls_cv_metric", "reference_cv_metric"),
            ("simpls_selection", root / "selection_replay.csv",
             old / "simpls_estimator_preservation_cv_selection.csv", keys,
             "candidate_selected", "fastpls_selected_ncomp", "reference_selected_ncomp"),
        ])
    summaries = []
    for name, path, stored, keys, metric, previous, external in panels:
        current_rows, old_rows = read(path), read(stored)
        rows = compare(current_rows, old_rows, keys, metric, previous, external)
        write_rows(output / (name + ".csv"), rows)
        differences = [abs(row["candidate_minus_frozen"]) for row in rows
                       if row["candidate_minus_frozen"] is not None]
        summaries.append({"panel": name, "candidate_rows": len(rows), "stored_rows": len(old_rows),
                          "matched": sum(row["match_status"] == "matched" for row in rows),
                          "finite_comparisons": len(differences),
                          "candidate_failed_rows": sum(row["candidate_status"] in ("error", "failed", "FALSE") for row in rows),
                          "maximum_metric_or_component_difference": max(differences, default=None),
                          "different_values_above_1e_10": sum(x > 1e-10 for x in differences),
                          "candidate_source": str(path), "stored_source": str(stored),
                          "scope": "metrics/components only; no new reference predictions or timing comparison"})
    (output / "comparison_summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
    print(json.dumps(summaries, indent=2))


if __name__ == "__main__":
    main()
