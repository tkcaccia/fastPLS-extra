"""Emit a checked patch removing unused IRLBA R formals and forwarding."""
import argparse
from pathlib import Path
import difflib
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
args = parser.parse_args()
path = args.source / "R" / "main.R"
before = path.read_text()
name = r"irlba_(?:work|maxit|tol|eps|svtol)"
value = rf"(?:(?:ctl|control)\${name}|{name}|[0-9]+(?:e-[0-9]+)?L?)"
argument = rf"{name}(?:\s*=\s*{value})?"
start = before.index('    if (!identical(context$backend, "cuda")) {\n'
    '        arguments <- c(')
end = before.index("    arguments\n}", start)
after = before[:start] + before[end:]
after = re.sub(rf"\b{argument}\s*,\s*", "", after)
after = re.sub(rf",\s*{argument}(?=\s*\))", "", after)
after = re.sub(rf',\s*"{name}"', "", after)
assert not re.search(name, after), [line for line in after.splitlines()
    if re.search(name, line)]
assert before != after
diff = list(difflib.unified_diff(before.splitlines(True), after.splitlines(True)))[2:]
print("*** Begin Patch\n*** Update File: " + str(path))
print("".join("@@\n" if line.startswith("@@") else line for line in diff), end="")
print("*** End Patch")
