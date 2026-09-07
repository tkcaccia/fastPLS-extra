#!/usr/bin/env python3
"""Run one memory-monitored Python PLS fit on NMR or ImageNet inputs."""

import csv
import importlib.metadata
from pathlib import Path
import sys
import threading
import time
import warnings

import numpy as np
import psutil


IMPLEMENTATIONS = {
    "nirs4all_methods_simpls",
    "nirs4all_methods_rsvd",
    "sklearn_plsregression",
}


def read_metadata(path: Path) -> dict[str, str]:
    with path.open(newline="") as handle:
        return {
            row["key"]: row["value"]
            for row in csv.DictReader(handle, delimiter="\t")
        }


def make_model(implementation: str, ncomp: int):
    if implementation in {
        "nirs4all_methods_simpls",
        "nirs4all_methods_rsvd",
    }:
        from pls4all.sklearn import PLSRegression

        solver = (
            "simpls"
            if implementation == "nirs4all_methods_simpls"
            else "randomized-svd"
        )
        return (
            PLSRegression(
                n_components=ncomp,
                solver=solver,
                center_x=False,
                scale_x=False,
                center_y=False,
                scale_y=False,
                store_scores=False,
            ),
            "pls4all",
            "nirs4all-methods "
            + ("SIMPLS" if solver == "simpls" else "randomized-SVD PLS"),
        )
    if implementation == "sklearn_plsregression":
        from sklearn.cross_decomposition import PLSRegression

        return (
            PLSRegression(
                n_components=ncomp,
                scale=False,
                max_iter=500,
                tol=1e-6,
                copy=False,
            ),
            "scikit-learn",
            "scikit-learn PLSRegression",
        )
    raise ValueError(f"Unknown implementation: {implementation}")


if len(sys.argv) != 7:
    raise SystemExit(
        "Usage: worker_python_pls_large.py DATASET_DIR NCOMP REPLICATE "
        "IMPLEMENTATION OUTPUT_CSV PREDICTION_BLOCK"
    )

root = Path(sys.argv[1])
ncomp = int(sys.argv[2])
replicate = int(sys.argv[3])
implementation = sys.argv[4]
output_path = Path(sys.argv[5])
block = int(sys.argv[6])
if implementation not in IMPLEMENTATIONS:
    raise SystemExit(f"Unknown implementation: {implementation}")

meta = read_metadata(root / "metadata.tsv")
dataset = meta["dataset"].lower()
n_train, n_test, p, q = (
    int(meta[name]) for name in ("n_train", "n_test", "p", "q")
)
if dataset not in {"nmr", "imagenet"}:
    raise ValueError(f"Unsupported large dataset: {dataset}")

order = "F" if dataset == "nmr" else "C"
Xtrain = np.memmap(
    root / "Xtrain_centered.f32",
    dtype="<f4",
    mode="r",
    shape=(n_train, p),
    order=order,
)
Ytrain = np.memmap(
    root / "Ytrain_centered.f32",
    dtype="<f4",
    mode="r",
    shape=(n_train, q),
    order=order,
)

process = psutil.Process()
prefit = process.memory_info().rss
peak = prefit
monitoring = True


def sample_memory() -> None:
    global peak
    while monitoring:
        peak = max(peak, process.memory_info().rss)
        time.sleep(0.01)


monitor = threading.Thread(target=sample_memory, daemon=True)
monitor.start()
model, distribution, algorithm = make_model(implementation, ncomp)
fit_sec = prediction_sec = float("nan")
accuracy = top5 = rmsd = q2 = float("nan")
correct = test_total = 0

try:
    with warnings.catch_warnings(record=True) as captured_warnings:
        warnings.simplefilter("always")
        started = time.perf_counter()
        model.fit(Xtrain, Ytrain)
        fit_sec = time.perf_counter() - started
    del Xtrain, Ytrain

    started = time.perf_counter()
    if dataset == "nmr":
        Xtest = np.memmap(
            root / "Xtest_centered.f32",
            dtype="<f4",
            mode="r",
            shape=(n_test, p),
            order="F",
        )
        Ytest = np.memmap(
            root / "Ytest.f32",
            dtype="<f4",
            mode="r",
            shape=(n_test, q),
            order="F",
        )
        ymean = np.fromfile(root / "Ymean.f32", dtype="<f4")
        sse = denominator = 0.0
        count = 0
        for lower in range(0, n_test, block):
            upper = min(n_test, lower + block)
            predicted = np.asarray(model.predict(Xtest[lower:upper]))
            predicted += ymean
            observed = np.asarray(Ytest[lower:upper], dtype=np.float64)
            residual = predicted - observed
            sse += np.sum(residual**2, dtype=np.float64)
            denominator += np.sum(
                (observed - ymean) ** 2,
                dtype=np.float64,
            )
            count += residual.size
        rmsd = float(np.sqrt(sse / count))
        q2 = float(1.0 - sse / denominator) if denominator > 0 else float("nan")
    else:
        Xtest = np.memmap(
            root / "Xtest_raw.f32",
            dtype="<f4",
            mode="r",
            shape=(n_test, p),
            order="F",
        )
        ytest = np.fromfile(root / "ytest.i32", dtype="<i4")
        xmean = np.fromfile(root / "Xmean.f32", dtype="<f4")
        correct5 = 0
        for lower in range(0, n_test, block):
            upper = min(n_test, lower + block)
            scores = np.asarray(
                model.predict(
                    np.asarray(Xtest[lower:upper] - xmean, dtype=np.float32)
                )
            )
            truth = ytest[lower:upper]
            predicted = np.argmax(scores, axis=1)
            correct += int(np.sum(predicted == truth))
            top = np.argpartition(scores, -5, axis=1)[:, -5:]
            correct5 += int(np.sum(np.any(top == truth[:, None], axis=1)))
        test_total = int(n_test)
        accuracy = correct / test_total
        top5 = correct5 / test_total
    prediction_sec = time.perf_counter() - started
finally:
    monitoring = False
    monitor.join(timeout=1)

row = {
    "dataset": dataset,
    "task_type": "regression" if dataset == "nmr" else "classification",
    "implementation": implementation,
    "package": distribution,
    "package_version": importlib.metadata.version(distribution),
    "algorithm": algorithm,
    "solver_controls": (
        "package defaults; randomized controls not exposed by binding"
        if implementation == "nirs4all_methods_rsvd"
        else "package defaults"
    ),
    "precision": "float64 native; float32 interchange",
    "replicate": replicate,
    "n_train": n_train,
    "n_test": n_test,
    "p": p,
    "q": q,
    "ncomp": ncomp,
    "fit_sec": fit_sec,
    "prediction_sec": prediction_sec,
    "total_sec": fit_sec + prediction_sec,
    "accuracy": accuracy,
    "top5_accuracy": top5,
    "correct": correct,
    "test_total": test_total,
    "rmsd": rmsd,
    "q2": q2,
    "prefit_rss_mib": prefit / 1024**2,
    "peak_rss_mib": peak / 1024**2,
    "incremental_peak_rss_mib": (peak - prefit) / 1024**2,
    "warning_count": len(captured_warnings),
    "warnings": " | ".join(
        f"{type(item.message).__name__}: {item.message}"
        for item in captured_warnings
    ),
    "status": "success",
    "error": "",
    "retained_output": "native fitted model and blocked held-out predictions",
}
with output_path.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=row)
    writer.writeheader()
    writer.writerow(row)
