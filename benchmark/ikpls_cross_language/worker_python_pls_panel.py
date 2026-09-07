#!/usr/bin/env python3
"""Run one component-matched Python PLS benchmark replicate."""

import csv
import importlib.metadata
from pathlib import Path
import sys
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


def balanced_accuracy(
    observed: np.ndarray,
    predicted: np.ndarray,
    classes: int,
) -> float:
    recalls = []
    for class_id in range(classes):
        selected = observed == class_id
        if np.any(selected):
            recalls.append(np.mean(predicted[selected] == class_id))
    return float(np.mean(recalls)) if recalls else float("nan")


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
        model = PLSRegression(
            n_components=ncomp,
            solver=solver,
            center_x=True,
            scale_x=False,
            center_y=True,
            scale_y=False,
            store_scores=False,
        )
        label = "SIMPLS" if solver == "simpls" else "randomized-SVD PLS"
        return model, "pls4all", f"nirs4all-methods {label}"

    if implementation == "sklearn_plsregression":
        from sklearn.cross_decomposition import PLSRegression

        model = PLSRegression(
            n_components=ncomp,
            scale=False,
            max_iter=500,
            tol=1e-6,
            copy=False,
        )
        return model, "scikit-learn", "scikit-learn PLSRegression"

    raise ValueError(f"Unknown implementation: {implementation}")


if len(sys.argv) != 5:
    raise SystemExit(
        "Usage: worker_python_pls_panel.py DATASET_DIR REPLICATE "
        "IMPLEMENTATION OUTPUT_CSV"
    )

dataset_dir = Path(sys.argv[1])
replicate = int(sys.argv[2])
implementation = sys.argv[3]
output_path = Path(sys.argv[4])
if implementation not in IMPLEMENTATIONS:
    raise SystemExit(f"Unknown implementation: {implementation}")

meta = read_metadata(dataset_dir / "metadata.tsv")
n_train = int(meta["n_train"])
n_test = int(meta["n_test"])
p = int(meta["p"])
q = int(meta["q"])
ncomp = int(meta["ncomp"])
task_type = meta["task_type"]

# Both compared Python APIs execute these estimators in float64. Conversion is
# completed before the pre-fit baseline and timer so timing measures the model
# workflow rather than the interchange format.
Xtrain = np.fromfile(
    dataset_dir / "Xtrain.f32", dtype="<f4"
).reshape(n_train, p).astype(np.float64)
Xtest = np.fromfile(
    dataset_dir / "Xtest.f32", dtype="<f4"
).reshape(n_test, p).astype(np.float64)
Ytrain = np.fromfile(
    dataset_dir / "Ytrain.f32", dtype="<f4"
).reshape(n_train, q).astype(np.float64)
if task_type == "classification":
    Ytest = np.fromfile(dataset_dir / "Ytest.i32", dtype="<i4")
else:
    Ytest = np.fromfile(
        dataset_dir / "Ytest.f32", dtype="<f4"
    ).reshape(n_test, q).astype(np.float64)

process = psutil.Process()
prefit_rss_mib = process.memory_info().rss / 1024**2
model, distribution, algorithm = make_model(implementation, ncomp)

with warnings.catch_warnings(record=True) as captured_warnings:
    warnings.simplefilter("always")
    fit_started = time.perf_counter()
    model.fit(Xtrain, Ytrain)
    fit_sec = time.perf_counter() - fit_started

prediction_started = time.perf_counter()
prediction = np.asarray(model.predict(Xtest), dtype=np.float64)
if prediction.ndim == 1:
    prediction = prediction[:, None]
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
    squared_error = np.sum(residual**2, dtype=np.float64)
    rmsd = float(np.sqrt(squared_error / residual.size))
    mae = float(np.mean(np.abs(residual), dtype=np.float64))
    y_mean = np.mean(Ytrain, axis=0, dtype=np.float64)
    denominator = np.sum((Ytest - y_mean) ** 2, dtype=np.float64)
    q2 = (
        float(1.0 - squared_error / denominator)
        if denominator > 0
        else float("nan")
    )

row = {
    "dataset": meta["dataset"],
    "task_type": task_type,
    "implementation": implementation,
    "package": distribution,
    "package_version": importlib.metadata.version(distribution),
    "algorithm": algorithm,
    "solver_controls": (
        "package defaults; randomized controls not exposed by binding"
        if implementation == "nirs4all_methods_rsvd"
        else "package defaults"
    ),
    "precision": "float64",
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
    "warning_count": len(captured_warnings),
    "warnings": " | ".join(
        f"{type(item.message).__name__}: {item.message}"
        for item in captured_warnings
    ),
    "retained_output": "native fitted model and final held-out predictions",
}
with output_path.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=row.keys())
    writer.writeheader()
    writer.writerow(row)
