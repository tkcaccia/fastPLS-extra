#!/usr/bin/env python3
import argparse
import csv
import ctypes
from pathlib import Path
import platform
import subprocess
import time


def rss_mib(pid):
    status = Path(f"/proc/{pid}/status")
    if status.exists():
        for line in status.read_text().splitlines():
            if line.startswith("VmRSS:"):
                return float(line.split()[1]) / 1024.0
    if platform.system() == "Darwin":
        class ProcTaskInfo(ctypes.Structure):
            _fields_ = [
                ("virtual_size", ctypes.c_uint64),
                ("resident_size", ctypes.c_uint64),
                ("total_user", ctypes.c_uint64),
                ("total_system", ctypes.c_uint64),
                ("threads_user", ctypes.c_uint64),
                ("threads_system", ctypes.c_uint64),
                ("policy", ctypes.c_int32),
                ("faults", ctypes.c_int32),
                ("pageins", ctypes.c_int32),
                ("cow_faults", ctypes.c_int32),
                ("messages_sent", ctypes.c_int32),
                ("messages_received", ctypes.c_int32),
                ("syscalls_mach", ctypes.c_int32),
                ("syscalls_unix", ctypes.c_int32),
                ("context_switches", ctypes.c_int32),
                ("thread_count", ctypes.c_int32),
                ("running_threads", ctypes.c_int32),
                ("priority", ctypes.c_int32),
            ]
        info = ProcTaskInfo()
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        size = libproc.proc_pidinfo(
            pid, 4, 0, ctypes.byref(info), ctypes.sizeof(info)
        )
        return info.resident_size / 1024**2 if size else 0.0
    return 0.0


def run(command, ready, go, output, ready_timeout=900):
    process = subprocess.Popen(command)
    deadline = time.time() + ready_timeout
    while not ready.exists() and process.poll() is None:
        if time.time() > deadline:
            process.kill()
            raise RuntimeError("worker did not reach the fit boundary")
        time.sleep(0.01)
    if process.poll() is not None:
        raise RuntimeError("worker exited before fitting")
    baseline = float(ready.read_text().strip())
    peak = baseline
    go.touch()
    while process.poll() is None:
        peak = max(peak, rss_mib(process.pid))
        time.sleep(0.005)
    if process.returncode:
        raise RuntimeError(f"worker failed with status {process.returncode}")
    with output.open(newline="") as stream:
        row = next(csv.DictReader(stream))
    row["peak_rss_mib"] = f"{peak:.9f}"
    row["incremental_peak_rss_mib"] = f"{max(0.0, peak-baseline):.9f}"
    with output.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(row))
        writer.writeheader()
        writer.writerow(row)
    return row


def selected_components(path):
    selected = {}
    with Path(path).open(newline="") as stream:
        for row in csv.DictReader(stream):
            family = row.get("family", row.get("method"))
            backend = row.get("backend", "cpu")
            component = row.get("ncomp", row.get("selected_ncomp"))
            if family in {"simpls", "plssvd"} and backend == "cpu" and component:
                selected[(row["dataset"], family)] = int(component)
    return selected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--selected-panel", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--oversample", type=int, default=32)
    parser.add_argument("--power", type=int, default=5)
    parser.add_argument("--methods", nargs="+", default=("simpls", "plssvd"),
                        choices=("simpls", "plssvd"))
    parser.add_argument("--datasets", nargs="+", default=(
        "ccle", "cifar100", "gtex_v8", "metref", "retina", "tabula",
        "tcga_brca", "tcga_hnsc_methylation", "tcga_pan_cancer"
    ))
    args = parser.parse_args()
    ncomp = selected_components(args.selected_panel)
    root = Path(__file__).resolve().parent
    target = Path(args.output).resolve()
    work = target.parent / (target.stem + "_workers")
    work.mkdir(parents=True, exist_ok=True)
    records = []
    for dataset in args.datasets:
        for method in args.methods:
            key = (dataset, method)
            if key not in ncomp:
                raise RuntimeError(
                    f"missing {method} component count for {dataset}"
                )
            for classifier in ("argmax", "lda"):
                for replicate in range(1, args.repetitions + 1):
                    stem = f"{dataset}_{method}_{classifier}_r{replicate}"
                    output = work / f"{stem}.csv"
                    ready = work / f"{stem}.ready"
                    go = work / f"{stem}.go"
                    if output.exists():
                        with output.open(newline="") as stream:
                            existing = next(csv.DictReader(stream))
                        if "peak_rss_mib" in existing:
                            records.append(existing)
                            continue
                    for path in (ready, go):
                        if path.exists():
                            path.unlink()
                    command = [
                        "Rscript", str(root / "figure1_worker.R"), args.library,
                        dataset, method, classifier, str(ncomp[key]),
                        str(replicate), str(output), str(ready), str(go),
                        str(args.oversample), str(args.power),
                        args.package_version
                    ]
                    records.append(run(command, ready, go, output))
    with target.open("w", newline="") as stream:
        fieldnames = list(dict.fromkeys(
            key for record in records for key in record
        ))
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(records)


if __name__ == "__main__":
    main()
