#!/usr/bin/env python3
"""Assemble the six-panel Figure 1 table from immutable benchmark summaries."""

import argparse
import csv
from pathlib import Path


R_LABELS = {
    "pls_simpls_fit": ("pls / SIMPLS", "pls / SIMPLS"),
    "plsgenomics_pls_lda": ("plsgenomics / PLS-LDA", "plsgenomics / PLS regression"),
    "plsgenomics_pls_regression": ("plsgenomics / PLS-LDA", "plsgenomics / PLS regression"),
    "mdatools_plsda_or_pls": ("mdatools / PLS-DA", "mdatools / PLS"),
    "plsdepot_simpls": ("plsdepot / SIMPLS", "plsdepot / SIMPLS"),
    "pcv_simpls": ("pcv / SIMPLS", "pcv / SIMPLS"),
    "chemometrics_pls_eigen": ("chemometrics / PLS eigen", "chemometrics / PLS eigen"),
    "mixOmics_plsda": ("mixOmics / PLS-DA", "mixOmics / PLS"),
    "mixOmics_pls": ("mixOmics / PLS-DA", "mixOmics / PLS"),
    "spls_splsda": ("spls / sPLS-DA", "spls / sPLS"),
    "spls_spls": ("spls / sPLS-DA", "spls / sPLS"),
}
PYTHON_LABELS = {
    "sklearn_plsregression": "scikit-learn / PLSRegression",
}


def rows(path):
    if not path or not Path(path).is_file():
        return []
    with Path(path).open(newline="") as handle:
        return list(csv.DictReader(handle))


def normalized_dataset(value):
    key = value.lower().replace("/dinov2", "").replace("-", "_").replace(" ", "_")
    aliases = {
        "cifar_100": "cifar100",
        "tabula_muris": "tabula",
        "tcga_hnsc_methylation": "tcga_hnsc_methylation",
        "tcga_pan_cancer": "tcga_pan_cancer",
        "imagenet": "imagenet",
    }
    return aliases.get(key, key)


def base_row(dataset, task_type, implementation, source):
    return {
        "dataset": normalized_dataset(dataset),
        "task_type": task_type,
        "implementation": implementation,
        "source": source,
        "family": "",
        "classifier": "",
        "ncomp_requested": "",
        "ncomp": "",
        "status": "success",
        "accuracy": "",
        "balanced_accuracy": "",
        "rmsd": "",
        "q2": "",
        "total_sec": "",
        "peak_rss_mib": "",
        "repetitions": "",
        "precision": "",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fastpls", nargs="+", required=True)
    parser.add_argument("--fastpls-imagenet", nargs="*", default=[])
    parser.add_argument("--ikpls", required=True)
    parser.add_argument("--ikpls-large", nargs="*", default=[])
    parser.add_argument("--r-packages", required=True)
    parser.add_argument("--python", default="")
    parser.add_argument("--python-status", default="")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    assembled = []

    for path in args.fastpls:
        for value in rows(path):
            task = value["task_type"]
            family = value["method"]
            classifier = value.get("classifier", "")
            keep = family == "simpls" and (
                (task == "classification" and classifier == "lda") or
                task == "regression"
            )
            if not keep:
                continue
            label = "fastPLS SIMPLS"
            if task == "classification":
                label += " / LDA"
            row = base_row(value["dataset"], task, label, path)
            row.update({
                "family": family, "classifier": classifier,
                "ncomp_requested": value.get("ncomp_requested", value["ncomp"]),
                "ncomp": value["ncomp"], "status": "success",
                "accuracy": value.get("accuracy", ""),
                "balanced_accuracy": value.get("balanced_accuracy", ""),
                "rmsd": value.get("rmsd", ""), "q2": value.get("q2", ""),
                "total_sec": value.get("median_total_sec", ""),
                "peak_rss_mib": value.get("median_peak_rss_mib", ""),
                "repetitions": value.get("repetitions", ""),
                "precision": value.get("precision", ""),
            })
            assembled.append(row)

    for path in args.fastpls_imagenet:
        for value in rows(path):
            family = value.get("method", "simpls")
            classifier = value.get("classifier", "")
            if not classifier:
                classifier = (
                    "lda" if "LDA" in value.get("display", "") else "argmax"
                )
            if family != "simpls" or classifier != "lda":
                continue
            label = "fastPLS SIMPLS / LDA"
            row = base_row("imagenet", "classification", label, path)
            row.update({
                "family": family, "classifier": classifier,
                "ncomp_requested": value.get("ncomp_requested", "1000"),
                "ncomp": value.get("ncomp", ""),
                "status": value.get("status", "success"),
                "accuracy": value.get("accuracy", ""),
                "total_sec": value.get("time_sec", value.get("total_sec", "")),
                "peak_rss_mib": value.get("peak_rss_mib", ""),
                "repetitions": value.get("repetitions", "1"),
                "precision": value.get("precision", "float32"),
            })
            assembled.append(row)

    for value in rows(args.ikpls):
        row = base_row(value["dataset"], value["task_type"], "IKPLS", args.ikpls)
        row.update({
            "ncomp_requested": value.get("ncomp", ""),
            "ncomp": value.get("ncomp", ""), "accuracy": value.get("accuracy", ""),
            "balanced_accuracy": value.get("balanced_accuracy", ""),
            "rmsd": value.get("rmsd", ""), "q2": value.get("q2", ""),
            "total_sec": value.get("median_total_sec", ""),
            "peak_rss_mib": value.get("median_peak_rss_mib", ""),
            "repetitions": value.get("repetitions", ""),
            "precision": value.get("precision", "float32"),
        })
        assembled.append(row)

    for path in args.ikpls_large:
        for value in rows(path):
            dataset = normalized_dataset(value["dataset"])
            task = "regression" if dataset == "nmr" else "classification"
            row = base_row(dataset, task, "IKPLS", path)
            metric = value.get("top1_accuracy_or_rmsd", "")
            row.update({
                "ncomp_requested": value.get("ncomp", ""),
                "ncomp": value.get("ncomp", ""),
                "status": value.get("status", "success"),
                "accuracy": metric if task == "classification" else "",
                "rmsd": metric if task == "regression" else "",
                "total_sec": value.get("total_sec", ""),
                "peak_rss_mib": value.get("peak_rss_mib", ""),
                "repetitions": "1", "precision": value.get("precision", "float32"),
            })
            assembled.append(row)

    for value in rows(args.r_packages):
        method = value.get("method_id", "")
        if method not in R_LABELS:
            continue
        task = value["task_type"]
        label = R_LABELS[method][0 if task == "classification" else 1]
        row = base_row(value["dataset"], task, label, args.r_packages)
        row.update({
            "ncomp_requested": value.get("ncomp", ""),
            "ncomp": value.get("ncomp", ""), "status": value.get("status", ""),
            "accuracy": value.get("accuracy", ""),
            "balanced_accuracy": value.get("balanced_accuracy", ""),
            "rmsd": value.get("rmsd", ""), "q2": value.get("q2", ""),
            "total_sec": value.get("median_total_sec", ""),
            "peak_rss_mib": value.get("median_peak_rss_mib", ""),
            "repetitions": value.get("repetitions_completed", ""),
            "precision": value.get("execution_precision", "float64"),
        })
        assembled.append(row)

    successful_python = set()
    for value in rows(args.python):
        implementation = value.get("implementation", "")
        if implementation not in PYTHON_LABELS:
            continue
        task = value["task_type"]
        dataset = normalized_dataset(value["dataset"])
        successful_python.add((dataset, implementation))
        row = base_row(dataset, task, PYTHON_LABELS[implementation], args.python)
        row.update({
            "ncomp_requested": value.get("ncomp", ""),
            "ncomp": value.get("ncomp", ""), "accuracy": value.get("accuracy", ""),
            "balanced_accuracy": value.get("balanced_accuracy", ""),
            "rmsd": value.get("rmsd", ""), "q2": value.get("q2", ""),
            "total_sec": value.get("median_total_sec", ""),
            "peak_rss_mib": value.get("median_peak_rss_mib", ""),
            "repetitions": value.get("repetitions", ""),
            "precision": value.get("precision", ""),
        })
        assembled.append(row)
    failed_python = {}
    status_priority = {
        "timeout": 4,
        "failed": 3,
        "not_repeated_after_failure": 2,
        "not_repeated_long_runtime": 1,
    }
    for value in rows(args.python_status):
        implementation = value.get("implementation", "")
        dataset = normalized_dataset(value.get("dataset", ""))
        key = (dataset, implementation)
        if implementation not in PYTHON_LABELS or key in successful_python:
            continue
        current = failed_python.get(key)
        candidate_priority = status_priority.get(value.get("status", ""), 0)
        current_priority = status_priority.get(
            current.get("status", "") if current else "", 0
        )
        if current is None or candidate_priority > current_priority:
            failed_python[key] = value
    for (dataset, implementation), value in sorted(failed_python.items()):
        task = "regression" if dataset in {"cbmc_citeseq", "prism", "nmr"} else "classification"
        row = base_row(dataset, task, PYTHON_LABELS[implementation], args.python_status)
        row.update({"status": value.get("status", "failed")})
        assembled.append(row)

    deduplicated = {}
    for row in assembled:
        key = (row["dataset"], row["task_type"], row["implementation"])
        if key in deduplicated:
            raise RuntimeError(f"duplicate Figure 1 row: {key}")
        deduplicated[key] = row
    final = list(deduplicated.values())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(final[0]))
        writer.writeheader()
        writer.writerows(final)


if __name__ == "__main__":
    main()
