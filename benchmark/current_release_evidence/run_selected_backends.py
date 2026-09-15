#!/usr/bin/env python3
"""Run selected-component CPU/accelerator fits in monitored fresh processes."""

import argparse
import csv
import ctypes
import os
from pathlib import Path
import platform
import signal
import subprocess
import time


RESULT_FIELDS = (
    "package_version", "package_library", "source_id", "dataset", "family",
    "backend", "precision", "classifier", "requested_ncomp",
    "effective_ncomp", "seed", "replicate",
    "kernel", "gamma", "degree", "coef0",
    "fit_sec", "prediction_sec", "total_sec", "metric_name", "metric_value",
    "prefit_rss_mib", "final_rss_mib", "execution_route", "refresh_block",
    "effective_oversample", "effective_power", "status", "error_message",
    "peak_rss_mib", "incremental_peak_rss_mib", "gpu_peak_mib",
)


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
            if family:
                selected[(row["dataset"], family)] = int(
                    float(row["selected_ncomp"])
                )
                continue
            if "plssvd_ncomp" not in row or "simpls_ncomp" not in row:
                raise ValueError(
                    "selection table must be long format or the publication "
                    "component contract"
                )
            selected[(row["dataset"], "plssvd")] = int(
                float(row["plssvd_ncomp"])
            )
            sequential = int(float(row["simpls_ncomp"]))
            for sequential_family in ("simpls", "opls", "kernelpls"):
                selected[(row["dataset"], sequential_family)] = sequential
    return selected


def stop_process(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def monitor(command, ready, go, output, log, use_gpu, timeout_sec):
    log_stream = log.open("w")
    process = subprocess.Popen(
        command, stdout=log_stream, stderr=subprocess.STDOUT, text=True,
        start_new_session=True,
    )
    deadline = time.time() + 300
    while not ready.exists() and process.poll() is None:
        if time.time() > deadline:
            stop_process(process)
            log_stream.close()
            raise RuntimeError("worker did not reach the measurement boundary")
        time.sleep(0.01)
    if process.poll() is not None:
        log_stream.close()
        detail = log.read_text(errors="replace")[-2000:]
        raise RuntimeError(
            f"worker exited before measurement: {process.returncode}: {detail}"
        )
    baseline = float(ready.read_text().strip())
    peak = baseline
    gpu_peak = 0.0
    go.touch()
    measurement_deadline = time.time() + timeout_sec
    while process.poll() is None:
        if time.time() > measurement_deadline:
            stop_process(process)
            log_stream.close()
            raise TimeoutError(
                f"worker exceeded the {timeout_sec}-second measurement limit"
            )
        peak = max(peak, rss_mib(process.pid))
        if use_gpu:
            gpu_peak = max(gpu_peak, gpu_mib(process.pid))
        time.sleep(0.005)
    log_stream.close()
    if process.returncode:
        detail = log.read_text(errors="replace")[-2000:]
        raise RuntimeError(
            f"worker failed with status {process.returncode}: {detail}"
        )
    with output.open(newline="") as stream:
        row = next(csv.DictReader(stream))
    row["peak_rss_mib"] = f"{peak:.9f}"
    row["incremental_peak_rss_mib"] = f"{max(0.0, peak - baseline):.9f}"
    row["gpu_peak_mib"] = f"{gpu_peak:.9f}"
    row["error_message"] = ""
    return row


def failure_row(args, dataset, family, backend, classifier, ncomp, replicate,
                error):
    message = " ".join(str(error).split())
    lowered = message.lower()
    if isinstance(error, TimeoutError):
        status = "timeout"
    elif any(word in lowered for word in (
        "unavailable", "not available", "unsupported"
    )):
        status = "unavailable"
    else:
        status = "failed"
    row = {field: "" for field in RESULT_FIELDS}
    row.update({
        "package_version": args.expected_version,
        "package_library": args.library,
        "source_id": args.source_id,
        "dataset": dataset,
        "family": family,
        "backend": backend,
        "precision": args.precision,
        "classifier": classifier,
        "requested_ncomp": ncomp,
        "effective_ncomp": "",
        "seed": 123,
        "replicate": replicate,
        "kernel": args.kernel if family == "kernelpls" else "",
        "gamma": args.gamma if family == "kernelpls" else "",
        "degree": args.degree if family == "kernelpls" else "",
        "coef0": args.coef0 if family == "kernelpls" else "",
        "status": status,
        "error_message": message,
    })
    return row


def record_key(record):
    return tuple(str(record[field]) for field in (
        "dataset", "family", "classifier", "backend", "replicate",
        "precision", "kernel", "gamma", "degree", "coef0",
    ))


def write_records(path, records):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=RESULT_FIELDS)
        writer.writeheader()
        writer.writerows(records)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--task-dir", required=True)
    parser.add_argument("--selected", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--backends", nargs="+", required=True)
    parser.add_argument("--precision", default="float32")
    parser.add_argument(
        "--kernel", choices=("linear", "rbf", "polynomial"),
        default="linear"
    )
    parser.add_argument("--gamma", default="auto")
    parser.add_argument("--degree", type=int, default=3)
    parser.add_argument("--coef0", type=float, default=1.0)
    parser.add_argument("--classifiers", nargs="+", default=("argmax",))
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--timeout-sec", type=int, default=14400)
    parser.add_argument("--resume", action="store_true")
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
    completed = {}
    if args.resume and target.exists():
        with target.open(newline="") as stream:
            for record in csv.DictReader(stream):
                if record.get("status") == "success":
                    completed[record_key(record)] = record
    for dataset in datasets:
        task = task_dir / f"{dataset}_task.rds"
        for family in args.families:
            ncomp = selected[(dataset, family)]
            for classifier in args.classifiers:
                for backend in args.backends:
                    for replicate in range(1, args.repetitions + 1):
                        prospective = {
                            "dataset": dataset,
                            "family": family,
                            "classifier": classifier,
                            "backend": backend,
                            "replicate": replicate,
                            "precision": args.precision,
                            "kernel": args.kernel if family == "kernelpls" else "",
                            "gamma": args.gamma if family == "kernelpls" else "",
                            "degree": args.degree if family == "kernelpls" else "",
                            "coef0": args.coef0 if family == "kernelpls" else "",
                        }
                        key = record_key(prospective)
                        if key in completed:
                            records.append(completed[key])
                            continue
                        stem = (
                            f"{dataset}_{family}_{classifier}_{backend}"
                            f"_r{replicate}"
                        )
                        if family == "kernelpls" and args.kernel != "linear":
                            stem = f"{stem}_{args.kernel}"
                        output = work / f"{stem}.csv"
                        ready = work / f"{stem}.ready"
                        go = work / f"{stem}.go"
                        log = work / f"{stem}.log"
                        for path in (output, ready, go, log):
                            if path.exists():
                                path.unlink()
                        command = [
                            "Rscript", str(root / "selected_backend_worker.R"),
                            args.library, str(task), family, backend,
                            str(ncomp), str(replicate), str(output),
                            str(ready), str(go), args.source_id,
                            args.precision, args.expected_version, classifier,
                            args.kernel, args.gamma, str(args.degree),
                            str(args.coef0),
                        ]
                        try:
                            record = monitor(
                                command, ready, go, output, log,
                                backend == "cuda", args.timeout_sec
                            )
                        except Exception as error:
                            record = failure_row(
                                args, dataset, family, backend, classifier,
                                ncomp, replicate, error
                            )
                        records.append(record)
                        write_records(target, records)
    write_records(target, records)


if __name__ == "__main__":
    main()
