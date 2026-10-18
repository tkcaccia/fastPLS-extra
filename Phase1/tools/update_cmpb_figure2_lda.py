#!/usr/bin/env python3
"""Update CMPB Figure 2, its quantitative text, and Tables S5-S6."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from statistics import median

from docx import Document

from assemble_cmpb_documents import (
    TABLE_SPECS,
    build_table,
    paragraph_starting,
    read_csv,
    replace_caption,
    replace_picture_before_caption,
    replace_table_after_caption,
    usable_width,
)


def replace_started(document, prefix: str, text: str) -> None:
    replace_caption(paragraph_starting(document, prefix), text)


def successful_routes(facts: dict) -> list[dict]:
    return [
        row for row in facts["figure2"]["cpu_cuda_routes"]
        if row.get("status_cpu") == row.get("status_accelerator") == "success"
    ]


def ratio_range(routes: list[dict], dataset: str) -> str:
    values = [
        float(row["runtime_ratio"]) for row in routes
        if row["dataset"] == dataset
    ]
    if not values:
        raise RuntimeError(f"No CPU/CUDA routes found for {dataset}")
    return f"{min(values):.2f}-{max(values):.2f}-fold"


def update_main(document, assets: Path, facts: dict) -> None:
    figure2 = facts["figure2"]
    routes = successful_routes(facts)
    faster = [row for row in routes if float(row["runtime_ratio"]) > 1]

    replace_started(
        document,
        "CUDA acceleration was strongly dependent",
        "CUDA acceleration depended strongly on workload size (Figure 2A). "
        "All classification routes used LDA. For most small and medium datasets, "
        "initialization, transfer and synchronization outweighed GPU computation, "
        "and the CPU was faster. Clear gains emerged for the largest workloads: "
        f"CUDA was {ratio_range(routes, 'imagenet')} faster on ImageNet and "
        f"{ratio_range(routes, 'nmr')} faster on NMR across the four PLS families. "
        f"The gains were smaller on CIFAR-100 ({ratio_range(routes, 'cifar100')}) "
        "and mixed on PRISM, where SIMPLS-family, OPLS and kernel PLS were "
        "3.17-3.78-fold faster on CUDA but PLS-SVD remained CPU-favourable. "
        f"Overall, CUDA reduced fitting-and-prediction time in {len(faster)} of "
        f"{len(routes)} dataset-family combinations. Ratios below one indicate "
        "faster CPU execution."
    )

    cv = figure2["cv_over_fit_prediction"]
    cuda_opls = {
        row["dataset"]: float(row["cv_over_fit_predict"])
        for row in figure2["cross_validation_routes"]
        if row.get("backend") == "cuda" and row.get("method") == "opls"
        and row.get("status_cv") == "success"
    }
    cuda_ratios = [
        float(row["cv_over_fit_predict"])
        for row in figure2["cross_validation_routes"]
        if row.get("backend") == "cuda" and row.get("status_cv") == "success"
        and row.get("status_fit_predict") == "success"
    ]
    cuda_tail = (
        "No CUDA ratio exceeded ten. CUDA OPLS ratios were "
        f"{cuda_opls['prism']:.2f} for PRISM, {cuda_opls['nmr']:.2f} for NMR "
        f"and {cuda_opls['imagenet']:.2f} for ImageNet."
        if not any(value > 10 for value in cuda_ratios)
        else
        "Most ratios remained below ten. The exceptions were CUDA OPLS for "
        "PRISM, NMR and ImageNet, with ratios of "
        f"{cuda_opls['prism']:.2f}, {cuda_opls['nmr']:.2f} and "
        f"{cuda_opls['imagenet']:.2f}, respectively."
    )
    replace_started(
        document,
        "Complete 10-fold validation cost",
        "Complete 10-fold validation cost a median "
        f"{cv['cpu']['median']:.2f} times one matched fit and prediction on CPU "
        f"(range {cv['cpu']['minimum']:.2f}-{cv['cpu']['maximum']:.2f}) and "
        f"{cv['cuda']['median']:.2f} times on CUDA "
        f"({cv['cuda']['minimum']:.2f}-{cv['cuda']['maximum']:.2f}; "
        "Figure 2C,D). Component counts were fixed, whereas LDA was refitted in "
        "every training fold. " + cuda_tail
    )

    replace_started(
        document,
        "CUDA increased host-RSS increments",
        "CUDA increased the baseline-corrected host-RSS peak in "
        f"{figure2['cuda_host_memory_increase_count']} of "
        f"{figure2['paired_routes']} paired calculations, with a median "
        f"CUDA/CPU ratio of {figure2['median_cuda_cpu_host_memory_ratio']:.2f}. "
        "On small tasks, CUDA libraries, context creation, allocator pools and "
        "staging buffers dominated the increase. Host RSS decreased for "
        "SIMPLS-family, OPLS and kernel PLS on ImageNet and for OPLS on NMR, "
        "where substantial storage moved to the device; PLS-SVD did not show "
        "the same reduction. Device allocation reached approximately 4.1 GiB "
        "on ImageNet and 1.9 GiB for NMR OPLS. These values describe complete "
        "runtime residency rather than isolated algorithmic workspace "
        "(Figure 2B and Supplementary Tables S5-S6)."
    )

    replace_started(
        document,
        "CUDA helped only when work offset",
        "CUDA was advantageous only when the workload offset initialization, "
        f"transfer and synchronization: it accelerated {len(faster)} of "
        f"{len(routes)} fits, principally ImageNet and NMR, while increasing the "
        "host-RSS increment in 48 comparisons. Compiled cross-validation limited "
        f"the median cost to {cv['cpu']['median']:.2f} matched fits on CPU and "
        f"{cv['cuda']['median']:.2f} on CUDA by reusing additive statistics and "
        "component prefixes, which is valuable for repeated-validation tools "
        "such as KODAMA [19, 34]."
    )

    caption = paragraph_starting(document, "Figure 2.")
    replace_picture_before_caption(
        caption, assets / "figures/Figure2.png", usable_width(document)
    )
    replace_caption(
        caption,
        "Figure 2. CPU/CUDA comparisons using float32 inputs. Classification "
        "uses LDA in all panels; regression uses continuous prediction. "
        "A: CPU/CUDA fitting-plus-prediction time ratio. B: CUDA/CPU host-RSS "
        "increment ratio. Panels A-B report medians from three fresh processes. "
        "C-D: 10-fold validation divided by one matched fit and prediction on "
        "CPU and CUDA; LDA is refitted in every training fold. Panels C-D use "
        "five fresh processes except for ImageNet, which uses one. Timings "
        "include initialization, transfers and synchronization."
    )


def update_supplement(document, assets: Path) -> None:
    tables = assets / "tables"
    for label in ("S5", "S6"):
        spec = TABLE_SPECS[label]
        caption = paragraph_starting(document, f"Table {label}.")
        table = build_table(
            document,
            read_csv(tables / spec["file"]),
            spec["columns"],
            spec["widths"],
            spec["font"],
            spec.get("cell_margin", 50),
            spec.get("paragraph_after", 1.2),
        )
        replace_table_after_caption(document, caption, table)
        replace_caption(caption, spec["caption"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("main_input", type=Path)
    parser.add_argument("supplement_input", type=Path)
    parser.add_argument("assets", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()

    facts = json.loads((args.assets / "cmpb_narrative_summary.json").read_text())
    main = Document(args.main_input)
    supplement = Document(args.supplement_input)
    update_main(main, args.assets, facts)
    update_supplement(supplement, args.assets)

    args.output_directory.mkdir(parents=True, exist_ok=True)
    main.save(args.output_directory / "fastPLS_CMPB.docx")
    supplement.save(args.output_directory / "fastPLS_CMPB_supplement.docx")


if __name__ == "__main__":
    main()
