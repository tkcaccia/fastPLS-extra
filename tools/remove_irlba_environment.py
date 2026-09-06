"""Emit an apply_patch diff removing obsolete R IRLBA environment wrappers."""
import argparse
from pathlib import Path
import difflib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
args = parser.parse_args()
path = args.source / "R" / "main.R"
before = path.read_text()
after = before
start = after.index(".with_irlba_options <- function(")
end = after.index(".with_gpu_native_options <- function(", start)
after = after[:start] + after[end:]
token = ".with_irlba_options("
removed = 0
while token in after:
    start = after.index(token)
    begin = start + len(token)
    depth = 1
    quote = None
    comment = False
    comma = None
    i = begin
    while depth:
        char = after[i]
        if comment:
            comment = char != "\n"
        elif quote:
            if char == "\\":
                i += 1
            elif char == quote:
                quote = None
        elif char in "\"'`":
            quote = char
        elif char == "#":
            comment = True
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 1 and comma is None:
            comma = i
        i += 1
    assert comma is not None
    after = after[:start] + after[begin:comma].strip() + after[i:]
    removed += 1
assert removed == 6, removed
after = "".join(line for line in after.splitlines(True)
                if not line.lstrip().startswith("FASTPLS_IRLBA_"))
assert "FASTPLS_IRLBA_" not in after
diff = list(difflib.unified_diff(before.splitlines(True), after.splitlines(True)))[2:]
print("*** Begin Patch\n*** Update File: " + str(path))
print("".join("@@\n" if line.startswith("@@") else line for line in diff), end="")
print("*** End Patch")
