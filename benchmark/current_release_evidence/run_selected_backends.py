#!/usr/bin/env python3
"""Run selected-component CPU/accelerator fits in monitored fresh processes."""

import argparse
import csv
import ctypes
import os
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
        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        size = library.proc_pidinfo(
            pid, 4, 0, ctypes.byref(info), ctypes.sizeof(info)
        )
        return info.resident_size / 1024**2 if size else 0.0
    return 0.0


def gpu_mib(pid):
    try:
        result = subprocess.run(
            [
                "nvidia-smi", "--query-compute-apps=pid,used_gpu_memory",
                "--format=csv,noheader,nounits",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return 0.0
    for line in result.stdout.splitlines():
        fields = [part.strip() for part in line.split(",")]
        if len(fields) == 2 and fields[0] == str(pid):
            try:
                return float(fields[1])
            except ValueError:
                return 0.0
    return 0.0


def read_selection(path):
    selected = {}
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream):
            family = row.get("family") or row.get("method")
            selected[(row["dataset"], family)] = int(float(row["selected_ncomp"]))
    return selected


def monitor(command, ready, go, output, use_gpu):
    process = subprocess.Popen(command)
    deadline = time.time() + 300
    while not ready.exists() and process.poll() is None:
        if time.time() > deadline:
            process.kill()
            raise RuntimeError("worker did not reach the measurement boundary")
        time.sleep(0.01)
    if process.poll() is not None:
        raise RuntimeError(f"worker exited before measurement: {process.returncode}")
    baseline = float(ready.read_text().strip())
    peak = baseline
    gpu_peak = 0.0
    go.touch()
    while process.poll() is None:
        peak = max(peak, rss_mib(process.pid))
        if use_gpu:
            gpu_peak = max(gpu_peak, gpu_mib(process.pid))
        time.sleep(0.005)
    if process.returncode:
        raise RuntimeError(f"worker failed with status {process.returncode}")
    with output.open(newline="") as stream:
        row = next(csv.DictReader(stream))
    row["peak_rss_mib"] = f"{peak:.9f}"
    row["incremental_peak_rss_mib"] = f"{max(0.0, peak - baseline):.9f}"
    row["gpu_peak_mib"] = f"{gpu_peak:.9f}"
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--task-dir", required=True)
    parser.add_argument("--selected", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--backends", nargs="+", required=True)
    parser.add_argument("--precision", default="float32")
    parser.add_argument("--classifiers", nargs="+", default=("argmax",))
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--source-id", default="unrecorded")
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--datasets", nargs="+")
    parser.add_argument(
        "--families", nargs="+",
        default=("plssvd", "simpls", "opls", "kernelpls"),
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    task_dir = Path(args.task_dir).resolve()
    datasets = args.datasets or sorted(
        path.name.removesuffix("_task.rds")
        for path in task_dir.glob("*_task.rds")
    )
    selected = read_selection(Path(args.selected))
    target = Path(args.output).resolve()
    work = target.parent / f"{target.stem}_workers"
    work.mkdir(parents=True, exist_ok=True)
    records = []
    for dataset in datasets:
        task = task_dir / f"{dataset}_task.rds"
        for family in args.families:
            ncomp = selected[(dataset, family)]
            for classifier in args.classifiers:
                for backend in args.backends:
                    for replicate in range(1, args.repetitions + 1):
                        stem = (
                            f"{dataset}_{family}_{classifier}_{backend}"
                            f"_r{replicate}"
                        )
                        output = work / f"{stem}.csv"
                        ready = work / f"{stem}.ready"
                        go = work / f"{stem}.go"
                        for path in (output, ready, go):
                            if path.exists():
                                path.unlink()
                        command = [
                            "Rscript", str(root / "selected_backend_worker.R"),
                            args.library, str(task), family, backend,
                            str(ncomp), str(replicate), str(output),
                            str(ready), str(go), args.source_id,
                            args.precision, args.expected_version, classifier,
                        ]
                        records.append(monitor(
                            command, ready, go, output, backend == "cuda"
                        ))
    with target.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)


if __name__ == "__main__":
    main()
