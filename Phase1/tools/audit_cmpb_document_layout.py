#!/usr/bin/env python3
"""Check portrait sections and continuous line numbering in CMPB DOCX files."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from docx import Document
from docx.oxml.ns import qn


def audit(path: Path) -> list[str]:
    document = Document(path)
    failures: list[str] = []
    for number, section in enumerate(document.sections, start=1):
        if section.page_width >= section.page_height:
            failures.append(f"section {number} is not portrait")
        line_numbers = section._sectPr.find(qn("w:lnNumType"))
        if line_numbers is None:
            failures.append(f"section {number} has no line numbering")
            continue
        count_by = line_numbers.get(qn("w:countBy"))
        restart = line_numbers.get(qn("w:restart"))
        if count_by != "1":
            failures.append(
                f"section {number} line numbering countBy is {count_by!r}"
            )
        if restart != "continuous":
            failures.append(
                f"section {number} line numbering restart is {restart!r}"
            )
    return failures


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("documents", nargs="+", type=Path)
    args = parser.parse_args()
    failed = False
    for path in args.documents:
        findings = audit(path)
        if findings:
            failed = True
            print(f"FAIL {path}")
            for finding in findings:
                print(f"  {finding}")
        else:
            print(f"PASS {path}: portrait with continuous line numbering")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
