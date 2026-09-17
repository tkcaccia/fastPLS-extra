#!/usr/bin/env python3
"""Measure a candidate worker without attributing other users' GPU allocations.

The worker can emit fit_start/fit_end/predict_end CSV events via
FASTPLS_MEASUREMENT_EVENTS. Memory runs are separate from timing-only runs.
Reported increments include allocations made by the runtime after baseline;
they are not labelled isolated algorithmic workspace.
"""

import argparse
import csv
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def sample(pid):
    values = {"timestamp": time.time(), "rss_mib": None, "gpu_mib": None}
    try:
        status = Path(f"/proc/{pid}/status").read_text()
        for line in status.splitlines():
            if line.startswith("VmRSS:"):
                values["rss_mib"] = int(line.split()[1]) / 1024
    except FileNotFoundError:
        try:
            rss = subprocess.check_output(
                ["ps", "-o", "rss=", "-p", str(pid)], stderr=subprocess.DEVNULL
            )
            values["rss_mib"] = float(rss.strip()) / 1024
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
    try:
        rows = subprocess.check_output(
            ["nvidia-smi", "--query-compute-apps=pid,used_gpu_memory",
             "--format=csv,noheader,nounits"], stderr=subprocess.DEVNULL,
            timeout=2, text=True
        )
        allocations = []
        for row in csv.reader(rows.splitlines()):
            if len(row) == 2 and row[0].strip() == str(pid):
                allocations.append(float(row[1].strip()))
        values["gpu_mib"] = sum(allocations)
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("--interval", type=float, default=0.05)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a worker command is required")
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    events = output / "events.csv"
    env = dict(os.environ, FASTPLS_MEASUREMENT_EVENTS=str(events.resolve()))
    started = time.time()
    timed_out = False
    samples = []
    with (output / "worker.log").open("w") as log:
        worker = subprocess.Popen(command, env=env, stdout=log, stderr=log,
                                  start_new_session=True)
        while worker.poll() is None:
            samples.append(sample(worker.pid))
            if time.time() - started > args.timeout:
                timed_out = True
                os.killpg(worker.pid, signal.SIGTERM)
                try:
                    worker.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(worker.pid, signal.SIGKILL)
                break
            time.sleep(args.interval)
        code = worker.wait()
    with (output / "samples.csv").open("w") as handle:
        writer = csv.DictWriter(handle, fieldnames=["timestamp", "rss_mib", "gpu_mib"])
        writer.writeheader()
        writer.writerows(samples)
    measured = []
    if events.exists():
        with events.open() as handle:
            markers = list(csv.DictReader(handle))
        for start in (x for x in markers if x["event"] == "fit_start"):
            end = next((x for x in markers if x["replicate"] == start["replicate"]
                        and x["event"] == "predict_end"), None)
            if end is None:
                continue
            begin, finish = float(start["timestamp"]), float(end["timestamp"])
            before = [s for s in samples if s["timestamp"] <= begin]
            during = [s for s in samples if begin <= s["timestamp"] <= finish]
            row = {"replicate": int(start["replicate"]), "samples": len(during)}
            for kind in ("rss_mib", "gpu_mib"):
                baseline = next((s[kind] for s in reversed(before)
                                 if s[kind] is not None), None)
                if kind == "rss_mib" and start.get("rss_mib"):
                    baseline = float(start["rss_mib"])
                finite = [s[kind] for s in during if s[kind] is not None]
                peak = max(finite) if finite else None
                row["baseline_" + kind] = baseline
                row["peak_" + kind] = peak
                row["incremental_" + kind] = (
                    max(0, peak - baseline)
                    if baseline is not None and peak is not None else None
                )
            measured.append(row)
    result = {"command": command, "pid": worker.pid, "exit_code": code,
              "timed_out": timed_out, "elapsed_sec": time.time() - started,
              "interval_sec": args.interval, "measurements": measured}
    (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    raise SystemExit(code if not timed_out else 124)


if __name__ == "__main__":
    main()
