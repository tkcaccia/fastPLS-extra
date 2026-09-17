#!/usr/bin/env python3
"""Convert the portable raw Figure 1 inputs to self-describing NumPy files."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import shutil

import numpy as np


def read_metadata(path: Path) -> dict[str, str]:
    with path.open(newline="") as handle:
        return {
            row["key"]: row["value"]
            for row in csv.DictReader(handle, delimiter="\t")
        }


def copy_memmap(source: Path, shape: tuple[int, ...], dtype: str, target: Path) -> None:
    values = np.memmap(source, dtype=dtype, mode="r", shape=shape, order="C")
    output = np.lib.format.open_memmap(
        target,
        mode="w+",
        dtype=np.dtype(dtype),
        shape=shape,
        fortran_order=False,
    )
    rows = shape[0]
    block_rows = max(1, min(rows, 8192))
    for start in range(0, rows, block_rows):
        stop = min(rows, start + block_rows)
        output[start:stop] = values[start:stop]
    output.flush()
    del output, values


def convert_dataset(source: Path, target: Path) -> dict[str, object]:
    meta = read_metadata(source / "metadata.tsv")
    n_train = int(meta["n_train"])
    n_test = int(meta["n_test"])
    p = int(meta["p"])
    q = int(meta["q"])
    task_type = meta["task_type"]
    target.mkdir(parents=True, exist_ok=True)

    copy_memmap(source / "Xtrain.f32", (n_train, p), "<f4", target / "X_train.npy")
    copy_memmap(source / "Xtest.f32", (n_test, p), "<f4", target / "X_test.npy")
    copy_memmap(source / "Ytrain.f32", (n_train, q), "<f4", target / "Y_train.npy")

    arrays: dict[str, dict[str, object]] = {
        "X_train": {"file": "X_train.npy", "shape": [n_train, p], "dtype": "float32"},
        "X_test": {"file": "X_test.npy", "shape": [n_test, p], "dtype": "float32"},
        "Y_train": {"file": "Y_train.npy", "shape": [n_train, q], "dtype": "float32"},
    }
    if task_type == "classification":
        y_test = np.fromfile(source / "Ytest.i32", dtype="<i4")
        if y_test.shape != (n_test,):
            raise ValueError(f"Invalid test-label shape for {meta['dataset']}")
        if np.any((y_test < 0) | (y_test >= q)):
            raise ValueError(f"Out-of-range test labels for {meta['dataset']}")
        y_train = np.argmax(np.load(target / "Y_train.npy", mmap_mode="r"), axis=1).astype(
            np.int32
        )
        if y_train.shape != (n_train,):
            raise ValueError(f"Invalid training-label shape for {meta['dataset']}")
        np.save(target / "y_train.npy", y_train, allow_pickle=False)
        np.save(target / "y_test.npy", y_test, allow_pickle=False)
        arrays.update(
            {
                "y_train": {"file": "y_train.npy", "shape": [n_train], "dtype": "int32"},
                "y_test": {"file": "y_test.npy", "shape": [n_test], "dtype": "int32"},
            }
        )
    else:
        copy_memmap(source / "Ytest.f32", (n_test, q), "<f4", target / "Y_test.npy")
        arrays["Y_test"] = {
            "file": "Y_test.npy",
            "shape": [n_test, q],
            "dtype": "float32",
        }

    portable = {
        "format": "fastPLS Python benchmark NumPy v1",
        "dataset": meta["dataset"],
        "task_type": task_type,
        "ncomp": int(meta["ncomp"]),
        "split_seed": meta.get("split_seed", "NA"),
        "array_order": "C",
        "arrays": arrays,
    }
    with (target / "metadata.json").open("w") as handle:
        json.dump(portable, handle, indent=2)
        handle.write("\n")
    shutil.copy2(source / "metadata.tsv", target / "metadata.tsv")
    return {
        "dataset": meta["dataset"],
        "task_type": task_type,
        "n_train": n_train,
        "n_test": n_test,
        "p": p,
        "q": q,
        "ncomp": int(meta["ncomp"]),
        "precision": "float32",
        "format": "npy",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    manifest_path = args.inputs / "manifest.csv"
    if not manifest_path.is_file():
        raise FileNotFoundError(manifest_path)
    with manifest_path.open(newline="") as handle:
        datasets = [row["dataset"] for row in csv.DictReader(handle)]
    args.output.mkdir(parents=True, exist_ok=True)
    rows = [
        convert_dataset(args.inputs / dataset, args.output / dataset)
        for dataset in datasets
    ]
    with (args.output / "manifest.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    (args.output / "README.md").write_text(
        """# Portable NumPy benchmark data

Every matrix is a C-contiguous NumPy `.npy` array. Predictors and continuous
responses are float32; classification labels are zero-based int32 values.
No pickle payload is used.

```python
import json
from pathlib import Path
import numpy as np

dataset = Path("ccle")
metadata = json.loads((dataset / "metadata.json").read_text())
X_train = np.load(dataset / "X_train.npy", mmap_mode="r")
X_test = np.load(dataset / "X_test.npy", mmap_mode="r")
Y_train = np.load(dataset / "Y_train.npy", mmap_mode="r")
y_train = np.load(dataset / "y_train.npy", mmap_mode="r")
y_test = np.load(dataset / "y_test.npy", mmap_mode="r")
```

Regression datasets contain `Y_test.npy` instead of class-label vectors.
`metadata.json` records the task, component count, shapes, dtypes and split.
"""
    )
    print(f"Converted {len(rows)} datasets to {args.output}")


if __name__ == "__main__":
    main()
