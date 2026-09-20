#!/usr/bin/env python3
"""Report and validate the exact OpenBLAS library used by a benchmark."""

from __future__ import annotations

import argparse
import ctypes
from pathlib import Path


def read_text_function(library: ctypes.CDLL, name: str) -> str:
    function = getattr(library, name)
    function.restype = ctypes.c_char_p
    value = function()
    if value is None:
        raise RuntimeError(f"{name} returned no value")
    return value.decode("utf-8", errors="strict")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--require-version")
    parser.add_argument("--require-core")
    args = parser.parse_args()

    path = Path(args.library).expanduser().resolve(strict=True)
    library = ctypes.CDLL(str(path))
    configuration = read_text_function(library, "openblas_get_config")
    core = read_text_function(library, "openblas_get_corename")

    if args.require_version and args.require_version not in configuration:
        raise SystemExit(
            f"OpenBLAS version mismatch: expected {args.require_version}; "
            f"loaded {configuration}"
        )
    if args.require_core and core.casefold() != args.require_core.casefold():
        raise SystemExit(
            f"OpenBLAS core mismatch: expected {args.require_core}; loaded {core}"
        )

    print(f"{configuration}; core={core}; library={path}")


if __name__ == "__main__":
    main()
