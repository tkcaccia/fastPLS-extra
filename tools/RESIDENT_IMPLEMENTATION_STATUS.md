# Resident CUDA implementation work

## Isolated installation in progress

The current source was built successfully with `R CMD build --no-build-vignettes
--no-manual` as `/tmp/fastpls-resident-package-check/fastPLS_0.99.39.tar.gz`.
The archive contains the resident R adapter, CUDA metrics helper and
`test-cuda-resident-public.R`. It was transferred to
`/home/chiamaka/fastPLS_resident_20260905/fastPLS_0.99.39.tar.gz` and installation
started into the separate `library` directory there with CUDA_ROOT pointing to
CUDA 13.0. Installation log: `install.log` in the same parent directory.
The rebuilt archive was installed successfully. R initially loaded the existing
user-library package because that library preceded the isolated path; after the
test explicitly prepended the isolated library, `find.package()` identified the
correct installation and the installed dispatcher contained the resident route.
The installed-package test completed 114 assertions with no failures. Existing
user libraries were not replaced.

The resident SIMPLS route now mirrors the accelerated refresh policy without a
warm start. Eligible large classification shapes use up to eight candidate
directions generated from one fresh randomized block at each refresh. Cross-
covariance objects above 512 MiB use a fresh rank-one randomized solve with zero
oversampling and one power iteration internally; requested and effective controls
are recorded separately. Other routes refresh one direction per component.
The synthetic block-route test used n=8,192, p=1,024, 64 classes and eight
components. It activated an eight-direction block and completed in both float32
and float64 with valid predictions. NMR accuracy and speed for the massive route
remain to be measured with the installed package under an uncontended GPU.

## Public-source CUDA integration (2026-09-05)

Public `pls()` dispatch now selects the resident core for CUDA SIMPLS and
PLS-SVD, in float32 and float64. Resident `predict()` uses device state and
rejects explicitly requested CPU prediction rather than falling back. OPLS,
kernel PLS and Metal integration remain separate unfinished work.

Added GPU response SSE, training-mean SST and observed-mean SST reductions,
including label-only dummy responses, and direct GPU score projection.
The internal R regression tests compare these quantities with independent R
calculations in all tested prefixes, tasks, families and precisions.

`test_resident_public.R` sources the current public R functions into an isolated
environment and links the actual package CUDA compilation unit. All 12
family/precision/task combinations completed, covering regression, argmax and
LDA; fitted values, test predictions, R2/Q2, loadings, variance, score projection,
top-k labels and explicit CPU-override rejection were checked. Six expected
warnings reported existing float64 CUDA safety-floor adjustment of the requested
oversample=10/power=2 to oversample=32/power=5. These are source integration
tests, not yet an installed-package test or benchmark qualification.

Final R output assembly, class-index labelling and general `evaluate()` summaries
remain host reporting steps. Model matrix operations and response sums of
squares in this resident route are device operations. Public permutation testing
is not yet integrated and produces an explicit error. Top-k score-value export,
large-data tiling, and complete installed-package validation remain pending.

## Resident loadings and predictor variance (2026-09-05)

Added `cuda_resident_variance.cuh`: device cross-products, predictor loadings,
and sequential predictor sums of squares without an n-by-p residual copy.
Both scalar types retain their precision throughout. The sequential recurrence
uses the score Gram matrix and previous residual loadings. This reproduces
sequential projection algebra; floating-point results need not equal the R
orthogonality-shortcut path bit for bit.

`test_resident_variance.cu` was compiled using CUDA 13.0 and run on the authorized
CUDA workstation. Four cases (float32/float64, with/without a zero score column)
met thresholds against an explicit-residual host oracle. Maximum scaled errors
were 4.74243e-5 and 8.3495e-14, respectively; thresholds were 2e-4 and 1e-11.
These are isolated helper tests, not public API or real-dataset validation.
The helper is now connected to C ABI export fields 6 (P) and 7 (predictor
sums of squares), with lazy allocation and caching in the resident model.
The internal R wrapper exposes optional `loadings` and `variance` exports;
these are not new public `pls()` parameters. Public fit finalization remains
to be connected.

The actual package CUDA compilation unit was rebuilt and the complete internal
R-wrapper test suite rerun. All eight method/task/precision combinations met
the optional-output thresholds against independent R sequential projections.
Maximum scaled optional-output errors were 2.401117e-7 (float32) and
6.142798e-16 (float64). Prediction, LDA and top-k regression tests also completed
successfully. This still does not constitute installed public `pls()` testing.

## Validated on 2026-09-05

The isolated `test_resident_preprocess.cu` executable was compiled with
`nvcc -std=c++17 -O2 -I. test_resident_preprocess.cu -o test_preprocess`
and run on the NVIDIA GeForce RTX 5060 Ti workstation.

All 24 cases met tolerance: float32/float64, n = 1, 17, 257, 5000,
and scaling modes 1 (center), 2 (center/sample-SD scale), 3 (unchanged).
Each case includes a constant column. Maximum absolute error against
the host test oracle was 4.76837158e-7 for float32 and 6.66133815e-16
for float64. Test tolerances were 2e-5 and 1e-12, respectively.

Statistics and transformation use device arrays on an explicit CUDA stream.
The float32 kernel does not widen accumulators to double. Host copies in
the test are input upload and final verification only.

Remote isolated test directory:
`/home/chiamaka/fastPLS_resident_20260905/preprocess_test`.

## Device class products

`test_resident_labels.cu` was compiled and executed using
`/usr/local/cuda-13.0/bin/nvcc -std=c++17 -O2 -I.` on the same GPU.
All 36 cases met tolerance: two precisions, three sample sizes
(17, 257, 5000), one or 13 predictor columns, and valid, invalid-label,
or empty-class cases. Valid cases used seven imbalanced classes.
All kernels and sorting were submitted to a nonblocking CUDA stream.
Maximum absolute product error was 1.1920929e-7 (float32) and
2.22044605e-16 (float64); thresholds were 2e-4 and 1e-11.
Invalid labels and empty classes were detected through a device status flag.

The implementation builds reusable sorted class membership on the device,
then computes class sums and centered dummy-response cross-products without
allocating dense one-hot responses. The same primitive supports score-response
products with p=1. Float32 accumulation remains float32. Thrust's sorting
scratch allocation is not yet retained in a persistent fitting workspace.

The default `/usr/bin/nvcc` is CUDA 11.5 and failed to compile the Thrust
headers with the host standard-library headers. CUDA 13 compiled and ran
the tests successfully. The package build must resolve the intended toolkit
rather than assume the shell's default nvcc is suitable.

## Resident SIMPLS component workspace

`cuda_resident_component.cuh` supplies a shared float32/float64 component
workspace with reusable cuBLAS handles and scratch buffers. Score formation,
conditional direction/score reorthogonalization, coupled prediction-weight
correction, normalization, response loadings, loading orthogonalization and
cross-covariance deflation operate on device arrays. Scalar norm decisions
are CUDA kernels; there are no component-wise host scalar copies.

The isolated CUDA 13 `test_resident_component.cu` executable compares identical
candidate directions against an independent CPU loop. All 16 endpoint tests
met the stated thresholds for regression and classification, n=17/257,
p=7/23, q=3 and four components, in both precisions. The classification path
uses device class membership and is compared against a dense centered
dummy-response oracle. Compared objects are R, scores, V, Q and deflated S.
Maximum scaled errors were 1.33946604e-5 (float32) and 3.17801341e-14
(float64), with thresholds 2e-4 and 1e-11. Scaling divides maximum absolute
error by max(1, maximum absolute oracle entry), separately for each object.

These tests isolate component execution, not rSVD candidate quality or complete
public API behavior. The reusable workspace is not yet dispatched publicly.

## Resident rSVD and integrated core

The CUDA 13 `test_resident_rsvd.cu` executable completed 16 cases across
float32/float64, seeds 7/11, and tall, wide, truncated and single-response
matrices. GPU cuRAND generates sketches, cuBLAS performs power products,
and cuSOLVER performs QR and the tall reduced SVD. The workspace is reused
and no reduced matrix is sent to a CPU decomposition. Tests cover singular
values, U/V orthogonality, reconstruction residual versus the known best-rank
residual, and exact repeat-seed replay. All met thresholds (2e-5 float32,
1e-9 float64); this is a limited constructed-spectrum test panel.

The connected `ResidentSimpls` core in `cuda_resident_simpls.cuh` combines
device preprocessing, regression or label-aware cross-products, resident
rSVD and component execution. Test prediction standardization, projection
and response reconstruction are device operations. Only initial inputs,
final outputs and a final error-status scalar cross the device boundary.

`test_resident_simpls.cu` completed four small complete-core smoke tests:
regression/classification and float32/float64, n=64, p=7, q=3, four components
and 11 independent test rows. Held-out predictions agree with a host
reconstruction using exported model factors and independently computed
training centering/scaling: maximum errors 8.34562721e-8 float32 and
3.33066907e-16 float64. These are prediction consistency checks, not
independent estimator equivalence, broad rSVD qualification or speed tests.

## Remaining integration

Final-output exports are available for R, Q, training scores and training
centering/scaling statistics. Copies preserve float32 bits rather than
widening to double. Device factors remain available for subsequent calls.
PLS-SVD exports its SVD right directions as Q; prediction continues to use
its prefix-specific score-Gram coefficients, not those directions directly.

Argmax and top-k decoding now run on-device for raw PLS response scores and
LDA discriminants. The C/R interface can return only integer class rankings,
avoiding host transfer of the full score matrix when it is not requested.
Output index buffers are retained and grown when necessary. This is a
straightforward exact top-k scan, not yet a tuned large-class benchmark.

The expanded R tests passed for both families, precisions and task types.
Exported training scores matched standardized X times exported R within
1e-4 (float32) and 1e-10 (float64). Three-class top-k output matched R's
ordering of the corresponding raw and LDA scores at every tested prefix.
All previously recorded dense-reference and repeated-prediction checks
still met tolerance. Public `pls()` has not yet been switched to this core.

Resident LDA has now been connected to the internal model handle. Device
class sums produce class means; cuBLAS forms the pooled within-class
covariance from score cross-products and weighted means. Prefix Cholesky
factorization, triangular solves, scale-normalized regularization and
discriminant-score prediction stay on-device. Only solver status scalars
are read for the deterministic fallback sequence. No inverse is formed.
The sequence is 1e-8, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2 times the positive
finite mean covariance diagonal (otherwise scale one), increasing only
after Cholesky failure. Means/covariance and prefix scratch are reused.

`test_resident_lda.cu` met thresholds for six cases: float32/float64 and
ordinary, all-zero, or duplicated-column covariance. Predictions matched
the independent centered-block CPU oracle for all nine test labels in
every case. Maximum score errors were 7.92089594e-7 float32 and
1.77635684e-15 float64, below 1e-3/1e-7 thresholds. The duplicated-column
float32 case used rho=1e-6; float64 used rho=1e-8. Fallback selection may
differ by precision and needs to remain visible in final model diagnostics.

Integrated R tests exercised LDA after both SIMPLS and PLS-SVD and visited
prefixes forwards/backwards. Independent dense PLS-SVD plus pooled-LDA
held-out score differences were at most 2.749993e-7 float32 and
9.992007e-16 float64. Existing regression and raw-response tests still
passed. Large-dataset accuracy, runtime and memory are not established.

Resident PLS-SVD now has a device score-Gram/cross-product cache and
prefix-specific cuSOLVER Cholesky solves. Predictions use the resulting
latent regression coefficients, not SIMPLS loadings. Internal R dispatch
accepts method 1 (PLS-SVD) or 3 (SIMPLS); no public argument was added.

The expanded CUDA 13 R-interface tests used 64 training and 11 independent
test rows, seven predictors and three responses/classes. PLS-SVD prefixes
1 and 2 were visited forwards and backwards. Held-out results met dense
R SVD/least-squares reference tolerances: maximum errors 1.500784e-7
(float32 regression), 5.551115e-16 (float64 regression), 4.370003e-8
(float32 classification), and 2.775558e-16 (float64 classification).
SIMPLS prefixes 1-4 also completed forwards/backwards; maximum paired
float32/float64 prediction differences over all tested prefixes were
2.69005e-7 for regression and 3.012819e-7 for classification.
These are small integration tests, not broad estimator qualification.

The persistent C interface is now compiled by the package's existing
`lda_cuda_kernels.cu` unit. An independently linked C++ executable validated
four precision/task combinations, all four prediction prefixes, repeated
prediction replay, invalid-prefix rejection and model destruction.

Internal Rcpp fitting/prediction entry points are registered in RcppExports
and `cuda_resident_r.o` is included in Unix and Windows Makevars templates.
The non-CUDA wrapper compiled on macOS and rejected CUDA fitting explicitly
without fallback. On the CUDA workstation, `test_resident_r.R` loaded the
wrapper with `Rcpp::sourceCpp`, linked to the actual package CUDA object.
Regression and classification tests passed in both precisions, with four
prefixes, repeat prediction checks and wrong-predictor-count rejection.
Float32 versus float64 maximum prediction differences were 1.822538e-7
(regression) and 2.302616e-7 (classification). These are small synthetic
integration checks, not complete installed-package or public `pls()` tests.

The internal R interface is not connected to public package dispatch. It does not
establish GPU-resident public SIMPLS or PLS-SVD. Remaining work includes
public R fitting/prediction integration and classifier output/diagnostic contracts,
full output contracts, runtime residency tracing, memory checks and complete
benchmark reruns. Other PLS families and backend paths also require audit.
The existing installed package was not replaced.

Full benchmark reruns and manuscript/figure updates must follow validated
public-API integration; no new full-model performance claims arise from
these primitive tests.
