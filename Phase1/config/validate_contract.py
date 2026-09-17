#!/usr/bin/env python3
"""Validate the CMPB component contract and update its derived inputs."""

import csv
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(__file__).with_name("cmpb_component_contract.csv")
FIGURE1 = ROOT / "benchmark/current_release_evidence/figure1_component_contract.csv"
CV = ROOT / "benchmark/gpu_cross_validation/selected_component_contract.csv"
FAMILIES = ("plssvd", "simpls", "opls", "kernelpls")
GRID_MAXIMUM = {
    "ccle": 100,
    "cifar100": 300,
    "gtex_v8": 200,
    "metref": 150,
    "retina": 50,
    "tabula": 50,
    "tcga_brca": 50,
    "tcga_hnsc_methylation": 42,
    "tcga_pan_cancer": 200,
    "cbmc_citeseq": 100,
    "prism": 100,
    "nmr": 300,
    "imagenet": 1000,
}


def read_rows(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def write_rows(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main():
    rows = read_rows(SOURCE)
    required = {
        "dataset", "task_type", "external_ncomp", "include_external",
        *(f"{family}_ncomp" for family in FAMILIES),
    }
    if not rows or not required.issubset(rows[0]):
        raise SystemExit("component contract has an incompatible schema")
    datasets = [row["dataset"] for row in rows]
    if len(datasets) != len(set(datasets)):
        raise SystemExit("component contract contains duplicate datasets")
    if set(datasets) != set(GRID_MAXIMUM):
        raise SystemExit("component contract and grid definitions differ")
    for row in rows:
        if row["task_type"] not in {"classification", "regression"}:
            raise SystemExit(f"invalid task type for {row['dataset']}")
        for field in ["external_ncomp", *(f"{x}_ncomp" for x in FAMILIES)]:
            if int(row[field]) < 1:
                raise SystemExit(f"invalid {field} for {row['dataset']}")
        if row["include_external"] not in {"yes", "no"}:
            raise SystemExit(f"invalid include_external for {row['dataset']}")

    figure_fields = [
        "dataset", "task_type", "plssvd_ncomp", "simpls_ncomp",
        "opls_ncomp", "kernelpls_ncomp", "external_ncomp",
        "include_external",
    ]
    write_rows(FIGURE1, rows, figure_fields)
    long_rows = []
    for row in rows:
        for family in FAMILIES:
            long_rows.append({
                "dataset": row["dataset"],
                "task_type": row["task_type"],
                "family": family,
                "selected_ncomp": row[f"{family}_ncomp"],
                "grid_max": GRID_MAXIMUM[row["dataset"]],
                "status": "success",
            })
    write_rows(
        CV, long_rows,
        [
            "dataset", "task_type", "family", "selected_ncomp",
            "grid_max", "status",
        ],
    )
    print(f"validated {len(rows)} datasets and {len(long_rows)} family rows")


if __name__ == "__main__":
    main()
