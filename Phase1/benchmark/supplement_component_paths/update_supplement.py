#!/usr/bin/env python3

import argparse
import csv
from pathlib import Path

from docx import Document
from docx.enum.table import WD_ALIGN_VERTICAL
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt


DATASET_LABELS = {
    "cbmc_citeseq": "CBMC CITE-seq",
    "ccle": "CCLE",
    "cifar100": "CIFAR-100",
    "gtex_v8": "GTEx v8",
    "metref": "MetRef",
    "prism": "PRISM",
    "retina": "Retina",
    "tabula": "Tabula Muris",
    "tcga_brca": "TCGA-BRCA",
    "tcga_hnsc_methylation": "TCGA-HNSC methylation",
    "tcga_pan_cancer": "TCGA Pan-Cancer",
}
FAMILY_LABELS = {
    "plssvd": "PLS-SVD",
    "simpls": "SIMPLS",
    "opls": "OPLS",
    "kernelpls": "kernel PLS",
}
FIGURES = [
    ("S1", "ccle"),
    ("S2", "cifar100"),
    ("S3", "gtex_v8"),
    ("S4", "metref"),
    ("S5", "retina"),
    ("S6", "tabula"),
    ("S7", "tcga_brca"),
    ("S8", "tcga_hnsc_methylation"),
    ("S9", "tcga_pan_cancer"),
    ("S10", "cbmc_citeseq"),
    ("S11", "prism"),
]


def read_csv(path):
    with Path(path).open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def find_paragraph(document, prefix):
    for paragraph in document.paragraphs:
        if paragraph.text.strip().startswith(prefix):
            return paragraph
    raise ValueError(f"Paragraph not found: {prefix}")


def paragraph_before(paragraph):
    element = paragraph._p.getprevious()
    while element is not None and element.tag != qn("w:p"):
        element = element.getprevious()
    if element is None:
        raise ValueError("No preceding paragraph was found for a figure caption.")
    from docx.text.paragraph import Paragraph

    return Paragraph(element, paragraph._parent)


def insert_paragraph_after(paragraph, text):
    element = OxmlElement("w:p")
    paragraph._p.addnext(element)
    from docx.text.paragraph import Paragraph

    inserted = Paragraph(element, paragraph._parent)
    inserted.style = document.styles["Normal"]
    inserted.add_run(text)
    return inserted


def replace_picture(paragraph, image_path, width=Inches(6.45)):
    paragraph.clear()
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    paragraph.add_run().add_picture(str(image_path), width=width)


def set_cell_shading(cell, fill):
    tc_pr = cell._tc.get_or_add_tcPr()
    shading = tc_pr.find(qn("w:shd"))
    if shading is None:
        shading = OxmlElement("w:shd")
        tc_pr.append(shading)
    shading.set(qn("w:fill"), fill)


def set_cell_margins(cell, top=70, start=70, bottom=70, end=70):
    tc = cell._tc
    tc_pr = tc.get_or_add_tcPr()
    tc_mar = tc_pr.first_child_found_in("w:tcMar")
    if tc_mar is None:
        tc_mar = OxmlElement("w:tcMar")
        tc_pr.append(tc_mar)
    for margin, value in (("top", top), ("start", start),
                          ("bottom", bottom), ("end", end)):
        node = tc_mar.find(qn(f"w:{margin}"))
        if node is None:
            node = OxmlElement(f"w:{margin}")
            tc_mar.append(node)
        node.set(qn("w:w"), str(value))
        node.set(qn("w:type"), "dxa")


def format_table(table, font_size=7.2):
    table.autofit = True
    for row_index, row in enumerate(table.rows):
        for column_index, cell in enumerate(row.cells):
            cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
            set_cell_margins(cell)
            set_cell_shading(cell, "17365D" if row_index == 0 else (
                "EDF3F8" if row_index % 2 == 0 else "FFFFFF"
            ))
            for paragraph in cell.paragraphs:
                paragraph.paragraph_format.space_before = Pt(0)
                paragraph.paragraph_format.space_after = Pt(0)
                paragraph.alignment = (
                    WD_ALIGN_PARAGRAPH.LEFT
                    if column_index == 0
                    else WD_ALIGN_PARAGRAPH.CENTER
                )
                for run in paragraph.runs:
                    run.font.name = "Arial"
                    run.font.size = Pt(font_size)
                    run.font.bold = row_index == 0
                    run.font.color.rgb = None
                    if row_index == 0:
                        from docx.dml.color import RGBColor

                        run.font.color.rgb = RGBColor(255, 255, 255)
        if row_index == 0:
            tr_pr = row._tr.get_or_add_trPr()
            repeat = OxmlElement("w:tblHeader")
            repeat.set(qn("w:val"), "true")
            tr_pr.append(repeat)


def replace_table(document, index, headers, rows, font_size=7.2):
    old = document.tables[index]
    new = document.add_table(rows=1, cols=len(headers))
    if old.style is not None:
        new.style = old.style
    for column, value in enumerate(headers):
        new.rows[0].cells[column].text = str(value)
    for values in rows:
        cells = new.add_row().cells
        for column, value in enumerate(values):
            cells[column].text = str(value)
    old._tbl.addprevious(new._tbl)
    old._element.getparent().remove(old._element)
    format_table(new, font_size=font_size)
    return new


def clean_status(value):
    return value.replace("_", " ")


def format_number(value, digits=3):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "NA"
    if number != number:
        return "NA"
    return f"{number:.{digits}f}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--figures", required=True)
    parser.add_argument("--selection", required=True)
    parser.add_argument("--correlations", required=True)
    parser.add_argument("--nmr-figure", required=True)
    parser.add_argument("--nmr-decisions", required=True)
    args = parser.parse_args()

    global document
    document = Document(args.input)
    selection = read_csv(args.selection)
    correlations = read_csv(args.correlations)
    nmr_decisions = read_csv(args.nmr_decisions)

    # The consolidated component-path output names the PLS family `method`.
    # Normalize it here so the document builder also accepts older `family` files.
    for row in selection:
        row.setdefault("family", row.get("method", ""))

    dataset_order = list(DATASET_LABELS)
    family_order = ["plssvd", "simpls", "opls", "kernelpls"]
    selection.sort(key=lambda row: (
        dataset_order.index(row["dataset"]), family_order.index(row["family"])
    ))

    selection_rows = []
    selected_heads = {}
    for row in selection:
        selected_heads[(row["dataset"], row["family"])] = row["selected_classifier"]
        head = (
            "Not applicable"
            if row["selection_metric"].lower() == "rmsd"
            else row["selected_classifier"].upper()
        )
        selection_rows.append([
            DATASET_LABELS[row["dataset"]],
            FAMILY_LABELS[row["family"]],
            row["selected_ncomp"],
            head,
            row["selection_metric"].upper(),
            clean_status(row["selection_status"]),
            f'{row["grid_min"]}-{row["grid_max"]}',
            row["intrinsic_limit"],
        ])

    replace_table(
        document,
        12,
        ["Dataset", "PLS family", "Selected components", "Selected head",
         "CV metric", "Status", "Evaluated grid", "Rank limit"],
        selection_rows,
        font_size=7.1,
    )

    architecture = {
        ("Metal workstation", "CPU"): "Mac CPU",
        ("Metal workstation", "Metal"): "Metal",
        ("CUDA workstation", "CPU"): "Linux CPU",
        ("CUDA workstation", "CUDA"): "CUDA",
    }
    architecture_order = ["Mac CPU", "Metal", "Linux CPU", "CUDA"]
    correlation_rows = []
    for row in correlations:
        key = (row["dataset"], row["method"])
        if row["classifier"] != selected_heads.get(key):
            continue
        label = architecture.get((row["platform"], row["backend"]))
        if label is None:
            continue
        head = "" if row["dataset"] in {"cbmc_citeseq", "prism"} else row["classifier"].upper()
        correlation_rows.append((
            architecture_order.index(label),
            dataset_order.index(row["dataset"]),
            family_order.index(row["method"]),
            [
                label,
                DATASET_LABELS[row["dataset"]],
                FAMILY_LABELS[row["method"]],
                head or "Not applicable",
                row["n_path_points"],
                format_number(row["rho_metric"]),
                format_number(row["rho_total_time"]),
                format_number(row["rho_incremental_rss"]),
            ],
        ))
    correlation_rows.sort(key=lambda value: value[:3])
    replace_table(
        document,
        13,
        ["Architecture", "Dataset", "PLS family", "Head", "Path points",
         "Metric rho", "Time rho", "RSS rho"],
        [value[3] for value in correlation_rows],
        font_size=6.8,
    )

    nmr_rows = []
    nmr_decisions.sort(key=lambda row: family_order.index(row["family"]))
    for row in nmr_decisions:
        nmr_rows.append([
            FAMILY_LABELS[row["family"]],
            row["selected_ncomp"],
            row["minimum_mean_ncomp"],
            f'{float(row["one_se_threshold"]):.7f}',
            row["eligible_ncomp"].replace(",", ", "),
            row["largest_tested_ncomp"],
            row["n_splits_successful"],
        ])
    replace_table(
        document,
        14,
        ["PLS family", "Selected components", "Mean-minimum components",
         "One-SE threshold", "Eligible components", "Grid maximum",
         "Successful splits"],
        nmr_rows,
        font_size=7.4,
    )

    component_heading = find_paragraph(document, "S5. Component paths")
    component_heading.text = "S5. Component paths and training-selected component counts"
    component_methods = find_paragraph(document, "For the eleven general benchmark")
    component_methods.text = (
        "For the eleven general benchmark datasets, component counts were selected "
        "using only the training partition. Ten fixed folds (seed 123) were used "
        "with float32 inputs and the CPU rSVD route in fastPLS 0.99.65. At every "
        "admissible count, classification evaluated both argmax and LDA and retained "
        "the component-head pair with the greatest pooled out-of-fold accuracy. "
        "Regression retained the component count with the smallest pooled "
        "out-of-fold RMSD. Ties were resolved by the ordered grid in favour of the "
        "smaller count. OPLS removed one orthogonal component and kernel PLS used "
        "the linear kernel. PLS-SVD classification was restricted to q - 1 components. "
        "Selections at the largest evaluated count or an intrinsic rank limit are "
        "labelled explicitly and are not interpreted as unconstrained optima. "
        "The package selected its public automatic rSVD controls; the effective "
        "oversampling and power values were recorded with every result."
    )

    find_paragraph(document, "Table S11.").text = (
        "Table S11. Training-only component and prediction-head selections for "
        "PLS-SVD, SIMPLS, OPLS and linear kernel PLS in fastPLS 0.99.65."
    )
    find_paragraph(document, "Table S12.").text = (
        "Table S12. Spearman associations with requested component count for the "
        "training-selected prediction head."
    )
    find_paragraph(document, "Positive time or RSS correlations").text = (
        "Positive time or RSS correlations indicate increasing computational cost "
        "with additional components. For accuracy, positive metric correlations "
        "indicate improvement; for RMSD, negative correlations indicate improvement. "
        "The architecture labels refer to same-host measurements: Mac CPU and Metal "
        "on the Apple M3 computer, and Linux CPU and CUDA on the NVIDIA workstation."
    )

    figure_root = Path(args.figures)
    general_caption = (
        "PLS-SVD, SIMPLS, OPLS and linear kernel PLS used matched float32 "
        "inputs in fastPLS 0.99.65. "
        "Mac CPU, Metal, Linux CPU and CUDA are distinguished by colour; solid lines "
        "show argmax and dashed lines show LDA. Regression paths are solid because "
        "classification heads do not apply. Points are medians of three fresh-process "
        "runs. Dotted vertical lines mark the training-only selected component count. "
        "Time includes fitting and held-out prediction; memory is baseline-corrected "
        "peak process RSS. Automatic rSVD controls were recorded for every run."
    )
    for figure_number, dataset in FIGURES:
        caption = find_paragraph(document, f"Figure {figure_number}.")
        image_paragraph = paragraph_before(caption)
        image_path = figure_root / f"component_path_{dataset}.png"
        replace_picture(image_paragraph, image_path)
        caption.text = (
            f"Figure {figure_number}. {DATASET_LABELS[dataset]} component paths. "
            + general_caption
        )

    nmr_heading = find_paragraph(document, "S6. NMR component selection")
    nmr_heading.text = "S6. NMR held-out component paths"
    nmr_methods = find_paragraph(document, "NMR component selection used")
    nmr_methods.text = (
        "NMR component selection used only the predefined 1,200-spectrum training "
        "partition. Five fixed 80/20 inner splits used seeds 123, 456, 789, 1011 "
        "and 2027, and the smallest component count within one standard error of "
        "the minimum mean validation RMSD was retained for each family. Figure S12 "
        "is a separate held-out analysis: each model was fitted on all 1,200 training "
        "spectra and predictions were evaluated against the predefined 321-spectrum "
        "test partition at 1, 2, 3, 5, 8, 10, 25, 50, 75, 100, 125, 150, 165, "
        "175, 200, 250 and 300 components. Every family, route and component count "
        "was measured in three isolated processes with rSVD seed 123 and float32 "
        "inputs. Complete fitting-plus-prediction time and baseline-corrected peak "
        "host RSS were monitored over the same interval as the held-out prediction. "
        "Mac CPU and Metal were measured on the Apple workstation; Linux CPU and "
        "CUDA were measured on the NVIDIA workstation. Test responses were not used "
        "for model fitting or component selection. OPLS used one orthogonal component "
        "and kernel PLS used the linear kernel."
    )
    find_paragraph(document, "Table S13.").text = (
        "Table S13. NMR training-only one-standard-error component decisions in "
        "fastPLS 0.99.65."
    )
    nmr_caption = find_paragraph(document, "Figure S12.")
    replace_picture(paragraph_before(nmr_caption), Path(args.nmr_figure))
    nmr_caption.text = (
        "Figure S12. NMR component-dependent prediction and computation using "
        "float32 inputs in fastPLS 0.99.66. PLS-SVD, SIMPLS, OPLS and linear kernel "
        "PLS were fitted only on the predefined 1,200-spectrum training partition "
        "and evaluated on the fixed 321-spectrum test partition. Rows report held-out "
        "RMSD, complete fitting-plus-prediction time and baseline-corrected peak host "
        "RSS. Mac CPU, Metal, Linux CPU and CUDA are distinguished by colour. Points "
        "are medians of three isolated-process runs with rSVD seed 123; ribbons show "
        "the interquartile range. Dotted lines mark component counts selected "
        "independently by training-only inner validation. Vertical scales are "
        "family- and measure-specific."
    )

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    document.save(output)


if __name__ == "__main__":
    main()
