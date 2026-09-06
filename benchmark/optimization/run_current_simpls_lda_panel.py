#!/usr/bin/env python3
"""Run the current float32 CPU SIMPLS classification panel in isolated processes."""

import argparse
import csv
import json
import os
from pathlib import Path
import subprocess


DEFAULT_COMPONENTS = {
    "ccle": 26,
    "cifar100": 298,
    "gtex_v8": 190,
    "metref": 118,
    "retina": 30,
    "tabula": 44,
    "tcga_brca": 7,
    "tcga_hnsc_methylation": 2,
    "tcga_pan_cancer": 185,
}


def read_csv(path):
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def finite(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def first_existing(paths):
    for path in paths:
        if path.exists():
            return str(path)
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--library", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=10800)
    parser.add_argument("--classifier", choices=("argmax", "lda"), default="lda")
    parser.add_argument("--selected-components", default="")
    args = parser.parse_args()

    components = dict(DEFAULT_COMPONENTS)
    if args.selected_components:
        selected_path = Path(args.selected_components).resolve()
        for row in read_csv(selected_path):
            if row.get("family") != "simpls":
                continue
            dataset = row.get("dataset", "")
            if dataset in components:
                components[dataset] = int(float(row["selected_ncomp"]))

    repo = Path(args.repo).resolve()
    output = Path(args.output).resolve()
    rows_dir = output / "run_rows"
    memory_dir = output / "memory"
    output.mkdir(parents=True, exist_ok=True)
    rows_dir.mkdir(exist_ok=True)
    memory_dir.mkdir(exist_ok=True)

    env = dict(os.environ)
    retina_path = first_existing([
        Path.home() / "Documents/GPUPLS/Data/metal_matched/Macosko2015_retina_float32.RData",
        Path.home() / "Documents/fastpls/data/Macosko2015_retina_float32.RData",
    ])
    tabula_path = first_existing([
        Path.home() / "Documents/GPUPLS/Data/metal_matched/TabulaMuris_float32.RData",
        Path.home() / "Documents/fastpls/data/TabulaMuris_float32.RData",
    ])
    env.update({
        "FASTPLS_BENCH_LIB": str(Path(args.library).resolve()),
        "FASTPLS_BENCH_PRECISION": "float32",
        "FASTPLS_TASK_ROOT": str(
            repo / "publication_results" / "0.99.39" /
            "current_release" / "tasks"
        ),
        "FASTPLS_RETINA_RDATA": retina_path,
        "FASTPLS_TABULA_RDATA": tabula_path,
    })

    method_id = "fastPLS_simpls_cpu_rsvd"
    if args.classifier == "lda":
        method_id += "_lda"

    statuses = []
    for dataset, ncomp in components.items():
        for replicate in range(1, args.repetitions + 1):
            stem = f"{dataset}__{method_id}__r{replicate}"
            row_path = rows_dir / f"{stem}.csv"
            monitor_path = memory_dir / stem
            command = [
                "Rscript", str(repo / "benchmark/benchmark_pls_package_comparison.R"),
                "--mode=run_one", f"--dataset={dataset}", f"--ncomp={ncomp}",
                f"--method-id={method_id}",
                f"--replicate={replicate}", f"--row-out={row_path}",
            ]
            monitored = [
                "python3", str(repo / "benchmark/optimization/monitor_process.py"),
                f"--output={monitor_path}", f"--timeout={args.timeout}",
                "--interval=0.005", "--", *command,
            ]
            result = subprocess.run(monitored, cwd=repo, env=env, check=False)
            statuses.append({
                "dataset": dataset, "replicate": replicate,
                "ncomp": ncomp, "exit_code": result.returncode,
                "row": str(row_path), "memory": str(monitor_path),
            })
            print(f"finished {stem}: exit={result.returncode}", flush=True)

    raw = []
    for status in statuses:
        path = Path(status["row"])
        if not path.exists():
            continue
        row = read_csv(path)[0]
        summary_path = Path(status["memory"]) / "summary.json"
        if summary_path.exists():
            measurements = json.loads(summary_path.read_text()).get("measurements", [])
            if measurements:
                row.update(measurements[0])
        raw.append(row)

    if raw:
        columns = list(raw[0])
        for row in raw[1:]:
            for key in row:
                if key not in columns:
                    columns.append(key)
        raw_path = output / f"current_simpls_{args.classifier}_raw.csv"
        with raw_path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=columns)
            writer.writeheader()
            writer.writerows(raw)

        summary = []
        for dataset in components:
            subset = [row for row in raw if row.get("dataset") == dataset]
            ok = [row for row in subset if row.get("status") == "ok"]
            def median(key):
                vals = sorted(v for row in ok if (v := finite(row.get(key))) is not None)
                if not vals:
                    return None
                middle = len(vals) // 2
                return vals[middle] if len(vals) % 2 else (vals[middle - 1] + vals[middle]) / 2
            summary.append({
                "dataset": dataset,
                "ncomp": components[dataset],
                "repetitions": len(subset),
                "successful": len(ok),
                "median_time_sec": None if median("total_runtime_ms") is None else median("total_runtime_ms") / 1000,
                "median_accuracy": median("accuracy"),
                "median_balanced_accuracy": median("balanced_accuracy"),
                "median_macro_f1": median("macro_f1"),
                "median_baseline_rss_mib": median("baseline_rss_mib"),
                "median_peak_rss_mib": median("peak_rss_mib"),
                "median_incremental_rss_mib": median("incremental_rss_mib"),
            })
        summary_path = output / f"current_simpls_{args.classifier}_summary.csv"
        with summary_path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(summary[0]))
            writer.writeheader()
            writer.writerows(summary)

    (output / "run_status.json").write_text(json.dumps(statuses, indent=2) + "\n")
    if any(item["exit_code"] != 0 for item in statuses):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
