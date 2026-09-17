#!/usr/bin/env python3

import csv
import importlib.metadata
import pathlib
import resource
import sys
import threading
import time

import numpy as np
import psutil
from ikpls.numpy import PLS


def read_meta(root):
    with (root / "metadata.tsv").open(newline="") as handle:
        return {row["key"]: row["value"] for row in csv.DictReader(handle, delimiter="\t")}


root = pathlib.Path(sys.argv[1])
ncomp = int(sys.argv[2])
output = pathlib.Path(sys.argv[3])
block = int(sys.argv[4]) if len(sys.argv) > 4 else 2000
meta = read_meta(root)
dataset = meta["dataset"]
n, nt, p, q = (int(meta[x]) for x in ("n_train", "n_test", "p", "q"))

process = psutil.Process()
baseline = process.memory_info().rss
peak = baseline
running = True


def sample_memory():
    global peak
    while running:
        peak = max(peak, process.memory_info().rss)
        time.sleep(0.05)


monitor = threading.Thread(target=sample_memory, daemon=True)
monitor.start()
status = "success"
error = ""
fit_sec = predict_sec = np.nan
metric1 = metric5 = np.nan

try:
    train_order = "F" if dataset == "nmr" else "C"
    X = np.memmap(root / "Xtrain_centered.f32", dtype="<f4", mode="r", shape=(n, p), order=train_order)
    Y = np.memmap(root / "Ytrain_centered.f32", dtype="<f4", mode="r", shape=(n, q), order=train_order)
    model = PLS(
        algorithm=2, center_X=False, center_Y=False, scale_X=False,
        scale_Y=False, copy=False, dtype=np.float32,
    )
    started = time.perf_counter()
    model.fit(X, Y, ncomp)
    fit_sec = time.perf_counter() - started
    del X, Y

    started = time.perf_counter()
    if dataset == "nmr":
        Xt = np.memmap(root / "Xtest_centered.f32", dtype="<f4", mode="r", shape=(nt, p), order="F")
        Yt = np.memmap(root / "Ytest.f32", dtype="<f4", mode="r", shape=(nt, q), order="F")
        ymean = np.fromfile(root / "Ymean.f32", dtype="<f4")
        sse = 0.0
        n_values = 0
        for lo in range(0, nt, block):
            hi = min(nt, lo + block)
            pred = np.asarray(model.predict(Xt[lo:hi], n_components=ncomp), dtype=np.float32)
            pred += ymean
            diff = pred.astype(np.float64) - np.asarray(Yt[lo:hi], dtype=np.float64)
            sse += np.square(diff).sum()
            n_values += diff.size
        metric1 = float(np.sqrt(sse / n_values))
    else:
        Xt = np.memmap(root / "Xtest_raw.f32", dtype="<f4", mode="r", shape=(nt, p), order="F")
        ytest = np.fromfile(root / "ytest.i32", dtype="<i4")
        xmean = np.fromfile(root / "Xmean.f32", dtype="<f4")
        correct1 = correct5 = 0
        for lo in range(0, nt, block):
            hi = min(nt, lo + block)
            xb = np.asarray(Xt[lo:hi] - xmean, dtype=np.float32)
            scores = np.asarray(model.predict(xb, n_components=ncomp), dtype=np.float32)
            truth = ytest[lo:hi]
            pred = np.argmax(scores, axis=1)
            correct1 += int(np.sum(pred == truth))
            top5 = np.argpartition(scores, -5, axis=1)[:, -5:]
            correct5 += int(np.sum(np.any(top5 == truth[:, None], axis=1)))
        metric1 = correct1 / nt
        metric5 = correct5 / nt
    predict_sec = time.perf_counter() - started
except Exception as exc:
    status = "failed"
    error = f"{type(exc).__name__}: {exc}"
finally:
    running = False
    monitor.join(timeout=1)

row = {
    "dataset": dataset,
    "implementation": "IKPLS_numpy_cross_product",
    "ikpls_version": importlib.metadata.version("ikpls"),
    "precision": "float32",
    "n_train": n,
    "n_test": nt,
    "p": p,
    "q": q,
    "ncomp": ncomp,
    "coefficient_tensor_gib": ncomp * p * q * 4 / 1024**3,
    "fit_sec": fit_sec,
    "predict_sec": predict_sec,
    "total_sec": fit_sec + predict_sec,
    "top1_accuracy_or_rmsd": metric1,
    "top5_accuracy": metric5,
    "baseline_rss_mib": baseline / 1024**2,
    "peak_rss_mib": peak / 1024**2,
    "incremental_peak_rss_mib": (peak - baseline) / 1024**2,
    "ru_maxrss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
    "status": status,
    "error": error,
}
with output.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=row)
    writer.writeheader()
    writer.writerow(row)
