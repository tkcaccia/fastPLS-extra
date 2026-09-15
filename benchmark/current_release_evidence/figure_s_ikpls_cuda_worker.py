#!/usr/bin/env python3
"""Run one float32 IKPLS JAX/CUDA benchmark replicate."""

import csv
import importlib.metadata
from pathlib import Path
import sys
import time

import jax
import jax.numpy as jnp
import numpy as np
import psutil
from ikpls.jax import PLS


def read_metadata(path: Path) -> dict[str, str]:
    with path.open(newline="") as handle:
        return {
            row["key"]: row["value"]
            for row in csv.DictReader(handle, delimiter="\t")
        }


def ready(value) -> None:
    for leaf in jax.tree_util.tree_leaves(value):
        if hasattr(leaf, "block_until_ready"):
            leaf.block_until_ready()


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


def load_inputs(dataset_dir: Path, meta: dict[str, str]):
    n_train = int(meta["n_train"])
    n_test = int(meta["n_test"])
    p = int(meta["p"])
    q = int(meta["q"])
    task_type = meta["task_type"]
    precentered = meta.get("precentered", "false").lower() == "true"
    x_train_name = "Xtrain_centered.f32" if precentered else "Xtrain.f32"
    y_train_name = "Ytrain_centered.f32" if precentered else "Ytrain.f32"
    x_test_name = "Xtest_raw.f32" if precentered else "Xtest.f32"
    x_train = np.fromfile(
        dataset_dir / x_train_name, dtype="<f4"
    ).reshape(n_train, p)
    x_test = np.fromfile(
        dataset_dir / x_test_name, dtype="<f4"
    ).reshape(n_test, p)
    y_train = np.fromfile(
        dataset_dir / y_train_name, dtype="<f4"
    ).reshape(n_train, q)
    if task_type == "classification":
        y_test = np.fromfile(dataset_dir / "Ytest.i32", dtype="<i4")
    else:
        y_test = np.fromfile(
            dataset_dir / "Ytest.f32", dtype="<f4"
        ).reshape(n_test, q)
    y_mean = None
    if precentered:
        x_mean = np.fromfile(dataset_dir / "Xmean.f32", dtype="<f4")
        y_mean = np.fromfile(dataset_dir / "Ymean.f32", dtype="<f4")
        x_test = x_test - x_mean
    return x_train, x_test, y_train, y_test, precentered, y_mean


def fit_predict(
    x_train_host: np.ndarray,
    x_test_host: np.ndarray,
    y_train_host: np.ndarray,
    ncomp: int,
    precentered: bool,
    y_mean: np.ndarray | None,
):
    started = time.perf_counter()
    x_train = jax.device_put(x_train_host)
    y_train = jax.device_put(y_train_host)
    ready((x_train, y_train))
    model = PLS(
        algorithm=2,
        center_X=not precentered,
        center_Y=not precentered,
        scale_X=False,
        scale_Y=False,
        copy=False,
        dtype=jnp.float32,
    )
    model.fit(x_train, y_train, ncomp)
    ready(model.B)
    fit_sec = time.perf_counter() - started

    started = time.perf_counter()
    x_test = jax.device_put(x_test_host)
    prediction_device = model.predict(x_test, n_components=ncomp)
    ready(prediction_device)
    prediction = np.asarray(prediction_device, dtype=np.float32)
    if y_mean is not None:
        prediction += y_mean
    prediction_sec = time.perf_counter() - started
    return model, prediction, fit_sec, prediction_sec


if len(sys.argv) != 6:
    raise SystemExit(
        "Usage: figure_s_ikpls_cuda_worker.py DATASET_DIR REPLICATE "
        "OUTPUT READY GO"
    )

dataset_dir = Path(sys.argv[1])
replicate = int(sys.argv[2])
output_path = Path(sys.argv[3])
ready_path = Path(sys.argv[4])
go_path = Path(sys.argv[5])
meta = read_metadata(dataset_dir / "metadata.tsv")
ncomp = int(meta["ncomp"])
task_type = meta["task_type"]
n_train = int(meta["n_train"])
n_test = int(meta["n_test"])
p = int(meta["p"])
q = int(meta["q"])

devices = jax.devices("gpu")
if not devices:
    raise RuntimeError("IKPLS CUDA benchmark requires a JAX GPU device")

x_train, x_test, y_train, y_test, precentered, y_mean = load_inputs(
    dataset_dir, meta
)
process = psutil.Process()
prefit_rss_mib = process.memory_info().rss / 1024**2
ready_path.write_text(f"{prefit_rss_mib:.15g}\n")
while not go_path.exists():
    time.sleep(0.01)

cold_model, prediction, cold_fit, cold_prediction = fit_predict(
    x_train, x_test, y_train, ncomp, precentered, y_mean
)
warm_model, _, warm_fit, warm_prediction = fit_predict(
    x_train, x_test, y_train, ncomp, precentered, y_mean
)

accuracy = balanced = top5 = rmsd = q2 = mae = float("nan")
correct = 0
if task_type == "classification":
    predicted = np.argmax(prediction, axis=1)
    correct = int(np.sum(predicted == y_test))
    accuracy = correct / y_test.size
    balanced = balanced_accuracy(y_test, predicted, q)
    if q >= 5:
        top = np.argpartition(prediction, -5, axis=1)[:, -5:]
        top5 = float(np.mean(np.any(top == y_test[:, None], axis=1)))
else:
    residual = prediction.astype(np.float64) - y_test.astype(np.float64)
    squared_error = np.sum(residual**2, dtype=np.float64)
    rmsd = float(np.sqrt(squared_error / residual.size))
    mae = float(np.mean(np.abs(residual), dtype=np.float64))
    y_mean = np.mean(y_train, axis=0, dtype=np.float64)
    denominator = np.sum(
        (y_test.astype(np.float64) - y_mean) ** 2,
        dtype=np.float64,
    )
    q2 = float(1.0 - squared_error / denominator) if denominator > 0 else float("nan")

row = {
    "dataset": meta["dataset"],
    "task_type": task_type,
    "implementation": "IKPLS_jax_cuda_alg2",
    "package_version": importlib.metadata.version("ikpls"),
    "jax_version": jax.__version__,
    "device": str(devices[0]),
    "precision": "float32",
    "backend": "cuda",
    "method": "improved_kernel_pls_algorithm_2",
    "classifier": "argmax" if task_type == "classification" else "none",
    "replicate": replicate,
    "n_train": n_train,
    "n_test": n_test,
    "p": p,
    "q": q,
    "ncomp_requested": ncomp,
    "ncomp": ncomp,
    "cold_fit_sec": cold_fit,
    "cold_prediction_sec": cold_prediction,
    "cold_total_sec": cold_fit + cold_prediction,
    "warm_fit_sec": warm_fit,
    "warm_prediction_sec": warm_prediction,
    "warm_total_sec": warm_fit + warm_prediction,
    "accuracy": accuracy,
    "balanced_accuracy": balanced,
    "top5_accuracy": top5,
    "correct": correct,
    "test_total": n_test,
    "rmsd": rmsd,
    "q2": q2,
    "mae": mae,
    "prefit_rss_mib": prefit_rss_mib,
    "final_rss_mib": process.memory_info().rss / 1024**2,
    "status": "success",
    "error": "",
    "retained_output": "IKPLS coefficient path and final held-out predictions",
}
with output_path.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=row.keys())
    writer.writeheader()
    writer.writerow(row)

# Keep objects alive until the monitor records their resident memory.
ready((cold_model.B, warm_model.B))
