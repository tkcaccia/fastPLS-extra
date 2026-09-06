#!/usr/bin/env python3

import csv
import importlib.metadata
import pathlib
import sys
import time

import numpy as np
import psutil
from ikpls.numpy import PLS


def metadata(path: pathlib.Path) -> dict[str, str]:
    with path.open(newline="") as handle:
        return {row["key"]: row["value"] for row in csv.DictReader(handle, delimiter="\t")}


dataset_dir = pathlib.Path(sys.argv[1])
algorithm = int(sys.argv[2])
replicate_id = int(sys.argv[3])
output_csv = pathlib.Path(sys.argv[4])
meta = metadata(dataset_dir / "metadata.tsv")
n_train, n_test = int(meta["n_train"]), int(meta["n_test"])
p, q, ncomp = int(meta["p"]), int(meta["q"]), int(meta["ncomp"])

Xtrain = np.fromfile(dataset_dir / "Xtrain.f64", dtype="<f8").reshape(n_train, p)
Xtest = np.fromfile(dataset_dir / "Xtest.f64", dtype="<f8").reshape(n_test, p)
Ytrain = np.fromfile(dataset_dir / "Ytrain.f64", dtype="<f8").reshape(n_train, q)
Ymean = np.fromfile(dataset_dir / "Ymean.f64", dtype="<f8")
ytest = np.loadtxt(dataset_dir / "ytest.txt", dtype=np.int64)

model = PLS(
    algorithm=algorithm,
    center_X=False,
    center_Y=False,
    scale_X=False,
    scale_Y=False,
    copy=False,
    dtype=np.float64,
)
prefit_rss_mb = psutil.Process().memory_info().rss / 1024**2
fit_start = time.perf_counter()
model.fit(Xtrain, Ytrain, ncomp)
fit_sec = time.perf_counter() - fit_start

prediction_start = time.perf_counter()
prediction = np.asarray(model.predict(Xtest, n_components=ncomp)) + Ymean
predicted = np.argmax(prediction, axis=1)
prediction_sec = time.perf_counter() - prediction_start

row = {
    "dataset": meta["dataset"],
    "implementation": f"IKPLS_numpy_alg{algorithm}",
    "package_version": importlib.metadata.version("ikpls"),
    "algorithm": f"Improved Kernel PLS algorithm {algorithm}",
    "solver": "eigendecomposition",
    "precision": "float64",
    "replicate": replicate_id,
    "n_train": n_train,
    "n_test": n_test,
    "p": p,
    "q": q,
    "ncomp": ncomp,
    "fit_sec": fit_sec,
    "prediction_sec": prediction_sec,
    "total_sec": fit_sec + prediction_sec,
    "accuracy": float(np.mean(predicted == ytest)),
    "prediction_checksum": int(np.sum(predicted * np.arange(1, predicted.size + 1))),
    "prefit_rss_mb": prefit_rss_mb,
    "retained_output": "final predictions requested; IKPLS internal coefficient path retained by implementation",
    "numerical_status": "different estimator family; end-to-end software comparison only",
}
with output_csv.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=row.keys())
    writer.writeheader()
    writer.writerow(row)
