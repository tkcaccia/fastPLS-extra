#!/usr/bin/env python3
import argparse
import csv
import ctypes
from pathlib import Path
import platform
import subprocess
import time



def rss_mib(pid):
    """Return resident memory for one worker without third-party modules."""
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


def measured(command, output, ready, go):
    process = subprocess.Popen(command)
    deadline = time.time() + 180
    while not ready.exists() and process.poll() is None:
        if time.time() > deadline:
            process.kill()
            raise RuntimeError("solver worker did not reach the measurement boundary")
        time.sleep(0.01)
    if process.poll() is not None:
        raise RuntimeError("solver worker failed before fitting")
    baseline = float(ready.read_text().strip())
    peak = baseline
    go.touch()
    while process.poll() is None:
        peak = max(peak, rss_mib(process.pid))
        time.sleep(0.005)
    if process.returncode:
        raise RuntimeError(f"solver worker failed: {process.returncode}")
    with output.open(newline="") as stream:
        row = next(csv.DictReader(stream))
    row["peak_rss_mib"] = f"{peak:.9f}"
    row["incremental_peak_rss_mib"] = f"{max(0.0, peak-baseline):.9f}"
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--repetitions", type=int, default=5)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    target = Path(args.output).resolve()
    work = target.parent / (target.stem + "_workers")
    work.mkdir(parents=True, exist_ok=True)
    rows = []
    for shape in ("balanced", "predictor_wide", "response_wide"):
        for family in ("simpls", "plssvd"):
            for solver in ("rsvd", "irlba"):
                for replicate in range(1, args.repetitions + 1):
                    stem = f"{shape}_{family}_{solver}_r{replicate}"
                    output = work / f"{stem}.csv"
                    ready = work / f"{stem}.ready"
                    go = work / f"{stem}.go"
                    for path in (output, ready, go):
                        if path.exists():
                            path.unlink()
                    command = [
                        "Rscript", str(root / "solver_worker.R"), args.library,
                        shape, family, solver, str(replicate), str(output),
                        str(ready), str(go)
                    ]
                    rows.append(measured(command, output, ready, go))
    fields = list(rows[0])
    with target.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
