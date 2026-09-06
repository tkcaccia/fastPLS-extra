# Optimization and publication rerun

## Current objective update (2026-09-05)

The active goal now includes an MIT-licensed fastPLS source/core and a separate
GPL-3 `../fastPLS-extra` companion. Native rSVD is to be the only public solver
in the main package; IRLBA integration, manuscript tools and comparison
evidence move to the companion without duplicating PLS engines. No frozen or
external comparator may be executed. The detailed scope and license gates are
recorded in `../fastPLS-extra/MIGRATION.md`. Earlier progress entries below
describe their identified snapshots, not the final separated release.

The first extraction shares the native CPU matrix-rSVD routine between its
standalone header and the public R adapter. Its float32/float64 standalone
tests pass under OpenBLAS and Accelerate; the rebuilt R package passed 2,018
CPU/Metal assertions and twelve saved public-metric comparisons at 1e-12.
IRLBA recovery paths, shared PLS/CV/GPU extraction and the final MIT audit
remain unfinished; DESCRIPTION still correctly declares GPL-3.

Both component-path tables from the preceding fold-reuse queues reached
3,360 rows. The local controlled-scaling stage has terminal exit code zero.
The former local main/worker PIDs are no longer live; a stale matched-shapes
status file must not be interpreted as an active job. The earlier temporary
source/library directories are no longer present. Do not restart that older
snapshot merely because of a stale status record. Two NMR-selection stage
failures and the incomplete final common-source panel still need resolution.

## Scope

Improve CUDA and Metal workspace reuse and transfers, compiled cross-validation
storage reuse, prediction and model assembly, and massive-response computation.
Apply the applicable execution changes to IRLBA after validating rSVD.
Public inputs, fold assignments, grouping, preprocessing, selection metrics,
classifier semantics, and requested components must remain consistent.

## Frozen comparison

The read-only local reference is `../fastPLS_frozen_0.99.39`, at commit
`4d31203e5953db659f579da16fe043773a7dbf8a`. Its committed result tables under
`publication_results/0.99.39/current_release` are the baseline. No frozen
fastPLS runs, IKPLS runs, or external R-package fits are to be rerun.

New runs go to a separate candidate result directory. Comparison keys include
dataset, split, preprocessing, family, classifier, precision, backend, solver,
component set, controls, seed, output contract, thread count, and hardware.
Absent or incompatible baseline rows are reported as unmatched. Candidate
results must never overwrite baseline files or inherit baseline timings.

## Implementation and validation order

1. Validate no-copy CUDA input wrappers and bounded candidate batches. Confirm
   input matrices are unmodified, LDA/CV callers compile, and repeated fits
   retain predictions. CPU and Metal smoke tests cover the shared code.
2. Remove unrequested dense CUDA SIMPLS coefficient workspaces. Compare dense
   and compact predictions, then measure NMR and CIFAR-100 time and memory.
3. Inspect persistent CUDA/Metal workspaces, redundant data upload, model
   construction, and prediction. Preserve accelerator residency and explicit
   errors when an accelerator is unavailable.
4. Reuse fold indices, fold preprocessing and score workspaces within a CV
   operation. Avoid stale cross-call caches of mutable R input objects.
5. Extend shared matrix, solver-workspace and prediction improvements to IRLBA.
   Preserve its direction solve, convergence controls and component semantics.
6. Run focused numerical, precision, ownership and repeated-workspace tests,
   then R CMD check and BiocCheck on the stable candidate.
7. Freeze one candidate archive and rerun the full fastPLS publication panel.

## Full publication panel

Use `scripts/audit_current_release_evidence.py` and the current manuscript
builder as the inventory, with candidate-only adaptations of the runners:

- Eleven non-NMR datasets, all four PLS families, training component selection,
  matched selected CPU/CUDA/Metal fits and full component paths.
- The fastPLS rows from the external SIMPLS and broad R-package comparisons,
  preserving output contracts and repetition counts; join stored comparators.
- FastPLS cross-language rows; join saved IKPLS measurements.
- Controlled dimensions, numerical qualification across seeds, exact-reference
  outputs where saved, SIMPLS versus PLS-SVD, and implementation ablations.
- OPLS and linear/RBF/polynomial kernel reliability, float32/float64 comparisons,
  and one/two/four-core scaling with verified BLAS settings.
- Compiled versus R-loop CV using fastPLS on identical folds; repeated outer
  partitions and component-selection frequencies.
- NMR with the established water handling, training-only component grid,
  selected and matched 165-component fits, RMSD/Q2, per-spectrum and response
  errors, full/zoom spectra, time, and baseline/incremental/absolute memory.
- ImageNet SIMPLS argmax/LDA component paths, top-1/top-5, transformation and
  prediction time, memory, failures, and saved independent retrieval controls.

Retain raw repetitions, convergence/errors, effective solver controls, source
identity, and session/hardware metadata. Regenerate comparisons and figures
only from completed candidate runs and explicitly identified frozen rows.

## Progress

- Candidate installs locally with Accelerate/Metal and remotely with CUDA.
- CPU smoke panel: 36 configurations complete with finite models and metrics.
- Focused local tests: 241 assertions passed, with two unavailable-CUDA skips.
- Conditional dense CUDA coefficient workspaces and resident Metal products
  have passed compact/dense and repeated-workspace checks.
- IRLBA workspaces are reused within a fit while starts are freshly generated;
  15 saved before/after candidate configurations agree exactly, including RNG.
- Fold-matrix ownership and streamed metric accumulation agree with saved
  candidate outputs for 108 CPU and 54 CUDA CV configurations. Public input
  matrices and RNG/fold assignments are unchanged in those checks.
- CUDA NMR timing pilots at 50 and 165 components have median total times of
  0.707 s and 1.797 s, compared with stored matched values of 1.547 s and 4.290 s.
  RMSD agrees with the stored values. These are preliminary three-replicate
  results; an unrelated GPU workload was present and isolated reruns remain.
- Metal NMR pilots show no improvement at 50 components and a modest change
  at 165 components. Do not claim uniform backend acceleration.
- A local explicit-matrix IRLBA NMR pilot was terminated by the agent after
  profiling confirmed repeated dense BLAS scans and heavy system swapping.
  It is not a completed benchmark or a comparable timing result. The existing
  implicit route completed in 21.522 s at 50 components and 120.575 s at 165,
  with RMSD matching the stored reference to the reported precision. These
  Mac timings must not be presented as matched speedups over Linux timings.
- Automatic IRLBA routing now avoids large explicit cross-products when
  n * (p + q) < p * q. A strict-tolerance explicit/implicit comparison agreed
  to approximately 4e-12 (PLS-SVD) and 2e-9 (SIMPLS) relative prediction error.
  Default iterative tolerances allow larger differences and remain unchanged.
- The first frozen optimization snapshot passed 1,370 local CPU/Metal and
  1,381 remote CPU/CUDA assertions, with no test failures or warnings.
- Superseded first-snapshot publication queues were run separately. The local queue was
  `benchmark_results/optimization_20260904/publication_metal_v2`; the remote
  queue was `/home/chiamaka/fastPLS_optimization_20260904/publication_cuda_v3`.
  Earlier launcher attempts are retained separately: one hid the float
  dependency, and a remote startup profile overrode the library search path.
  Corrected launchers validate the loaded library, dependencies, and backend.
- All 44 local training-selection cases completed. Forty-one selected the
  stored component count. CIFAR-100 SIMPLS, OPLS, and linear kernel PLS differ
  by up to 0.0019 in selected accuracy; the remote SIMPLS check reproduces the
  difference. It must not be attributed only to hardware or BLAS differences.
- The separate final-left-range correction passed 1,381 CPU/CUDA assertions
  but did not change the CIFAR-100 selected result (298, accuracy 0.89038).
  It is not sufficient to resolve the component-selection difference.
- The candidate CPU batch width was increased from the stored implementation's
  8 to 64. An isolated current-code test restores 8 while keeping the memory
  and workspace changes: CIFAR-100 selects 286 with accuracy 0.89214, versus
  stored 263 with 0.89226. This is closer but not identical; the full 1:300
  metric paths are retained. A direct-sketch candidate selected the same 286
  components with accuracy 0.89214, so disabling the Gram product gave no
  additional accuracy benefit. The current candidate retains an eight-direction
  CPU batch and the corrected final left-range projection. These
  concurrent diagnostic timings are not publication timing measurements.
- The eight-direction candidate passed 1,381 CPU/CUDA assertions, with no
  failures, errors, or warnings. Its results were not relabelled as results
  from the first snapshot or the later fold-reuse candidate.
- All 264 local selected-point CPU/Metal runs completed successfully. Every
  Metal metric matches the stored value; observed Metal timing gains are
  modest and not uniform. Large local CPU ratios include the BLAS change
  to Accelerate and must not be attributed entirely to the C++ edits.
- The supplementary queue builder now covers controlled factorial/shape
  studies, same-code ablations, stored-protocol repeated outer splits, current
  fastPLS-only cross-language rows, verified OpenBLAS multicore runs, and NMR
  float32 timing/memory pairs. Five orchestration tests passed. Missing inputs
  or unauthorized external numerical references are recorded as pending,
  never silently counted as completed evidence.
- NMR float32 conversion is outside the timed fitting/prediction region and
  original training matrices are released before measuring baseline RSS.
  Both precisions are scored against the same original held-out response and
  training-response mean. Full paired runs on the settled candidate remain.
- A further candidate reuses fold predictor/response buffers and accumulates
  the regression metric denominator without an n-by-q centered temporary.
  All 240 CPU and 120 CUDA before/after configurations agree within 1e-10,
  including folds, stored predictions, metrics, and RNG state; inputs remain
  unchanged. This panel includes all four families, unequal fold sizes,
  three scaling modes, and RMSD/R2/Q2 accumulation. The complete CPU/CUDA
  suite also passed 1,381 assertions with no failures, errors, or warnings.
- The fold-reuse candidate is installed separately at
  `/home/chiamaka/Rlib_fastPLS_fold_reuse_candidate_20260904`.
  Local CPU/Metal verification passed 1,370 assertions without failures,
  errors, or warnings. All 120 saved before/after Metal CV configurations
  agreed within 1e-10, including the RNG state and stored predictions.
- Both first-snapshot queues were intentionally stopped after verification
  of their process trees. Completed results and superseded records remain;
  interrupted rows are not labelled as numerical or resource failures.
- The final R-layer edits only wrap two long lines and shorten an equivalent
  conditional expression in diagnostics. The rebuilt source archive passed
  R CMD check --as-cran with 0 errors, 0 warnings, and one CRAN incoming
  note about the existing CRAN version and maintainer email. Its examples,
  vignette rebuild, PDF/HTML manuals and tests succeeded. The installed-check
  test run recorded 1,368 passes, 22 skips, and no failures or warnings.
  The check uses en_US.UTF-8 and an isolated Matrix dependency matching R
  4.6.0; this fixes host locale/version warnings without suppressing checks.
- BiocCheck after formatting reports 0 errors, one warning that fastPLS is
  already on CRAN, and one note that mailing-list membership cannot be
  verified without administrator credentials. Neither is a code defect.
- Both latest queues have been started with frozen source/library fingerprints:
  `benchmark_results/optimization_20260904/publication_metal_fold_reuse_v1`
  and remote `.../publication_cuda_fold_reuse_v1`. Each execution plan has
  77 stages. Their explicit pending-panel lists still require follow-up;
  runner completion alone is not scientific completion.
- Linux symbol-binding checks found that linking OpenBLAS alone still used
  R's reference BLAS. Multicore workers now preload only the isolated
  OpenBLAS library and verify actual dgemm/dgemv/dsyrk bindings. The probe
  confirmed all three resolve to that OpenBLAS, with no system R changes.
  The 1/2/4-thread experiments remain to be completed on both hosts.
- A local read-only comparison snapshot includes existing protocol manifests.
  All 113 table/metadata files present in the frozen checkout match it
  byte-for-byte. Transfer of the snapshot to the remote host was blocked by
  a permission safeguard; approval has been requested. Remote work continues
  with pre-existing remote inputs and tables only.
- The comparison tool now inventories selected points, component paths,
  precision, shapes/scaling, ablation, dense-oracle validation, repeated outer
  partitions, multicore runs, NMR, external-workflow fastPLS rows, and
  ImageNet. Missing schemas/rows and ambiguous stored duplicates are explicit.
  Known cross-host comparisons do not emit speedup ratios. Twelve Python
  orchestration/comparison checks passed; no comparator is executed by them.
- The complete publication panel, numerical/precision checks, package checks,
  provenance joins, and final candidate-versus-frozen report remain pending.
- Unrelated remote jobs are not to be stopped. Timed GPU publication runs
  must wait until the device is free; correctness tests are labelled separately.
- Current-only numerical replays now reproduce the stored OPLS/kernel setting
  protocol without uploading baseline tables or executing external estimators.
  All 66 endpoint and 1,540 fold-component results are finite; all 66 selected
  component counts match the stored table. Maximum endpoint metric difference
  is 2.87e-11 and maximum fold metric difference is 7.93e-12.
- The SIMPLS replay includes all 28 tasks, IRLBA and five rSVD seeds. Its 702
  endpoint results and 1,530 fold-component results are finite. All 72 selected
  component counts match the stored table; the largest endpoint metric change
  is 2.07e-6 and the largest change across 306 mean-CV curve values is 1.42e-7.
  These are metric/selection comparisons, not renewed coefficient/subspace or
  label-vector comparisons: stored reference vectors are unavailable. The own
  dense-LAPACK oracle remains a separate validation stage. No external estimator
  or frozen fastPLS was rerun. Correctness-run timings are not publication timings.
- Two SIMPLS replay setup/collection failures were diagnosed, not labelled as
  package failures: a repeated source assignment confused the task loader,
  then a missing slice helper prevented metric collection. Both helpers now
  have regression tests, and failed scientific rows produce a failed exit.
  The completed run is `simpls_replay_v3`; earlier attempts remain distinct.
- A separate experimental Metal candidate reuses up to eight matrix-product
  workspaces, bounded to 64 MiB, while refreshing input contents on every call.
  It shares float32 device storage between double-input and float-input products,
  without changing their arithmetic. Oversized one-off products release retained
  workspaces and allocate transient storage. Input mutation, transpose flags,
  shape eviction, model outputs, and repeated CV are included in validation.
  This is not yet adopted into either live publication snapshot. Its isolated
  build/test guard waits for the current Mac stage to finish before running;
  only our queue dispatcher is temporarily paused, not the timed worker.
- The second isolated Metal product candidate also tiles the column-major to
  row-major packing and unpacking. It completed 1,412 unit assertions without
  failures/errors/warnings, 42 bit-identical product/model comparisons, and
  120 before/after CV configurations within 1e-10. Product-only timing batches
  improved by about 1.1-2.0x on the tested shapes; short model timings were mixed.
  These product ratios are not whole-workflow speedups.
- Its three-repeat, masked-predictor float64 NMR runs took median 1.899 s at
  50 components and 4.819 s at 165, versus stored 2.176 and 6.024 s under the
  same protocol. Maximum RMSD differences were 5.26e-10 and 7.92e-7 respectively.
  The float32 50-component worker exceeded its 900-second limit; 165 float32
  components were not reached in that attempt. No frozen fit was rerun.
- Source tracing confirmed repeated copies of the large cross-covariance
  matrix inside the float32 Metal rSVD/IRLBA products. A third, isolated
  candidate retains this operator across products and refreshes its values
  after every deflation, retaining only two forward/reverse product workspaces.
  It does not change directions, solver controls, RNG, orthogonalization or
  float32 arithmetic. Its numerical tests and NMR timings are pending. Neither
  this experiment nor the preceding product cache changes either live queue.
- The remote paired selected-point stage completed 264/264 successful runs,
  all with uniquely matched stored rows. All CUDA metrics match exactly. The
  median stored/current total-time ratios across these replicates are 1.15 for
  PLS-SVD, 1.07 for SIMPLS, 1.05 for OPLS and 1.07 for linear kernel PLS. CPU
  SIMPLS/OPLS/kernel ratios are about 1.30-1.35; PLS-SVD is unchanged. CPU
  classification changes reach 0.0007, so numerical equality is not claimed.
  These aggregate metrics do not establish paired prediction-vector agreement.
- Both 44-setting component-selection stages are complete. Each differs from
  the stored selection in three nearly flat CIFAR-100 paths. Follow-up plans
  distinguish candidate-selected workloads from the matched fixed-workload
  timings; they must not be silently merged or called identical selections.
- The float32 Metal operator candidate passed 1,422 unit assertions,
  36 bit-identical float32 model/SVD comparisons (IRLBA/rSVD, all families,
  regression/argmax/LDA), and 120 CV comparisons. Its 50- and 165-component
  NMR workers still exceeded a 300-second limit. A two-second native stack
  sample located the residual cost in the CPU deflation row product and
  the alias-protection p-by-q temporary; the process footprint peaked near
  4.9 GiB. That profiled worker is diagnostic, not a publication timing.
- A subsequent candidate caches the float32 deflation row and updates S with
  a reusable p-vector. This removes the p-by-q temporary for CPU/CUDA/Metal
  float32 SIMPLS and the SIMPLS cores of OPLS/kernel PLS, for both solvers
  where available. It retains separate multiplication/subtraction rounding.
  Verification: 1,436 unit assertions, no failures/errors/warnings, 36 CPU
  plus 36 Metal bit-identical float32 model comparisons including RNG state,
  and 120 unchanged Metal CV cases. Small-model timing changes are mixed.
- Float32 direction diagnostics previously inferred float64 rank-one/batch
  routing and labelled Metal/CUDA as CPU because their internal solver token
  is cpu_rsvd. Reporting now uses the requested execution backend and the
  actual float32 per-component sketch rule, without changing numerical fits.
  Large-shape diagnostic tests do not allocate a large matrix.
- The lower-memory candidate's one-component NMR diagnostic completed in
  6.003 seconds versus 10.592 for the operator-only candidate, with identical
  RMSD/Q2; both are single observations, not a general speedup estimate.
  Its 50-component run now completes in 126.682 seconds, but RMSD is
  0.00202220 (Q2 0.08433), substantially worse than the different float64
  Metal implementation. This is not evidence that float32 itself causes the
  difference, nor an acceptable general fast-NMR result. A matrix-free
  float32 operator and matched numerical qualification remain necessary.
  The 165-component rerun exceeded its 300-second limit in
  `float_deflation_nmr`; no completed metric is reported for that case.
  This candidate is installed only in `/private/tmp/fastpls_float_deflation_lib`;
  the publication queues continue to use their unchanged fold-reuse snapshots.
- NMR workers now save each finished replicate atomically, outside measured
  fitting/prediction, and orchestration verifies requested repetitions,
  precision, protocol, finite metrics and status. Timeouts/errors continue
  to subsequent cases and remain explicit. Twenty-two Python checks pass.
- Linux GCC syntax-checking of the new Metal-disabled stubs succeeded with
  the installed R/Rcpp/RcppArmadillo headers. An initial check incorrectly
  assumed R_HOME/include; retrying with R.home("include") fixed that tooling
  path. This is a stub compilation check, not a full Linux/CUDA package test.
- Both isolated NMR guards have exited and resumed the Mac dispatcher. The
  main Mac queue has now produced 72 successful compiled-versus-R-loop CV
  rows. The remote queue is live but waiting on unrelated GPU process 544775;
  it must not start timed CUDA stages until the device is free.

## Float32 Matrix-Free Follow-Up (2026-09-05)

- Added CPU/CUDA/Metal float32 cross-product operators. Accelerator X/Y
  buffers and intermediate products persist within a fit. The existing
  float32 rSVD/Lanczos code now accepts explicit or implicit products;
  there is no new public solver or argument, and no licensing work.
- The first implementation stored low-rank deflation corrections. Small
  product tests agreed, but NMR suffered severe late-component cancellation.
  That implementation is rejected, not counted as a successful speed result.
- The revised operator updates the smaller predictor factor, with resident
  rank-one updates on CUDA/Metal. The reduced full-decomposition fallback
  also works on factors, without materializing the p-by-q matrix. It retains
  a host reduced-decomposition stage; this is not claimed fully GPU-resident.
- Float32 directions contaminated by previous loading directions are
  reorthogonalized twice when their projection exceeds 32 machine epsilons
  times their norm. This restores a SIMPLS invariant, without warm starts,
  changed requested components, or an added tuning parameter.
- Candidate `float_factor_stable` passed 1,436 existing unit assertions,
  72 bit-identical existing CPU/Metal float32 model comparisons, 120 unchanged
  CV cases, and CPU/Metal forward/transpose/deflation tests. The benchmark
  probe initially had an Armadillo index-width ABI mismatch; it now explicitly
  compiles with the package's 64-bit indices and checks the index size.
- Large synthetic SIMPLS/PLS-SVD/OPLS tests use the automatic implicit route.
  All predictions are finite; the largest relative difference against the
  preceding explicit candidate is approximately 1.43e-5. This is a limited
  numerical panel, not proof across all shapes or datasets.
- Single-run float32 Metal NMR diagnostics, same masked-X/unmasked-Y protocol,
  automatic oversampling 12/power 2, seed 123, conversion outside timing:
  50 components: total 2.691 s, RMSD 0.000755995861, Q2 0.872023964.
  165 components: total 7.952 s, RMSD 0.000974099248, Q2 0.787530676.
  These do not establish repeated timing uncertainty, peak workspace memory,
  equivalence to the different float64 Metal direction solver, or multi-seed
  robustness. Those checks remain required.
- Fixed NMR selection scripts to accept Metal and to score PLS-SVD through
  its latent regression coefficients rather than SIMPLS loadings. The scorer
  matches public predict() for both families on CPU/Metal. Original failed
  selection stages remain in the queue ledger; corrected runs must be saved
  separately and must not be joined to invalid historical prefix scores.
- Mac manuscript CV completed 120 rows. NMR 165-component CPU IRLBA completed
  three repeats (median 128.5 s), on this Mac rather than the Linux workstation.
  The Mac queue is now running the 3,360-row component-path stage.
- CUDA candidate validation uses a separate source/library and a guard between
  CV child workers. An initial installation failed because disabling R startup
  files hid the existing dependency libraries. The driver now preserves the
  verified .libPaths() explicitly. The direction-only CUDA candidate completed
  1,381 assertions without failures/errors/warnings and 54 bit-identical small
  CPU/CUDA comparisons. This is not a test of the subsequent score correction.
- The source-only remote candidate, local candidate libraries, and full
  manuscript queues are separate. No frozen or external estimators were run,
  no baseline data/manifests were uploaded, and no changes were pushed.

## Paired Float32 Score Correction (2026-09-05)

- A further roundoff check corrects scores and prediction weights together
  when score projections exceed 32 float32 machine epsilons times the score
  norm. Correcting stored scores alone would not preserve prediction semantics.
  No controls, fresh initialization, requested components or public arguments
  change. The current local candidate passed 1,448 assertions and 120 CV cases.
- The NMR prefix-scorer test initially iterated over a removed public ncomp
  field and therefore performed no comparisons. This test was invalid. It now
  requires an explicit positive count: 36 CPU/Metal blocked-scoring comparisons
  against public predict() completed in `float_factor_scores_v3`.
- Single-run Metal float32 NMR, identical protocol/seed/controls to the prior
  direction-only candidate: 50 components 2.728 s, RMSD 0.000755995861;
  165 components 7.846 s, RMSD 0.000974080228. Replicated timing, multiple seeds,
  peak-memory measurement and current CUDA verification remain pending.
- A dedicated CPU test compares stored scores with training projection and
  fitted responses with predict(). Prediction relative errors are at most
  6.23e-7. In synthetic near-rank-deficient problems, score relative errors
  nevertheless reach 0.0505 at 30 components after 20 strong latent dimensions.
  Stored-score orthogonality alone therefore does not establish float32 score
  fidelity. This limitation must remain visible in broader qualification,
  especially for classifiers based on scores. Additional prediction-consistency
  assertions and CPU/CUDA coherence reports are included in the next test run.

## Current Run Ledger (2026-09-05)

- The newer CUDA source upload was stopped by the approval gate. Explicit user
  approval was requested for implementation/test source only. Do not retry by
  another transfer mechanism. The separately created remote
  `float_factor_scores_candidate` directory still contains the preceding
  direction-only source; it has NOT received the score correction or new tests.
- The stable remote manuscript queue completed 120 CPU/CUDA SIMPLS CV runs
  across eleven datasets: all succeeded, all fold partitions match the R-loop
  comparator, classification prediction agreement is 1, and maximum regression
  relative prediction error is 1.40e-15. Eighteen CPU rows match stored frozen
  rows with unchanged metrics and median stored/current compiled-time ratio
  2.68. No matching stored CUDA CV rows exist. Against the current R loop,
  median loop/compiled ratios are 1.10 (CPU) and 1.09 (CUDA), not large gains.
- The remote queue has advanced to `external_simpls_fastpls_only`, running
  only fastPLS. No external package or frozen estimator is rerun. The two new
  aggregate CV CSVs were downloaded; no datasets/model arrays were transferred.
- The Mac component path has 720 uniquely matched stored rows in partial
  comparison v4. The largest absolute classification accuracy difference so
  far is 0.0037 on CPU CIFAR-100 SIMPLS at 20 components. This is aggregate
  metric evidence, not paired prediction equivalence.
- A separate NMR panel runs CPU/Metal, SIMPLS/PLS-SVD, float32/float64, 50/165
  components, seeds 123/124/125, three timing repetitions and a separate memory
  run per setting. It has 96 planned workers and does not include a frozen
  estimator. Results are in `float_factor_scores_nmr_replicated`; partial
  summaries retain completion counts in `float_factor_scores_nmr_summary`.
  Input conversion is outside timing. Memory is sampled process RSS in MiB,
  not an isolated allocation count, and timing does not come from memory runs.
- CPU SIMPLS float32 completed nine timing repetitions per component count:
  medians 4.747 s (50) and 20.732 s (165). Median RMSDs are 0.000756102 and
  0.000977377. It remains slower than the different float64 SIMPLS route.
  Median sampled RSS increments are 256/265 MiB versus 455/477 MiB for
  float64; complete-process peak RSS reductions are smaller. Do not describe
  these results as a general float32 speed or two-fold total-memory advantage.
- The R float32 regression/argmax prediction paths now reuse one maximal
  test-score projection instead of recomputing it at every requested prefix.
  PLS-SVD top-k blocks reuse their projection too; LDA already did so.
  This is a separate, not-yet-validated R-only candidate in
  `/private/tmp/fastPLS_prediction_prefix_20260905`, NOT the NMR panel source.
  Its test runner waits for NMR guard 31975 to finish, then uses the existing
  component-worker boundary before installing/testing. Twenty prediction-only
  repetitions per family/backend, prefix agreement, full tests and CV checks
  are scheduled. Float32 R-layer projection remains host-assisted; caching it
  does not make prediction fully GPU-resident.
- The current NMR guard (PID 31975, exec session 62490) automatically resumes
  component dispatcher 4754. Prediction validation waiter is exec session
  90203. Neither should be restarted solely because a polling call times out.
  Latest full package check/BiocCheck and full benchmark on one consolidated
  candidate remain required. IRLBA licensing/replacement work is cancelled.

## Completed Local Follow-Up

- All 96 NMR workers completed: 144 timing repetitions and 48 memory runs,
  with no failed workers. The summary CSV includes seed ranges, timing IQRs,
  sampled baseline/peak/incremental RSS and separate memory repetition counts.
  Twenty-four rows have uniquely matched stored results; 120 have no stored
  counterpart (additional seeds or float32). No baseline estimator was run.
- In the matched stored Metal float64 comparisons, median stored/current
  total-time ratios are 1.21/1.27 for SIMPLS at 50/165 components and
  1.17/0.90 for PLS-SVD. The 165-component PLS-SVD route is therefore slower,
  not an improvement. Its RMSD is unchanged. SIMPLS RMSD changes are at most
  7.92e-7 absolute in these matched rows; prediction-vector equality is not
  inferred from those aggregate errors.
- Within the new NMR precision panel, Metal PLS-SVD float32 medians are
  0.679/1.380 s at 50/165 components versus 6.657/25.283 s for float64.
  At 165 components, median RMSDs are 0.000786732 and 0.000785889.
  This comparison combines different internal execution paths and precision;
  it does NOT isolate the effect of single-precision arithmetic alone.
- The projection-cache candidate installed successfully in
  `/private/tmp/fastpls_prediction_prefix_lib`. It passed 1,464 assertions
  with zero failures/errors/warnings and 120 CV comparisons. Twenty timed
  predictions per family/backend show approximately 4-10% shorter median
  prediction times in the synthetic panel (20-28 ms tasks). Maximum relative
  prediction change is 7.32e-8. This is not a whole-workflow speedup estimate.
- Both local guards completed and resumed the live component-path dispatcher.
  Exec sessions 62490 and 90203 are terminal. Source upload approval for the
  newer CUDA candidate is still pending; the unchanged full remote queue is
  independently live in its fastPLS-only external-comparison stage.
- Source inspection identified full n-by-p double broadcast temporaries in
  `.float32_sweep_cols()` and repeated X/Y transfers in the double-input Metal
  PLS-SVD cross-product route. The follow-up below addresses these independently.

## Float32 Preprocessing and Prediction Follow-Up

- `float_broadcast_v1` completed with 1,555 assertions, no failures, errors or
  warnings, and unchanged CV comparisons. The columnwise compiled operation
  replaces the double broadcast without changing float arithmetic. Twenty
  prediction repetitions per family/backend gave medians of 4-10 ms compared
  with 20-28 ms before this change. The synthetic prediction panel has 200
  training rows, 3,000 test rows, 400 predictors, 20 responses and ten requested
  prefixes; it is not a real-dataset fitting benchmark. Compared predicted
  matrices are unchanged in this panel.
- `float_standardize_v1` then fused centering/scaling into one output allocation
  and changed zero workspaces to allocate zero float bits directly. It passed
  1,643 assertions with no failures/errors/warnings. Tests cover arithmetic,
  zero dimensions, invalid dimensions, non-finite values, input ownership and
  RNG preservation. The primitive does not require float BLAS symbols; hosted
  Windows testing is still required rather than inferred from the Mac run.
- A separate allocation profile on an 8,000-by-512 matrix measured 187.511 MiB
  of R-managed allocations for the preceding double-broadcast implementation,
  versus 15.626 MiB for fused standardization. Input/output payload is each
  15.625 MiB. Over twenty unprofiled repetitions, medians were 43.5 ms versus
  2 ms. Direct zero allocation reduced R-managed allocation from 46.876 to
  15.626 MiB and median time from 12 to 1 ms. Output-bit checksums match all
  three current candidates. These measurements are allocation totals, NOT
  peak process RSS or native/GPU allocation measurements.
- Verified source/library: `/private/tmp/fastPLS_float_standardize_20260905`
  and `/private/tmp/fastpls_float_standardize_lib`. No frozen estimator or
  external PLS package ran. Guards 35817 and 17483 completed and resumed the
  existing component-path queue.

## Metal Matrix-Free Follow-Up

- The double-input Metal PLS-SVD rSVD path previously recopied X and Y during
  every composed cross-product. A candidate now creates one fit-scoped resident
  cross-product workspace, combines both products in one command buffer, and
  keeps the intermediate on device. It releases the workspace explicitly on
  normal/error exit. A tagged pointer prevents mixing unrelated workspaces.
- This retains the existing Metal float arithmetic and host double QR/reduced
  SVD; it does NOT add native GPU float64 support or change the randomized
  sketch, seed, power count, family or retained component semantics. The path
  remains hybrid. CPU and CUDA dispatch are unchanged by this Metal-specific
  optimization.
- Isolated source `/private/tmp/fastPLS_metal_xprod_20260905` is being validated
  against the preceding current candidate. Tests compare each product and
  complete small matrix-free sketch, RNG state, dimensions, multiple live
  workspaces and explicit release; the full suite and model/CV comparisons
  also run. Only after validation succeeds will masked NMR PLS-SVD float64
  run at 50/165 components, three seeds, three timing repetitions and separate
  memory workers (`metal_xprod_v1`). This is not yet accepted performance
  evidence. Source upload permission for the newest CUDA changes remains
  pending; no upload workaround has been attempted.

## Latest Measurements and Next Bottleneck

- The remote fastPLS-only external-comparison stage completed 2,090 measured
  iterations from 726 workers. All 2,090 uniquely match stored comparison rows
  and have unchanged accuracy. Median stored/current total-time ratios are
  1.061/1.071 for cold/steady complete workflows and 1.084/1.102 for
  cold/steady minimum-output estimator workflows (pooled ratios, not a universal
  dataset speedup). Only new aggregate CSVs and session metadata were downloaded.
  `publication_cuda_comparison_partial_v6` contains the joined evidence.
- The resident Metal cross-product candidate passed 1,678 assertions and the
  product/model/CV comparisons. All twelve NMR workers completed. Over nine
  timing repetitions per count (three seeds), median PLS-SVD times were 5.184 s
  at 50 components and 23.951 s at 165, compared with 6.657/25.283 s for the
  preceding candidate. RMSD is unchanged for every seed/replicate. Timing IQR
  at 165 is 6.139 s, so the modest median improvement is not evidence of stable
  universal acceleration. Three separate memory runs per count report median
  peak RSS 1,363/1,480 MiB and increments 646/767 MiB. These remain complete
  process measurements, not isolated workspace sizes.
- A separate profiled 165-component PLS-SVD fit attributes 77.67% of sampled
  CPU time to the R QR .Fortran calls and 12.58% to La.svd. The resident
  cross-product functions account for approximately 3% combined. The profile
  is excluded from timing evidence; the NMR timing verifier rejects profiled
  records. This supplies a measured reason to optimize host decompositions
  rather than modifying rSVD controls or SIMPLS mathematics.
- A new isolated Metal candidate delegates matrix-free range QR and reduced
  SVD to compiled Armadillo using the package BLAS/LAPACK. The fresh random
  sketch is still generated in R with the same seed, dimensions and power
  count; products remain Metal float arithmetic. This remains a hybrid route.
  QR basis signs/rounding can differ from LINPACK, so tests compare reconstructed
  operators and subspaces as well as seeds, dimensions, and deficient cases.
  It is under validation in `metal_qr_v1`; no performance claim is yet made.
- Mac comparison v5 has 860 uniquely matched component-path rows. Full queues,
  corrected training-only NMR selections, newer CUDA validation, final package
  checks, and consolidated release-level benchmark evidence remain incomplete.

## Compiled Metal Host Decomposition Result

- `metal_qr_v1` completed 1,696 assertions with zero failures/errors/warnings,
  the existing Metal product/model comparisons and 120 CV comparisons, then
  all twelve NMR workers (18 timing fits plus six separate memory fits).
  Source/library are `/private/tmp/fastPLS_metal_qr_20260905` and
  `/private/tmp/fastpls_metal_qr_lib`.
- NMR PLS-SVD, double-input Metal, controls oversample=32 and power=5, fresh
  seeds 123/124/125: median total times over nine timing fits are 1.693 s at
  50 components (IQR 0.261 s) and 3.376 s at 165 (IQR 0.117 s). Against the
  preceding pre-resident current candidate's 6.657/25.283 s medians, paired
  runtime ratios have medians 3.73/7.39. Largest absolute RMSD differences
  are 7.57e-11/3.16e-9; largest Q2 differences are 2.51e-8/1.11e-6.
  These improvements concern PLS-SVD, not SIMPLS, and remain hybrid Metal
  products with host double QR/SVD.
- Only seed 123 has a matched frozen observation: three timings at each
  component count, with stored medians 7.909/22.421 s versus new medians
  2.250/3.376 s. Median paired stored/current ratios are 3.33/6.66. Extra seeds
  remain explicitly unmatched. No frozen estimator was rerun.
- Process-memory results are not uniformly better: median peaks are
  1,686/1,352 MiB at 50/165 components, compared with 1,568/1,698 MiB in the
  earlier precision panel. Median sampled increments are 776/740 MiB.
  Report baseline, peak and increment separately; medians of differences
  need not equal differences of medians. Do not claim universal memory gains.
- A separate source copy is undergoing full R CMD build, R CMD check --as-cran
  and BiocCheck in `metal_qr_package_checks`; guard session 58672 pauses only
  component dispatcher 4754 and resumes it on exit. This check is not yet
  complete. Guard sessions 7107, 23547 and 99192 are terminal and resumed it.
- The remote queue advanced beyond its fastPLS-only package panel to NMR
  timing/memory workers. Its source is still the earlier stable fold-reuse
  candidate, not the newer locally validated float32 changes. Permission to
  upload newer implementation/test source remains outstanding.

## Package Check Follow-Up

- `metal_qr_package_checks` finished R CMD check --as-cran with zero errors,
  zero warnings and one incoming-feasibility NOTE about the existing CRAN
  version/maintainer differences. Vignette rebuilding and PDF/HTML manual
  checks succeeded. BiocCheck reported zero errors, the known already-on-CRAN
  warning, and three notes: two long generated-wrapper lines, one 51-plus-line
  diagnostics function, and mailing-list verification requiring administrator
  credentials.
- The two source-style notes were addressed without changing diagnostic
  values or numerical code: wrapped the internal calls, moved the float32
  optimization labels into the existing label helper, and removed redundant
  scalar storage. A separate copied source is being rechecked in
  `metal_qr_formatted_checks` (guard session 32116); session 58672 is terminal.
  Do not claim that the style-only recheck has completed before reading its
  final logs. The latest full algorithmic validation remains `metal_qr_v1`.
- Free local disk space was about 2.2 GiB when checked. Do not duplicate
  datasets or delete frozen measurements to make room. Scratch source copies
  use APFS clone copying, but compilation still allocates new object files.

## Compact Metal Component Paths and Corrected NMR Selection

- The formatted check completed: R CMD check --as-cran has zero errors,
  zero warnings and the existing incoming-feasibility NOTE. BiocCheck has
  zero errors, one already-on-CRAN warning, and one administrator-dependent
  mailing-list verification NOTE. Both source-style notes are resolved.
- Removed the redundant Metal SIMPLS response-weight cube, which repeated
  Q-transpose at each prefix. Multi-prefix Metal PLS-SVD paths exceeding
  32 MiB of latent weights now retain C and Q and construct only the current
  prefix's weights. Single-prefix/small paths retain cached weights. Prediction
  still evaluates the original host C times Q-transpose before the Metal
  product, preserving that path's arithmetic order. Compact factors take
  precedence over B, as previously happened through the stored weights.
- Source `/private/tmp/fastPLS_metal_compact_path_20260905`, library
  `/private/tmp/fastpls_metal_compact_path_lib`, results
  `metal_compact_path_v1`: 1,719 assertions with no failures/errors/warnings,
  all 72 product/model results unchanged from the immediately preceding
  current Metal candidate, 120 matched CV cases, and 90 blocked NMR-scoring
  comparisons against public predictions. No frozen model was executed.
- In `metal_component_storage_v1`, 20 isolated construction timings per
  family/candidate used fixed factors with n=150, p=500, q=6000, 64 components
  and 12 prefixes. Model sizes fell from 38.84 to 3.68 MiB (PLS-SVD) and
  38.71 to 3.55 MiB (SIMPLS). Predictions were bit-identical. Median component
  construction times fell from 48.5 to 2 ms and 16 to 1 ms respectively;
  the millisecond resolution limits precision at the new timings. This is
  not an estimator/whole-fit speedup. Separate Rprofmem allocation totals
  fell from 78.82/63.89 to 0.95/0.07 MiB; these are not process RSS or native
  allocator measurements.
- NMR scoring now prepares centered validation X and maximal scores once per
  split and reuses the training-mean Q2 denominator. Prefix predictions remain
  response-blocked. Per-row score_time_sec includes an equal allocation of
  shared preparation, so its sum counts the shared work exactly once.
  This benchmark scorer uses host BLAS, even for a Metal-fitted model; it is
  not a claim of device-native CV. Public CV is checked independently above.
- Corrected Metal NMR training-only selection completed 85/85 prefix rows
  per family: five paired splits (123,456,789,1011,2027), fixed fit seed123,
  grid 1,2,3,5,8,10,25,50,75,100,125,150,165,175,200,250,300. The one-SE
  choices are 75 for PLS-SVD (mean-RMSD minimum125; eligible75-250 excluding300)
  and 50 for SIMPLS (minimum50; eligible50,75,100). Median validation RMSD
  at these choices is 0.0009456030/0.0009331824; median Q2 is
  0.8630838/0.8683447. These are training-only validation metrics, not held-out
  outer-test estimates. Median maximal-grid fit times are 5.010/8.549 s.
- Reading, not executing, the frozen selection source confirmed a baseline
  defect: lines74-110 of its benchmark_nmr_component_selection.R always used
  scores times Q-transpose, including PLS-SVD. Its stored five-component
  PLS-SVD selection is not a valid numerical baseline for corrected PLS-SVD
  scoring. The comparison tool retains both values but withholds differences
  and speed ratios for this panel. Stored selection is also CUDA, not Metal.
  The extra eight-component point prevents an identical-grid timing claim.
- All 26 Python benchmark/verifier tests pass. Guards70758 and48768 completed
  and resumed dispatcher4754. Full package/vignette/manual checks for this
  numerical candidate are running under guard70838 in
  `metal_compact_path_checks`, source
  `/private/tmp/fastPLS_metal_compact_check_20260905`; do not claim completion
  before final logs. Local main queue57261 and remote queue502738 were verified
  live; the remote queue advanced to the 165-component CPU NMR rSVD worker.
- The current changes do not modify IRLBA licensing. The newer CUDA source
  upload is still awaiting explicit permission following its earlier denial.
  Remaining work includes compact native CPU/CUDA paths, corresponding CUDA
  validation, final selected-point NMR testing after the corrected selection,
  and completion/reconciliation of all full-suite outputs on one final source.

### Compact-Path Check Follow-Up

- Guard70838 completed. All R tests, vignette rebuilds and manual checks passed,
  but R CMD check found an undeclared `withr` dependency introduced by the new
  test, and BiocCheck found one long comment. The test now uses a naturally
  large coefficient-path shape (so automatic compact storage applies), without
  changing the environment or adding a dependency. The comment was shortened.
- A new immutable scratch source
  `/private/tmp/fastPLS_metal_compact_final_check_20260905` is being checked under
  guard49528 in `metal_compact_path_final_checks`. Numerical package code is
  unchanged apart from that comment. Do not report this recheck as finished
  before inspecting its final logs.
- `publication_metal_comparison_partial_v6` includes 1,520 matched component-path
  rows and the completed corrected NMR selection panels. PLS-SVD selection
  differences/ratios are withheld because of the stored scorer defect; SIMPLS
  selection differences are explicitly cross-backend (stored CUDA/current Metal),
  not an optimization agreement test. Frozen source/data remain untouched.
- Next local NMR endpoint panel should use both PLS-SVD and SIMPLS at 50,75,165
  components, seeds123/124/125, three timing replicates and separate memory
  workers. This covers training-selected counts plus the fixed165 workload;
  it has not yet started because the package-check guard owns the queue pause.

## CPU/IRLBA Prediction-Score Reuse and NMR Endpoints

- `metal_compact_path_final_checks` completed (guard49528 terminal): R CMD
  check --as-cran zero errors/warnings and the existing incoming-feasibility
  NOTE; BiocCheck zero errors, the already-on-CRAN warning and admin-dependent
  mailing-list NOTE. Vignette and PDF/HTML manual checks passed.
- The native double CPU predictor now projects the maximal requested score
  matrix once for compact SIMPLS and both PLS-SVD latent representations.
  Requested prefixes use that matrix; proj=TRUE reuses it while retaining all
  stored R columns, including when the requested prefixes are a subset.
  Dense coefficient fallback and component validation remain available.
  This applies to both native rSVD and IRLBA fits without changing SVD or
  deflation mathematics, public arguments, seeds, or IRLBA licensing.
- `cpu_prediction_prefix_v1` stopped on a new test passing an integer matrix
  directly to the double-only internal predictor. The test was corrected;
  no public input dispatch was changed. Guard9933 is terminal. V2 (guard63848,
  source `/private/tmp/fastPLS_cpu_prefix_v2_20260905`, library
  `/private/tmp/fastpls_cpu_prefix_v2_lib`) passed 1,786 assertions, 240 CPU CV
  comparisons including IRLBA, and 120 Metal CV comparisons. No test failures,
  numerical failures, or test warnings were reported.
- The first batched timing panel had sub-resolution iris timings. V3 repeated
  timings with 10,000 iris calls and 50 wide-response calls per batch, retaining
  five calls per tall-predictor batch and 20 batches per setting. This exposed
  an 8-20% wide-response regression in the initial subview implementation.
  That subview variant is not the retained worktree implementation.
- The retained variant exposes contiguous cached score columns as non-owning
  const Armadillo matrix views. `cpu_prediction_prefix_view_v1` (guard5823
  terminal) passed all 1,786 assertions and the same CPU/Metal CV comparisons,
  with before-after and after-before timing orders. Pooled 40-batch medians:
  tall predictors improved 15.8-16.0 ms to 5.8-6.3 ms (2.54-2.74x); iris
  native predictions improved about 8-11% at 4-5 microseconds per call.
  Wide-response ratios range 0.987-1.064, with overlapping order variation;
  report no clear wide-response gain. Prediction relative differences are
  at most 2.741e-17, projected scores are unchanged, and all observed
  accuracy/RMSD metrics are unchanged. These are compact native-prediction
  timings, not whole-fit or frozen-version speedups.
- Current source/library:
  `/private/tmp/fastPLS_cpu_prefix_view_20260905` and
  `/private/tmp/fastpls_cpu_prefix_view_lib`. Its full package/vignette/manual
  checks are running under guard97359 in `cpu_prediction_prefix_view_checks`,
  source `/private/tmp/fastPLS_cpu_prefix_view_check_20260905`.
- The NMR endpoint panel in `cpu_prediction_prefix_v2/nmr` completed all36
  workers: 54 timing fits plus18 separate memory fits. Metal double-input,
  both families, counts50/75/165, seeds123/124/125, three timing replicates per
  seed. Native CPU predictor revisions do not affect these Metal predictions.
  Summary and strict stored comparisons are in its `nmr_summary` and
  `nmr_vs_stored` directories; no old estimator was executed.
- Median total time / held-out RMSD:
  PLS-SVD50 1.634s / 0.0007399733; PLS-SVD75 2.142s / 0.0007292221;
  PLS-SVD165 3.322s / 0.0007858883;
  SIMPLS50 1.931s / 0.0007500158; SIMPLS75 2.491s / 0.0007745997;
  SIMPLS165 4.760s / 0.0009368480.
  The training-selected comparisons are PLS-SVD75 and SIMPLS50; the165 rows
  are a separate matched-count workload. Median sampled process peaks range
  1,549.5-1,717.3 MiB, and sampled increments 779.75-965.41 MiB, not isolated
  allocation or device-memory measurements.
- Only12 timing rows have a frozen match (seed123 at50/165);42 rows have no
  stored equivalent and remain explicitly unmatched. Median paired
  frozen/current ratios are4.566/6.672 for PLS-SVD50/165 and1.081/1.258 for
  SIMPLS50/165. Maximum RMSD differences are7.57e-11/9.92e-10 and
  5.26e-10/7.92e-7 respectively. Aggregate RMSD agreement is not a claim of
  identical NMR prediction vectors.
- Guards30654 and5823 completed their timing reruns and resumed dispatcher4754.
  The previous whole-suite queues still use their identified earlier snapshots;
  completing/reconciling all analyses on a final common source and validating
  the newest CUDA changes remain outstanding. Source upload approval remains
  pending. No push, frozen execution, external PLS rerun, or relicensing occurred.

## CPU Blocked-Prediction Weight Reuse

- The prefix-view full check completed (guard97359 terminal): R CMD check
  --as-cran zero errors/warnings, one incoming-feasibility NOTE; BiocCheck
  zero errors, one already-on-CRAN warning and one mailing-list verification
  NOTE. Vignette rebuild and PDF/HTML manual checks passed.
- CPU blocked prediction now stores one shared SIMPLS Q-transpose rather
  than repeating it for every requested prefix. Existing PLS-SVD W_latent
  weights are viewed without copying. The C-only PLS-SVD fallback still
  materializes its weight cube; that allocation is not claimed as resolved.
  The change applies to rSVD and IRLBA fitted factors without changing fitting.
- Source `/private/tmp/fastPLS_cpu_flash_weights_20260905`, library
  `/private/tmp/fastpls_cpu_flash_weights_lib`: 1,946 assertions, zero failures,
  errors and test warnings. New checks cover blocking, projection, stored and
  factorized weights, prefix reordering/duplicates, input immutability, and
  invalid counts. CUDA runtime tests remain unavailable locally.
- `cpu_flash_weights_v1` stopped in its independently refitted timing panel:
  wide-response SIMPLS/rSVD component21 had an opposite score sign. Its
  sign-aligned score difference was 6.84e-15 and total relative prediction
  difference 2.77e-15; the other seven completed comparisons were identical.
  The source diff affects only the predictor. This is not used to waive a
  predictor discrepancy: `cpu_flash_weights_fixed_models_v2` now loads exactly
  the same saved current-model factors in both installations. Guard45631 is
  running its forward/reverse batched timings and must be checked before
  reporting final timing or agreement results. Guard26881 resumed dispatcher
  after the v1 check failure; its remaining CV checks did not run.
- New `validate_cpu_flash_memory.py` and `check_cpu_flash_memory.R` prepare
  independent prediction-only RSS workers; these have not run yet. Memory
  runs are separate from timings and retain absolute/baseline/incremental RSS.
  `validate_cpu_prediction_prefix.py --validation-only` can complete package
  and CPU/Metal CV checks against the installed current candidates without
  refitting the timing panel. These checks are still pending for this change.
- Full queues were revalidated live: Mac dispatcher4754 reached1910/3360
  component-path workers; remote dispatcher661937 reached1772/3360. Mac
  selected-point aggregate contains264 successful rows and all44 component
  selections succeeded. These queues use the earlier identified fold-reuse
  snapshots, not the latest prediction/Metal QR source. Completion on a common
  final source, latest CUDA validation, and remaining full-suite panels are
  still required. All26 Python orchestration tests pass.

### Completed CPU Predictor Validation

- Guard45631 completed and resumed the queue. Fixed-model timings contain
  40 batches per candidate/case across forward and reverse library orders.
  All36 prediction/projection comparisons are bit-identical and metrics are
  unchanged. Wide-response SIMPLS medians are6.95ms before and5.40ms after
  for both IRLBA/rSVD factors; stored-weight PLS-SVD is7.45/7.20ms before and
  5.85/5.80ms after. These are prediction-only results, not whole-fit gains.
  Factorized PLS-SVD retains the same cube construction; its small timing
  differences are not attributed to an allocation change.
- `cpu_flash_memory_v1` (guard22611 terminal) completed12 independent memory
  workers, three per family/candidate. Fixed factors use p=200, q=8000,
  96 stored components,16 requested prefixes and8 test observations.
  SIMPLS median baseline/peak/incremental RSS is190.17/320.75/128.97MiB before
  and191.38/230.92/39.55MiB after. PLS-SVD is331.44/400.59/69.16MiB before
  and341.11/351.44/10.33MiB after. Each prediction window has18 or more
  samples. This is sampled process memory, not isolated native allocation;
  native allocator retention and the R output are included.
- `cpu_flash_cv_validation_v1` (guard99838 terminal) completed1,946 assertions
  with no test failures/errors/warnings,240 paired CPU CV configurations
  including IRLBA and120 paired Metal CV configurations. Outputs and RNG
  states meet1e-10 comparison tolerance. All four compiled method IDs are
  exercised across scaling, heads, stored/online metrics and regression metrics.
- `cpu_flash_full_checks` (guard33521 terminal), source
  `/private/tmp/fastPLS_optimization_release_candidate_20260905`, completed
  R CMD check --as-cran with zero errors/warnings and the existing incoming
  NOTE. BiocCheck: zero errors, one already-on-CRAN warning and one
  administrator-dependent mailing-list NOTE. Vignette and PDF/HTML manual
  checks passed. No newer CUDA upload or CUDA runtime validation occurred.
- The publication runner now adds a separate NMR selected-endpoint stage.
  It validates complete one-SE curves and uses each newly selected count,
  rather than interpreting hard-coded5/50/165 workloads as selected models.
  The helper independently verifies the existing corrected Metal choices75
  (PLS-SVD) and50 (SIMPLS). New unit tests reject missing splits, nonfinite
  curves and stale decisions. All30 orchestration tests pass. The new full
  selected-endpoint stage itself has not run yet; the earlier Metal endpoints
  remain the identified measured evidence.
- Guard52539 is building the same numerical source against OpenBLAS in
  `/private/tmp/fastPLS_optimization_openblas_20260905`, installing into
  `/private/tmp/fastpls_optimization_openblas_lib`. Its install, checks and
  subsequent1/2/4-thread panel must be verified before claiming completion.
  The old full-suite source/library remains immutable. The remaining full
  benchmark and latest CUDA validation are still required; the goal is active.
