#!/usr/bin/env python3

import csv
import os
import pathlib
import platform
import re
import subprocess
import sys
import time

import pandas as pd
try:
    import psutil
except ImportError:
    psutil = None


ROOT = pathlib.Path(__file__).resolve().parents[2]
if len(sys.argv) > 1:
    OUT = pathlib.Path(sys.argv[1])
elif os.environ.get("FASTPLS_RESULTS_ROOT"):
    OUT = pathlib.Path(os.environ["FASTPLS_RESULTS_ROOT"]) / "ikpls_cross_language"
else:
    raise RuntimeError("Supply an output directory or set FASTPLS_RESULTS_ROOT")
cached_inputs = os.environ.get("FASTPLS_IKPLS_INPUTS", "")
INPUTS = pathlib.Path(cached_inputs).resolve() if cached_inputs else OUT / "inputs"
ROWS = OUT / "rows"
ROWS.mkdir(parents=True, exist_ok=True)


def run_monitored(command: list[str], row_path: pathlib.Path, log_path: pathlib.Path) -> None:
    env = os.environ.copy()
    benchmark_library = env.get("FASTPLS_BENCH_LIB", "/private/tmp/fastpls_ikpls_rlib")
    for name in ("R_LIBS", "R_LIBS_USER"):
        env[name] = os.pathsep.join(dict.fromkeys(
            [benchmark_library, *env.get(name, "").split(os.pathsep)]
        )).rstrip(os.pathsep)
    env["OMP_NUM_THREADS"] = "1"
    env["OPENBLAS_NUM_THREADS"] = "1"
    env["MKL_NUM_THREADS"] = "1"
    timed_command = command
    if platform.system() == "Darwin":
        timed_command = ["/usr/bin/time", "-l", *command]
    elif platform.system() == "Linux":
        timed_command = ["/usr/bin/time", "-v", *command]
    started = time.perf_counter()
    with log_path.open("w") as log:
        process = subprocess.Popen(timed_command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        child = psutil.Process(process.pid) if psutil is not None else None
        try:
            baseline = child.memory_info().rss if child is not None else float("nan")
        except (psutil.NoSuchProcess, psutil.AccessDenied, PermissionError):
            baseline = float("nan")
        peak = baseline
        while process.poll() is None:
            if child is not None:
                try:
                    rss = child.memory_info().rss
                    for descendant in child.children(recursive=True):
                        rss += descendant.memory_info().rss
                    peak = max(peak, rss)
                except (psutil.NoSuchProcess, psutil.AccessDenied,
                        PermissionError):
                    pass
            time.sleep(0.002)
    if process.returncode != 0:
        raise RuntimeError(f"Command failed ({process.returncode}); see {log_path}")
    rows = pd.read_csv(row_path)
    log_text = log_path.read_text(errors="replace")
    if platform.system() == "Darwin":
        match = re.search(r"^\s*(\d+)\s+maximum resident set size$", log_text, re.MULTILINE)
        if match:
            peak = int(match.group(1))
    elif platform.system() == "Linux":
        match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", log_text)
        if match:
            peak = int(match.group(1)) * 1024
    rows["launch_rss_mb"] = baseline / 1024**2
    rows["peak_rss_mb"] = peak / 1024**2
    rows["incremental_peak_rss_mb"] = rows["peak_rss_mb"] - rows["prefit_rss_mb"]
    rows["isolated_process_wall_sec"] = time.perf_counter() - started
    rows.to_csv(row_path, index=False)


if not cached_inputs:
    subprocess.run(["Rscript", str(pathlib.Path(__file__).with_name("export_inputs.R")), str(INPUTS)], cwd=ROOT, check=True)
for dataset in ("breast", "metref", "cifar100"):
    if not (INPUTS / dataset / "metadata.tsv").is_file():
        raise RuntimeError(f"Missing prepared inputs for {dataset}: {INPUTS}")
python = os.environ.get("IKPLS_PYTHON", sys.executable)
implementations = (
    ("fastPLS_irlba", ["Rscript", str(pathlib.Path(__file__).with_name("worker_fastpls.R")), None, "irlba"]),
    ("fastPLS_rsvd", ["Rscript", str(pathlib.Path(__file__).with_name("worker_fastpls.R")), None, "rsvd"]),
    ("IKPLS_numpy_alg1", [python, str(pathlib.Path(__file__).with_name("worker_ikpls.py")), None, "1"]),
    ("IKPLS_numpy_alg2", [python, str(pathlib.Path(__file__).with_name("worker_ikpls.py")), None, "2"]),
)
requested = os.environ.get("FASTPLS_IKPLS_IMPLEMENTATIONS", "")
if requested:
    names = {value.strip() for value in requested.split(",") if value.strip()}
    unknown = names - {name for name, _ in implementations}
    if unknown:
        raise ValueError(f"Unknown implementations: {sorted(unknown)}")
    implementations = tuple(item for item in implementations if item[0] in names)
    if not implementations:
        raise ValueError("No implementations selected")

for dataset in ("breast", "metref", "cifar100"):
    for name, template in implementations:
        for replicate in range(1, 4):
            row_path = ROWS / f"{dataset}__{name}__rep{replicate}.csv"
            log_path = row_path.with_suffix(".log")
            if row_path.exists():
                continue
            command = list(template)
            command[2] = str(INPUTS / dataset)
            command.extend([str(replicate), str(row_path)])
            print(time.strftime("%Y-%m-%d %H:%M:%S"), dataset, name, replicate, flush=True)
            try:
                run_monitored(command, row_path, log_path)
            except Exception as error:
                with row_path.open("w", newline="") as handle:
                    writer = csv.DictWriter(handle, fieldnames=["dataset", "implementation", "replicate", "status", "error"])
                    writer.writeheader()
                    writer.writerow({"dataset": dataset, "implementation": name, "replicate": replicate,
                                     "status": "failed", "error": str(error)})

frames = [pd.read_csv(path) for path in sorted(ROWS.glob("*.csv"))]
results = pd.concat(frames, ignore_index=True, sort=False)
results["status"] = results.get("status", pd.Series(index=results.index, dtype=object)).fillna("success")
results.to_csv(OUT / "ikpls_cross_language_all_runs.csv", index=False)

success = results[results["status"] == "success"].copy()
summary = success.groupby(["dataset", "implementation", "package_version", "algorithm", "solver", "precision", "ncomp"], dropna=False).agg(
    repetitions=("replicate", "count"),
    accuracy=("accuracy", "median"),
    median_fit_sec=("fit_sec", "median"),
    iqr_fit_sec=("fit_sec", lambda x: x.quantile(0.75) - x.quantile(0.25)),
    median_prediction_sec=("prediction_sec", "median"),
    median_total_sec=("total_sec", "median"),
    iqr_total_sec=("total_sec", lambda x: x.quantile(0.75) - x.quantile(0.25)),
    median_peak_rss_mb=("peak_rss_mb", "median"),
    median_incremental_peak_rss_mb=("incremental_peak_rss_mb", "median"),
).reset_index()
summary.to_csv(OUT / "ikpls_cross_language_summary.csv", index=False)
print(summary.to_string(index=False))
