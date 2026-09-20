# Current-release supplementary evidence

These scripts produce the precision and solver comparisons for a frozen
fastPLS release candidate. Results must be written outside the Git checkout by
setting `FASTPLS_RESULTS_ROOT`; every runner verifies and records the requested
package version rather than assigning a historical version to new output.

`run_precision.py` compares float32 and float64 after conversion, so conversion
time is not part of fitting or prediction. It starts process-memory monitoring
only after the prepared matrices are resident and garbage collection has run.

The former executable IRLBA companion comparison has been removed. Any IRLBA
rows retained in publication inputs identify deposited comparison evidence;
current benchmark workers execute only supported fastPLS rSVD routes.

CPU thread-scaling experiments are part of the future software paper and now
live under `../Phase2/benchmark/multicore_scaling/`. They are not inputs to the
CMPB figures.

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

Publication Figure 2 uses float32 inputs for all 13 tasks in
`figure1_component_contract.csv`, including NMR and ImageNet. Run CPU and CUDA
within one Chiamaka campaign and CPU and Metal within one Mac campaign so every
ratio is paired on the same machine. `run_selected_backends.py` checkpoints the
aggregate CSV after each isolated worker, supports `--resume`, records explicit
timeouts, and rejects an execution route or precision that differs from the
request. After both campaigns finish, render the figure without rerunning fits:

```bash
Rscript benchmark/current_release_evidence/build_figure2_float32.R \
  /absolute/results/chiamaka/selected_backend_cuda_float32.csv \
  /absolute/results/mac/selected_backend_metal_float32.csv \
  /absolute/results/figure2
```

The CMPB renderer creates main-text Figure 2 with Linux CPU/CUDA ratios. Metal
experiments are retained under `Phase2/` for the future software paper. Runtime
is CPU/CUDA, whereas memory is CUDA/CPU baseline-corrected host RSS. CUDA
device-memory peaks remain in the detailed summary table.

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
classifier. Each worker requests one CPU core and records the detailed
`fastPLS_blas()` report and the BLAS path reported by R; the
publication run requires an OpenBLAS-linked package.
The complete campaign accepts an explicit `OPENBLAS_ROOT` and validates the
loaded OpenBLAS version and CPU kernel before installation. CMPB runs on the
Intel workstation require OpenBLAS 0.3.29 with the Haswell kernel; the exact
configuration and resolved shared-library path are written to
`openblas_configuration.txt`. This prevents an older distribution library
from being reported under a newer hard-coded version label.

OpenBLAS builds are not interchangeable benchmark conditions. In particular,
`fastPLS_blas()` now reports the library family, version, and selected
dynamic-architecture kernel. The campaign additionally validates those fields
before installation. A Chiamaka campaign
that linked OpenBLAS 0.3.20 and selected the Prescott kernel must not be labelled
as, or pooled with, the verified OpenBLAS 0.3.29/Haswell campaign.

After an already-running campaign has finished, rerun the fastPLS timing stages
in a new external results directory. Do not stop or overwrite the original
campaign. The timing-only scope installs one newly frozen source archive,
verifies the OpenBLAS library before fitting, prepares the common inputs, and
reruns the fastPLS rows used by Figures 1--4 and the timing-bearing
supplementary paths. If the package source changed after the earlier campaign,
build a new archive and record its new commit and checksum rather than
relabelling the earlier archive:

```bash
PACKAGE_ARCHIVE=/absolute/path/fastPLS_0.3.tar.gz \
CAMPAIGN_ROOT=/absolute/results/campaign_openblas_0.3.29_haswell \
SEED_TASK_ROOT=/absolute/tasks \
NMR_INPUT=/absolute/data/NMR.RData \
IMAGENET_TASK_RDS=/absolute/data/imagenet_task.rds \
OPENBLAS_ROOT=/home/chiamaka/fastPLS_openblas_0.3.29/root \
EXPECTED_OPENBLAS_VERSION=0.3.29 \
EXPECTED_OPENBLAS_CORE=Haswell \
CAMPAIGN_SCOPE=fastpls-timing \
BENCHMARK_HOST_ID=chiamaka \
SOURCE_ID=FULL_GIT_COMMIT \
bash scripts/run_cmpb_release_campaign.sh
```

The command requires the same remaining campaign variables as the full run,
including the archive checksum and deposited NMR comparator location. Its
`stage_status.tsv`, `openblas_configuration.txt`, installation log, and result
rows form a separate evidence set. Only after every required stage succeeds
should the manuscript timing summaries and graphics be regenerated from this
verified set.
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

The R-package runner requests up to three isolated-process repetitions for
every planned method-dataset cell. Each attempted repetition has its own
1,800-second timeout and memory guard. If the first attempt fails or reaches a
resource limit, repetitions two and three are not launched; explicit linked
rows retain those planned positions in the output grid. Completed, failed,
resource-limited and timed-out attempts are retained, and the summary reports
the requested, attempted and successful repetition counts for every
method-dataset cell.

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

## CUDA software comparison

`run_cuda_ikpls_comparison.py` compares the release fastPLS CUDA workflow with
IKPLS algorithm 2 through JAX/CUDA. It consumes the same float32 prepared splits
and SIMPLS component counts as Figure 1. Classification uses fastPLS
SIMPLS-LDA and the native IKPLS regression-score argmax; regression uses the
native multivariate response of each implementation. The comparison is an
end-to-end software comparison, not an estimator-matched comparison.

Both cold and warm fitting-plus-prediction times are retained. Cold times include
CUDA context or JAX compilation where incurred, host-to-device transfer,
synchronization, and result transfer. Warm times repeat the public workflow in
the initialized process. `nvidia-smi` is polled by process to record peak device
memory, and host RSS is recorded separately. Resource failures are output rows
rather than omitted cells.

Use `assemble_cuda_ikpls_summary.py` to combine disjoint standard, NMR, and
ImageNet runs, then create the publication figure with
`tools/build_supplement_cuda_ikpls_figure.R`. Raw rows and logs remain in the
local results archive and are not committed to this repository.
