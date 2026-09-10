#!/usr/bin/env python3
"""Time IKPLS algorithm 2 on an exported benchmark task."""

import csv
from pathlib import Path
import sys
import time

import numpy as np


def metadata(path: Path) -> dict[str, str]:
    with path.open(newline="") as handle:
        return {
            row["key"]: row["value"]
            for row in csv.DictReader(handle, delimiter="\t")
        }


source_parent = Path(sys.argv[1]).resolve()
task_dir = Path(sys.argv[2]).resolve()
repetitions = int(sys.argv[3])
sys.path.insert(0, str(source_parent))

from ikpls.numpy import PLS  # noqa: E402


info = metadata(task_dir / "metadata.tsv")
n_train = int(info["n_train"])
n_test = int(info["n_test"])
p = int(info["p"])
q = int(info["q"])
ncomp = int(info["ncomp"])

fit_times = []
prediction_times = []
accuracies = []
for _ in range(repetitions):
    x_train = np.fromfile(
        task_dir / "Xtrain.f32", dtype="<f4"
    ).reshape(n_train, p).copy()
    x_test = np.fromfile(
        task_dir / "Xtest.f32", dtype="<f4"
    ).reshape(n_test, p).copy()
    y_train = np.fromfile(
        task_dir / "Ytrain.f32", dtype="<f4"
    ).reshape(n_train, q).copy()
    y_test = np.fromfile(task_dir / "Ytest.i32", dtype="<i4")

    started = time.perf_counter()
    x_mean = x_train.mean(axis=0, dtype=np.float32)
    y_mean = y_train.mean(axis=0, dtype=np.float32)
    x_train -= x_mean
    y_train -= y_mean
    model = PLS(
        algorithm=2,
        center_X=False,
        center_Y=False,
        scale_X=False,
        scale_Y=False,
        copy=False,
        dtype=np.float32,
    )
    model.fit(x_train, y_train, ncomp)
    fit_times.append(time.perf_counter() - started)

    started = time.perf_counter()
    x_test -= x_mean
    prediction = np.asarray(
        model.predict(x_test, n_components=ncomp), dtype=np.float32
    )
    prediction += y_mean
    prediction_times.append(time.perf_counter() - started)
    accuracies.append(float(np.mean(np.argmax(prediction, axis=1) == y_test)))

print(f"n_train={n_train} n_test={n_test} p={p} q={q} ncomp={ncomp}")
print("fit_sec=" + ",".join(f"{value:.9f}" for value in fit_times))
print(
    "prediction_sec="
    + ",".join(f"{value:.9f}" for value in prediction_times)
)
print("accuracy=" + ",".join(f"{value:.9f}" for value in accuracies))
print("numpy_config_begin")
np.show_config()
print("numpy_config_end")
