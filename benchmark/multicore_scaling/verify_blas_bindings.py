"""Confirm fastPLS's actual Linux symbol bindings, not just linked libraries."""

import re
import sys
from pathlib import Path


def verify(text):
    bindings = {}
    for line in text.splitlines():
        match = re.search(
            r"binding file (\S*/fastPLS\.so) .*? to (\S+) .*?symbol [`'](\w+)'",
            line,
        )
        if match:
            bindings.setdefault(match[3], set()).add(match[2])
    required = {"dgemm_", "dgemv_", "dsyrk_"}
    if required - bindings.keys():
        raise ValueError(f"Missing actual BLAS bindings: {sorted(required - bindings.keys())}")
    invalid = {symbol: sorted(bindings[symbol]) for symbol in required
               if any("openblas" not in path.lower() for path in bindings[symbol])}
    if invalid:
        raise ValueError(f"fastPLS is not using OpenBLAS for all tested operations: {invalid}")
    return {symbol: sorted(bindings[symbol]) for symbol in sorted(required)}


if __name__ == "__main__":
    print(verify(Path(sys.argv[1]).read_text()))
