# Current-code optimization validation

These tools execute only current fastPLS candidates. Stored frozen fastPLS,
IKPLS, and external-package tables are read-only comparisons, not executable
baselines. The full scope and live snapshot names are in `../OPTIMIZATION_PLAN.md`.

The reusable source-package check and installed-test runners now live in
`fastPLS-extra/tools/check_release_candidate.py` and
`fastPLS-extra/tools/run_candidate_tests.R`. Benchmark validators locate them
in a sibling `fastPLS-extra` checkout, or at `FASTPLS_EXTRA_ROOT` when the
repositories are stored elsewhere. A missing companion tool gives an explicit
error. This developer-tool requirement is not a fastPLS package dependency.

## Publication runs

`run_publication_candidate.py` creates a source/library fingerprint and execution
plan, checks dependencies and the requested accelerator, and runs isolated
candidate stages. Each stage has a log and a process/status record. CUDA timing
waits for an idle device. Do not modify a source or library used by a live queue.

`compare_candidate.py` joins new rows to stored rows using protocol keys. It
retains failures, missing rows, and ambiguous matches; known cross-host timings
are not converted into speedup ratios. A successful runner exit is not proof
that every requested scientific measurement succeeded.

## Numerical replay without refitting references

`replay_simpls.R` and `replay_opls_kernel.R` load only named data/preprocessing
helpers and setting declarations from existing benchmark scripts. They never
source the external-estimator loops. They retain new endpoint and fold metrics,
component selections, and errors. Their timing fields are descriptive correctness
measurements, not isolated publication timings.

`compare_replays.py` compares these new measurements with stored metric and
component tables. SIMPLS CV curves require all five finite, successful folds.
The comparator does not infer coefficient, prediction-vector, or subspace
agreement from matching aggregate metrics. Those require saved reference vectors
or the separately scheduled dense-LAPACK mathematical oracle.

The completed September 5 replay outputs are `opls_kernel_replay_v2` and
`simpls_replay_v3`, beneath `benchmark_results/optimization_20260904`. Earlier
setup/collector failures are retained separately and must not be counted as
package failures or successful validation.

## Isolated Metal experiment

`check_metal_host_workspace.R` compares product and model outputs between two
current-code builds. `validate_metal_host_workspace.py` installs the isolated
candidate, runs before/after comparisons and the full test suite, and compares
repeated CV outputs. It does not replace the live publication library.

`run_at_queue_boundary.py` can temporarily pause our queue dispatcher while
allowing its current worker to finish. It then runs an isolated check and resumes
the dispatcher in a `finally` block. Live process inspection, not a status file
alone, determines whether the worker has finished. Do not kill the guard without
checking that the dispatcher has resumed.

## Prediction-only comparisons

`check_cpu_flash_weights.R` fits only the first current candidate, saves its
latent factors, and loads those identical factors for subsequent prediction
comparisons. It reports repeated blocked-prediction times and full prediction
and projected-score agreement. These measurements exclude fitting and do not
stand in for the publication's whole-workflow or frozen-result comparisons.
`validate_cpu_prediction_prefix.py --validation-only` separately checks the
installed candidate and CPU/Metal CV results.

`validate_cpu_flash_memory.py` uses independent current-code workers for
prediction-only memory measurements. It reports sampled complete-process RSS,
the pre-prediction baseline, and their difference. Runtime sampling, allocator
retention and R outputs are included; these are not isolated workspace bytes.
The input and theoretical response-weight sizes are saved separately.

## NMR selected endpoints

`run_nmr_selected_endpoints.py` reads each family's completed training-only
selection, checks its one-standard-error decision against the validation curve,
and schedules CPU IRLBA, CPU rSVD and accelerator rSVD at that selected count.
Both float64 and float32 have timing and separate memory workers. Incomplete
selection fails explicitly rather than substituting an older component count.
The publication runner keeps these predictive endpoints separate from the
fixed-count workload comparisons. It does not change the public CV procedure.

## Tool checks

```sh
python3 -m unittest discover -s benchmark/optimization -p 'test_*.py'
Rscript benchmark/optimization/check_replay_helpers.R
```

These are orchestration checks, not substitutes for the package tests, complete
benchmark measurements, precision checks, or frozen-result comparisons.
