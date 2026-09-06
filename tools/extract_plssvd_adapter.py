#!/usr/bin/env python3
"""Emit an apply_patch for the current owned PLS-SVD adapter extraction."""
from pathlib import Path
import sys

source = Path(sys.argv[1]).resolve(strict=True)
text = source.read_text()
start = text.index("List pls_model1(\n")
end = text.index("\nList pls_model1_metal_cv(\n", start)
old = text[start:end].rstrip()
if "fastpls::native::PlssvdOptions" in old or "arma::mat S=trans(Xtrain)*Ytrain" not in old:
    raise SystemExit("Expected original current-code function was not found")
replacement = Path(__file__).with_name("plssvd_adapter.cpp.in").read_text().rstrip()
print("*** Begin Patch")
print("*** Update File: " + str(source))
print("@@")
print("\n".join("-" + line for line in old.splitlines()))
print("\n".join("+" + line for line in replacement.splitlines()))
print("*** End Patch")
