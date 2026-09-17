#!/usr/bin/env python3
"""Insert the current float32 backend evidence into manuscript documents."""

import argparse
import csv
from pathlib import Path

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.table import CT_Tbl
from docx.oxml.text.paragraph import CT_P
from docx.shared import Inches, Pt
from docx.table import Table
from docx.text.paragraph import Paragraph


DATASET_LABELS = {
    "ccle": "CCLE",
    "cifar100": "CIFAR-100",
    "gtex_v8": "GTEx v8",
    "metref": "MetRef",
    "retina": "Retina",
    "tabula": "Tabula Muris",
    "tcga_brca": "TCGA-BRCA",
    "tcga_hnsc_methylation": "TCGA-HNSC methylation",
    "tcga_pan_cancer": "TCGA Pan-Cancer",
    "cbmc_citeseq": "CBMC CITE-seq",
    "prism": "PRISM",
    "nmr": "NMR",
    "imagenet": "ImageNet/DINOv2",
}
DATASET_ORDER = {name: index for index, name in enumerate(DATASET_LABELS)}
FAMILY_LABELS = {
    "plssvd": "PLS-SVD",
    "simpls": "SIMPLS",
    "opls": "OPLS",
    "kernelpls": "linear kernel PLS",
}
FAMILY_ORDER = {name: index for index, name in enumerate(FAMILY_LABELS)}


def read_rows(path):
    with Path(path).open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    if not rows:
        raise ValueError(f"No Figure 2 rows in {path}")
    expected = {
        "dataset", "family", "requested_ncomp", "metric_name",
        "median_total_sec_cpu", "median_total_sec_accelerator",
        "runtime_ratio", "median_metric_cpu", "median_metric_accelerator",
        "median_incremental_rss_mib_cpu",
        "median_incremental_rss_mib_accelerator", "host_memory_ratio",
        "median_gpu_peak_mib_accelerator", "effective_oversample_accelerator",
        "effective_power_accelerator", "seed_accelerator",
        "execution_route_accelerator", "status_cpu", "status_accelerator",
        "accelerator", "package_version_cpu", "package_version_accelerator",
    }
    missing = expected.difference(rows[0])
    if missing:
        raise ValueError(f"Missing Figure 2 columns: {sorted(missing)}")
    return sorted(
        rows,
        key=lambda row: (
            0 if row["accelerator"] == "CUDA" else 1,
            DATASET_ORDER[row["dataset"]],
            FAMILY_ORDER[row["family"]],
        ),
    )


def number(row, name):
    value = row.get(name, "")
    return float(value) if value not in ("", None) else None


def fmt_time(value):
    if value is None:
        return "NA"
    return f"{value:.3f}" if value < 100 else f"{value:.1f}"


def fmt_metric(value, metric):
    if value is None:
        return "NA"
    if metric == "accuracy":
        return f"{value:.4f}"
    if abs(value) < 0.001:
        return f"{value:.3e}"
    if abs(value) < 1:
        return f"{value:.6f}"
    return f"{value:.4f}"


def fmt_ratio(value):
    return "NA" if value is None else f"{value:.2f}"


def fmt_memory(value):
    return "NA" if value is None else f"{value:.1f}"


def controls(row):
    bits = []
    if row.get("effective_oversample_accelerator"):
        bits.append(f"o={row['effective_oversample_accelerator']}")
    if row.get("effective_power_accelerator"):
        bits.append(f"power={row['effective_power_accelerator']}")
    if row.get("seed_accelerator"):
        bits.append(f"seed={row['seed_accelerator']}")
    return ", ".join(bits) if bits else "not reported"


def row_completed(row):
    return row["status_cpu"] == "success" and row["status_accelerator"] == "success"


def set_text(paragraph, text):
    paragraph.clear()
    paragraph.add_run(text)


def replace_figure_before_caption(document, caption_prefix, image_path):
    paragraphs = list(document.paragraphs)
    caption_index = next(
        index for index, paragraph in enumerate(paragraphs)
        if paragraph.text.strip().startswith(caption_prefix)
    )
    drawing = next(
        paragraph for paragraph in reversed(paragraphs[:caption_index])
        if paragraph._p.xpath(".//w:drawing")
    )
    drawing.clear()
    drawing.alignment = WD_ALIGN_PARAGRAPH.CENTER
    drawing.add_run().add_picture(str(image_path), width=Inches(6.0))
    drawing.paragraph_format.keep_with_next = True


def insert_paragraph_before(anchor, text="", style=None):
    element = OxmlElement("w:p")
    anchor._p.addprevious(element)
    paragraph = Paragraph(element, anchor._parent)
    if style is not None:
        paragraph.style = style
    if text:
        paragraph.add_run(text)
    return paragraph


def insert_metal_figure(document, image_path):
    existing = next(
        (paragraph for paragraph in document.paragraphs
         if paragraph.text.strip().startswith("Figure S19.")),
        None,
    )
    if existing is not None:
        replace_figure_before_caption(document, "Figure S19.", image_path)
        return

    anchor = next(
        paragraph for paragraph in document.paragraphs
        if paragraph.text.strip().startswith("S10. ImageNet stress test")
    )
    intro = insert_paragraph_before(
        anchor,
        "The matched Mac CPU/Metal comparison is separated from the main-text "
        "CPU/CUDA analysis because the two ratios use different host systems. "
        "Figure S19 retains every completed Metal timing and uses the same "
        "float32 inputs, component counts and output contract as Figure 2.",
    )
    intro.paragraph_format.keep_with_next = True
    drawing = insert_paragraph_before(anchor)
    drawing.alignment = WD_ALIGN_PARAGRAPH.CENTER
    drawing.add_run().add_picture(str(image_path), width=Inches(6.0))
    drawing.paragraph_format.keep_with_next = True
    caption_style = next(
        paragraph.style for paragraph in document.paragraphs
        if paragraph.text.strip().startswith("Figure S18.")
    )
    caption = insert_paragraph_before(
        anchor,
        "Figure S19. Float32 CPU/Metal performance across 13 selected "
        "family-dataset workloads. Panel A reports CPU/Metal total-runtime "
        "ratios; values above one favour Metal. Panel B reports Metal/CPU "
        "baseline-corrected incremental host-RSS ratios; values below one "
        "indicate lower host-memory growth for the Metal route. Measurements "
        "were paired on the Apple M3 and used three fresh processes per cell. "
        "Totals include Metal initialization, synchronization, fitting and "
        "held-out prediction.",
        style=caption_style,
    )
    caption.paragraph_format.keep_together = True
    caption.paragraph_format.keep_with_next = False


def find_table_after_caption(document, caption_prefix):
    found = False
    for child in document.element.body.iterchildren():
        if isinstance(child, CT_P):
            paragraph = Paragraph(child, document)
            if paragraph.text.strip().startswith(caption_prefix):
                found = True
        elif isinstance(child, CT_Tbl) and found:
            return Table(child, document)
    raise ValueError(f"Could not find table after {caption_prefix}")


def replace_table_rows(table, values, body_size=6.5):
    for row in list(table.rows)[1:]:
        table._tbl.remove(row._tr)
    for row_values in values:
        row = table.add_row()
        row_properties = row._tr.get_or_add_trPr()
        row_properties.append(OxmlElement("w:cantSplit"))
        cells = row.cells
        if len(cells) != len(row_values):
            raise ValueError("Replacement row width does not match table")
        for cell, value in zip(cells, row_values):
            cell.text = str(value)
            for paragraph in cell.paragraphs:
                for run in paragraph.runs:
                    run.font.size = Pt(body_size)
    for cell in table.rows[0].cells:
        for paragraph in cell.paragraphs:
            for run in paragraph.runs:
                run.font.size = Pt(body_size + 0.5)
                run.bold = True


def set_table_header(table, labels):
    if len(table.rows[0].cells) != len(labels):
        raise ValueError("Replacement header width does not match table")
    for cell, label in zip(table.rows[0].cells, labels):
        cell.text = label
        for run in cell.paragraphs[0].runs:
            run.font.size = Pt(7)
            run.bold = True


def route_label(row):
    route = row.get("execution_route_accelerator", "")
    if "cuda" in route.lower():
        return "resident CUDA"
    if "metal" in route.lower():
        return "CPU/Metal split"
    return route


def update_main(document, figure_path, rows):
    replace_figure_before_caption(document, "Figure 2.", figure_path)
    completed = [row for row in rows if row_completed(row)]
    cuda = [row for row in rows if row["accelerator"] == "CUDA"]
    metal = [row for row in rows if row["accelerator"] == "Metal"]
    cuda_completed = [row for row in cuda if row_completed(row)]
    metal_completed = [row for row in metal if row_completed(row)]
    cuda_faster = sum(number(row, "runtime_ratio") > 1 for row in cuda_completed)
    metal_faster = sum(number(row, "runtime_ratio") > 1 for row in metal_completed)
    cuda_memory = sum(
        number(row, "host_memory_ratio") is not None and
        number(row, "host_memory_ratio") < 1
        for row in cuda_completed
    )
    metal_memory = sum(
        number(row, "host_memory_ratio") is not None and
        number(row, "host_memory_ratio") < 1
        for row in metal_completed
    )
    versions = sorted({row["package_version_cpu"] for row in rows})
    if len(versions) != 1:
        raise ValueError(f"Expected one Figure 2 package version, found {versions}")
    version = versions[0]

    for paragraph in document.paragraphs:
        text = paragraph.text.strip()
        if text.startswith("The backend comparison evaluated"):
            set_text(
                paragraph,
                "The main backend comparison evaluated PLS-SVD, SIMPLS, OPLS "
                "and linear kernel PLS on 13 datasets, including the NMR and "
                "ImageNet/DINOv2 stress tests, using the family-specific "
                "component counts defined before this analysis. All inputs "
                "used float32. CPU/CUDA ratios were paired on an Intel Core "
                "i7-13700 workstation with an NVIDIA GeForce RTX 5060 Ti. "
                "CUDA timing includes host-to-device transfer, fitting, "
                "synchronization, prediction and result transfer. The matched "
                "Mac CPU/Metal comparison is reported separately in "
                "Supplementary Figure S19. Host-memory results are "
                "baseline-corrected complete-process RSS increments; CUDA "
                "device allocation is reported separately in the "
                "Supplementary material."
            )
        elif text.startswith("Accelerator benefit was conditional"):
            audit_suffix = ""
            marker = " In the corresponding metric audit,"
            if marker in paragraph.text:
                audit_suffix = marker + paragraph.text.split(marker, 1)[1]
            set_text(
                paragraph,
                "CUDA benefit was conditional on matrix shape and PLS "
                f"family (Figure 2). CUDA completed {len(cuda_completed)} of "
                f"{len(cuda)} paired float32 workloads and was faster than its "
                f"same-machine CPU route in {cuda_faster}. Metal completed "
                f"{len(metal_completed)} of {len(metal)} pairs and was faster "
                f"in {metal_faster} (Supplementary Figure S19). "
                f"Baseline-corrected host RSS was lower for CUDA in "
                f"{cuda_memory} completed pairs and for Metal in "
                f"{metal_memory}. NMR and ImageNet are included in both "
                "comparisons. Every completed timing is displayed irrespective of "
                "metric difference; the paired metrics, timing dispersion, "
                "host RSS, CUDA device allocation and executed route are "
                "reported in Supplementary Tables S7 and S8."
                + audit_suffix
            )
        elif text.startswith("Figure 2."):
            set_text(
                paragraph,
                "Figure 2. Float32 CPU/CUDA performance across 13 selected "
                "family-dataset workloads. Panel A reports CPU/CUDA total-"
                "runtime ratios, so values above one favour CUDA. Panel B "
                "reports CUDA/CPU baseline-corrected incremental host-RSS "
                f"ratios, so values below one favour CUDA. fastPLS {version} "
                "was used throughout. CPU/CUDA pairs were "
                "measured on an Intel Core i7-13700 with an NVIDIA GeForce RTX "
                "5060 Ti. Three "
                "fresh processes were requested per cell. Totals include "
                "accelerator initialization, transfer, synchronization, "
                "fitting and held-out prediction. The corresponding Mac "
                "CPU/Metal analysis is shown in Supplementary Figure S19."
            )
    if len(completed) != len(cuda_completed) + len(metal_completed):
        raise AssertionError("Completed-row accounting failed")


def update_supplement(document, rows, metal_figure_path):
    time_table = find_table_after_caption(document, "Table S7.")
    memory_table = find_table_after_caption(document, "Table S8.")
    set_table_header(time_table, [
        "Platform", "Dataset", "Family", "A", "CPU s", "Accel. s",
        "Time ratio", "CPU metric", "Accel. metric", "rSVD controls",
        "Route",
    ])
    set_table_header(memory_table, [
        "Platform", "Dataset", "Family", "A", "CPU RSS MiB",
        "Accel. RSS MiB", "RSS ratio", "GPU peak MiB", "Route",
    ])
    time_values = []
    memory_values = []
    versions = sorted({row["package_version_cpu"] for row in rows})
    if len(versions) != 1:
        raise ValueError(f"Expected one Figure 2 package version, found {versions}")
    version = versions[0]
    for row in rows:
        completed = row_completed(row)
        platform = row["accelerator"]
        dataset = DATASET_LABELS[row["dataset"]]
        family = FAMILY_LABELS[row["family"]]
        metric = row["metric_name"]
        status = "success" if completed else (
            f"CPU {row['status_cpu']}; {platform} {row['status_accelerator']}"
        )
        time_values.append([
            platform,
            dataset,
            family,
            row["requested_ncomp"],
            fmt_time(number(row, "median_total_sec_cpu")) if completed else status,
            fmt_time(number(row, "median_total_sec_accelerator")) if completed else "NA",
            fmt_ratio(number(row, "runtime_ratio")) if completed else "NA",
            fmt_metric(number(row, "median_metric_cpu"), metric) if completed else "NA",
            fmt_metric(number(row, "median_metric_accelerator"), metric) if completed else "NA",
            controls(row),
            route_label(row) if completed else status,
        ])
        gpu_peak = number(row, "median_gpu_peak_mib_accelerator")
        memory_values.append([
            platform,
            dataset,
            family,
            row["requested_ncomp"],
            fmt_memory(number(row, "median_incremental_rss_mib_cpu")) if completed else status,
            fmt_memory(number(row, "median_incremental_rss_mib_accelerator")) if completed else "NA",
            fmt_ratio(number(row, "host_memory_ratio")) if completed else "NA",
            fmt_memory(gpu_peak) if platform == "CUDA" and completed else "n/a",
            route_label(row) if completed else status,
        ])
    replace_table_rows(time_table, time_values)
    replace_table_rows(memory_table, memory_values)
    insert_metal_figure(document, metal_figure_path)

    for paragraph in document.paragraphs:
        text = paragraph.text.strip()
        if text.startswith("Table S7."):
            set_text(
                paragraph,
                "Table S7. Complete float32 selected-point CPU/CUDA and "
                "CPU/Metal fitting-plus-prediction comparison across 13 "
                "datasets. The metric is accuracy for classification and "
                "RMSD for regression."
            )
        elif text.startswith("Table S8."):
            set_text(
                paragraph,
                "Table S8. Float32 selected-point baseline-corrected host-RSS "
                "and CUDA device-memory comparison across 13 datasets."
            )
        elif text.startswith("CPU/accelerator runtime ratios above one"):
            set_text(
                paragraph,
                "CPU/accelerator runtime ratios above one favour the "
                f"accelerator. Every row was evaluated with fastPLS {version} "
                "in three fresh processes and includes device and pipeline "
                "initialization. The Metal route uses one invariant operation "
                "partition: Metal evaluates fitting products involving the "
                "training sample matrix, while the CPU performs reduced "
                "factorizations, sequential PLS updates and compact "
                "prediction. Host RSS is the baseline-corrected "
                "complete-process increment. CUDA device allocation can "
                "include context, library and allocator state. Values are "
                "paired within workstation, and no completed timing is "
                "suppressed on the basis of metric disagreement."
            )
        elif text.startswith("Figure S18 isolates the argmax"):
            set_text(
                paragraph,
                text.replace(
                    "the complete CPU/accelerator analysis in Figure 2",
                    "the main-text CPU/CUDA analysis in Figure 2 and the "
                    "CPU/Metal analysis in Supplementary Figure S19",
                ),
            )
        elif text.startswith("In Figure 1,") and "fastPLS 0.99.42" in text:
            set_text(paragraph, text.replace("fastPLS 0.99.42", "fastPLS 0.99.65"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--main-input", required=True)
    parser.add_argument("--supplement-input", required=True)
    parser.add_argument("--figure", required=True)
    parser.add_argument("--metal-figure", required=True)
    parser.add_argument("--ratios", required=True)
    parser.add_argument("--main-output", required=True)
    parser.add_argument("--supplement-output", required=True)
    args = parser.parse_args()

    rows = read_rows(args.ratios)
    expected = 13 * 4 * 2
    if len(rows) != expected:
        raise ValueError(f"Expected {expected} paired rows, found {len(rows)}")

    main_document = Document(args.main_input)
    update_main(main_document, Path(args.figure), rows)
    main_document.save(args.main_output)

    supplement = Document(args.supplement_input)
    update_supplement(supplement, rows, Path(args.metal_figure))
    supplement.save(args.supplement_output)


if __name__ == "__main__":
    main()
