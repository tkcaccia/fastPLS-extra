#!/usr/bin/env python3
"""Update the CMPB manuscript with the resident-CUDA OPLS CV rerun."""

import argparse
from pathlib import Path

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.shared import Inches


RESULTS_PREFIX = (
    "Complete 10-fold cross-validation with LDA classification was compared"
)
DISCUSSION_PREFIX = (
    "CUDA was beneficial only after workloads became large enough"
)


def replace_figure(document, image_path):
    paragraphs = list(document.paragraphs)
    caption_index = next(
        index
        for index, paragraph in enumerate(paragraphs)
        if paragraph.text.strip().startswith("Figure 2.")
    )
    drawing = next(
        paragraph
        for paragraph in reversed(paragraphs[:caption_index])
        if paragraph._p.xpath(".//w:drawing")
    )
    drawing.clear()
    drawing.alignment = WD_ALIGN_PARAGRAPH.CENTER
    drawing.add_run().add_picture(str(image_path), width=Inches(6.0))
    drawing.paragraph_format.keep_with_next = True


def replace_paragraph(paragraph, text):
    paragraph.clear()
    paragraph.add_run(text)


def update_document(source, output, figure):
    document = Document(source)
    replace_figure(document, figure)

    found_results = False
    found_discussion = False
    for paragraph in document.paragraphs:
        text = paragraph.text.strip()
        if text.startswith(RESULTS_PREFIX):
            replace_paragraph(
                paragraph,
                "Complete 10-fold cross-validation with LDA classification "
                "was compared with one full-training fit plus fixed-test "
                "prediction (Figure 2C,D). The CPU median ratio was 4.08 "
                "(range 0.58-9.62), and the CUDA median was 2.14 (range "
                "1.06-8.49); none of the 52 ratios on either backend exceeded "
                "ten. Resident CUDA OPLS cross-validation reduced the ratios "
                "for PRISM, NMR and ImageNet to 3.26, 4.35 and 8.49, "
                "respectively. The classifier and retained component count "
                "were held constant so that the comparison measured execution "
                "cost rather than a second component-selection procedure. LDA "
                "was refitted within every training fold. Complete "
                "discriminant-score matrices were retained in both "
                "classification workflows, whereas the Figure 1 workflow "
                "returned only the outputs needed for its software comparison; "
                "their absolute times therefore have different output "
                "contracts."
            )
            found_results = True
        elif text.startswith(DISCUSSION_PREFIX):
            replace_paragraph(
                paragraph,
                "CUDA was beneficial only after workloads became large enough "
                "to offset initialization, transfer and synchronization. It "
                "reduced runtime in 14 of 52 paired fitting-and-prediction "
                "calculations, while increasing the host-RSS increment in 48 "
                "pairs. The largest matrices instead moved substantial storage "
                "to device memory. The compiled CV workflow required a median "
                "of 4.08 times one fit and prediction on CPU and 2.14 times on "
                "CUDA, with a maximum ratio of 8.49. The lower CUDA OPLS cost "
                "resulted from retaining fold data and linear-algebra resources "
                "on the device across consecutive operations rather than "
                "reconstructing them for each stage. Leakage-free reuse of "
                "additive statistics and component prefixes is especially "
                "relevant to methods such as KODAMA that repeatedly fit "
                "cross-validated PLS models [19,20]."
            )
            found_discussion = True

    if not found_results or not found_discussion:
        raise RuntimeError(
            "Could not locate both the Results and Discussion CV paragraphs"
        )

    Path(output).parent.mkdir(parents=True, exist_ok=True)
    document.save(output)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--figure", required=True)
    args = parser.parse_args()
    update_document(args.input, args.output, Path(args.figure))


if __name__ == "__main__":
    main()
