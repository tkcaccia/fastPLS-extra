#!/usr/bin/env python3
"""Run one float32 IKPLS algorithm-2 benchmark replicate."""

import csv
import importlib.metadata
from pathlib import Path
import sys
import time

import numpy as np
import psutil
from ikpls.numpy import PLS


def read_metadata(path: Path) -> dict[str, str]:
    with path.open(newline="") as handle:
        return {row["key"]: row["value"] for row in csv.DictReader(handle, delimiter="\t")}


def balanced_accuracy(observed: np.ndarray, predicted: np.ndarray, classes: int) -> float:
    recalls = []
    for class_id in range(classes):
        selected = observed == class_id
        if np.any(selected):
            recalls.append(np.mean(predicted[selected] == class_id))
    return float(np.mean(recalls)) if recalls else float("nan")


dataset_dir = Path(sys.argv[1])
replicate = int(sys.argv[2])
output_path = Path(sys.argv[3])
meta = read_metadata(dataset_dir / "metadata.tsv")
n_train = int(meta["n_train"])
n_test = int(meta["n_test"])
p = int(meta["p"])
q = int(meta["q"])
ncomp = int(meta["ncomp"])
task_type = meta["task_type"]

Xtrain = np.fromfile(dataset_dir / "Xtrain.f32", dtype="<f4").reshape(n_train, p)
Xtest = np.fromfile(dataset_dir / "Xtest.f32", dtype="<f4").reshape(n_test, p)
Ytrain = np.fromfile(dataset_dir / "Ytrain.f32", dtype="<f4").reshape(n_train, q)
if task_type == "classification":
    Ytest = np.fromfile(dataset_dir / "Ytest.i32", dtype="<i4")
else:
    Ytest = np.fromfile(dataset_dir / "Ytest.f32", dtype="<f4").reshape(n_test, q)

process = psutil.Process()
prefit_rss_mib = process.memory_info().rss / 1024**2
fit_started = time.perf_counter()
x_mean = Xtrain.mean(axis=0, dtype=np.float32)
y_mean = Ytrain.mean(axis=0, dtype=np.float32)
Xtrain -= x_mean
Ytrain -= y_mean
model = PLS(
    algorithm=2,
    center_X=False,
    center_Y=False,
    scale_X=False,
    scale_Y=False,
    copy=False,
    dtype=np.float32,
)
model.fit(Xtrain, Ytrain, ncomp)
fit_sec = time.perf_counter() - fit_started

prediction_started = time.perf_counter()
Xtest -= x_mean
prediction = np.asarray(model.predict(Xtest, n_components=ncomp), dtype=np.float32)
prediction += y_mean
prediction_sec = time.perf_counter() - prediction_started

accuracy = balanced = top5 = rmsd = q2 = mae = float("nan")
correct = test_total = 0
if task_type == "classification":
    predicted = np.argmax(prediction, axis=1)
    correct = int(np.sum(predicted == Ytest))
    test_total = int(Ytest.size)
    accuracy = correct / test_total
    balanced = balanced_accuracy(Ytest, predicted, q)
    if q >= 5:
        top = np.argpartition(prediction, -5, axis=1)[:, -5:]
        top5 = float(np.mean(np.any(top == Ytest[:, None], axis=1)))
else:
    residual = prediction - Ytest
    squared_error = np.sum(residual.astype(np.float64) ** 2)
    rmsd = float(np.sqrt(squared_error / residual.size))
    mae = float(np.mean(np.abs(residual), dtype=np.float64))
    denominator = np.sum(
        (Ytest.astype(np.float64) - y_mean.astype(np.float64)) ** 2
    )
    q2 = float(1.0 - squared_error / denominator) if denominator > 0 else float("nan")

row = {
    "dataset": meta["dataset"],
    "task_type": task_type,
    "implementation": "IKPLS_numpy_alg2",
    "package_version": importlib.metadata.version("ikpls"),
    "algorithm": "Improved Kernel PLS algorithm 2",
    "precision": "float32",
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
    "balanced_accuracy": balanced,
    "top5_accuracy": top5,
    "correct": correct,
    "test_total": test_total,
    "rmsd": rmsd,
    "q2": q2,
    "mae": mae,
    "prefit_rss_mib": prefit_rss_mib,
    "status": "success",
    "error": "",
    "retained_output": "final held-out predictions; IKPLS coefficient path retained internally",
}
with output_path.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=row.keys())
    writer.writeheader()
    writer.writerow(row)
