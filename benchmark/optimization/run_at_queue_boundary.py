#!/usr/bin/env python3
"""Run an isolated candidate check between stages of our own live queue."""

import argparse
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import time


def process(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat=", "-o", "command="],
                            text=True, capture_output=True)
    parts = result.stdout.strip().split(maxsplit=1)
    return tuple(parts) if len(parts) == 2 else None


def alive(state):
    return state is not None and not state[0].startswith("Z")


def children_from_listing(text, parent):
    children = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 3 and int(fields[1]) == parent and not fields[2].startswith("Z"):
            children.append(int(fields[0]))
    return children


def matches_r_dispatcher(command, expected):
    if not expected or Path(expected[0]).name != "Rscript" or len(expected) < 2:
        return False
    tokens = shlex.split(command)
    if not tokens or Path(tokens[0]).name not in ("R", "Rscript"):
        return False
    if Path(tokens[0]).name == "Rscript":
        return tokens[1:] == expected[1:]
    if "--file=" + expected[1] not in tokens or "--args" not in tokens:
        return False
    return tokens[tokens.index("--args") + 1:] == expected[2:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--queue", required=True, type=Path)
    parser.add_argument("--shell-stage", help="Pause an identified shell worker dispatcher instead of the queue")
    parser.add_argument("--r-stage", help="Pause an identified R worker dispatcher between its child processes")
    parser.add_argument("--wait-seconds", type=int, default=14400)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.r_stage and args.shell_stage:
        raise ValueError("Choose one worker-dispatcher type")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise ValueError("A check command is required")
    queue = args.queue.resolve(strict=True)
    identity = process(args.pid)
    child_stage = args.shell_stage or args.r_stage
    if child_stage:
        plan = json.loads((queue / "execution_plan.json").read_text())
        stages = [item for item in plan if item["name"] == child_stage]
        record = json.loads((queue / "queue_logs" / (child_stage + ".json")).read_text())
        parent = int(subprocess.check_output(["ps", "-p", str(args.pid), "-o", "ppid="], text=True).strip())
        parent_identity = process(parent)
        matches = len(stages) == 1 and alive(identity) and (
            matches_r_dispatcher(identity[1], stages[0]["command"]) if args.r_stage else
            stages[0]["command"][0] == "bash" and identity[1] == " ".join(stages[0]["command"]))
        if (not matches or
                record.get("pid") != args.pid or record.get("status") != "running" or
                not alive(parent_identity) or "run_publication_candidate.py" not in parent_identity[1] or
                str(queue) not in parent_identity[1]):
            raise RuntimeError("PID does not identify the requested shell stage in our live queue")
    elif not alive(identity) or "run_publication_candidate.py" not in identity[1] or str(queue) not in identity[1]:
        raise RuntimeError("PID does not identify the requested live candidate queue")
    if "T" in identity[0]:
        raise RuntimeError("Queue is already paused; do not override another guard")

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    stopped = False
    try:
        os.kill(args.pid, signal.SIGSTOP)
        stopped = True
        start = time.monotonic()
        while True:
            if not alive(process(args.pid)):
                raise RuntimeError("Queue exited while waiting for its stage")
            pending = []
            if not child_stage:
                for path in (queue / "queue_logs").glob("*.json"):
                    item = json.loads(path.read_text())
                    if item.get("status") == "running" and item.get("pid"):
                        state = process(item["pid"])
                        if alive(state):
                            pending.append((path.stem, item["pid"]))
            # Dispatch can be paused between spawning a worker and writing its
            # status file. Inspect live children as well as the recorded handles.
            listing = subprocess.check_output(["ps", "ax", "-o", "pid=,ppid=,stat="], text=True)
            recorded = {pid for _, pid in pending}
            pending.extend(("unrecorded child", pid) for pid in
                           children_from_listing(listing, args.pid) if pid not in recorded)
            if not pending:
                break
            if time.monotonic() - start > args.wait_seconds:
                raise TimeoutError("Current stage still active; isolated check not run")
            print("Waiting for the existing stage, without interrupting it:", pending, flush=True)
            time.sleep(30)
        print("Stage finished. Starting isolated check:", command, flush=True)
        result = subprocess.run(command, timeout=2400)
        if result.returncode:
            raise RuntimeError(f"Isolated check exited with {result.returncode}")
    finally:
        if stopped:
            try:
                current = process(args.pid)
                if current and current[1] == identity[1]:
                    os.kill(args.pid, signal.SIGCONT)
                    print("Own queue dispatch resumed", flush=True)
            except ProcessLookupError:
                pass


if __name__ == "__main__":
    main()
