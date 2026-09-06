"""Candidate-only supplementary experiments, with no comparator execution."""

from pathlib import Path


def build_supplement_stages(source, library, results, tasks, accelerator,
                            baseline, nmr=None, cross_language_inputs=None,
                            repeated_inputs=None, openblas_library=None,
                            openblas_root=None):
    stages = []
    pending = []

    def add(name, command, environment=None, timeout=172800):
        stages.append({"name": name, "command": list(map(str, command)),
                       "environment": environment or {}, "timed": True,
                       "timeout_seconds": timeout})

    # This script implements its own dense LAPACK oracle; it never invokes an
    # external PLS package or a frozen fastPLS library.
    add("simpls_exact_reference", [
        "Rscript", source / "benchmark/benchmark_simpls_exact_reference.R",
        f"--root={source}", f"--out={results / 'simpls_exact'}",
    ])
    add("controlled_scaling", [
        "bash", source / "scripts/run_controlled_scaling.sh",
        results / "controlled_scaling", "publication", f"cpu,{accelerator}", "3",
    ], {"FASTPLS_SCALING_SKIP_INSTALL": "true",
        "FASTPLS_SCALING_LIB": str(library),
        "FASTPLS_SCALING_CPU_PROFILE": "candidate_1_thread",
        "FASTPLS_SCALING_RESUME": "true"})
    add("matched_shapes", [
        "Rscript", source / "benchmark/benchmark_simpls_vs_plssvd_shapes.R",
        source, results / "matched_shapes", f"cpu,{accelerator}",
    ])
    add("simpls_ablation", [
        "Rscript", source / "benchmark/run_simpls_ablation_current.R", source,
    ], {"FASTPLS_ABLATION_OUT": str(results / "simpls_ablation"),
        "FASTPLS_ABLATION_TASK_ROOT": str(tasks),
        "FASTPLS_ABLATION_LIB": str(library)})

    if cross_language_inputs is not None:
        for dataset in ("breast", "metref", "cifar100"):
            if not (cross_language_inputs / dataset / "metadata.tsv").is_file():
                raise ValueError(f"Missing prepared cross-language inputs: {dataset}")
        add("cross_language_fastpls_only", [
            "python3", source / "benchmark/ikpls_cross_language/run_benchmark.py",
            results / "cross_language_fastpls",
        ], {"FASTPLS_IKPLS_INPUTS": str(cross_language_inputs),
            "FASTPLS_IKPLS_IMPLEMENTATIONS": "fastPLS_irlba,fastPLS_rsvd",
            "FASTPLS_BENCH_BACKEND": "cpu"})
    else:
        pending.append({"panel": "cross_language_fastpls_only",
                        "reason": "Prepared matched inputs were not supplied"})

    # Read the recorded protocol, not today's runner defaults. In particular,
    # the frozen repeated-partition panel used rSVD rather than IRLBA.
    supplied = repeated_inputs or {}
    fields = ("outer_train_fraction", "outer_seeds", "inner_kfold", "methods",
              "classifiers", "backend", "svd_method", "inner_seed", "fit_seed")
    for dataset in ("metref", "gtex_v8", "retina", "nmr"):
        path = baseline / "repeated_outer" / dataset / "repeated_outer_manifest.txt"
        if not path.is_file():
            pending.append({"panel": f"repeated_outer_{dataset}",
                            "reason": "No frozen repeated-partition manifest"})
            continue
        metadata = dict(line.split(": ", 1) for line in path.read_text().splitlines()
                        if ": " in line)
        data = Path(supplied.get(dataset, metadata["source"]))
        if not data.is_file():
            pending.append({"panel": f"repeated_outer_{dataset}",
                            "reason": f"Matched input not available: {data}"})
            continue
        if metadata["backend"] not in ("cpu", accelerator):
            pending.append({"panel": f"repeated_outer_{dataset}",
                            "reason": "Stored backend is unavailable on this host"})
            continue
        add(f"repeated_outer_{dataset}", [
            "Rscript", source / "benchmark/benchmark_repeated_outer_selection.R",
            f"--dataset={dataset}", f"--data={data.resolve()}",
            f"--out={results / 'repeated_outer' / dataset}",
            *(f"--{key}={metadata[key]}" for key in fields),
        ])

    if openblas_library is not None:
        if openblas_root is None:
            raise ValueError("An OpenBLAS prefix is required for the thread probe")
        if "frozen" in str(openblas_library).lower():
            raise ValueError("Refusing to execute a frozen multicore library")
        add("multicore_scaling", [
            "bash", source / "benchmark/multicore_scaling/run.sh",
        ], {"FASTPLS_MULTICORE_OUT": str(results / "multicore_scaling"),
            "FASTPLS_MULTICORE_LIB": str(openblas_library),
            "OPENBLAS_ROOT": str(openblas_root)})
    else:
        pending.append({"panel": "multicore_scaling",
                        "reason": "Separate current-source OpenBLAS build is required"})

    if nmr is not None:
        for family in ("plssvd", "simpls"):
            for backend, solver in (("cpu", "irlba"), ("cpu", "rsvd"),
                                    (accelerator, "rsvd")):
                for components in sorted({5 if family == "plssvd" else 50, 50, 165}):
                    name = f"nmr_float32_{family}_{backend}_{solver}_{components}"
                    command = [
                        "Rscript", source / "benchmark/benchmark_nmr_qualified_solver.R",
                        f"--input={nmr}", f"--output={results / 'nmr' / (name + '.csv')}",
                        f"--family={family}", f"--backend={backend}", f"--solver={solver}",
                        f"--ncomp={components}", "--precision=float32", "--seed=123",
                        "--replicates=3",
                    ]
                    add(name, command, timeout=10000)
                    memory_command = ["--replicates=1" if arg == "--replicates=3" else
                                      f"--output={results / 'nmr' / (name + '_memory.csv')}"
                                      if str(arg).startswith("--output=") else arg
                                      for arg in command]
                    add(name + "_memory", [
                        "python3", source / "benchmark/optimization/monitor_process.py",
                        "--output", results / "nmr" / (name + "_memory"),
                        "--timeout", "10000", "--", *memory_command,
                    ], timeout=10100)

    pending.extend([
        {"panel": "external_numerical_references",
         "reason": "Use saved predictions only; external reference fits are not authorized"},
        {"panel": "imagenet_independent_retrieval",
         "reason": "Requires matched current-score transformation and saved retrieval controls"},
    ])
    return stages, pending
