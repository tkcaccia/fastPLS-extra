"""Locate migrated developer tools, never a runtime package dependency."""

import os
from pathlib import Path


def companion_tool(name):
    if Path(name).name != name:
        raise ValueError("Expected a single companion tool filename")
    default = Path(__file__).resolve().parents[3] / "fastPLS-extra"
    root = Path(os.environ.get("FASTPLS_EXTRA_ROOT", str(default)))
    path = root / "tools" / name
    if not path.is_file():
        raise FileNotFoundError(
            f"Missing companion developer tool {path}; set FASTPLS_EXTRA_ROOT "
            "to the fastPLS-extra checkout")
    return path.resolve()
