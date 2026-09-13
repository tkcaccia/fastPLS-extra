# Current-release supplementary evidence

These scripts produce the precision and solver comparisons for a frozen
fastPLS release candidate. Results must be written outside the Git checkout by
setting `FASTPLS_RESULTS_ROOT`; every runner verifies and records the requested
package version rather than assigning a historical version to new output.

`run_precision.py` compares float32 and float64 after conversion, so conversion
time is not part of fitting or prediction. It starts process-memory monitoring
only after the prepared matrices are resident and garbage collection has run.

`run_solver_comparison.py` compares public rSVD with the CPU float64 IRLBA
companion while holding data, PLS family, component count, preprocessing, and
prediction output fixed. IRLBA remains a GPL comparison route in fastPLSextra.

The verified one-, two-, and four-thread experiment remains in
`benchmark/multicore_scaling/` and requires an OpenBLAS-linked fastPLS build.

The public `metal` backend is a fixed CPU/Metal operation split. Predictive
PLS products involving the training sample matrix execute through persistent
Metal workspaces; preprocessing, reduced decompositions, sequential PLS state,
prediction, and report assembly remain on CPU. OPLS orthogonal filtering also
remains on CPU to avoid repeated unified-memory synchronization, after which
the predictive PLS stage uses Metal. The benchmark never substitutes an
all-CPU route according to dataset shape.

`run_selected_backends.py` and `selected_backend_worker.R` provide the
four-family backend/precision audit. They use the same prepared task objects
and component contract for PLS-SVD, SIMPLS, OPLS (`north = 1`), and linear
kernel PLS. Nonlinear RBF and polynomial kernels are separate because their
quadratic Gram storage is not feasible for large-sample tasks. The companion
`summarize_family_backend_precision.py` reports medians, dispersion, execution
status, memory, and float32 metric differences from CPU float64. IKPLS rows are
attached only to SIMPLS because IKPLS is not an estimator comparator for the
other three families. All raw outputs must remain outside the Git checkout.

`run_figure1_fastpls.py` regenerates the single fastPLS row in the
independent-implementation figure using ten fresh Linux float32 CPU processes
per dataset. Component counts are read
from `figure1_component_contract.csv`; the script never selects components
from held-out responses. The contract covers classification and regression,
including the CBMC CITE-seq, PRISM, NMR, and ImageNet stress-test workloads.
The rows fit centred SIMPLS with rSVD, `oversample = 32`, `power = 5`, and
`seed = 123`. Classification uses LDA, whereas regression reports RMSD, Q2,
and MAE. The worker uses `fit = FALSE` and requests no fitted responses,
training-score matrix, variance summaries, projections, or loading matrices.
SIMPLS-LDA keeps only the compact class and score moments needed to fit the
classifier. Each worker requests one CPU core and records both `fastPLS_blas()`
and the BLAS path reported by R; the
publication run requires an OpenBLAS-linked package.
Supply the release with `--package-version`; each worker verifies the loaded
package before fitting, so the same scripts can be reused without relabelling
older evidence.

`summarize_figure1.R` reduces the fresh-process output to one row per dataset,
PLS family, and classifier, retaining timing quartiles, predictive metrics,
successful-run counts, and baseline-corrected peak host memory.

The publication Figure 1 is regenerated in four explicit stages:

```bash
# 1. Prepare one implementation-neutral task directory.
Rscript benchmark/current_release_evidence/prepare_figure1_tasks.R \
  benchmark/current_release_evidence/figure1_component_contract.csv \
  /absolute/results/figure1/tasks

# 2. Run the package-specific workers on the same host and component contract.
python3 benchmark/current_release_evidence/run_figure1_fastpls.py \
  --library /absolute/private/R/library \
  --tasks /absolute/results/figure1/tasks \
  --output /absolute/results/figure1/fastpls_raw.csv \
  --package-version 0.99.z
python3 benchmark/current_release_evidence/run_figure1_r_packages.py --help
Rscript benchmark/ikpls_cross_language/export_panel_float32.R \
  /absolute/results/figure1/tasks \
  benchmark/current_release_evidence/figure1_component_contract.csv \
  /absolute/results/figure1/python_inputs
python3 benchmark/ikpls_cross_language/run_python_pls_panel.py --help

# 3. Assemble the immutable summaries into one plotting table.
python3 benchmark/current_release_evidence/assemble_figure1_data.py --help

# 4. Render the six panels without recomputing any benchmark.
Rscript tools/build_figure1_six_panel.R \
  /absolute/results/figure1/figure1_six_panel_data.csv \
  /absolute/output/figure1.png /absolute/output/figure1.pdf
```

The two runners expose their full command-line contracts through `--help` so
that package paths, repetitions and timeouts remain explicit in the retained
manifest. Figure rendering never launches a model fit. This separation keeps
raw timings outside Git while making the component contract, aggregation and
graphics reproducible from `fastPLS-extra`.

The fastPLS runner requires `--tasks /absolute/results/figure1/tasks`. It reads
the serialized task objects produced in stage 1 rather than reconstructing
splits independently. With no `--datasets` argument it runs every non-ImageNet
row in the component contract; ImageNet uses the dedicated bounded-memory
worker described below.

The R-package runner defaults to three isolated-process repetitions. When its
first successful run exceeds 300 seconds, it retains that measured run and
records the remaining repetitions as `not_repeated_long_runtime`; failed runs
are likewise retained and not repeatedly relaunched. The summary reports the
actual successful repetition count for every method-dataset cell.

`prepare_figure1_tasks.R` creates the exact prepared tasks used by independent
implementations. `run_figure1_r_packages.py` executes the selected R workflows
in monitored fresh processes, and `summarize_figure1_r_packages.py` produces
their common summary. The IKPLS export accepts the same component contract.
`assemble_figure1_data.py` creates one implementation-neutral table, and
`tools/build_figure1_six_panel.R` renders the six-panel classification and
regression figure from that table. Raw results belong under the external
`FASTPLS_RESULTS_ROOT`, not in either source repository.

The million-sample task uses `run_figure1_imagenet_cpu.sh` with
`figure1_imagenet_cpu_worker.R`. Only fastPLS SIMPLS-LDA is attempted; known
scale-infeasible implementations remain `NE`.
`summarize_figure1_imagenet.py` attaches the GNU-time peak process RSS to each
completed row before the common table is assembled.
