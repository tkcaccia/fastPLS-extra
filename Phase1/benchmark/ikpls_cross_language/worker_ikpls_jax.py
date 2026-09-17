#!/usr/bin/env python3

import csv
import importlib.metadata
import pathlib
import sys
import time

import jax
jax.config.update("jax_enable_x64", True)
import jax.numpy as jnp
import numpy as np
from ikpls.jax import PLS


def metadata(path: pathlib.Path) -> dict[str, str]:
    with path.open(newline="") as handle:
        return {row["key"]: row["value"] for row in csv.DictReader(handle, delimiter="\t")}


def ready(value):
    leaves = jax.tree_util.tree_leaves(value)
    for leaf in leaves:
        if hasattr(leaf, "block_until_ready"):
            leaf.block_until_ready()


dataset_dir = pathlib.Path(sys.argv[1])
algorithm = int(sys.argv[2])
replicate_id = int(sys.argv[3])
output_csv = pathlib.Path(sys.argv[4])
meta = metadata(dataset_dir / "metadata.tsv")
n_train, n_test = int(meta["n_train"]), int(meta["n_test"])
p, q, ncomp = int(meta["p"]), int(meta["q"]), int(meta["ncomp"])

Xtrain_host = np.fromfile(dataset_dir / "Xtrain.f64", dtype="<f8").reshape(n_train, p)
Xtest_host = np.fromfile(dataset_dir / "Xtest.f64", dtype="<f8").reshape(n_test, p)
Ytrain_host = np.fromfile(dataset_dir / "Ytrain.f64", dtype="<f8").reshape(n_train, q)
Ymean = np.fromfile(dataset_dir / "Ymean.f64", dtype="<f8")
ytest = np.loadtxt(dataset_dir / "ytest.txt", dtype=np.int64)

transfer_start = time.perf_counter()
Xtrain = jax.device_put(Xtrain_host)
Ytrain = jax.device_put(Ytrain_host)
ready((Xtrain, Ytrain))
train_transfer_sec = time.perf_counter() - transfer_start

kwargs = dict(algorithm=algorithm, center_X=False, center_Y=False, scale_X=False,
              scale_Y=False, copy=False, dtype=jnp.float64)
model = PLS(**kwargs)
fit_start = time.perf_counter()
model.fit(Xtrain, Ytrain, ncomp)
ready(model.B)
cold_fit_sec = time.perf_counter() - fit_start

warm_model = PLS(**kwargs)
fit_start = time.perf_counter()
warm_model.fit(Xtrain, Ytrain, ncomp)
ready(warm_model.B)
warm_fit_sec = time.perf_counter() - fit_start

transfer_start = time.perf_counter()
Xtest = jax.device_put(Xtest_host)
ready(Xtest)
test_transfer_sec = time.perf_counter() - transfer_start

prediction_start = time.perf_counter()
prediction_device = model.predict(Xtest, n_components=ncomp)
ready(prediction_device)
cold_prediction_device_sec = time.perf_counter() - prediction_start
host_start = time.perf_counter()
prediction = np.asarray(prediction_device) + Ymean
host_result_transfer_sec = time.perf_counter() - host_start
predicted = np.argmax(prediction, axis=1)

prediction_start = time.perf_counter()
warm_prediction = warm_model.predict(Xtest, n_components=ncomp)
ready(warm_prediction)
warm_prediction_device_sec = time.perf_counter() - prediction_start

cold_total_sec = (train_transfer_sec + cold_fit_sec + test_transfer_sec +
                  cold_prediction_device_sec + host_result_transfer_sec)
warm_total_sec = train_transfer_sec + warm_fit_sec + test_transfer_sec + warm_prediction_device_sec + host_result_transfer_sec
row = {
    "dataset": meta["dataset"], "implementation": f"IKPLS_jax_cuda_alg{algorithm}",
    "package_version": importlib.metadata.version("ikpls"),
    "jax_version": jax.__version__, "device": str(jax.devices()[0]),
    "algorithm": f"Improved Kernel PLS algorithm {algorithm}", "precision": "float64",
    "replicate": replicate_id, "n_train": n_train, "n_test": n_test,
    "p": p, "q": q, "ncomp": ncomp,
    "train_transfer_sec": train_transfer_sec, "cold_fit_sec": cold_fit_sec,
    "warm_fit_sec": warm_fit_sec, "test_transfer_sec": test_transfer_sec,
    "cold_prediction_device_sec": cold_prediction_device_sec,
    "warm_prediction_device_sec": warm_prediction_device_sec,
    "host_result_transfer_sec": host_result_transfer_sec,
    "cold_total_sec": cold_total_sec, "warm_total_sec": warm_total_sec,
    "accuracy": float(np.mean(predicted == ytest)),
    "prediction_checksum": int(np.sum(predicted * np.arange(1, predicted.size + 1))),
    "numerical_status": "different estimator family; end-to-end software comparison only",
}
with output_csv.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=row.keys())
    writer.writeheader(); writer.writerow(row)
