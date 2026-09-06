#!/usr/bin/env python3
"""Run current fastPLS only; frozen results are read-only comparison inputs."""

import argparse
import csv
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time

from supplement_stages import build_supplement_stages


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def identity(source, library):
    files = {}
    for directory in ("R", "src", "inst/include", "benchmark", "scripts"):
        for path in sorted((source / directory).rglob("*")):
            if path.is_file() and path.suffix in (
                ".R", ".py", ".sh", ".cpp", ".h", ".hpp", ".c", ".in"
            ):
                files[str(path.relative_to(source))] = digest(path)
    for name in ("DESCRIPTION", "NAMESPACE", "configure", "configure.win"):
        files[name] = digest(source / name)
    installed = {}
    for directory in ("R", "libs"):
        for path in sorted((library / "fastPLS" / directory).rglob("*")):
            if path.is_file():
                installed[str(path.relative_to(library))] = digest(path)
    if not installed:
        raise RuntimeError("No installed candidate library found")
    return {"source": files, "installed": installed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--tasks", required=True, type=Path)
    parser.add_argument("--accelerator", required=True, choices=("cuda", "metal"))
    parser.add_argument("--nmr", type=Path)
    parser.add_argument("--imagenet", type=Path)
    parser.add_argument("--wait-pid", type=int)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--stages", help="Optional comma-separated stage selection")
    parser.add_argument("--include-supplement", action="store_true")
    parser.add_argument("--cross-language-inputs", type=Path)
    parser.add_argument("--repeated-input", action="append", default=[],
                        help="Matched repeated-partition input as DATASET=PATH")
    parser.add_argument("--openblas-library", type=Path)
    parser.add_argument("--openblas-root", type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    library = args.library.resolve(strict=True)
    baseline = args.baseline.resolve(strict=True)
    tasks = args.tasks.resolve(strict=True)
    results = args.results.resolve()
    if results == baseline or baseline in results.parents:
        raise RuntimeError("Candidate results must not overwrite the frozen baseline")
    if "frozen" in str(library).lower():
        raise RuntimeError("Refusing to execute a frozen library")
    fingerprint = identity(source, library)
    openblas_library = args.openblas_library.resolve(strict=True) if args.openblas_library else None
    openblas_identity = identity(source, openblas_library) if openblas_library else None
    selected = baseline / "component_selection/selected_components.csv"
    if not selected.is_file():
        selected = baseline / "component_selection/component_selection_summary.csv"
    if not selected.is_file():
        raise RuntimeError(f"Missing frozen selection table: {selected}")
    with selected.open() as handle:
        selections = list(csv.DictReader(handle))
    keys = {(row["dataset"], row["family"]) for row in selections}
    if len(selections) != 44 or len(keys) != 44 or any(
        int(row["selected_ncomp"]) < 1 or row.get("status", "success") != "success"
        for row in selections
    ):
        raise RuntimeError("Frozen selection table is incomplete or has failed rows")
    metadata = {
        "identity": fingerprint, "source_root": str(source),
        "library": str(library), "baseline_read_only": str(baseline),
        "task_root": str(tasks), "accelerator": args.accelerator,
        "host": platform.node(), "platform": platform.platform(),
        "thread_request": 1, "comparator_execution": "fastPLS candidate only",
        "frozen_selection_sha256": digest(selected),
        "openblas_library": str(openblas_library) if openblas_library else None,
        "openblas_identity": openblas_identity,
        "supplement_requested": args.include_supplement,
        "cross_language_inputs": str(args.cross_language_inputs.resolve())
        if args.cross_language_inputs else None,
        "repeated_inputs": sorted(args.repeated_input),
        "nmr_input": str(args.nmr.resolve()) if args.nmr else None,
        "imagenet_input": str(args.imagenet.resolve()) if args.imagenet else None,
    }
    manifest = results / "candidate_manifest.json"
    if manifest.exists():
        if json.loads(manifest.read_text()) != metadata:
            raise RuntimeError("Source, library, host, or protocol changed; use a new results directory")
    else:
        if results.exists() and any(results.iterdir()):
            raise RuntimeError("Existing results have no candidate identity; refusing to adopt them")
        results.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps(metadata, indent=2) + "\n")
    logs = results / "queue_logs"
    logs.mkdir(exist_ok=True)
    lock = (results / "queue.lock").open("a")
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    dependency_paths = subprocess.check_output([
        "Rscript", "-e", "cat(paste(.libPaths(), collapse=.Platform$path.sep))"
    ], text=True).strip()
    library_paths = os.pathsep.join(dict.fromkeys([str(library), *dependency_paths.split(os.pathsep)]))
    env = dict(os.environ)
    env.update({
        "FASTPLS_BENCH_LIB": str(library), "FASTPLS_LIB": str(library),
        "R_LIBS_USER": library_paths, "R_LIBS": library_paths,
        "R_PROFILE_USER": os.devnull, "R_ENVIRON_USER": os.devnull,
        "FASTPLS_SELECTED_COMPONENTS_CSV": str(selected),
        "FASTPLS_COMPONENT_TASK_ROOT": str(tasks),
        "FASTPLS_METAL_MATCHED_TASK_ROOT": str(tasks),
        "FASTPLS_COMPONENT_ACCELERATOR": args.accelerator,
        "FASTPLS_MATCHED_ACCELERATOR": args.accelerator,
        "FASTPLS_CV_TASK_ROOT": str(tasks),
        "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1",
        "MKL_NUM_THREADS": "1", "BLIS_NUM_THREADS": "1",
        "VECLIB_MAXIMUM_THREADS": "1",
    })
    preflight = subprocess.run([
        "Rscript", "-e",
        '.libPaths(unique(c(Sys.getenv("FASTPLS_BENCH_LIB"), .libPaths()))); '
        'library(fastPLS); stopifnot(requireNamespace("float", quietly=TRUE)); '
        'stopifnot(normalizePath(find.package("fastPLS")) == '
        'normalizePath(file.path(Sys.getenv("FASTPLS_BENCH_LIB"), "fastPLS"))); '
        f'stopifnot(isTRUE(has_{args.accelerator}())); '
        'print(.libPaths()); print(sessionInfo())',
    ], env=env, text=True, capture_output=True)
    (logs / "preflight.log").write_text(preflight.stdout + preflight.stderr)
    if preflight.returncode:
        raise RuntimeError("Candidate/dependency/backend preflight failed; see preflight.log")
    stages = []

    def add(name, command, extra=None, timed=True, timeout=172800):
        stages.append({"name": name, "command": list(map(str, command)),
                       "environment": extra or {}, "timed": timed,
                       "timeout_seconds": timeout})

    def r(name, script, arguments, extra=None, timed=True):
        add(name, ["Rscript", source / script, *arguments], extra, timed)

    r("component_selection", "benchmark/run_current_component_selection.R",
      [results / "component_selection"], timed=False)
    for backend in ("cpu", args.accelerator):
        r(f"float32_{backend}", "benchmark/benchmark_float32_backend_agreement.R",
          [f"--backend={backend}", f"--out={results / ('float32_' + backend)}", "--seed=123"])
    r("selected_backend", "benchmark/metal_validation/run_matched_cuda_dataset_metal.R",
      [results / "selected_backend"])
    add("cv_compiled_vs_r_loop", ["bash", source / "scripts/run_cv_compiled_vs_r_loop.sh"], {
        "FASTPLS_CV_BACKENDS": f"cpu,{args.accelerator}",
        "FASTPLS_CV_REPETITIONS": "3",
        "FASTPLS_CV_COMPARATOR_OUT": str(results / "cv_compiled_vs_r_loop"),
    })
    if args.accelerator == "cuda":
        add("external_simpls_fastpls_only", ["bash", source / "scripts/run_external_simpls_timing.sh"], {
            "FASTPLS_EXTERNAL_TIMING_IMPLEMENTATIONS": "fastpls",
            "FASTPLS_EXTERNAL_TIMING_RESULTS_DIR": str(results / "external_simpls"),
        })
        add("package_panel_fastpls_only", ["bash", source / "scripts/remote_run_pls_package_comparison.sh"], {
            "FASTPLS_PKG_COMPARE_METHODS": "fastPLS_simpls_cpu_irlba,fastPLS_simpls_cpu_irlba_lda",
            "FASTPLS_PKG_COMPARE_RESULTS_DIR": str(results / "r_package_panel"),
        })
    if args.nmr:
        for family in ("plssvd", "simpls"):
            r(f"nmr_selection_{family}", "benchmark/benchmark_nmr_component_selection.R", [
                f"--input={args.nmr.resolve(strict=True)}",
                f"--out={results / 'nmr' / ('selection_' + family)}",
                f"--backend={args.accelerator}", f"--method={family}",
                "--grid=1,2,3,5,10,25,50,75,100,125,150,165,175,200,250,300",
                "--seeds=123,456,789,1011,2027", "--fit_seed=123",
            ])
            for backend, solver in (("cpu", "irlba"), ("cpu", "rsvd"), (args.accelerator, "rsvd")):
                for components in sorted(set((5 if family == "plssvd" else 50, 50, 165))):
                    name = f"nmr_{family}_{backend}_{solver}_{components}"
                    r(name, "benchmark/benchmark_nmr_qualified_solver.R", [
                        f"--input={args.nmr.resolve()}", f"--output={results / 'nmr' / (name + '.csv')}",
                        f"--prediction_output={results / 'nmr' / (name + '_prediction.rds')}",
                        f"--family={family}", f"--backend={backend}", f"--solver={solver}",
                        f"--ncomp={components}", "--seed=123", "--replicates=3",
                    ])
                    stages[-1]["timeout_seconds"] = 10000
                    command = list(stages[-1]["command"])
                    command = [arg for arg in command if not arg.startswith("--prediction_output=")]
                    command = ["--replicates=1" if arg == "--replicates=3" else arg for arg in command]
                    command = [f"--output={results / 'nmr' / (name + '_memory.csv')}"
                               if arg.startswith("--output=") else arg for arg in command]
                    add(name + "_memory", [
                        "python3", source / "benchmark/optimization/monitor_process.py",
                        "--output", results / "nmr" / (name + "_memory"),
                        "--timeout", "10000", "--", *command,
                    ], timeout=10100)
        add("nmr_selected_endpoints", [
            "python3", source / "benchmark/optimization/run_nmr_selected_endpoints.py",
            "--source", source, "--library", library,
            "--selections", results / "nmr", "--input", args.nmr.resolve(),
            "--out", results / "nmr_selected_endpoints", "--accelerator", args.accelerator,
        ])
    r("component_paths", "benchmark/run_current_component_path.R",
      [results / "component_paths"], {"FASTPLS_COMPONENT_REPLICATES": "5"})
    if args.imagenet:
        if args.accelerator != "cuda":
            raise RuntimeError("This ImageNet runner requires native CUDA")
        add("imagenet", ["bash", source / "scripts/run_imagenet_current_fused_lda_remote.sh"], {
            "REPO_ROOT": str(source), "TASK_RDS": str(args.imagenet.resolve(strict=True)),
            "OUTPUT_DIR": str(results / "imagenet"), "CLASSIFIERS": "argmax lda",
            "NCOMP_GRID": "100 200 300 400 500 600 700 800 900 1000", "PRECISION": "float32",
        })
    if args.include_supplement:
        repeated_inputs = {}
        for entry in args.repeated_input:
            dataset, path = entry.split("=", 1)
            if dataset in repeated_inputs:
                raise ValueError(f"Duplicate repeated-partition input: {dataset}")
            repeated_inputs[dataset] = str(Path(path).resolve(strict=True))
        supplementary, pending = build_supplement_stages(
            source, library, results, tasks, args.accelerator, baseline,
            nmr=args.nmr.resolve(strict=True) if args.nmr else None,
            cross_language_inputs=args.cross_language_inputs.resolve(strict=True)
            if args.cross_language_inputs else None,
            repeated_inputs=repeated_inputs, openblas_library=openblas_library,
            openblas_root=args.openblas_root.resolve(strict=True) if args.openblas_root else None,
        )
        stages.extend(supplementary)
        (results / "pending_panels.json").write_text(json.dumps(pending, indent=2) + "\n")
    (results / "execution_plan.json").write_text(json.dumps(stages, indent=2) + "\n")
    if args.prepare_only:
        print(f"Prepared {len(stages)} candidate-only stages in {results}")
        return
    requested = set(args.stages.split(",")) if args.stages else {s["name"] for s in stages}
    if requested - {s["name"] for s in stages}:
        raise RuntimeError("Unknown stage requested")
    for stage in stages:
        name = stage["name"]
        if name not in requested:
            continue
        status_path = logs / (name + ".json")
        if status_path.exists() and json.loads(status_path.read_text()).get("exit_code") == 0:
            print(f"[EXISTING CANDIDATE] {name}", flush=True)
            continue
        if stage["timed"]:
            while True:
                busy = []
                if args.wait_pid and Path(f"/proc/{args.wait_pid}").exists():
                    busy.append(f"protected process {args.wait_pid}")
                if args.accelerator == "cuda":
                    check = subprocess.run([
                        "nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader"
                    ], capture_output=True, text=True, timeout=30, check=True)
                    busy.extend(check.stdout.strip().splitlines())
                if not busy:
                    break
                print(f"[WAIT] {name}: {'; '.join(busy)}", flush=True)
                time.sleep(60)
        if identity(source, library) != fingerprint:
            raise RuntimeError("Candidate files changed while the queue was running")
        if openblas_library and identity(source, openblas_library) != openblas_identity:
            raise RuntimeError("Multicore candidate files changed while the queue was running")
        started = time.time()
        print(f"[RUN] {name} {time.ctime(started)}", flush=True)
        stage_env = dict(env, **stage["environment"])
        with (logs / (name + ".log")).open("w") as log:
            process = subprocess.Popen(stage["command"], cwd=source, env=stage_env,
                                       stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            status_path.write_text(json.dumps({"name": name, "pid": process.pid,
                                               "started": started, "status": "running"}) + "\n")
            try:
                code = process.wait(timeout=stage["timeout_seconds"])
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 124
        status_path.write_text(json.dumps({
            "name": name, "exit_code": code, "started": started,
            "finished": time.time(), "command": stage["command"],
            "scope": "runner exit status; scientific row validation is separate",
        }, indent=2) + "\n")
        print(f"[FINISHED] {name} exit={code}", flush=True)
    print("Queue finished; inspect row completeness and compare frozen tables separately.", flush=True)


if __name__ == "__main__":
    main()
