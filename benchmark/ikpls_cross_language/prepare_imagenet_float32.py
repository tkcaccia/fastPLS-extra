#!/usr/bin/env python3

import csv
import pathlib
import sys
import time

import numpy as np


root = pathlib.Path(sys.argv[1])
meta = {}
with (root / "metadata.tsv").open(newline="") as handle:
    for row in csv.DictReader(handle, delimiter="\t"):
        meta[row["key"]] = row["value"]
n, p, q = int(meta["n_train"]), int(meta["p"]), int(meta["q"])
block = int(sys.argv[2]) if len(sys.argv) > 2 else 10000

start = time.perf_counter()
X = np.memmap(root / "Xtrain_raw.f32", dtype="<f4", mode="r", shape=(n, p), order="F")
mean64 = np.zeros(p, dtype=np.float64)
for lo in range(0, n, block):
    hi = min(n, lo + block)
    mean64 += np.asarray(X[lo:hi], dtype=np.float64).sum(axis=0)
xmean = (mean64 / n).astype(np.float32)
xmean.tofile(root / "Xmean.f32")

Xc = np.memmap(root / "Xtrain_centered.f32", dtype="<f4", mode="w+", shape=(n, p), order="C")
for lo in range(0, n, block):
    hi = min(n, lo + block)
    Xc[lo:hi] = X[lo:hi] - xmean
Xc.flush()
del Xc, X

labels = np.fromfile(root / "ytrain.i32", dtype="<i4")
counts = np.bincount(labels, minlength=q).astype(np.float32)
ymean = counts / np.float32(n)
ymean.tofile(root / "Ymean.f32")
Yc = np.memmap(root / "Ytrain_centered.f32", dtype="<f4", mode="w+", shape=(n, q), order="C")
base = -ymean
for lo in range(0, n, block):
    hi = min(n, lo + block)
    rows = hi - lo
    chunk = np.broadcast_to(base, (rows, q)).copy()
    chunk[np.arange(rows), labels[lo:hi]] += np.float32(1)
    Yc[lo:hi] = chunk
Yc.flush()
del Yc

with (root / "preprocessing.tsv").open("w", newline="") as handle:
    writer = csv.writer(handle, delimiter="\t")
    writer.writerow(["preprocess_sec", time.perf_counter() - start])
    writer.writerow(["block_rows", block])
