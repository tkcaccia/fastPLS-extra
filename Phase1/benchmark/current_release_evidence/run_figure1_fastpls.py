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


def component_contract(path):
    selected = {}
    with Path(path).open(newline="") as stream:
        for row in csv.DictReader(stream):
            for family in ("simpls", "plssvd"):
                component = row.get(f"{family}_ncomp")
                if component:
                    selected[(row["dataset"], family)] = {
                        "ncomp": int(component),
                        "task_type": row["task_type"]
                    }
    return selected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--tasks", required=True, type=Path)
    parser.add_argument(
        "--component-contract",
        default=str(Path(__file__).with_name("figure1_component_contract.csv"))
    )
    parser.add_argument("--output", required=True)
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--oversample", type=int, default=32)
    parser.add_argument("--power", type=int, default=5)
    parser.add_argument("--methods", nargs="+", default=("simpls",),
                        choices=("simpls", "plssvd"))
    parser.add_argument(
        "--datasets",
        nargs="+",
        default=None,
        help="Datasets to run; the default is every non-ImageNet contract row.",
    )
    args = parser.parse_args()
    contract = component_contract(args.component_contract)
    datasets = args.datasets
    if datasets is None:
        datasets = list(dict.fromkeys(
            dataset for dataset, _ in contract if dataset != "imagenet"
        ))
    unknown = sorted({dataset for dataset in datasets if
                      not any(key[0] == dataset for key in contract)})
    if unknown:
        parser.error("datasets absent from component contract: " + ", ".join(unknown))
    root = Path(__file__).resolve().parent
    target = Path(args.output).resolve()
    work = target.parent / (target.stem + "_workers")
    work.mkdir(parents=True, exist_ok=True)
    records = []
    for dataset in datasets:
        task_path = args.tasks.resolve() / f"{dataset}_task.rds"
        if not task_path.is_file():
            raise RuntimeError(f"missing prepared task: {task_path}")
        for method in args.methods:
            key = (dataset, method)
            if key not in contract:
                raise RuntimeError(
                    f"missing {method} component count for {dataset}"
                )
            task_type = contract[key]["task_type"]
            classifiers = ("lda",) if task_type == "classification" else ("none",)
            for classifier in classifiers:
                for replicate in range(1, args.repetitions + 1):
                    stem = f"{dataset}_{method}_{classifier}_r{replicate}"
                    output = work / f"{stem}.csv"
                    ready = work / f"{stem}.ready"
                    go = work / f"{stem}.go"
                    if output.exists():
                        with output.open(newline="") as stream:
                            existing = next(csv.DictReader(stream))
                        if "peak_rss_mib" in existing:
                            existing.setdefault(
                                "ncomp_requested",
                                str(contract[key]["ncomp"])
                            )
                            records.append(existing)
                            continue
                    for path in (ready, go):
                        if path.exists():
                            path.unlink()
                    command = [
                        "Rscript", str(root / "figure1_worker.R"), args.library,
                        str(task_path), dataset, method, classifier,
                        str(contract[key]["ncomp"]),
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
