#!/usr/bin/env python3
"""Benchmark current-development LDA alternatives, not external PLS packages."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--binary", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=False)
binary = a.binary.resolve(strict=True)
(a.out / "binary.json").write_text(json.dumps({
    "path": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "scope": "CPU LDA scores only; conversion and PLS fit excluded",
}, indent=2) + "\n")
all_rows = []
for threads in (1, 2, 4):
    print(f"OpenBLAS threads={threads}", flush=True)
    env = dict(os.environ, OPENBLAS_NUM_THREADS=str(threads), OMP_NUM_THREADS=str(threads))
    with (a.out / f"threads_{threads}.csv").open("w") as out, (
            a.out / f"threads_{threads}.log").open("w") as log:
        subprocess.run([str(binary)], env=env, stdout=out, stderr=log,
                       timeout=900, check=True)
    with (a.out / f"threads_{threads}.csv").open() as source:
        rows = list(csv.DictReader(source))
    assert rows and all(int(row["threads"]) == threads for row in rows)
    all_rows.extend(rows)
groups = {}
keys = ("precision", "n", "scores", "classes", "threads", "solver")
for row in all_rows:
    groups.setdefault(tuple(row[k] for k in keys), []).append(row)
summary = []
for key, rows in groups.items():
    result = dict(zip(keys, key), repetitions=len(rows))
    for field in ("moments_s", "solve_s", "predict_s", "total_s"):
        values = [float(r[field]) for r in rows]
        quartiles = statistics.quantiles(values, n=4, method="inclusive")
        result[field] = statistics.median(values)
        result[field + "_iqr"] = quartiles[2] - quartiles[0]
    result["accuracy"] = statistics.median(float(r["accuracy"]) for r in rows)
    result["min_agreement"] = min(float(r["agreement"]) for r in rows)
    result["max_score_error"] = max(float(r["relative_score_error"]) for r in rows)
    summary.append(result)
with (a.out / "summary.csv").open("w") as out:
    writer = csv.DictWriter(out, fieldnames=list(summary[0]))
    writer.writeheader()
    writer.writerows(summary)
print(f"Completed {len(all_rows)} measured fits; {len(summary)} summary rows", flush=True)
