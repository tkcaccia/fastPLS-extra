#!/usr/bin/env python3

"""Separate CMPB biomedical evidence from the future JSS software study."""

from copy import deepcopy
from pathlib import Path
import csv
import re

from docx import Document
from docx.enum.section import WD_ORIENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt
from docx.table import Table
from docx.text.paragraph import Paragraph


ROOT = Path("/Users/stefano/Documents/GPUPLS")
INPUT_MAIN = ROOT / "document_work/cmpb_latest_20260915/fastPLS_CMPB_manuscript_updated.docx"
INPUT_SUPP = ROOT / "document_work/cmpb_latest_20260915/fastPLS_CMPB_supplement_updated.docx"
INPUT_JSS = ROOT / "manuscript_style_revision_20260914/documents/fastPLS_JSS_future_draft.docx"
OUTPUT = ROOT / "document_work/cmpb_jss_restructure_20260915/documents"
FIGURES = ROOT / "document_work/cmpb_jss_restructure_20260915/figures"
FIGURE1 = FIGURES / "figure1_current_nmr.png"
FIGURE2 = FIGURES / "figure2_backend_and_cv.png"
FIGURE4 = FIGURES / "figure4_imagenet_no_version.png"
PATH_FIGURES = ROOT / "document_work/cmpb_jss_restructure_20260915/component_paths_current/component_path_plots"
CONTRACT = ROOT / "fastPLS-extra/benchmark/gpu_cross_validation/selected_component_contract.csv"
FIGURE1_DATA = FIGURES / "figure1_current_nmr.csv"
IKPLS_SUMMARY = (
    ROOT
    / "fastPLS_results_local/figure1_six_panel_0.99.65_20260912/"
    / "ikpls/ikpls_panel_summary.csv"
)
PYTHON_SUMMARY = (
    ROOT
    / "fastPLS_results_local/figure1_six_panel_0.99.65_20260912/"
    / "python/python_pls_panel_summary.csv"
)
IKPLS_IMAGENET = (
    ROOT
    / "fastPLS_results_local/simpls_compact_fit_false_20260912/"
    / "imagenet_ikpls_f32_n1000.csv"
)


def paragraph_text(element, document):
    return " ".join(Paragraph(element, document).text.split())


def body_elements(document):
    return list(document.element.body.iterchildren())


def find_paragraph_element(document, prefix):
    for element in body_elements(document):
        if element.tag == qn("w:p") and paragraph_text(element, document).startswith(prefix):
            return element
    raise ValueError(f"Paragraph not found: {prefix}")


def find_paragraph(document, prefix):
    return Paragraph(find_paragraph_element(document, prefix), document)


def set_paragraph(document, prefix, text, style=None):
    paragraph = find_paragraph(document, prefix)
    paragraph.clear()
    paragraph.add_run(text)
    if style:
        paragraph.style = style
    return paragraph


def add_paragraph_after(document, prefix, text, style=None):
    anchor = find_paragraph_element(document, prefix)
    paragraph = document.add_paragraph()
    paragraph.add_run(text)
    if style:
        paragraph.style = style
    anchor.addnext(paragraph._p)
    return paragraph


def delete_paragraph(document, prefix):
    element = find_paragraph_element(document, prefix)
    element.getparent().remove(element)


def delete_section(document, start_prefix, end_prefix):
    start = find_paragraph_element(document, start_prefix)
    end = find_paragraph_element(document, end_prefix)
    elements = body_elements(document)
    first = elements.index(start)
    last = elements.index(end)
    for element in elements[first:last]:
        element.getparent().remove(element)


def move_section_before(document, start_prefix, end_prefix, target_prefix):
    start = find_paragraph_element(document, start_prefix)
    end = find_paragraph_element(document, end_prefix)
    target = find_paragraph_element(document, target_prefix)
    elements = body_elements(document)
    block = elements[elements.index(start):elements.index(end)]
    for element in block:
        target.addprevious(element)


def nearest_previous_drawing(element):
    previous = element.getprevious()
    while previous is not None:
        if previous.tag == qn("w:p") and previous.xpath(".//w:drawing"):
            return previous
        if previous.tag == qn("w:p") and paragraph_text(previous, element.getparent()):
            return None
        previous = previous.getprevious()
    return None


def delete_caption_object(document, prefix, remove_following_table=True):
    caption = find_paragraph_element(document, prefix)
    drawing = caption.getprevious()
    while drawing is not None and drawing.tag == qn("w:p"):
        if drawing.xpath(".//w:drawing"):
            drawing.getparent().remove(drawing)
            break
        if paragraph_text(drawing, document):
            break
        previous = drawing.getprevious()
        drawing.getparent().remove(drawing)
        drawing = previous
    following = caption.getnext()
    caption.getparent().remove(caption)
    if remove_following_table:
        while following is not None and following.tag == qn("w:p") and not paragraph_text(following, document):
            next_element = following.getnext()
            following.getparent().remove(following)
            following = next_element
        if following is not None and following.tag == qn("w:tbl"):
            following.getparent().remove(following)


def table_after(document, caption_prefix):
    element = find_paragraph_element(document, caption_prefix).getnext()
    while element is not None and element.tag != qn("w:tbl"):
        element = element.getnext()
    if element is None:
        raise ValueError(f"Table not found after {caption_prefix}")
    return Table(element, document)


def filter_table_rows(table, column, keep):
    header = [cell.text.strip() for cell in table.rows[0].cells]
    index = header.index(column)
    for row in list(table.rows[1:]):
        if row.cells[index].text.strip() not in keep:
            table._tbl.remove(row._tr)


def remove_table_column(table, column):
    header = [cell.text.strip() for cell in table.rows[0].cells]
    index = header.index(column)
    for row in table.rows:
        row._tr.remove(row.cells[index]._tc)
    grid_columns = table._tbl.tblGrid.gridCol_lst
    table._tbl.tblGrid.remove(grid_columns[index])


def format_table(table, size=7.0):
    for row_index, row in enumerate(table.rows):
        for cell in row.cells:
            for paragraph in cell.paragraphs:
                paragraph.paragraph_format.space_before = Pt(0)
                paragraph.paragraph_format.space_after = Pt(0)
                for run in paragraph.runs:
                    run.font.name = "Arial"
                    run.font.size = Pt(size)
                    if row_index == 0:
                        run.font.bold = True


def replace_table_cell_text(table, prefix, text):
    for row in table.rows:
        for cell in row.cells:
            if " ".join(cell.text.split()).startswith(prefix):
                cell.text = text
                return
    raise ValueError(f"Table cell not found: {prefix}")


def replace_table(document, caption_prefix, headers, rows):
    old = table_after(document, caption_prefix)
    new = document.add_table(rows=1, cols=len(headers))
    if old.style:
        new.style = old.style
    for index, value in enumerate(headers):
        new.rows[0].cells[index].text = str(value)
    for values in rows:
        row = new.add_row()
        row_properties = row._tr.get_or_add_trPr()
        row_properties.append(OxmlElement("w:cantSplit"))
        cells = row.cells
        for index, value in enumerate(values):
            cells[index].text = str(value)
    old._tbl.addprevious(new._tbl)
    old._tbl.getparent().remove(old._tbl)
    header_properties = new.rows[0]._tr.get_or_add_trPr()
    repeat = OxmlElement("w:tblHeader")
    repeat.set(qn("w:val"), "true")
    header_properties.append(repeat)
    format_table(new)


def append_table(document, headers, rows, size=8.0):
    table = document.add_table(rows=1, cols=len(headers))
    table.style = "Table Grid"
    for index, value in enumerate(headers):
        table.rows[0].cells[index].text = str(value)
    for values in rows:
        cells = table.add_row().cells
        for index, value in enumerate(values):
            cells[index].text = str(value)
    header_properties = table.rows[0]._tr.get_or_add_trPr()
    repeat = OxmlElement("w:tblHeader")
    repeat.set(qn("w:val"), "true")
    header_properties.append(repeat)
    format_table(table, size=size)
    return table


def set_table_column_widths(table, widths):
    table.autofit = False
    twips = [int(width.inches * 1440) for width in widths]
    for grid_column, width in zip(table._tbl.tblGrid.gridCol_lst, twips):
        grid_column.set(qn("w:w"), str(width))
    for row in table.rows:
        for cell, width in zip(row.cells, twips):
            properties = cell._tc.get_or_add_tcPr()
            cell_width = properties.first_child_found_in("w:tcW")
            if cell_width is None:
                cell_width = OxmlElement("w:tcW")
                properties.append(cell_width)
            cell_width.set(qn("w:w"), str(width))
            cell_width.set(qn("w:type"), "dxa")


def add_algorithm_after(document, anchor_prefix, caption_text, rows):
    anchor = find_paragraph_element(document, anchor_prefix)
    caption = document.add_paragraph(caption_text)
    caption.paragraph_format.keep_with_next = True
    for run in caption.runs:
        run.bold = True
    table = document.add_table(rows=1, cols=2)
    table.style = "Table Grid"
    table.rows[0].cells[0].text = "Step"
    table.rows[0].cells[1].text = "Executable operation"
    for step, operation in rows:
        cells = table.add_row().cells
        cells[0].text = str(step)
        cells[1].text = operation
        row_properties = cells[0]._tc.getparent().get_or_add_trPr()
        row_properties.append(OxmlElement("w:cantSplit"))
    header_properties = table.rows[0]._tr.get_or_add_trPr()
    repeat = OxmlElement("w:tblHeader")
    repeat.set(qn("w:val"), "true")
    header_properties.append(repeat)
    format_table(table, size=7.0)
    set_table_column_widths(table, [Inches(0.55), Inches(5.95)])
    anchor.addnext(caption._p)
    caption._p.addnext(table._tbl)
    return table


def add_algorithm_before(document, anchor_prefix, caption_text, rows):
    anchor = find_paragraph_element(document, anchor_prefix)
    caption = document.add_paragraph(caption_text)
    caption.paragraph_format.keep_with_next = True
    for run in caption.runs:
        run.bold = True
    table = document.add_table(rows=1, cols=2)
    table.style = "Table Grid"
    table.rows[0].cells[0].text = "Step"
    table.rows[0].cells[1].text = "Executable operation"
    for step, operation in rows:
        cells = table.add_row().cells
        cells[0].text = str(step)
        cells[1].text = operation
        row_properties = cells[0]._tc.getparent().get_or_add_trPr()
        row_properties.append(OxmlElement("w:cantSplit"))
    header_properties = table.rows[0]._tr.get_or_add_trPr()
    repeat = OxmlElement("w:tblHeader")
    repeat.set(qn("w:val"), "true")
    header_properties.append(repeat)
    format_table(table, size=7.0)
    set_table_column_widths(table, [Inches(0.55), Inches(5.95)])
    anchor.addprevious(caption._p)
    anchor.addprevious(table._tbl)
    return table


def replace_picture_before_caption(document, caption_prefix, image_path, width=6.5):
    caption = find_paragraph_element(document, caption_prefix)
    element = caption.getprevious()
    intervening_text = 0
    while element is not None:
        if element.tag == qn("w:p") and element.xpath(".//w:drawing"):
            paragraph = Paragraph(element, document)
            paragraph.clear()
            paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
            paragraph.add_run().add_picture(str(image_path), width=Inches(width))
            return
        if element.tag == qn("w:p") and paragraph_text(element, document):
            intervening_text += 1
            if intervening_text > 2:
                break
        element = element.getprevious()
    raise ValueError(f"Image not found before {caption_prefix}")


def move_caption_after_picture(document, caption_prefix):
    caption = find_paragraph_element(document, caption_prefix)
    element = caption.getprevious()
    intervening_text = 0
    while element is not None:
        if element.tag == qn("w:p") and element.xpath(".//w:drawing"):
            element.addnext(caption)
            return
        if element.tag == qn("w:p") and paragraph_text(element, document):
            intervening_text += 1
            if intervening_text > 2:
                break
        element = element.getprevious()
    raise ValueError(f"Image not found before {caption_prefix}")


def replace_references(document, mapping):
    patterns = sorted(mapping, key=len, reverse=True)
    placeholders = {key: f"@@REF{index}@@" for index, key in enumerate(patterns)}
    for paragraph in document.paragraphs:
        text = paragraph.text
        changed = False
        for key in patterns:
            pattern = re.escape(key) + r"(?!\d)"
            if re.search(pattern, text):
                text = re.sub(pattern, placeholders[key], text)
                changed = True
        if changed:
            for key in patterns:
                text = text.replace(placeholders[key], mapping[key])
            paragraph.clear()
            paragraph.add_run(text)


def insert_before(anchor, element):
    anchor.addprevious(element)


def add_paragraph_before(document, anchor, text, style=None):
    paragraph = document.add_paragraph(text)
    if style:
        paragraph.style = style
    insert_before(anchor, paragraph._p)
    return paragraph


def add_table_copy_before(document, anchor, source_table, size=7.0):
    element = deepcopy(source_table._tbl)
    insert_before(anchor, element)
    table = Table(element, document)
    format_table(table, size=size)
    return table


def add_picture_before(document, anchor, path, width=6.4):
    paragraph = document.add_paragraph()
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    paragraph.add_run().add_picture(str(path), width=Inches(width))
    insert_before(anchor, paragraph._p)


def fixed_component_rows():
    labels = {
        "ccle": "CCLE", "cifar100": "CIFAR-100", "gtex_v8": "GTEx v8",
        "metref": "MetRef", "retina": "Retina", "tabula": "Tabula Muris",
        "tcga_brca": "TCGA-BRCA",
        "tcga_hnsc_methylation": "TCGA-HNSC methylation",
        "tcga_pan_cancer": "TCGA Pan-Cancer", "cbmc_citeseq": "CBMC CITE-seq",
        "prism": "PRISM", "nmr": "NMR", "imagenet": "ImageNet/DINOv2"
    }
    order = list(labels)
    values = {}
    with CONTRACT.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            values.setdefault(row["dataset"], {})[row["family"]] = row["selected_ncomp"]
    return [
        [labels[key], values[key]["plssvd"], values[key]["simpls"],
         values[key]["opls"], values[key]["kernelpls"]]
        for key in order
    ]


def read_csv_rows(path):
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def display_number(value, digits=3):
    if value in (None, "", "NA", "nan", "NaN"):
        return "NA"
    number = float(value)
    if number != number:
        return "NA"
    return f"{number:.{digits}f}"


def display_component(value):
    if value in (None, ""):
        return "NA"
    return str(int(float(value)))


def display_metric_value(value, classification):
    if value in (None, "", "NA", "nan", "NaN"):
        return "NA"
    number = float(value)
    if number != number:
        return "NA"
    if classification:
        return f"{number:.5f}"
    return f"{number:.2f}" if abs(number) >= 1 else f"{number:.6f}"


def fixed_python_comparison_rows():
    """Build Table S1 from the same fixed-component data as Figure 1."""
    labels = {
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
        "nmr": "NMR",
        "imagenet": "ImageNet/DINOv2",
    }
    order = {key: index for index, key in enumerate(labels)}
    figure_rows = [
        row for row in read_csv_rows(FIGURE1_DATA)
        if row["implementation"] in {
            "IKPLS", "scikit-learn / PLSRegression"
        }
    ]
    ikpls_detail = {
        row["dataset"]: row for row in read_csv_rows(IKPLS_SUMMARY)
    }
    sklearn_detail = {
        row["dataset"]: row for row in read_csv_rows(PYTHON_SUMMARY)
        if row["implementation"] == "sklearn_plsregression"
    }
    imagenet_detail = read_csv_rows(IKPLS_IMAGENET)[0]

    table_rows = []
    for row in sorted(
        figure_rows,
        key=lambda item: (
            0 if item["implementation"] == "IKPLS" else 1,
            order[item["dataset"]],
        ),
    ):
        is_ikpls = row["implementation"] == "IKPLS"
        dataset = row["dataset"]
        if is_ikpls and dataset == "imagenet":
            detail = imagenet_detail
            top5 = detail["top5_accuracy"]
            iqr = ""
        elif is_ikpls and dataset == "nmr":
            detail = {}
            top5 = ""
            iqr = ""
        else:
            detail = (
                ikpls_detail[dataset]
                if is_ikpls else sklearn_detail[dataset]
            )
            top5 = detail.get("top5_accuracy", "")
            iqr = detail.get("iqr_total_sec", "")

        classification = row["task_type"] == "classification"
        metric = "Accuracy" if classification else "RMSD"
        value = row["accuracy"] if classification else row["rmsd"]
        success = row["status"] == "success"
        table_rows.append([
            "IKPLS" if is_ikpls else "scikit-learn",
            labels[dataset],
            "Class." if classification else "Regr.",
            row["precision"],
            display_component(row["ncomp"]),
            metric,
            display_metric_value(value, classification),
            display_number(top5, 4),
            display_number(row["total_sec"], 3),
            display_number(iqr, 3),
            display_number(row["peak_rss_mib"], 0),
            display_component(row["repetitions"]),
            "OK" if success else "Memory failure",
        ])

    # This separate feasibility calculation is cited in the main Results but
    # was not part of Figure 1 because it used float64 and one isolated run.
    table_rows.append([
        "scikit-learn", "NMR", "Regr.", "float64",
        "50", "RMSD", "0.000745", "NA", "107.466", "NA", "9180",
        "1", "OK; feasibility",
    ])
    return table_rows


def build_cmpb_supplement():
    document = Document(INPUT_SUPP)
    set_paragraph(
        document, "fastPLS: accelerated SIMPLS",
        "fastPLS: an accelerated SIMPLS-family estimator for "
        "high-dimensional biomedical data"
    )
    for prefix in ("Figure 1 compares complete", "The CUDA comparison used"):
        paragraph = find_paragraph(document, prefix)
        text = paragraph.text.replace("fastPLS 0.99.65", "fastPLS")
        text = text.replace(
            "fastPLS used centred float32 predictors, SIMPLS with rSVD",
            "fastPLS used centred float32 predictors and its SIMPLS-family "
            "estimator with rSVD"
        )
        text = text.replace(
            "fastPLS used SIMPLS-LDA for classification and SIMPLS regression",
            "fastPLS used its SIMPLS-family estimator with LDA for "
            "classification and continuous prediction for regression"
        )
        paragraph.clear()
        paragraph.add_run(text)
    set_paragraph(
        document, "Figure S1.",
        "Figure S1. fastPLS and IKPLS on CUDA with identical input matrices. "
        "Classification compares the fastPLS SIMPLS-family estimator with "
        "LDA against improved-kernel PLS with argmax; regression uses "
        "continuous responses. Labels show first-execution time and, in "
        "parentheses, repeated-execution time. Standard tasks use medians of "
        "ten processes; NMR and ImageNet use one. The RTX 5060 Ti has 16 GiB "
        "device memory. Grey cells denote recorded resource failures."
    )
    for section in document.sections:
        section.orientation = WD_ORIENT.PORTRAIT
        if section.page_width < section.page_height:
            continue
        section.page_width, section.page_height = section.page_height, section.page_width

    set_paragraph(
        document,
        "Table S14.",
        "Table S14. Independent Python PLS results using the fixed component "
        "counts shown in Figure 1. The separate scikit-learn NMR feasibility "
        "run is retained and identified explicitly.",
    )
    replace_table(
        document,
        "Table S14.",
        [
            "Method", "Dataset", "Task", "Prec.", "A", "Metric",
            "Value", "Top-5", "Time (s)", "IQR (s)", "RSS (MiB)",
            "Runs", "Status",
        ],
        fixed_python_comparison_rows(),
    )

    delete_section(document, "S2. Algorithms", "S4. CPU and GPU")
    set_paragraph(document, "S4. CPU and GPU", "S3. CPU and CUDA comparisons", "Heading 1")
    filter_table_rows(table_after(document, "Table S4."), "Platform", {"CUDA"})
    filter_table_rows(table_after(document, "Table S5."), "Platform", {"CUDA"})
    remove_table_column(table_after(document, "Table S4."), "Platform")
    remove_table_column(table_after(document, "Table S5."), "Platform")
    timing_table = table_after(document, "Table S4.")
    timing_headers = {
        cell.text.strip(): index
        for index, cell in enumerate(timing_table.rows[0].cells)
    }
    for row in timing_table.rows[1:]:
        cells = row.cells
        dataset = cells[timing_headers["Dataset"]].text.strip()
        family = cells[timing_headers["Family"]].text.strip()
        replacements = None
        if dataset == "NMR" and family == "PLS-SVD":
            replacements = {
                "A": "100", "CPU s": "6.128", "Accel. s": "0.500",
                "Time ratio": "12.26", "CPU metric": "7.195e-04",
                "Accel. metric": "7.194e-04",
            }
        elif dataset == "NMR" and family == "SIMPLS":
            replacements = {
                "A": "50", "CPU s": "1.619", "Accel. s": "0.463",
                "Time ratio": "3.50", "CPU metric": "7.376e-04",
                "Accel. metric": "7.230e-04",
            }
        if replacements:
            for header, value in replacements.items():
                cells[timing_headers[header]].text = value
        if cells[timing_headers["Family"]].text.strip() == "SIMPLS":
            cells[timing_headers["Family"]].text = "SIMPLS family"
    memory_table = table_after(document, "Table S5.")
    memory_headers = {
        cell.text.strip(): index
        for index, cell in enumerate(memory_table.rows[0].cells)
    }
    for row in memory_table.rows[1:]:
        cells = row.cells
        dataset = cells[memory_headers["Dataset"]].text.strip()
        family = cells[memory_headers["Family"]].text.strip()
        replacements = None
        if dataset == "NMR" and family == "PLS-SVD":
            replacements = {
                "A": "100", "CPU RSS MiB": "593.1",
                "Accel. RSS MiB": "679.1", "RSS ratio": "1.15",
                "GPU peak MiB": "564.0",
            }
        elif dataset == "NMR" and family == "SIMPLS":
            replacements = {
                "A": "50", "CPU RSS MiB": "400.4",
                "Accel. RSS MiB": "706.3", "RSS ratio": "1.76",
                "GPU peak MiB": "440.0",
            }
        if replacements:
            for header, value in replacements.items():
                cells[memory_headers[header]].text = value
        if cells[memory_headers["Family"]].text.strip() == "SIMPLS":
            cells[memory_headers["Family"]].text = "SIMPLS family"
    set_paragraph(
        document, "Table S4.",
        "Table S4. Fitting and prediction time and predictive performance for matched float32 CPU/CUDA pairs. A is the number of components; the predictive measure is accuracy for classification and RMSD for regression."
    )
    set_paragraph(
        document, "Table S5.",
        "Table S5. Host-memory increase and CUDA device allocation for the CPU/CUDA comparisons in Table S4. RSS is reported in MiB."
    )
    delete_caption_object(document, "Table S6.")
    delete_caption_object(document, "Table S7.")

    set_paragraph(document, "S5. Component", "S4. Component counts and prediction paths", "Heading 1")
    delete_caption_object(document, "Table S9.")
    if any(p.text.strip().startswith("Table S9 reports") for p in document.paragraphs):
        delete_paragraph(document, "Table S9 reports")
    set_paragraph(
        document, "Table S8.",
        "Table S8. Component counts retained for the PLS-SVD, SIMPLS-family, OPLS and linear kernel-PLS benchmark workflows. PLS-SVD counts for GTEx v8, MetRef and TCGA Pan-Cancer are constrained by response rank."
    )
    replace_table(
        document, "Table S8.",
        ["Dataset", "PLS-SVD", "SIMPLS family", "OPLS", "Linear kernel PLS"],
        fixed_component_rows()
    )
    for number, dataset in enumerate([
        "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
        "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer",
        "cbmc_citeseq", "prism"
    ], start=1):
        replace_picture_before_caption(
            document, f"Figure S{number}.", PATH_FIGURES / f"component_path_{dataset}.png"
        )
        caption = find_paragraph(document, f"Figure S{number}.")
        text = caption.text
        text = text.replace(
            "colours and point shapes identify the hardware in the legend.",
            "colours and point shapes distinguish Linux CPU and CUDA."
        ).replace(
            "Dotted lines mark training-selected counts.",
            "Dotted lines mark the retained benchmark component counts."
        ).replace(
            " in fastPLS 0.99.65",
            " in fastPLS"
        )
        caption.clear()
        caption.add_run(text)

    delete_paragraph(document, "S6. NMR")
    delete_caption_object(document, "Table S10.")
    replace_picture_before_caption(document, "Figure S12.", FIGURES / "figureS12_nmr_test_component_path.png")
    set_paragraph(
        document, "Figure S12.",
        "Figure S12. NMR prediction and computational cost across component counts on Linux CPU and CUDA. Each model was fitted on all 1,200 training spectra and evaluated on the fixed 321 test spectra. Rows show held-out RMSD, fitting and prediction time, and host-RSS increase; columns show the four PLS families. Dotted lines mark the retained benchmark counts: 100 for PLS-SVD and 50 for the SIMPLS-family estimator, OPLS and kernel PLS."
    )
    delete_caption_object(document, "Table S11.")
    if any(p.text.strip().startswith("Table S11 and Figure 3") for p in document.paragraphs):
        delete_paragraph(document, "Table S11 and Figure 3")
    delete_caption_object(document, "Figure S13.", remove_following_table=False)
    delete_caption_object(document, "Figure S14.", remove_following_table=False)

    set_paragraph(
        document, "Each setting used three fresh",
        "Each setting used three fresh processes and the fastPLS R interface. Time includes CUDA initialization, fitting and test prediction. CPU/CUDA results are paired on the Intel/NVIDIA workstation. A CPU/CUDA time ratio above one indicates faster CUDA execution. Memory values are increases in process RSS above the recorded baseline, including runtime allocations; device allocation may also include CUDA context, library and allocator storage."
    )
    delete_paragraph(document, "The comparison recorded 360")
    if any(p.text.strip().startswith("Each solver pair used") for p in document.paragraphs):
        delete_paragraph(document, "Each solver pair used")
    set_paragraph(
        document, "Component selection for the eleven",
        "The retained benchmark component counts are listed in Table S6. Figures S2-S12 show the corresponding test-set paths for the general datasets on Linux CPU and CUDA. Classification paths report argmax and LDA where both were evaluated; regression paths report RMSD. The dotted line in each family panel identifies the retained count."
    )
    set_paragraph(
        document, "The NMR selection grid was",
        "The NMR path used the supplied training/test split and component counts from 1 to 300. Figure S12 reports held-out RMSD, fitting and prediction time, and host-memory increase. The retained comparison uses 100 PLS-SVD components and 50 components for the SIMPLS-family estimator, OPLS and kernel PLS."
    )

    delete_section(document, "S7. CPU thread", "S9. Independent")
    set_paragraph(document, "S9. Independent", "S2. Independent implementations", "Heading 1")
    delete_paragraph(document, "Argmax classification across accelerator backends")
    delete_paragraph(document, "Figure S18 contains")
    if any(p.text.strip().startswith("Figure S18 uses") for p in document.paragraphs):
        delete_paragraph(document, "Figure S18 uses")
    delete_caption_object(document, "Figure S18.", remove_following_table=False)
    if any(p.text.strip().startswith("Figure S19 provides") for p in document.paragraphs):
        delete_paragraph(document, "Figure S19 provides")
    delete_caption_object(document, "Figure S19.", remove_following_table=False)

    cross_validation_heading = find_paragraph_element(
        document, "S10. Cross-validation"
    )
    add_paragraph_before(
        document, cross_validation_heading,
        "OPLS and kernel-PLS execution", "Heading 2"
    )
    add_paragraph_before(
        document, cross_validation_heading,
        "Algorithms S1 and S2 map the two model-family workflows to the "
        "current compiled implementation. Both use training-derived "
        "preprocessing and the shared SIMPLS-family predictive core. OPLS "
        "adds a sequential orthogonal filter before that core, whereas "
        "nonlinear kernel PLS replaces the predictor matrix with a centred "
        "training Gram matrix. Classification by argmax or LDA is applied "
        "after the model-specific score and prediction steps."
    )
    add_algorithm_before(
        document,
        "S10. Cross-validation",
        "Algorithm S1. OPLS training and prediction in fastPLS. The "
        "orthogonal filter is estimated from the training data before the "
        "predictive SIMPLS-family model is fitted.",
        [
            (
                1,
                "Input training predictors X, responses Y or compact class "
                "labels z, A predictive components and O orthogonal "
                "components. Estimate predictor centres and scales from X; "
                "centre Y, or form the equivalent label-aware class "
                "cross-product without constructing a one-hot response."
            ),
            (
                2,
                "Standardize X to X(1) and form the current predictor-response "
                "cross-covariance S(1) = X(1)ᵀY(c). For classification, "
                "S(1) is obtained from class counts and class-wise predictor "
                "sums."
            ),
            (
                3,
                "For orthogonal component o = 1,...,O, obtain a unit "
                "predictive direction w(o) from the leading left direction "
                "of S(o) using the configured randomized solver and the "
                "component-specific seed."
            ),
            (
                4,
                "Compute the predictive score t(o) = X(o)w(o) and loading "
                "p(o) = X(o)ᵀt(o) / [t(o)ᵀt(o)]. Stop with an explicit "
                "failure if a required norm is non-finite or zero."
            ),
            (
                5,
                "Remove the part of p(o) parallel to w(o): w⊥(o) = p(o) - "
                "w(o)[w(o)ᵀp(o)]/[w(o)ᵀw(o)], then normalize w⊥(o). This "
                "constructs a predictor direction orthogonal to the current "
                "predictive weight."
            ),
            (
                6,
                "Compute t⊥(o) = X(o)w⊥(o) and p⊥(o) = "
                "X(o)ᵀt⊥(o) / [t⊥(o)ᵀt⊥(o)]. Store w⊥(o) and p⊥(o), then "
                "deflate X(o+1) = X(o) - t⊥(o)p⊥(o)ᵀ directly as a rank-one "
                "update."
            ),
            (
                7,
                "Refresh S(o+1) from the deflated predictors. An eligible "
                "sufficient-statistics route performs the algebraically "
                "corresponding updates to XᵀX and XᵀY instead of "
                "materializing each deflated predictor matrix. Repeat Steps "
                "3-7 until O components are complete."
            ),
            (
                8,
                "Fit one A-component SIMPLS-family predictive path to the "
                "filtered predictors X(O+1) and the centred response. Store "
                "the orthogonal weights and loadings, predictive latent "
                "factors, preprocessing statistics and response mean."
            ),
            (
                9,
                "For new predictors X(new), apply the stored training centre "
                "and scale. Sequentially compute t⊥(o,new) = "
                "X(new,o)w⊥(o) and update X(new,o+1) = X(new,o) - "
                "t⊥(o,new)p⊥(o)ᵀ for o = 1,...,O."
            ),
            (
                10,
                "Predict from the filtered X(new,O+1) with the retained "
                "SIMPLS-family prefix and restore the response mean. For "
                "classification, pass the resulting responses or scores to "
                "the requested argmax or LDA prediction head."
            ),
        ]
    )
    add_algorithm_before(
        document,
        "S10. Cross-validation",
        "Algorithm S2. Linear and nonlinear kernel-PLS training and "
        "prediction in fastPLS. The nonlinear route stores an n × n "
        "training Gram matrix and its centring statistics.",
        [
            (
                1,
                "Input training predictors X, responses Y or compact class "
                "labels z, A components, and a linear, radial-basis or "
                "polynomial kernel. Estimate predictor centres and scales "
                "from X and the response mean from Y; classification uses "
                "the equivalent label-aware response construction."
            ),
            (
                2,
                "Standardize X to X(c). For the linear kernel, set the design "
                "matrix Z = X(c) and continue to Step 5 without forming an "
                "n by n Gram matrix."
            ),
            (
                3,
                "For a nonlinear kernel, form K(i,j) from standardized "
                "training rows: exp[-γ||x(i)-x(j)||²] for the radial-basis "
                "kernel or [γx(i)ᵀx(j)+c]ᵈ for the polynomial kernel. Store "
                "X(c) as the training reference."
            ),
            (
                4,
                "Compute the training row means, column means and grand mean "
                "of K, and double-centre it as K(c)(i,j) = K(i,j) - "
                "rowmean(i) - colmean(j) + grandmean. Set Z = K(c) and store "
                "the training column means and grand mean for prediction."
            ),
            (
                5,
                "Form S = ZᵀY(c), or its label-aware equivalent, and fit one "
                "A-component SIMPLS-family path to Z. Retain the compact "
                "latent factors, response mean and predictor preprocessing "
                "statistics."
            ),
            (
                6,
                "For new predictors X(new), apply the stored training centre "
                "and scale. With a linear kernel, set Z(new) = X(new,c)."
            ),
            (
                7,
                "With a nonlinear kernel, compute the cross-kernel K(new) "
                "between X(new,c) and the stored training reference. Centre "
                "each new row using its own mean together with the stored "
                "training column means and training grand mean; set "
                "Z(new) to this centred cross-kernel."
            ),
            (
                8,
                "Predict from Z(new) with the requested SIMPLS-family prefix "
                "and restore the response mean. For classification, apply "
                "argmax or fit and apply LDA on the corresponding training "
                "scores."
            ),
            (
                9,
                "During cross-validation, repeat all preprocessing and "
                "nonlinear Gram centring within each training fold. The "
                "linear route can use the leakage-free sufficient-statistics "
                "algorithm; the nonlinear route cannot reuse a full-data "
                "centred Gram matrix."
            ),
        ]
    )

    set_paragraph(document, "S10. Cross-validation", "S5. Cross-validation workflow timing", "Heading 1")
    delete_caption_object(document, "Figure S20.", remove_following_table=False)
    set_paragraph(
        document, "We compared one complete ten-fold",
        "To quantify cross-validation overhead, we compared one complete "
        "ten-fold cross-validation run with a single model fitted to the full "
        "training partition and used to predict the fixed test partition. "
        "Within each pair, the dataset, PLS family, component count, float32 "
        "representation, rSVD controls, random seed and backend were identical. "
        "This timing experiment used argmax for classification solely to keep "
        "the prediction head identical between the two workflows; the "
        "cross-validation functions also support fold-specific LDA. Regression "
        "used continuous predictions. Timings excluded data loading and "
        "conversion. Cross-validation timing included fold construction, model "
        "fitting, out-of-fold prediction and assembly of the held-out scores. "
        "Accelerator measurements also included initialization, host-to-device "
        "and device-to-host transfers, and synchronization."
    )
    set_paragraph(
        document, "All 192 paired workflows",
        "All 48 Linux CPU and 48 CUDA cross-validation workflows shown in "
        "Figure 2C-D completed five repetitions. Ten-fold validation required "
        "a median of 4.14 times one full-training fit plus fixed-test prediction "
        "on the CPU (range 1.08-22.90) and 2.47 times on CUDA (range "
        "1.05-8.25). Forty-seven CPU workflows and all 48 CUDA workflows were "
        "below a ratio of ten. The exception was CPU OPLS on CBMC CITE-seq "
        "(22.90). These ratios are not expected to equal ten because each "
        "training fold contains approximately 90% of the observations and the "
        "compiled workflow reuses fold definitions and sufficient statistics; "
        "the comparator also includes prediction of a separate test set."
    )
    set_paragraph(
        document, "The savings in Algorithm S3",
        "The amount of computational reuse depends on the PLS family. "
        "PLS-SVD calculates one maximal decomposition in each training fold "
        "and evaluates the requested component prefixes from that fit. The "
        "SIMPLS-family route reuses cross-products and updates predictions "
        "incrementally across prefixes. OPLS reuses predictor moments and, for "
        "high-dimensional responses, the sample-space response Gram matrix, "
        "while estimating the orthogonal filter separately within every "
        "training fold. Linear kernel PLS uses the same sequential compiled "
        "core. Less work can be reused for nonlinear kernel PLS because each "
        "fold requires its own training Gram matrix and held-out cross-kernel, "
        "both centred using only the training-fold observations."
    )
    add_algorithm_after(
        document,
        "The amount of computational reuse depends on the PLS family",
        "Algorithm S3. Leakage-free sufficient-statistics cross-validation. "
        "The cached route is used only when the fold map covers every row and "
        "the storage/work guard accepts it; otherwise the same training-only "
        "quantities are computed directly within each fold.",
        [
            (
                1,
                "Input X, response Y or compact class labels z, fixed fold "
                "map f, candidate component set A, PLS family, scaling rule, "
                "prediction head, backend and seed. Validate dimensions and "
                "keep user-supplied groups intact when f is constructed."
            ),
            (
                2,
                "Before the fold loop, compute only eligible additive "
                "statistics: predictor sums sx, squared sums qx and XᵀX; "
                "for regression, response sums sy and optionally XᵀY or "
                "YYᵀ; for classification, class counts nc and class-wise "
                "predictor sums mc. Do not centre or scale with full-data "
                "means."
            ),
            (
                3,
                "For fold h = 1,...,K, set H = {i : f(i) = h} and define T "
                "as all row indices not in H. All following fitting quantities are "
                "defined for T; H is used only to remove its additive "
                "contribution and later to obtain predictions."
            ),
            (
                4,
                "Recover training marginals exactly: sx,T = sx - Σ(i in H) "
                "xi; qx,T = qx - Σ(i in H) xi²; and, for regression, "
                "sy,T = sy - Σ(i in H) yi. For classification use "
                "nc,T = nc - nc,H and mc,T = mc - mc,H."
            ),
            (
                5,
                "Compute predictor centres and scales and the response mean "
                "only from the recovered T statistics. Apply these "
                "training-fold values unchanged to X_H. A class absent from T "
                "is not fitted or predicted, but its held-out observations "
                "remain in the evaluation."
            ),
            (
                6,
                "When cached, recover the raw training cross-product as full "
                "XᵀY minus X_HᵀY_H and the raw training predictor Gram as "
                "full XᵀX minus X_HᵀX_H, then centre "
                "and scale them with T statistics. For labels, form the "
                "centred class cross-product from nc,T and mc,T without a "
                "one-hot matrix."
            ),
            (
                7,
                "For an eligible wide response, extract YYᵀ[T,T]. Obtain "
                "each training row sum by subtracting its entries against H "
                "from the cached full row sum, and double-centre the principal "
                "submatrix using only T. Retain one triangle until a full "
                "matrix is required."
            ),
            (
                8,
                "Fit one maximal PLS-SVD, SIMPLS-family, OPLS or linear "
                "kernel-PLS component path for T with seed + h and evaluate "
                "all requested prefixes in A. Fit the OPLS filter inside T. "
                "For nonlinear kernel PLS, build and centre the training Gram "
                "and held-out cross-kernel separately for this fold; do not "
                "apply the linear sufficient-statistics shortcut."
            ),
            (
                9,
                "Predict rows H after applying the T preprocessing. Argmax "
                "uses the fold response scores; LDA is fitted only from "
                "training scores or algebraically equivalent T-only moments. "
                "Write predictions back to their original row positions."
            ),
            (
                10,
                "After all folds, compute each candidate metric from the "
                "complete out-of-fold predictions and select within A using "
                "the declared rule. For nested CV, rerun Steps 1-10 inside "
                "each outer-training partition and evaluate the selected fit "
                "once on that outer holdout."
            ),
        ]
    )

    set_paragraph(document, "S11. Large", "S6. Large embedding matrices", "Heading 1")
    set_paragraph(document, "S12. Computational", "S7. Computational environment and reproducibility", "Heading 1")
    set_paragraph(
        document, "BLAS (Basic",
        "The software release described in this study is fastPLS version 0.3. BLAS (Basic Linear Algebra Subprograms) and LAPACK specify common matrix operations and decompositions. Linux performance builds used OpenBLAS. If OpenBLAS is absent, fastPLS can be built with R's BLAS/LAPACK, but such a build is not the CPU baseline reported here. The linked library affects speed and threading and can be inspected with fastPLS_blas()."
    )
    env_table = table_after(document, "Table S18.")
    for row in list(env_table.rows[1:]):
        text = " ".join(cell.text for cell in row.cells).lower()
        if any(token in text for token in ("apple", "mac", "metal")):
            env_table._tbl.remove(row._tr)
        elif row.cells[0].text.strip() == "Package":
            row.cells[1].text = "R, Python and MATLAB interfaces"
            row.cells[2].text = (
                "Source identifiers belong to the individual measurements"
            )
        elif row.cells[0].text.strip() == "Public interfaces":
            row.cells[1].text = "R; Python; MATLAB"
    set_paragraph(
        document, "The benchmark scripts record",
        "The benchmark scripts record method, component count, precision, randomized controls, implementation, elapsed time, predictive measures and completion status. The CMPB analyses use the Linux CPU and CUDA calculations identified with each figure or table. Interface checks and other platform-specific implementation studies are reported separately in the software article."
    )

    formal_heading = document.add_paragraph(
        "S8. Formal verification of algebraic invariants",
        style="Heading 1"
    )
    formal_heading.paragraph_format.page_break_before = True
    document.add_paragraph(
        "Ten algebraic statements underlying the fastPLS execution changes "
        "were encoded in Lean 4 and checked with the Mathlib mathematical "
        "library [34,35]. The statements are quantified over finite matrix "
        "dimensions and real-valued entries. They test identities used by "
        "the PLS-SVD, SIMPLS-family, OPLS, kernel-PLS and compiled "
        "cross-validation paths (Table S9). The complete Lean project pins "
        "the toolchain and resolved Mathlib revision. Its source is provided "
        "in the fastPLS-extra repository at formal/lean, with the theorem "
        "statements and proofs in FastPLSFormal/Invariants.lean. The complete "
        "verification is reproduced by running lake build from that directory."
    )
    caption = document.add_paragraph(
        "Table S9. Algebraic invariants checked by Lean. Every listed theorem "
        "was accepted by the pinned Lean 4 and Mathlib proof checker."
    )
    caption.paragraph_format.keep_with_next = True
    for run in caption.runs:
        run.bold = True
    append_table(
        document,
        ["Lean theorem", "Implementation area", "Checked statement"],
        [
            [
                "implicit_crossCovariance", "PLS-SVD, SIMPLS and kernel PLS",
                "The matrix-free action Xᵀ(YΩ) equals (XᵀY)Ω."
            ],
            [
                "compact_prediction", "SIMPLS and linear kernel PLS",
                "Latent prediction (XnewR)Qᵀ equals prediction with the dense coefficient matrix Xnew(RQᵀ)."
            ],
            [
                "plssvd_latent_normal_equation", "PLS-SVD",
                "If HL = D, the retained latent map satisfies H(LVᵀ) = DVᵀ."
            ],
            [
                "simpls_deflation_orthogonal", "SIMPLS family",
                "For a unit direction v, vᵀ[S - v(vᵀS)] = 0."
            ],
            [
                "simpls_cached_gram_entry", "SIMPLS family",
                "For a unit direction v, the inner product of two deflated "
                "columns equals their original inner product minus "
                "(vᵀx)(vᵀy)."
            ],
            [
                "opls_weight_is_orthogonal", "OPLS",
                "Removing the projection of a loading p onto a nonzero predictive weight w produces a weight orthogonal to w."
            ],
            [
                "linear_kernel_symmetric", "Kernel PLS",
                "The linear Gram matrix XXᵀ is symmetric."
            ],
            [
                "double_centering_preserves_symmetry", "Kernel PLS",
                "Double centering HKH preserves symmetry when H and K are symmetric."
            ],
            [
                "centered_gram_entry", "Kernel PLS and cross-validation",
                "A centered Gram entry equals its uncentered entry minus the two mean cross-terms plus the mean Gram term."
            ],
            [
                "training_statistic_by_subtraction", "Cross-validation",
                "For disjoint training and holdout sets, the training sufficient statistic equals the full statistic minus the holdout statistic."
            ],
        ],
        size=7.5
    )
    document.add_paragraph(
        "The SIMPLS deflation theorem applies after each accepted direction "
        "has been normalized, regardless of how that direction was obtained. "
        "It therefore verifies the deflation invariant shared by the "
        "one-direction recurrence and the bounded-block route. It does not "
        "prove that candidates reused from one deflated state equal directions "
        "recomputed after every component. The bounded-block implementation is "
        "accordingly described as an approximate SIMPLS-family estimator, "
        "rather than classical de Jong SIMPLS."
    )
    document.add_paragraph(
        "These proofs concern exact algebra over real numbers. They do not "
        "establish bounds for randomized SVD, floating-point error in float32 "
        "or float64, equivalence between the Lean specification and the C++ or "
        "GPU instructions, numerical stability, or predictive performance. "
        "Those questions remain covered by the numerical tests and empirical "
        "benchmarks."
    )

    move_section_before(
        document, "S2. Independent implementations",
        "S5. Cross-validation workflow timing", "S3. CPU and CUDA comparisons"
    )
    move_section_before(
        document, "OPLS and kernel-PLS execution",
        "S3. CPU and CUDA comparisons", "S5. Cross-validation workflow timing"
    )
    replace_references(document, {
        "Table S14": "Table S1", "Table S15": "Table S2",
        "Table S16": "Table S3", "Table S4": "Table S4",
        "Table S5": "Table S5", "Table S8": "Table S6",
        "Table S17": "Table S7", "Table S18": "Table S8",
        "Figure S17": "Figure S1",
        "Figure S20": "Figure S15", "Figure S12": "Figure S13",
        "Figure S11": "Figure S12", "Figure S10": "Figure S11",
        "Figure S9": "Figure S10", "Figure S8": "Figure S9",
        "Figure S7": "Figure S8", "Figure S6": "Figure S7",
        "Figure S5": "Figure S6", "Figure S4": "Figure S5",
        "Figure S3": "Figure S4", "Figure S2": "Figure S3",
        "Figure S1": "Figure S2", "[34]": "[33]"
    })
    for prefix, title in {
        "Table S4.": "Table S4. Fitting and prediction time and predictive performance for matched float32 CPU/CUDA pairs. A is the number of components; the predictive measure is accuracy for classification and RMSD for regression.",
        "Table S5.": "Table S5. Host-memory increase and CUDA device allocation for the CPU/CUDA comparisons in Table S4. RSS is reported in MiB.",
        "Table S6.": "Table S6. Component counts retained for the benchmark workflows. PLS-SVD counts for GTEx v8, MetRef and TCGA Pan-Cancer are constrained by response rank.",
    }.items():
        set_paragraph(document, prefix, title)

    references_heading = document.add_paragraph(
        "Supplementary references",
        style="Heading 1"
    )
    references_heading.paragraph_format.page_break_before = True
    document.add_paragraph(
        "Reference numbers are retained from the main article. Only works "
        "cited in this supplementary material are listed below."
    )
    supplementary_references = [
        "[7] Vignoli A, Cacciatore S, Tenori L. Deriving three "
        "one-dimensional NMR spectra from a single experiment through "
        "machine learning. Nature Communications. 2025;16:10159. "
        "doi:10.1038/s41467-025-65294-x.",
        "[17] Oquab M, Darcet T, Moutakanni T, et al. DINOv2: Learning "
        "Robust Visual Features without Supervision. Transactions on "
        "Machine Learning Research. 2024. "
        "https://openreview.net/forum?id=a68SUt6zFt.",
        "[18] Deng J, Dong W, Socher R, Li LJ, Li K, Fei-Fei L. ImageNet: "
        "a large-scale hierarchical image database. IEEE Conference on "
        "Computer Vision and Pattern Recognition. 2009:248-255. "
        "doi:10.1109/CVPR.2009.5206848.",
        "[19] Cacciatore S, Tenori L, Luchinat C, Bennett PR, MacIntyre DA. "
        "KODAMA: an R package for knowledge discovery and data mining. "
        "Bioinformatics. 2017;33:621-623. "
        "doi:10.1093/bioinformatics/btw705.",
        "[23] Assfalg M, Bertini I, Colangiuli D, et al. Evidence of "
        "different metabolic phenotypes in humans. Proceedings of the "
        "National Academy of Sciences of the United States of America. "
        "2008;105:1420-1424. doi:10.1073/pnas.0705685105.",
        "[24] Dieterle F, Ross A, Schlotterbeck G, Senn H. Probabilistic "
        "quotient normalization as robust method to account for dilution "
        "of complex biological mixtures: application in 1H NMR "
        "metabonomics. Analytical Chemistry. 2006;78:4281-4290. "
        "doi:10.1021/ac051632c.",
        "[25] GTEx Consortium. The GTEx Consortium atlas of genetic "
        "regulatory effects across human tissues. Science. "
        "2020;369:1318-1330. doi:10.1126/science.aaz1776.",
        "[26] Hoadley KA, Yau C, Hinoue T, et al. Cell-of-origin patterns "
        "dominate the molecular classification of 10,000 tumors from 33 "
        "types of cancer. Cell. 2018;173:291-304.e6. "
        "doi:10.1016/j.cell.2018.03.022.",
        "[27] Ghandi M, Huang FW, Jane-Valbuena J, et al. Next-generation "
        "characterization of the Cancer Cell Line Encyclopedia. Nature. "
        "2019;569:503-508. doi:10.1038/s41586-019-1186-3.",
        "[28] Cancer Genome Atlas Network. Comprehensive molecular "
        "portraits of human breast tumours. Nature. 2012;490:61-70. "
        "doi:10.1038/nature11412.",
        "[29] Cancer Genome Atlas Network. Comprehensive genomic "
        "characterization of head and neck squamous cell carcinomas. "
        "Nature. 2015;517:576-582. doi:10.1038/nature14129.",
        "[30] Stoeckius M, Hafemeister C, Stephenson W, et al. Simultaneous "
        "epitope and transcriptome measurement in single cells. Nature "
        "Methods. 2017;14:865-868. doi:10.1038/nmeth.4380.",
        "[31] Macosko EZ, Basu A, Satija R, et al. Highly parallel "
        "genome-wide expression profiling of individual cells using "
        "nanoliter droplets. Cell. 2015;161:1202-1214. "
        "doi:10.1016/j.cell.2015.05.002.",
        "[32] Tabula Muris Consortium. Single-cell transcriptomics of 20 "
        "mouse organs creates a Tabula Muris. Nature. "
        "2018;562:367-372. doi:10.1038/s41586-018-0590-4.",
        "[33] Corsello SM, Nagari RT, Spangler RD, et al. Discovering the "
        "anticancer potential of non-oncology drugs by systematic viability "
        "profiling. Nature Cancer. 2020;1:235-248. "
        "doi:10.1038/s43018-019-0018-6.",
        "[34] de Moura L, Ullrich S. The Lean 4 theorem prover and "
        "programming language. In: Automated Deduction - CADE 28. Lecture "
        "Notes in Computer Science. 2021;12699:625-635. "
        "doi:10.1007/978-3-030-79876-5_37.",
        "[35] The mathlib Community. The Lean mathematical library. In: "
        "Proceedings of the 9th ACM SIGPLAN International Conference on "
        "Certified Programs and Proofs. 2020:367-381. "
        "doi:10.1145/3372885.3373824.",
    ]
    for reference in supplementary_references:
        paragraph = document.add_paragraph(reference)
        paragraph.paragraph_format.space_after = Pt(4)

    OUTPUT.mkdir(parents=True, exist_ok=True)
    path = OUTPUT / "fastPLS_CMPB_supplement_restructured.docx"
    document.save(path)
    return path


def build_cmpb_main():
    document = Document(INPUT_MAIN)
    find_paragraph(document, "2.2 Classification").style = "Heading 2"
    set_paragraph(
        document, "fastPLS: accelerated SIMPLS",
        "fastPLS: an accelerated SIMPLS-family estimator for "
        "high-dimensional biomedical data"
    )
    set_paragraph(
        document, "Background and objective:",
        "Background and objective: Partial least squares (PLS) is widely used "
        "to predict biomedical outcomes from correlated measurements. Its "
        "computational cost increases when models require many components or "
        "predict thousands of responses, as in nuclear magnetic resonance "
        "(NMR) spectroscopy. We developed fastPLS to reduce the time and "
        "storage required by a sequential SIMPLS-family estimator."
    )
    abstract_results = find_paragraph(document, "Results:")
    abstract_results.text = abstract_results.text.replace(
        "CUDA SIMPLS required", "CUDA SIMPLS-family execution required"
    )
    set_paragraph(
        document, "Keywords:",
        "Keywords: partial least squares; SIMPLS family; randomized singular "
        "value decomposition; GPU computing; NMR; omics"
    )
    set_paragraph(
        document, "NMR reconstruction illustrates",
        find_paragraph(document, "NMR reconstruction illustrates").text.replace(
            "An efficient SIMPLS implementation",
            "An efficient SIMPLS-family implementation"
        )
    )
    set_paragraph(
        document, "Here we describe fastPLS",
        "Here we describe fastPLS, an implementation that reduces repeated "
        "computation and model storage during SIMPLS-family fitting and "
        "prediction. Its main features are reusable matrix products, compact "
        "prediction factors and specialized calculations for many-response "
        "and multiclass problems. We evaluate the implementation against "
        "independent software and across CPU and GPU hardware [21], with NMR "
        "reconstruction as the principal biomedical application. The shared "
        "C++ core is available through R, Python and MATLAB."
    )
    set_paragraph(
        document, "SIMPLS extracts successive",
        "Classical SIMPLS extracts successive directions while orthogonalizing "
        "predictor loadings and deflating the cross-covariance [8]. The public "
        "fastPLS method name simpls retains these sequential updates and "
        "reuses each deflation product, while storing only the predictor weights "
        "and response loadings needed for prediction (Algorithm 1). For "
        "responses with many columns, calculations in sample space avoid "
        "repeatedly multiplying by the full response matrix. For classification, "
        "class sums provide the required cross-products without constructing a "
        "dense indicator matrix. Some large problems use a bounded block of "
        "candidate directions computed from one deflated state and then apply "
        "the sequential orthogonalization and deflation updates to each accepted "
        "candidate. Because the leading direction is not recomputed after every "
        "component within that block, this execution defines an approximate "
        "SIMPLS-family estimator rather than classical de Jong SIMPLS. The "
        "component-path and held-out results therefore evaluate the implemented "
        "estimator directly."
    )
    set_paragraph(
        document, "Algorithm 1.",
        "Algorithm 1. Accelerated SIMPLS-family execution. A bounded candidate "
        "block is an approximate estimator because its directions are computed "
        "from one deflated state."
    )
    set_paragraph(
        document, "OPLS first filters",
        "OPLS first filters response-orthogonal predictor variation and then fits a predictive PLS model. Linear kernel PLS uses the predictor representation directly, whereas nonlinear kernel PLS constructs and centres an n by n kernel matrix. The quadratic storage of the nonlinear Gram matrix limits the sample sizes that can be fitted. The principal rSVD benchmark setting used 32 oversampling directions, five power iterations and seed 123."
    )
    add_paragraph_after(
        document, "OPLS first filters",
        "Ten exact algebraic identities used by the optimized PLS-SVD, "
        "SIMPLS-family, OPLS, kernel-PLS and cross-validation paths were "
        "formalized in Lean 4 with Mathlib [34,35]. The formal specification, "
        "located at https://github.com/tkcaccia/fastPLS-extra/tree/main/formal/lean, "
        "pins the Lean toolchain and Mathlib revision and is checked by running "
        "lake build. The verified statements and scope limitations are given "
        "in Supplementary Section S8."
    )
    replace_table_cell_text(
        document.tables[1],
        "For each requested component count a, solve",
        "For each requested component count a, solve "
        "H[1:a,1:a] Lₐ = D[1:a,1:a] by Cholesky factorization, with a "
        "general linear solve as the numerical fallback; do not invert H "
        "explicitly."
    )
    replace_table_cell_text(
        document.tables[1],
        "Form and retain the compact latent response map",
        "Form and retain the compact latent response map Wₐ = Lₐ Vₐᵀ. "
        "A dense predictor-by-response coefficient matrix UₐWₐ is formed "
        "only when an output explicitly requires it."
    )
    set_paragraph(
        document, "Classification was evaluated",
        "Classification was evaluated using either the largest predicted "
        "class-indicator response, termed argmax, or linear discriminant "
        "analysis (LDA) fitted to the PLS scores. For a score matrix T with a "
        "retained components, let n(c) and μ(c) denote the count and score mean "
        "of class c. The pooled covariance is Σ = [TᵀT - ∑ over c "
        "n(c)μ(c)μ(c)ᵀ] / max(1, n - C). The implementation solves "
        "(Σ + λI)w(c) = μ(c) by Cholesky "
        "factorization and triangular solves. It sets s = trace(Σ) / a, or "
        "s = 1 when this value is not finite and positive, and tries "
        "λ = ρs for ρ = 10⁻⁸, 10⁻⁶, 10⁻⁵, 10⁻⁴, 10⁻³ and "
        "10⁻², increasing ρ only after a failed factorization. Prediction "
        "uses δ(c | t) = tᵀw(c) - 0.5 μ(c)ᵀw(c) + log[n(c) / n]. "
        "Regression "
        "directly predicts the continuous responses."
    )
    set_paragraph(
        document, "The software provides single and nested cross-validation",
        "Single and nested cross-validation were implemented with optional "
        "grouped fold assignment. When a grouping identifier, such as donor "
        "or patient identity, is supplied, all observations from the same "
        "group are assigned to one fold. Related samples "
        "therefore cannot be divided between the training and held-out "
        "partitions; in nested cross-validation, this restriction is applied "
        "in both the outer and inner folds. For eligible "
        "compiled routes, additive sufficient statistics were calculated once "
        "and the statistics for each training fold were obtained by "
        "subtracting the held-out contribution. Centering, scaling, model "
        "fitting and, when requested, LDA fitting were then performed from "
        "these training-only quantities. This reuse reduces repeated work "
        "without allowing held-out observations to influence fitted "
        "parameters. Nonlinear kernel PLS was handled separately because the "
        "training Gram matrix and the held-out-to-training cross-kernel must "
        "be constructed and centred within each fold. Classification can use "
        "either response-score argmax or LDA fitted to the training-fold PLS "
        "scores; both prediction heads may also be compared within the same "
        "tuning grid. Candidate configurations can be selected using accuracy, "
        "balanced accuracy or another documented classification metric. "
        "Regression selection can use root mean squared deviation (RMSD) or "
        "another documented regression metric. Training-fit measures are "
        "reported separately from out-of-fold performance. Supplementary "
        "Algorithm S3 gives the complete single and nested procedures."
    )
    set_paragraph(
        document, "The backend experiment",
        "The backend experiment paired CPU and CUDA on an Intel Core i7-13700 workstation with 32 GiB RAM and an NVIDIA GeForce RTX 5060 Ti with 16 GiB device memory [21]. All four PLS families used float32 inputs; classification used argmax to avoid changing the prediction head between backends. Three fresh processes were requested per setting. Timing included initialization, transfers, fitting, prediction and synchronization, but excluded data loading and conversion."
    )
    delete_paragraph(document, "A separate precision comparison")
    set_paragraph(
        document, "Additional experiments compared",
        "Component-path experiments evaluated predictive performance, fitting and prediction time, and process memory across the retained component grids. The fixed workloads used for the independent-software comparison were kept separate from these path analyses."
    )
    set_paragraph(
        document, "NMR preprocessing",
        "NMR preprocessing and the supplied split of 1,200 training and 321 test spectra are described in Supplementary Section S1. Component paths were evaluated on the fixed held-out set. The principal comparison used 100 PLS-SVD components and 50 SIMPLS-family components. The deposited fastsimpls PLS-SVD implementation from the NMR study [7] was rerun at its published 165-component setting with IRLBA and float64 on the same prepared data."
    )
    delete_paragraph(document, "Numerical checks compared")
    delete_paragraph(document, "The dominant operations")
    delete_paragraph(document, "In the controlled solver comparison")
    delete_paragraph(document, "The effect of requesting four CPU cores")
    set_paragraph(
        document, "3.2 Solver and backend execution",
        "3.2 Component paths and CUDA execution",
        "Heading 2"
    )
    set_paragraph(
        document, "Figure 1.",
        "Figure 1. Prediction, runtime and memory for PLS software on an Intel Core i7-13700 workstation with one effective CPU thread. fastPLS uses its SIMPLS-family estimator with LDA for classification and continuous prediction for regression. A and B: test accuracy and RMSD. C and D: fitting and prediction time. E and F: absolute peak process RSS. Time and memory share colour scales across classification and regression. fastPLS and IKPLS used float32; independent-software settings and repetition counts are given in Tables S1-S3. Standard fastPLS and IKPLS tasks used ten processes; the focused fastPLS NMR benchmark used three and ImageNet used one. rSVD used oversampling 32, five power iterations and seed 123. Failed indicates an attempted calculation that did not complete; NE indicates not evaluated."
    )
    set_paragraph(
        document, "At 99 CIFAR-100 components",
        "At 99 CIFAR-100 components, fastPLS required 0.451 s and correctly "
        "classified 8,705 of 10,000 test observations; scikit-learn required "
        "414.8 s with accuracy 0.8696. For multivariate regression, fastPLS "
        "required 0.115 s on CBMC CITE-seq, 0.631 s on PRISM and 1.619 s on "
        "NMR. IKPLS was slightly faster on CBMC CITE-seq and slower on PRISM, "
        "with similar predictive measures on both. The tested IKPLS "
        "implementation could not complete NMR because the coefficient array "
        "exceeded the workstation memory."
    )
    set_paragraph(
        document, "CUDA completed all 52",
        "CUDA completed all 52 paired fitting and prediction calculations and "
        "was faster than the CPU in 15 (Figure 2A-B): all four families on "
        "CIFAR-100, NMR and ImageNet, and the SIMPLS-family, OPLS and linear kernel PLS "
        "on PRISM. CPU/CUDA runtime ratios ranged from 40.5 to 193.5 for "
        "ImageNet and from 3.4 to 17.2 for NMR. Supplementary Table S4 gives "
        "the paired performance measurements, Table S5 gives memory, and Table S6 "
        "records the retained component counts. The corresponding prediction, "
        "runtime and memory paths are shown for the classification datasets in "
        "Figures S2-S10 and the regression datasets in Figures S11-S13."
    )
    add_paragraph_after(
        document, "CUDA completed all 52",
        "All 48 CPU and 48 CUDA ten-fold cross-validation workflows completed "
        "five repetitions (Figure 2C-D). Relative to one full-training fit plus "
        "fixed-test prediction, the median validation cost was 4.14-fold on "
        "the CPU (range 1.08-22.90) and 2.47-fold on CUDA (range 1.05-8.25). "
        "Forty-seven of 48 CPU workflows and all CUDA workflows were below the "
        "nominal cost of repeating the comparator ten times; CPU OPLS on CBMC "
        "CITE-seq was the exception (22.90-fold). In a direct paired comparison, "
        "CUDA reduced validation time in 16 of 48 settings. The largest CUDA "
        "advantages were observed for PRISM with the SIMPLS-family and linear kernel PLS "
        "(approximately 11-fold) and for NMR with PLS-SVD (8.85-fold), whereas "
        "the CPU remained faster for most smaller workloads."
    )
    replace_picture_before_caption(document, "Figure 1.", FIGURE1, 6.6)
    replace_picture_before_caption(document, "Figure 2.", FIGURE2, 6.6)
    move_caption_after_picture(document, "Figure 2.")
    caption = find_paragraph(document, "Figure 2.")
    caption.clear()
    caption.add_run(
        "Figure 2. CPU and CUDA execution on the same Intel Core i7-13700/RTX 5060 Ti workstation. All calculations used float32 and classification used argmax. A and B include 13 datasets and four PLS families. A: CPU time divided by CUDA time for fitting and held-out prediction, with values above 1 indicating faster CUDA execution. B: CUDA host-RSS increment divided by the CPU increment, with values below 1 indicating less host-memory growth. C and D: complete ten-fold cross-validation time divided by one full-training fit plus fixed-test prediction time on Linux CPU and CUDA, respectively, across 12 datasets; ImageNet cross-validation was not evaluated. Three processes were requested for A-B and five for C-D. Timing includes initialization, transfers, synchronization, fitting and prediction. RSS increments include runtime allocations as well as numerical workspaces."
    )
    set_paragraph(
        document, "The NMR selection analysis",
        "The NMR component paths showed how held-out error and computational cost changed across the evaluated counts (Supplementary Figure S13). For the principal comparison, PLS-SVD used 100 components and the SIMPLS-family estimator used 50, matching the retained benchmark specification rather than claiming a unique optimum."
    )
    set_paragraph(
        document, "At 100 components",
        "At 100 components, PLS-SVD required 6.128 s on the Intel CPU and 0.500 s on CUDA, a 12.3-fold difference on the same workstation. Test RMSD was 0.0007195 and 0.0007194, respectively. At 50 components, the SIMPLS-family estimator required 1.619 s on the CPU and 0.463 s on CUDA, with RMSD 0.0007376 and 0.0007230 (Figure 3). The deposited 165-component PLS-SVD/IRLBA workflow required 457.511 s and achieved RMSD 0.000785806. Its different solver, precision and component count prevent attribution of the full timing difference to implementation alone."
    )
    replace_picture_before_caption(document, "Figure 3.", FIGURES / "figure3_nmr_family_components.png", 6.6)
    set_paragraph(
        document, "Figure 3.",
        "Figure 3. NMR spectral prediction with fastPLS and the deposited PLS-SVD implementation. fastPLS used float32 rSVD with 100 PLS-SVD or 50 SIMPLS-family components; the deposited fastsimpls model used float64 IRLBA with 165 components (grey). A: median fitting and prediction time and interquartile range from three processes. B: test RMSD over all 28,355 response intensities. C: peak host-RSS increment and CUDA device allocation. D: per-spectrum RMSD. E and F: observed and predicted spectra nearest the median CPU SIMPLS-family error, over 12-0 and 1.7-0.5 ppm. CPU and CUDA measurements were paired on the Intel/NVIDIA workstation. Conversion was excluded from timing, whereas CUDA initialization and transfers were included."
    )
    set_paragraph(
        document, "The separate scikit-learn",
        "The separate scikit-learn feasibility test completed a 50-component float64 NMR model in 107.5 s, with RMSD 0.000745 and peak process RSS of 9,180 MiB (Supplementary Table S1). This result uses a different software and precision setting from the fastPLS comparisons in Figure 3."
    )
    set_paragraph(
        document, "The ImageNet experiment fitted",
        find_paragraph(document, "The ImageNet experiment fitted").text
            .replace("Table S17", "Table S7")
            .replace("Table S18", "Table S8")
    )
    set_paragraph(
        document, "Figure 4.",
        "Figure 4. ImageNet/DINOv2 processing with the float32 CUDA "
        "SIMPLS-family estimator in "
        "fastPLS. The prepared split contains 1,000,000 training and 281,167 "
        "test embeddings. A: top-1 (solid circles) and top-5 (dashed "
        "triangles) accuracy for argmax and LDA from 50 to 1,000 components, "
        "using prefixes of one maximal fit per classifier. B: fitting time "
        "and top-5 prediction plus evaluation time after loading. C: "
        "device-memory increase above the pre-fit baseline and host-RSS "
        "increase above the pre-data baseline. rSVD used oversampling 32, "
        "five power iterations and seed 123. Values describe a single "
        "exploratory run; 1,000 components is the tested boundary."
    )
    replace_picture_before_caption(document, "Figure 4.", FIGURE4, 6.6)
    add_paragraph_after(
        document, "Figure 4.",
        "3.5 Formal verification",
        "Heading 2"
    )
    add_paragraph_after(
        document, "3.5 Formal verification",
        "The Lean proof checker verified all ten exact algebraic statements "
        "listed in Supplementary Table S9. These results cover the identities "
        "used for implicit products, compact prediction, deflation, orthogonal "
        "filtering, kernel centering and fold-statistic subtraction; they do "
        "not constitute a floating-point or compiled-code correctness proof."
    )
    set_paragraph(
        document, "The main contribution of fastPLS",
        "The results show that the main practical contribution of fastPLS is "
        "the reduction of repeated computation and model storage in sequential "
        "PLS workflows. This is consistent with the original motivation for "
        "PLS and SIMPLS: extracting response-directed latent variables when "
        "predictors are numerous, correlated or linked to several responses "
        "[1,2,8]. The storage advantage becomes especially important in the "
        "NMR application, where one dense predictor-by-response coefficient "
        "matrix contains about 369 million entries. Retaining compact predictor "
        "and response factors avoids storing such a matrix at every component "
        "count. The close agreement between observed and predicted spectra "
        "therefore extends the earlier NMR workflow [7] with a representation "
        "that is practical for repeated fitting and prediction. The large "
        "runtime difference from the deposited implementation is a workflow "
        "result, however, because solver, precision, component count and "
        "hardware also changed."
    )
    set_paragraph(
        document, "The benefit was limited",
        "The independent-software comparison also indicates where this design "
        "is most useful. fastPLS had the shortest completed R workflow on eight "
        "of nine classification datasets and was approximately three times "
        "faster than IKPLS in the million-sample ImageNet experiment, but IKPLS "
        "was faster on several small or low-component problems. Both the pls "
        "package and IKPLS already calculate component paths rather than "
        "requiring an independent fit for every prefix [11,12]. The distinction "
        "is therefore not component-path availability, but the combination of "
        "compact returned objects, class-sum response products, fused compiled "
        "operations and reduced intermediate storage. These savings matter "
        "when matrix products and output construction dominate. For short "
        "tasks, allocation, language-interface and small-matrix costs can be "
        "larger than the arithmetic saved. Similarly, implicit cross-covariance "
        "products reduce storage but require additional passes through the "
        "data. The results consequently support a workload-dependent advantage, "
        "not a universal speed ranking."
    )
    add_paragraph_after(
        document, "The independent-software comparison",
        "The classification results also show that the prediction head can be "
        "as important as the latent representation. Classical PLS discrimination "
        "commonly assigns the class with the largest predicted indicator response "
        "[3], whereas linear discriminant analysis uses class centroids, a pooled "
        "within-class covariance and class priors, following Fisher's discriminant "
        "construction {FISHER}. At matched fastPLS SIMPLS-family component counts, LDA "
        "improved held-out accuracy over argmax in nine of ten datasets (median "
        "gain 0.92 percentage points), including gains of 7.50 points for Tabula "
        "Muris and 4.55 points for TCGA-BRCA. The 1.72-point decrease for "
        "TCGA-HNSC methylation is equally informative: pooled-covariance and "
        "prior assumptions are data dependent and need not improve every task. "
        "Accordingly, the comparison with argmax-based software in Figure 1 is "
        "a complete-workflow comparison rather than evidence that one PLS "
        "representation is intrinsically more predictive."
    )
    set_paragraph(
        document, "The randomized solver was faster",
        "The rSVD results agree with the established trade-off of randomized "
        "range finding: fewer operations and less communication are obtained "
        "by approximating the leading subspace rather than computing a complete "
        "decomposition [14]. Oversampling and power iterations improve separation "
        "of the leading directions, but they do not make the result exact. The "
        "reported performance rows therefore identify the controls used "
        "(32 oversampling directions, five power iterations and seed 123) and "
        "should be interpreted together with the numerical-agreement analyses. "
        "Nearly tied directions, strong collinearity and component counts close "
        "to numerical rank remain difficult settings because small subspace "
        "changes can propagate to predictions or class decisions. For biomedical "
        "applications, stability across seeds and a plausible component range "
        "is therefore more informative than one randomized fit. A selection at "
        "the edge of the tested grid should trigger a wider training-only search "
        "or be reported explicitly as the best count within that grid."
    )
    set_paragraph(
        document, "GPU gains were largest",
        "The accelerator results can be understood in terms of arithmetic "
        "intensity: performance improves when enough matrix arithmetic is done "
        "for each byte transferred, whereas launch, transfer and synchronization "
        "costs dominate short calculations {ROOFLINE}. CUDA was faster in only "
        "15 of 52 paired fitting and prediction settings, but all four PLS "
        "families benefited on CIFAR-100, NMR and ImageNet. The large NMR response "
        "matrix and the million-sample ImageNet representation provide enough "
        "work to amortize accelerator overhead; most smaller fits still completed "
        "faster on the CPU. This pattern is consistent with the execution model "
        "of the CUDA numerical libraries used by fastPLS [21]. It supports CUDA "
        "for sufficiently large workloads, not a hardware-independent claim of "
        "acceleration."
    )
    add_paragraph_after(
        document, "The accelerator results",
        "Cross-validation is central to predictive model choice and assessment "
        "{STONE}, but its cost need not equal the cost of ten independent "
        "full-data workflows. Reusing fold assignments, centering terms and "
        "eligible sufficient statistics reduced the median ten-fold cost to "
        "4.14 times one fit and prediction on the CPU and 2.47 times on CUDA. "
        "This does not bypass fold-specific preprocessing or fitting; it removes "
        "work that is identical across folds. The approximately 9-11-fold CUDA "
        "advantages for NMR and PRISM show the value of amortizing repeated large "
        "products, whereas CUDA accelerated only one third of the paired "
        "validation settings overall. The 22.90-fold CPU ratio for OPLS on CBMC "
        "CITE-seq identifies repeated response-orthogonal filtering, which is "
        "intrinsic to the OPLS construction [9], as a remaining bottleneck. "
        "Nonlinear kernel PLS introduces a different constraint because its "
        "centred sample Gram matrix has quadratic storage in the number of "
        "observations [10]. The reported ratios should therefore be read as "
        "family- and workload-specific validation costs, not as speed-ups over "
        "a literal ten-call R loop."
    )
    set_paragraph(
        document, "Single precision makes",
        "Single precision halves the storage required for each floating-point "
        "matrix element and can reduce memory traffic, but lower precision also "
        "increases rounding error and does not guarantee a faster complete "
        "workflow {HIGHAM}. In this study, float32 enabled the largest NMR and "
        "ImageNet calculations, while the paired numerical comparisons were "
        "needed to establish whether predictions and metrics remained practically "
        "unchanged. The relevant endpoint is therefore not representation size "
        "alone, but the joint effect on runtime, peak memory and prediction."
    )
    set_paragraph(
        document, "Fixed splits support",
        "Several limitations define the scope of these findings. Fixed splits "
        "support paired computational comparisons, but they do not quantify "
        "variation across newly sampled patients, donors or preprocessing "
        "choices. The external implementations also differ in estimator, "
        "classification head and returned model objects, so Figure 1 evaluates "
        "usable workflows rather than one isolated numerical kernel. ImageNet "
        "is relevant as a stress test for the large embedding matrices now "
        "generated by foundation models in computational pathology [15-17], but "
        "its nonstandard split and incomplete extraction metadata preclude a "
        "claim of biomedical predictive validity. By contrast, the NMR study "
        "directly addresses a biomedical many-response problem previously "
        "studied with PLS-SVD [7]. Further evaluation should combine repeated "
        "grouped resampling with complete representation provenance while "
        "preserving the paired computational design used here."
    )
    replace_references(document, {
        "Table S14": "Table S1", "Table S15": "Table S2",
        "Table S16": "Table S3", "Table S17": "Table S7",
        "Table S18": "Table S8", "Figure S17": "Figure S1"
    })
    delete_paragraph(document, "[22] Apple Inc.")
    for paragraph in document.paragraphs:
        text = paragraph.text
        updated = re.sub(
            r"\[(2[3-9]|3[0-4])\]",
            lambda match: f"[{int(match.group(1)) - 1}]",
            text
        )
        if updated != text:
            paragraph.clear()
            paragraph.add_run(updated)
    citation_placeholders = {
        "{FISHER}": "[36]",
        "{ROOFLINE}": "[37]",
        "{STONE}": "[38]",
        "{HIGHAM}": "[39]",
    }
    for paragraph in document.paragraphs:
        text = paragraph.text
        updated = text
        for placeholder, citation in citation_placeholders.items():
            updated = updated.replace(placeholder, citation)
        if updated != text:
            paragraph.clear()
            paragraph.add_run(updated)
    add_paragraph_after(
        document, "[33] Corsello",
        "[34] de Moura L, Ullrich S. The Lean 4 theorem prover and "
        "programming language. In: Automated Deduction - CADE 28. Lecture "
        "Notes in Computer Science. 2021;12699:625-635. "
        "doi:10.1007/978-3-030-79876-5_37."
    )
    add_paragraph_after(
        document, "[34] de Moura",
        "[35] The mathlib Community. The Lean mathematical library. In: "
        "Proceedings of the 9th ACM SIGPLAN International Conference on "
        "Certified Programs and Proofs. 2020:367-381. "
        "doi:10.1145/3372885.3373824."
    )
    add_paragraph_after(
        document, "[35] The mathlib",
        "[36] Fisher RA. The use of multiple measurements in taxonomic "
        "problems. Annals of Eugenics. 1936;7:179-188. "
        "doi:10.1111/j.1469-1809.1936.tb02137.x."
    )
    add_paragraph_after(
        document, "[36] Fisher",
        "[37] Williams S, Waterman A, Patterson DA. Roofline: an insightful "
        "visual performance model for multicore architectures. Communications "
        "of the ACM. 2009;52:65-76. doi:10.1145/1498765.1498785."
    )
    add_paragraph_after(
        document, "[37] Williams",
        "[38] Stone M. Cross-validatory choice and assessment of statistical "
        "predictions. Journal of the Royal Statistical Society Series B. "
        "1974;36:111-133. doi:10.1111/j.2517-6161.1974.tb00994.x."
    )
    add_paragraph_after(
        document, "[38] Stone",
        "[39] Higham NJ, Mary T. Mixed precision algorithms in numerical linear "
        "algebra. Acta Numerica. 2022;31:347-414. "
        "doi:10.1017/S0962492922000022."
    )
    OUTPUT.mkdir(parents=True, exist_ok=True)
    path = OUTPUT / "fastPLS_CMPB_manuscript_restructured.docx"
    document.save(path)
    return path


def build_jss():
    source = Document(INPUT_SUPP)
    document = Document(INPUT_JSS)
    anchor = find_paragraph_element(document, "8. Reproducibility")

    set_paragraph(
        document, "Algorithm 1: SIMPLS-family fit",
        "Algorithm 1: SIMPLS-family fit in the shared core. Input: centred or "
        "scaled X, initial cross-covariance S₀, and requested maximum A. Set "
        "S ← S₀ and initialize R, Q and V. While fewer than A components have "
        "been accepted, obtain one or a bounded block of leading left "
        "candidates from the current deflated S by rSVD. For each candidate r, "
        "form t = Xr and p = Xᵀt; normalize r and t together so tᵀt = 1. "
        "Set c = S₀ᵀr. Project p from the retained columns of V and normalize "
        "the result to obtain v. Compute h = vᵀS once and update "
        "S ← S - vh. Append r, c and v to R, Q and V, and retain t only when "
        "requested. Consume the current candidate block before extracting new "
        "directions from the updated S. Return the preprocessing state and the "
        "accepted compact factors."
    )
    set_paragraph(
        document, "Algorithm 2: PLS-SVD fit",
        "Algorithm 2: PLS-SVD fit in the shared core. Input: centred or scaled "
        "X, initial cross-covariance S₀, and requested component set C. Set "
        "A = max(C) and compute [U, D, Vᵀ] = rSVD(S₀, A). Form the score Gram "
        "matrix H = (XU)ᵀ(XU), or H = Uᵀ(XᵀX)U when the predictor-Gram route "
        "is selected. For each a in C, solve H[1:a,1:a] Lₐ = D[1:a,1:a] "
        "without an explicit inverse, then store the latent prediction map "
        "Wₐ = LₐVₐᵀ. Return the preprocessing state, U and the requested "
        "Wₐ factors."
    )
    set_paragraph(
        document, "PLS-SVD performs one rSVD",
        "PLS-SVD performs one rSVD of S₀ up to the largest requested prefix. "
        "If U, D and V are the retained factors, U contains predictor-space "
        "directions and V contains response-space singular directions. The "
        "score Gram matrix H is formed from XU or, when cheaper, as "
        "Uᵀ(XᵀX)U. For each requested prefix, the core solves the small "
        "score-space system by Cholesky factorization, with a general solve as "
        "a numerical fallback, and combines its solution with D and Vᵀ to "
        "obtain the latent prediction map."
    )

    add_paragraph_before(document, anchor, "8. Extended algorithms and platform evaluation", "Heading 1")
    add_paragraph_before(document, anchor, "8.1 Computational requirements", "Heading 2")
    add_paragraph_before(
        document, anchor,
        "Let n denote training observations, p predictors, q responses, A retained components and l the randomized sketch width. An explicit route stores the cross-covariance X'Y, whereas an implicit route applies it to narrow matrices without storing it. The latter reduces storage but can require additional passes through the input. Table 7 summarizes dominant operations and residency."
    )
    add_paragraph_before(document, anchor, "Table 7. Dominant operations, storage and residency in the shared implementation.")
    add_table_copy_before(document, anchor, source.tables[0])
    for number, caption, table_index in [
        (3, "OPLS execution used by fastPLS.", 1),
        (4, "Linear and nonlinear kernel-PLS execution.", 2),
        (5, "Compiled cross-validation shared by PLS-SVD, SIMPLS, OPLS and kernel PLS.", 3),
    ]:
        add_paragraph_before(document, anchor, f"Algorithm {number}. {caption}")
        add_table_copy_before(document, anchor, source.tables[table_index], size=7.5)
    add_paragraph_before(
        document, anchor,
        "The compiled validation workflow constructs one maximal component path per fold and obtains exact fold statistics from full-data totals minus held-out contributions. This reduces repeated centering, cross-product construction, allocation and prefix refitting while preserving the supplied folds and grouping constraints."
    )

    add_paragraph_before(document, anchor, "8.2 Numerical precision and execution routes", "Heading 2")
    add_paragraph_before(document, anchor, "Table 8. Prediction differences across hardware and numerical precision, relative to Linux CPU float64.")
    add_table_copy_before(document, anchor, source.tables[8], size=6.2)
    add_paragraph_before(document, anchor, "Table 9. Numerical precision and execution routes used in the benchmark studies.")
    add_table_copy_before(document, anchor, source.tables[15], size=7.0)
    add_paragraph_before(
        document, anchor,
        "These measurements distinguish data representation from complete-process memory and runtime. Accelerator routes include initialization, data transfer and synchronization unless explicitly identified as repeated execution."
    )

    add_paragraph_before(document, anchor, "8.3 CPU threading and Metal execution", "Heading 2")
    add_paragraph_before(document, anchor, "Table 10. One- versus four-core CPU requests across the benchmark datasets and PLS families.")
    add_table_copy_before(document, anchor, source.tables[14], size=6.7)
    add_picture_before(document, anchor, ROOT / "fastPLS_results_local/multicore_0.99.65_20260913/macos/figureS15_multicore_runtime_ratio.png")
    add_paragraph_before(document, anchor, "Figure 2. Runtime with one- and four-core CPU requests on Linux/OpenBLAS and macOS/Accelerate. Values above one favour the four-core request.")
    add_picture_before(document, anchor, ROOT / "fastPLS_results_local/multicore_0.99.65_20260913/macos/figureS16_multicore_absolute_rss_ratio.png")
    add_paragraph_before(document, anchor, "Figure 3. Peak process memory with one- and four-core CPU requests. Values below one indicate lower memory with the four-core request.")
    add_picture_before(document, anchor, ROOT / "manuscript_revision_0.99.66/figures/figureS19_metal_backend_runtime.png")
    add_paragraph_before(document, anchor, "Figure 4. CPU and hybrid Metal fitting-and-prediction ratios on the Apple M3 across 13 datasets and four PLS families.")
    add_picture_before(document, anchor, FIGURES / "figure_jss_argmax_metal.png")
    add_paragraph_before(document, anchor, "Figure 5. Float32 argmax classification on Mac CPU and hybrid Metal, with matched component counts and outputs.")
    add_picture_before(document, anchor, FIGURES / "jss_metal_cv_vs_fit_prediction.png")
    add_paragraph_before(document, anchor, "Figure 6. Ten-fold cross-validation cost relative to one fit plus held-out prediction on Mac CPU and hybrid Metal.")

    add_paragraph_before(document, anchor, "8.4 NMR route measurements", "Heading 2")
    add_paragraph_before(document, anchor, "Table 11. NMR measurements across CPU, CUDA, Metal and the deposited PLS-SVD workflow.")
    add_table_copy_before(document, anchor, source.tables[13], size=6.5)
    add_paragraph_before(
        document, anchor,
        "The NMR table is retained here as a route-level software comparison. The CMPB paper uses the Linux CPU/CUDA subset for its biomedical analysis, while this software study also examines the hybrid Metal route and precision-specific execution."
    )

    for paragraph in document.paragraphs:
        text = paragraph.text.strip()
        replacements = {
            "8. Reproducibility and extension": "9. Reproducibility and extension",
            "9. Discussion": "10. Discussion",
            "10. Availability": "11. Availability",
            "11. Conclusion": "12. Conclusion",
        }
        if text in replacements:
            paragraph.clear()
            paragraph.add_run(replacements[text])

    OUTPUT.mkdir(parents=True, exist_ok=True)
    path = OUTPUT / "fastPLS_JSS_future_draft_extended.docx"
    document.save(path)
    return path


if __name__ == "__main__":
    print(build_cmpb_main())
    print(build_cmpb_supplement())
    print(build_jss())
