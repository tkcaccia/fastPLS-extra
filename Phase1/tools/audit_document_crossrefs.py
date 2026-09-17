#!/usr/bin/env python3
"""Audit main-text citations to main and supplementary figures and tables."""

import re
import sys
from pathlib import Path

from docx import Document


def paragraph_texts(path):
    doc = Document(path)
    texts = [p.text.strip() for p in doc.paragraphs if p.text.strip()]
    for table in doc.tables:
        for row in table.rows:
            for cell in row.cells:
                texts.extend(p.text.strip() for p in cell.paragraphs if p.text.strip())
    return texts


def captions(texts, kind):
    pattern = re.compile(rf"^(?:Supplementary\s+)?{kind}\s+(S?\d+)\.", re.I)
    return [(m.group(1).upper(), text) for text in texts if (m := pattern.match(text))]


def cited_labels(texts, kind):
    found = set()
    pattern = re.compile(
        rf"(?:Supplementary\s+)?{kind}s?\s+"
        r"((?:S?\d+)(?:\s*(?:-|\u2013|to|and|,)\s*S?\d+)*)",
        re.I,
    )
    for text in texts:
        for match in pattern.finditer(text):
            token = match.group(1).upper()
            prefix = "S" if "S" in token else ""
            nums = [int(value) for value in re.findall(r"\d+", token)]
            if re.search(r"(?:-|\u2013|TO)", token) and len(nums) == 2:
                nums = list(range(nums[0], nums[1] + 1))
            found.update(f"{prefix}{value}" for value in nums)
    return found


def cited_label_order(texts, kind):
    ordered = []
    seen = set()
    pattern = re.compile(
        rf"(?:Supplementary\s+)?{kind}s?\s+"
        r"((?:S?\d+)(?:\s*(?:-|\u2013|to|and|,)\s*S?\d+)*)",
        re.I,
    )
    for text in texts:
        for match in pattern.finditer(text):
            token = match.group(1).upper()
            prefix = "S" if "S" in token else ""
            nums = [int(value) for value in re.findall(r"\d+", token)]
            if re.search(r"(?:-|\u2013|TO)", token) and len(nums) == 2:
                nums = list(range(nums[0], nums[1] + 1))
            for value in nums:
                label = f"{prefix}{value}"
                if label not in seen:
                    seen.add(label)
                    ordered.append(label)
    return ordered


def numeric_citations(texts):
    out = set()
    for text in texts:
        for token in re.findall(r"\[([0-9,;\-\u2013 ]+)\]", text):
            for part in re.split(r"[,;]", token):
                nums = [int(value) for value in re.findall(r"\d+", part)]
                if re.search(r"[-\u2013]", part) and len(nums) == 2:
                    out.update(range(nums[0], nums[1] + 1))
                else:
                    out.update(nums)
    return out


def numeric_citation_order(texts):
    ordered = []
    seen = set()
    for text in texts:
        for token in re.findall(r"\[([0-9,;\-\u2013 ]+)\]", text):
            values = []
            for part in re.split(r"[,;]", token):
                nums = [int(value) for value in re.findall(r"\d+", part)]
                if re.search(r"[-\u2013]", part) and len(nums) == 2:
                    values.extend(range(nums[0], nums[1] + 1))
                else:
                    values.extend(nums)
            for value in values:
                if value not in seen:
                    seen.add(value)
                    ordered.append(value)
    return ordered


def main():
    main_path, supp_path = map(Path, sys.argv[1:3])
    main_texts = paragraph_texts(main_path)
    supp_texts = paragraph_texts(supp_path)
    main_narrative = [
        t for t in main_texts
        if not re.match(r"^(?:Supplementary\s+)?(?:Figure|Table)\s+S?\d+\.", t, re.I)
        and not re.match(r"^\[\d+\]", t)
    ]

    main_figs = captions(main_texts, "Figure")
    main_tabs = captions(main_texts, "Table")
    supp_figs = captions(supp_texts, "Figure")
    supp_tabs = captions(supp_texts, "Table")
    cited_figs = cited_labels(main_narrative, "Figure")
    cited_tabs = cited_labels(main_narrative, "Table")

    print("MAIN_FIGURES", [x[0] for x in main_figs])
    print("MAIN_TABLES", [x[0] for x in main_tabs])
    print("SUPP_FIGURES", [x[0] for x in supp_figs])
    print("SUPP_TABLES", [x[0] for x in supp_tabs])
    print("CITED_FIGURES", sorted(cited_figs, key=lambda x: (x.startswith("S"), int(x.lstrip("S")))))
    print("CITED_TABLES", sorted(cited_tabs, key=lambda x: (x.startswith("S"), int(x.lstrip("S")))))
    print("FIRST_FIGURE_CITATIONS", cited_label_order(main_narrative, "Figure"))
    print("FIRST_TABLE_CITATIONS", cited_label_order(main_narrative, "Table"))
    print("MISSING_MAIN_FIGURES", [x[0] for x in main_figs if x[0] not in cited_figs])
    print("MISSING_MAIN_TABLES", [x[0] for x in main_tabs if x[0] not in cited_tabs])
    print("MISSING_SUPP_FIGURES", [x[0] for x in supp_figs if x[0] not in cited_figs])
    print("MISSING_SUPP_TABLES", [x[0] for x in supp_tabs if x[0] not in cited_tabs])

    bibliography = []
    for text in main_texts:
        match = re.match(r"^\[(\d+)\]\s+", text)
        if match:
            bibliography.append(int(match.group(1)))
    cited_numbers = numeric_citations(main_narrative + supp_texts)
    print("BIBLIOGRAPHY", bibliography)
    print("CITED_NUMBERS", sorted(cited_numbers))
    print("FIRST_REFERENCE_CITATIONS", numeric_citation_order(main_narrative))
    print("UNCITED_REFERENCES", sorted(set(bibliography) - cited_numbers))
    print("MISSING_REFERENCES", sorted(cited_numbers - set(bibliography)))

    print("MAIN_SUPPLEMENTARY_REFERENCE_PARAGRAPHS")
    for text in main_narrative:
        if "Supplementary" in text:
            print("-", text)


if __name__ == "__main__":
    main()
