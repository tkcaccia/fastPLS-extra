#!/usr/bin/env python3

import argparse
import csv
import math
from pathlib import Path

from docx import Document
from docx.enum.text import WD_BREAK, WD_ALIGN_PARAGRAPH
from docx.shared import Inches, Pt


def insert_text_before(target, text, style="Normal", italic=False):
    paragraph = target.insert_paragraph_before(style=style)
    run = paragraph.add_run(text)
    run.italic = italic
    return paragraph


def insert_figure_before(target, path, width):
    paragraph = target.insert_paragraph_before()
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    paragraph.paragraph_format.keep_with_next = True
    paragraph.add_run().add_picture(str(path), width=Inches(width))
    return paragraph


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_docx", type=Path)
    parser.add_argument("figure_accelerator", type=Path)
    parser.add_argument("figure_repeated", type=Path)
    parser.add_argument("accelerator_csv", type=Path)
    parser.add_argument("repeated_csv", type=Path)
    parser.add_argument("output_docx", type=Path)
    args = parser.parse_args()

    for path in (
        args.input_docx, args.figure_accelerator, args.figure_repeated,
        args.accelerator_csv, args.repeated_csv
    ):
        if not path.exists():
            raise FileNotFoundError(path)

    document = Document(args.input_docx)
    target = next(
        paragraph for paragraph in document.paragraphs
        if paragraph.text.strip() == "S11. Reproducibility and software checks"
    )
    target.text = "S12. Reproducibility and software checks"
    target.style = "Heading 1"

    heading = insert_text_before(
        target, "S11. Cross-validation backend timing", style="Heading 1"
    )
    heading.paragraph_format.page_break_before = True
    insert_text_before(
        target,
        "Backend effects on cross-validation were measured at the family- and "
        "dataset-specific component counts selected "
        "from the training data (Table S11). Each cell used float32 inputs, ten "
        "fixed folds (seed 123) and five independent fresh-process "
        "repetitions; no warm-up was excluded. Argmax decoding was used for classification, "
        "RMSD for regression, one OPLS orthogonal component and a linear kernel "
        "for kernel PLS. rSVD used seed 123, 32 oversampling directions and "
        "five power iterations, except that the high-response PRISM sequential "
        "families used 48 directions and six iterations. CPU and accelerator "
        "measurements were paired on the "
        "same host. Mac CPU/Metal rows were recalculated with fastPLS 0.99.42; "
        "the retained Linux CPU/CUDA rows use 0.99.41, whose corresponding CPU "
        "and CUDA numerical paths are unchanged in 0.99.42. The Linux system was "
        "an Intel Core i7-13700 workstation with single-thread "
        "reference BLAS and an NVIDIA GeForce RTX 5060 Ti for CUDA, and an "
        "Apple M3 Mac with Accelerate BLAS and its integrated GPU for Metal. "
        "Timings include fold handling, fitting, prediction, metric "
        "aggregation, first-call accelerator context creation, device transfer "
        "and synchronization. Constraint groups were kept within folds when "
        "a task supplied them; otherwise rows were assigned independently. Fold orchestration "
        "and final metric aggregation remain host-resident. CUDA fold fitting "
        "and prediction are device-native; Metal folds use the same fixed "
        "CPU/Metal operation split as ordinary fitting. No unavailable "
        "accelerator is replaced by CPU execution. Same-host accelerator ratios are shown "
        "in Figure S16."
    )
    insert_figure_before(target, args.figure_accelerator, 6.55)
    caption = insert_text_before(
        target,
        "Figure S16. GPU backend benefit for ten-fold cross-validation. "
        "Cells show the median same-host CPU cross-validation time divided by "
        "the median CUDA or Metal time for PLS-SVD, SIMPLS, OPLS and linear "
        "kernel PLS. Values above one indicate faster accelerator execution; "
        "values below one indicate faster CPU execution. NE denotes a route "
        "that was not evaluated and ERR a failed route. All successful timing results "
        "are displayed without filtering on predictive concordance.",
        italic=True
    )
    caption.runs[0].font.size = Pt(9)

    page = target.insert_paragraph_before()
    page.add_run().add_break(WD_BREAK.PAGE)
    insert_text_before(
        target,
        "The cost of complete cross-validation was also compared with a naive "
        "ten-fold estimate. One fit and held-out prediction were timed on the "
        "first precomputed fold with the same data, preprocessing, component "
        "count, method, backend and cold-process policy; its median time was then "
        "multiplied by ten. The held-out audit metric was calculated after the "
        "timed standalone call. This comparison isolates whether the complete "
        "cross-validation workflow costs more or less than repeated model "
        "fitting and prediction under their respective public output contracts "
        "(Figure S17). Because pls.single.cv() always returns complete "
        "out-of-fold score and prediction structures, the comparison includes "
        "their assembly and is not a decomposition-kernel-only benchmark."
    )
    insert_figure_before(target, args.figure_repeated, 6.55)
    caption = insert_text_before(
        target,
        "Figure S17. Complete cross-validation compared with repeated fitting "
        "and prediction. Cells show ten times the median one-fold fit-and-"
        "prediction time divided by the median complete ten-fold cross-"
        "validation time. Values above one indicate that measured cross-"
        "validation was faster than the naive repeated-fit estimate; values "
        "below one indicate that the repeated-fit estimate was lower. Linux "
        "CPU is paired with CUDA and Mac CPU with Metal. The multiplier is a "
        "workflow reference rather than an exact operation count: fold "
        "composition can differ slightly, and cross-validation additionally "
        "assembles complete out-of-fold predictions and scores. NE denotes a route that was not "
        "evaluated and ERR a failed route.",
        italic=True
    )
    caption.runs[0].font.size = Pt(9)

    with args.accelerator_csv.open(newline="") as handle:
        accelerator_rows = list(csv.DictReader(handle))
    with args.repeated_csv.open(newline="") as handle:
        repeated_rows = list(csv.DictReader(handle))

    def finite_rows(rows, field, backend, platform=None):
        output = []
        for row in rows:
            if row.get("backend") != backend:
                continue
            if platform is not None and row.get("platform") != platform:
                continue
            try:
                value = float(row[field])
            except (TypeError, ValueError):
                continue
            if math.isfinite(value):
                output.append((row, value))
        return output

    cuda = finite_rows(accelerator_rows, "cpu_over_accelerator", "cuda")
    metal = finite_rows(accelerator_rows, "cpu_over_accelerator", "metal")
    all_accelerator = cuda + metal
    fastest_row, fastest_ratio = max(all_accelerator, key=lambda item: item[1])
    dataset_label = {
        "cbmc_citeseq": "CBMC CITE-seq", "ccle": "CCLE",
        "cifar100": "CIFAR-100", "gtex_v8": "GTEx v8",
        "metref": "MetRef", "prism": "PRISM", "retina": "Retina",
        "tabula": "Tabula Muris", "tcga_brca": "TCGA-BRCA",
        "tcga_hnsc_methylation": "TCGA-HNSC methylation",
        "tcga_pan_cancer": "TCGA Pan-Cancer"
    }
    method_label = {
        "plssvd": "PLS-SVD", "simpls": "SIMPLS", "opls": "OPLS",
        "kernelpls": "linear kernel PLS"
    }
    naive_groups = [
        ("Linux CPU", "linux_nvidia", "cpu"),
        ("CUDA", "linux_nvidia", "cuda"),
        ("Mac CPU", "mac_apple_silicon", "cpu"),
        ("Metal", "mac_apple_silicon", "metal"),
    ]
    naive_text = []
    for label, platform, backend in naive_groups:
        rows = finite_rows(repeated_rows, "naive_over_cv", backend, platform)
        naive_text.append(f"{label} {sum(value > 1 for _, value in rows)}/{len(rows)}")
    insert_text_before(
        target,
        "Across successful cells, CUDA was faster than its same-host CPU "
        f"reference in {sum(value > 1 for _, value in cuda)}/{len(cuda)} "
        "comparisons and Metal in "
        f"{sum(value > 1 for _, value in metal)}/{len(metal)}. The largest "
        "CPU/GPU runtime ratio was "
        f"{fastest_ratio:.2f}-fold for "
        f"{dataset_label.get(fastest_row['dataset'], fastest_row['dataset'])} "
        f"{method_label.get(fastest_row['method'], fastest_row['method'])}. "
        "Complete cross-validation was faster than "
        "the ten-times-one-fold estimate in " + ", ".join(naive_text) +
        " cells, respectively. Ratios below one identify configurations in "
        "which fold orchestration and aggregation outweighed reusable "
        "cross-validation work."
    )

    for table in document.tables:
        for row in table.rows:
            if len(row.cells) >= 3 and row.cells[0].text.strip() == "Package":
                if "fastPLS" in row.cells[1].text:
                    row.cells[1].text = "fastPLS 0.99.42"
                    row.cells[2].text = "One evaluated release for current evidence"

    args.output_docx.parent.mkdir(parents=True, exist_ok=True)
    document.save(args.output_docx)


if __name__ == "__main__":
    main()
