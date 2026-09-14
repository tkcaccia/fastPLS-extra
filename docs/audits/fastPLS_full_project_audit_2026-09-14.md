# fastPLS Full-Project Audit

Date: 2026-09-14

## Executive summary

The current R package is in substantially better condition than many of the
surrounding project artifacts: a fresh `R CMD check --as-cran` completed with
0 errors, 0 warnings, and 1 NOTE, and its testthat suite completed with 2,399
passes, 0 failures, 0 warnings, and 28 platform-dependent skips. The package's
CPU behavior is therefore well covered on this Mac.

The project is not yet ready to freeze as one reproducible software and paper
release. The principal blockers are:

1. The tested R source contains an uncommitted CUDA change, so the tested
   archive cannot be reconstructed from the reported Git commit.
2. The integrated standalone MIT C++ core does not compile its complete test
   suite because the test backend no longer implements two methods required by
   PLS-SVD.
3. `fastPLS-extra` does not install against the public headers exported by the
   current R package.
4. The manuscript and supplement combine results from fastPLS 0.99.65 and
   0.99.66, while the package is 0.99.66 and some scripts/manifests refer to
   still older releases.
5. The independent IKPLS evidence does not consistently use the component
   contract declared for Figure 1, despite the manuscript describing the
   comparison as component matched.
6. The public rSVD diagnostics usually certify only structural validity, not
   numerical agreement for the fitted dataset. The special large-problem
   control profile used by important workloads is not covered by the validation
   controls summarized in the manuscript.

These issues are fixable, but they should be resolved before regenerating the
paper's final tables and figures. Otherwise another benchmark run will create a
new mixture of source versions and output contracts.

## Scope and source states

### R package

- Path: `/Users/stefano/Documents/GPUPLS/fastPLS_fresh_github`
- Package: fastPLS 0.99.66
- Branch: `main`
- Commit: `3854e369c1f0cd615e58b968b7721efb4b2a3146`
- License: MIT
- Git state: dirty
- Modified: `src/cuda_resident_api.cuh`
- Untracked: `tmp/`
- `origin/main` and `BiocStaging/devel` were aligned with the recorded commit
  when inspected.

The uncommitted CUDA edit limits cached fold cross-covariance storage to 512 MB
and reuses cross-validation buffers. Because this edit was included in the
fresh archive, the audit results describe `commit + dirty patch`, not the
published commit alone.

### Benchmark and publication repository

- Path: `/Users/stefano/Documents/GPUPLS/fastPLS-extra`
- Package: fastPLSextra 0.0.2
- Commit: `9513a345233e9b95a8d849476217f9b97a8dc6ca`
- License: GPL-3
- Git state: 69 changes (36 modified and 33 untracked)
- Public repository: <https://github.com/tkcaccia/fastPLS-extra>

### Wrappers and standalone repositories

| Project | Local commit | Local status | Test result | Public status |
|---|---|---:|---|---|
| `fastPLS-py` | `f15d908ff873b6a4df1fe8b4f8f121153c16bc67` | clean | 33/33 passed | repository does not exist under `tkcaccia/fastPLS-py` |
| `fastPLS-matlab` | `abc7a7fd3f581ba0cf0c3230aae8d766e71be114` | clean | native macOS API suite passed | repository does not exist under `tkcaccia/fastPLS-matlab` |
| old `fastPLS-cpp` | current local HEAD | clean | 1/1 passed after fetching Eigen | public but stale and separate from the integrated core |
| integrated `core/` | part of fastPLS 0.99.66 | package tree dirty | compile failure | distributed inside the R package |

## Verification evidence

### Fresh R package archive

- Archive: `/private/tmp/fastpls_full_audit_09966/fastPLS_0.99.66.tar.gz`
- SHA-256: `cc73ba44a4946feb63aaa9daa1bbaa5c14a2d2e59649b4e4cfcbbcdd41b9ea17`
- Source state: commit `3854e369...` plus the recorded dirty CUDA edit
- `R CMD check --as-cran`: 0 errors, 0 warnings, 1 NOTE
- Testthat: 2,399 passed, 0 failed, 0 warnings, 28 skipped
- Check log:
  `/private/tmp/fastpls_full_audit_09966/check/fastPLS.Rcheck/00check.log`
- Test log:
  `/private/tmp/fastpls_full_audit_09966/check/fastPLS.Rcheck/tests/testthat.Rout`

The `R CMD check` NOTE concerns the version jump from the CRAN release and the
maintainer-email change. It is not a runtime defect, but it will need an
appropriate submission explanation.

### BiocCheck

- Result: 0 errors, 1 warning, 5 actionable/informational notes
- Log:
  `/private/tmp/fastpls_full_audit_09966/fastPLS.BiocCheck/00BiocCheck.log`
- Warning: fastPLS already exists on CRAN; Bioconductor requires removal from
  CRAN before the next Bioconductor release.
- Code-structure note: 39 R functions exceed 50 lines; the longest is
  `.compiled_cv_call()` at 398 lines.
- Style notes: 101 lines exceed 80 characters and 92 lines do not use
  multiples-of-four indentation.
- Administrative note: BiocCheck cannot verify bioc-devel subscription.
- Suggested `SupportVectorMachine` biocView appears algorithmically
  inappropriate and should not be added merely to silence an automatic
  suggestion.

### Documentation artifacts generated during this audit

- Current vignette HTML:
  `/private/tmp/fastpls_full_audit_09966/check/fastPLS.Rcheck/fastPLS/doc/fastPLS.html`
- Current manual PDF:
  `/private/tmp/fastpls_full_audit_09966/manual/fastPLS-reference-manual-0.99.66.pdf`

### Native Metal validation

The same 0.99.66 source archive was checked again in a native macOS process
with access to the Metal device:

- `has_metal()` returned `TRUE`;
- the complete `R CMD check --no-manual --no-build-vignettes` finished with
  `Status: OK`;
- the full suite reported 2,399 passes, 0 failures, and 28 skips;
- every skip concerned CUDA, Windows-only behavior, or unavailable source-tree
  inspection; no Metal test was skipped;
- a separate Metal-only run executed 8 files, 23 tests, and 200 expectations,
  all successfully.

Native check log:
`/private/tmp/fastpls_native_metal_check_utf8/fastPLS.Rcheck/00check.log`

Native test log:
`/private/tmp/fastpls_native_metal_check_utf8/fastPLS.Rcheck/tests/testthat.Rout`

## Critical findings

### C1. The tested source is not reproducible from Git

The package repository contains an uncommitted change in
`src/cuda_resident_api.cuh`. The fresh archive and all audit results include
this change, while `origin/main` and `BiocStaging/devel` point to the clean
commit without it.

Impact:

- A third party cannot reconstruct the audited archive from the commit.
- CUDA cross-validation behavior differs between the published commit and the
  tested source.
- Any manuscript statement tied only to the commit is ambiguous.

Required action:

- Decide whether the CUDA change is accepted or rejected.
- Validate it on CUDA, commit it if accepted, increment the package version,
  rebuild, and rerun the complete release matrix.
- Never label a dirty-tree archive as the immutable publication release.

### C2. The integrated standalone core does not compile

The CMake build under `fastPLS/core` fails while compiling the PLS-SVD tests.
`ReferenceBackend<float>` and `ReferenceBackend<double>` do not implement
`self_gram()` or `cholesky_solve()`, although the public core PLS-SVD template
requires both.

Affected files:

- `core/tests/reference_backend.hpp`
- `inst/include/fastpls/core/plssvd.hpp`, particularly calls near lines 139
  and 187

Impact:

- The reusable MIT core cannot currently demonstrate that all shipped headers
  compile independently.
- R CMD check misses this failure because `core/` is excluded from the R source
  archive.
- Python and MATLAB wrappers can drift from a core that is not independently
  build-tested.

Required action:

- Extend the reference test backend to the complete backend concept or revise
  the concept so required operations are explicit at compile time.
- Build and test the integrated core in CI independently of R CMD check.
- Add float32 and float64 tests for all four PLS families and prediction heads.

### C3. `fastPLS-extra` cannot install against fastPLS 0.99.66

`R CMD check` stops during installation because
`src/interface.cpp` includes `fastpls/native/simpls.hpp`, but the current R
package exports headers under `fastpls/core/` and no longer installs that
`native/` header.

Evidence:

- `/Users/stefano/Documents/GPUPLS/fastPLS-extra/fastPLSextra.Rcheck/00install.out`

Impact:

- The benchmark/reference package is not compatible with the software release
  it is intended to validate.
- The deposited NMR comparison and extraction checks cannot be reproduced from
  a clean installation.

Required action:

- Either port fastPLSextra to the public `fastpls/core` API or vendor the exact
  frozen GPL comparison implementation it needs.
- Add a versioned compatibility check and CI installation against the targeted
  fastPLS release.

### C4. The manuscript does not evaluate one immutable release

The manuscript and supplement combine fastPLS 0.99.65 and 0.99.66 results.
Component-path evidence and independent implementation comparisons are mostly
attributed to 0.99.65, whereas newer backend and ImageNet results use 0.99.66.
The supplement also contains a row identifying the documentation release as
0.99.65 even though the current package is 0.99.66.

Impact:

- Readers cannot map all claims to one installable implementation.
- Changes in solver dispatch, output construction, CV, LDA, or backend code may
  alter both timing and numerical results.
- The manuscript cannot support a current-release performance claim until the
  central analyses are rerun from one archive.

Required action:

- Freeze a clean release candidate first.
- Rerun at least Figure 1, Figure 2, the NMR comparison, rSVD validation,
  precision/backend concordance, and component-selection evidence with the
  identical archive.
- Record one archive checksum in the machine-readable evidence manifest even
  if the checksum is intentionally omitted from the paper.

### C5. The IKPLS comparison is not consistently component matched

The current Figure 1 contract specifies, among other values, CIFAR-100 at 99
components, MetRef at 50 external components, Retina at 10, Tabula Muris at 31,
NMR at 50, and ImageNet at 1,000. Other IKPLS scripts and Supplementary Table
S17 use older values such as CIFAR-100 298, MetRef 118, Retina 30, Tabula Muris
44, TCGA Pan-Cancer 185, and an ImageNet path of 100/200/500/1,000.

Affected contract:

- `benchmark/current_release_evidence/figure1_component_contract.csv`

Impact:

- The manuscript's claim that component counts were held fixed is not true for
  all displayed IKPLS evidence.
- Runtime and memory are highly component dependent, so this can reverse the
  interpretation of which implementation is faster.

Required action:

- Make the component-contract CSV the only source of component values.
- Have every worker copy the requested and effective component values into raw
  output and make the assembler reject mismatches.
- Regenerate IKPLS tables and Figure 1 only after this validation passes.

### C6. rSVD validation does not certify ordinary fitted objects

An ordinary public rSVD fit can return
`structural_checks_passed_case_audit_unavailable` with
`approximation_audited = FALSE`. This confirms finite structure, but not that
the approximation agrees with a higher-accuracy calculation for that dataset.
The manuscript's validation panel should therefore not be interpreted as a
per-fit certificate.

There is a second gap: the manuscript describes special large-problem controls
with approximately oversampling 12 and one power iteration, while the headline
validation controls use substantially stronger settings. The largest workloads
are therefore not directly covered by the validation panel used to justify the
default solver.

Impact:

- The user can receive a structurally valid but numerically inaccurate result
  without an automatic dataset-specific warning.
- Headline NMR/ImageNet performance may use controls not covered by the claimed
  qualification evidence.

Required action:

- Define route- and regime-specific acceptance evidence, including multiple
  seeds, rank boundaries, tied singular values, high response dimension, and
  classification stability.
- Display solver controls and audit status in every benchmark row.
- Use “met the stated numerical tolerances on the validation panel,” not
  “qualified” or “validated,” for results lacking case-level confirmation.
- Add a practical confirmatory workflow for users, such as repeated-seed
  agreement and a higher-accuracy comparison on a feasible subset.

### C7. The manuscript exceeds the intended journal format

The current main document is approximately 6,600 words and its abstract is
approximately 390 words. The supplement is approximately 14,800 words over 40
portrait pages, with 19 figures and 21 tables.

Impact:

- The methodological message is obscured by route-level detail.
- Dense supplementary tables use text too small for comfortable review.
- Extensive version and validation language makes the paper read partly like
  an engineering audit rather than a focused methods article.

Required action:

- Reduce the abstract below 350 words.
- Focus the main text on accelerated SIMPLS, matched independent comparisons,
  NMR, and a carefully qualified ImageNet feasibility example.
- Move full route grids and machine-level diagnostics to structured CSV files
  in the eventual immutable evidence archive.
- Consolidate the supplement around one authoritative table per question.

## High-priority findings

### H1. CPU thread selection has a permanent process-wide side effect

`.fastpls_apply_cpu_cores()` writes six environment variables and calls a
native thread setter, but it does not restore prior values after the operation.
A test call with `n.cores = 2` changed previously unset
`OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, and `VECLIB_MAXIMUM_THREADS` to `2`
for the remainder of the R process.

Affected code:

- `R/backend.R`, lines 131-152

Impact:

- A single fastPLS call changes later computations in fastPLS and other
  packages.
- Benchmarks can unknowingly inherit thread settings from an earlier call.
- Explicit function arguments do not behave as call-scoped controls.

Recommended correction:

- Save and restore environment and native library thread counts around each
  public operation, or document and expose the setting explicitly as a session
  mutation.
- Add tests for sequential calls using 1, 2, and 4 cores and for restoration
  after errors.

### H2. Installation documentation contradicts the build system

`INSTALL` says Linux and Windows require OpenBLAS and installation fails when it
is absent. `README.md`, `DESCRIPTION`, and `configure` correctly implement
OpenBLAS as optional and fall back to R's BLAS/LAPACK unless explicitly
required.

Affected locations:

- `INSTALL`, lines 11-19
- `README.md`, lines 143-146
- `configure`, lines 59-95

Recommended correction:

- Make all four documents describe the actual optional policy.
- Explain that published Linux/Windows performance runs require an OpenBLAS
  build, while package installation does not.

### H3. User-supplied OpenBLAS paths are embedded as an absolute rpath

When `OPENBLAS_ROOT` is used, `configure` inserts an absolute
`-Wl,-rpath,<local-directory>` into the package link flags.

Affected code:

- `configure`, lines 24-32

Impact:

- Built binaries may retain machine-specific paths.
- Binary redistribution and relocation can fail or violate platform policies.

Recommended correction:

- Prefer standard linker discovery, loader-relative paths where appropriate,
  or document source-only local builds.
- Audit installed binaries with `otool -L`/`ldd` and test relocation.

### H4. The claim that R is “only a wrapper” is not accurate

The package contains extensive R orchestration and a fallback
`.pls_cv_via_pls()` implementation. `.compiled_cv_call()` can dispatch to that
fallback, and CUDA nested-CV orchestration also remains partly in R.

Affected code:

- `R/main.R`, `.compiled_cv_call()` near line 6546
- fallback dispatch near line 6918
- `.pls_cv_via_pls()` near line 7699
- later fallback dispatch near line 10733

Recommended correction:

- Either complete the C++ migration and make fallback use explicit in
  diagnostics, or describe R as the orchestration/API layer rather than only a
  thin wrapper.
- Test that compiled and fallback routes use identical folds, selections,
  predictions, metrics, and permutation semantics.

### H5. Float32 capabilities are not uniform across the public API

Float32 is supported broadly for fitting and prediction, but permutation tests
and returned loadings are unavailable in important routes. CUDA resident
permutation also errors. Metal is float32-only while CUDA supports both
precisions.

Recommended correction:

- Maintain one generated capability matrix shared by vignette, manual, README,
  and manuscript.
- Mark every family/backend/precision/classifier/CV/permutation combination as
  supported, hybrid, experimental, unavailable, or untested.
- Add runtime contract tests for every cell.

### H6. Public output remains larger and more repetitive than documented

The manual says settings/backend bookkeeping are kept internally and are not
shown as public output fields, but the returned object still exposes fields
such as `xprod_mode`, `kernel`, `kernel_engine`, `kernel_linear_direct`,
`north`, and `opls_engine`. `P` is returned as an empty matrix when loadings are
not requested.

Affected documentation/code:

- `man/pls.Rd`, around lines 192-210
- `R/main.R`, around lines 9728-9808
- `R/resident_cuda.R`, around line 242

Recommended correction:

- Define one stable public schema.
- Omit absent optional objects rather than returning empty placeholders, unless
  compatibility requires them.
- Keep reproducibility controls in one documented `diagnostics` or
  `provenance` sub-list rather than duplicating settings at the top level.
- Add snapshot tests for output names by task and method.

### H7. NMR predictive selection and computational benchmarking remain mixed

The main NMR comparison uses PLS-SVD at 100 components and SIMPLS at 50, while
the training-only one-standard-error summary identifies 75 and 50,
respectively. A separate table compares implementations at 165 components,
matching the deposited workflow but not family-specific selection.

Recommended correction:

- Present two explicitly separate analyses:
  1. predictive comparison at training-selected component counts;
  2. implementation/backend comparison with family, component count, solver,
     precision, preprocessing, and outputs held fixed.
- Explain that 100 and 165 are predefined workloads when they are not selected
  optima.
- Report response-wise and spectrum-wise errors using the same water-region
  handling in all routes.

### H8. Benchmark source and evidence are not in a releasable state

`fastPLS-extra` has 69 uncommitted changes. Its `MANIFEST.csv` points to old
`build_current_09939_*` tools and does not capture the current multi-stage
Figure 1/2/3/4 workflows. The README still says the directory has not been
published even though the GitHub repository is public.

Recommended correction:

- Reduce the repository to one current workflow per evidence question.
- Create a machine-readable run manifest containing source commit, archive
  checksum, dataset hash, component contract, seed, precision, backend,
  output profile, hardware, software versions, command, status, and raw output
  path.
- Ensure every figure is generated by one documented command from immutable
  summaries, not by version-specific manuscript-edit scripts.

### H9. No project-owned CI or GitHub Pages site exists

The public `fastPLS`, `fastPLS-extra`, and `fastPLS-cpp` repositories have no
GitHub Actions workflows, no GitHub Pages site, no releases, and no repository
topics. External Bioconductor/R-universe checks are useful but do not replace
project-controlled CPU/CUDA/Metal/core/wrapper testing.

Recommended correction:

- Add CPU CI for Linux, macOS, and Windows.
- Add dedicated self-hosted or documented CUDA and Metal jobs.
- Add integrated-core, Python-wrapper, MATLAB-wrapper, documentation, and
  benchmark-schema checks.
- Publish a tagged release and a pkgdown site after the release is frozen.

### H10. The Python and MATLAB repositories are incomplete mirrors

Both wrappers pass their current local tests, which is encouraging. They are,
however, CPU-only subsets rather than full mirrors of the R package.

Python gaps include CV, permutation tests, ViP, plotting, accelerator backends,
session backend configuration, and release CI. MATLAB has similar gaps;
`evaluate()` and `fastcor()` are implemented on the MATLAB side rather than
through the same C++ implementation. Windows linkage in the MATLAB build path
also needs explicit validation.

Recommended correction:

- Describe both as experimental CPU API subsets until parity is achieved.
- Add cross-language golden tests using identical inputs, seeds, component
  counts, labels, preprocessing, and tolerances.
- Create the requested public repositories only after license and generated
  binary policies are settled.

## Medium-priority findings

### M1. The vignette is too long and repeats implementation material

The vignette is roughly 1,600 lines. It correctly starts with SVD and PLS
mathematics before backend configuration, but backend, float32, Metal, matrix
products, and implementation details recur in multiple sections.

It also repeatedly calls the internal matrix-free route `xprod`, even though
`xprod` is no longer a public argument. This exposes obsolete implementation
terminology to users.

Recommended correction:

- Keep one conceptual methods section, one backend/capability section, one
  classification workflow, one regression workflow, one CV/permutation
  workflow, and one diagnostics section.
- Replace internal route names with public concepts unless the internal name is
  essential for diagnostics.
- Move implementation and complexity detail to the supplement or developer
  documentation.

### M2. The checked-in reference manual is stale

The repository's `output/pdf` manual is version 0.99.64, while the package is
0.99.66. A fresh 0.99.66 manual can be generated, but it has overfull lines for
long output names and weak cross-reference warnings around base plotting
functions.

Recommended correction:

- Generate the manual and vignette only from the frozen source archive.
- Do not retain old generated manuals in the package repository.
- Reformat long value lists as compact tables or separate paragraphs.

### M3. Package source architecture is difficult to maintain

`R/main.R` exceeds 12,000 lines and `src/r_api.cpp` is approximately 273 KB.
BiocCheck identifies 39 R functions longer than 50 lines.

Recommended correction:

- Split R code by public API, validation, metrics, CV, permutation, prediction,
  diagnostics, and backend adapters.
- Split native registration/conversion code from numerical kernels.
- Replace duplicated family/backend branching with explicit typed dispatch
  tables where practical.

### M4. Dead or superseded numerical R code appears to remain

The `.float32_rsvd_raw()`, `.float32_rsvd()`, and
`.float32_rsvd_audit()` chain appears to have no active caller outside its own
chain. This should be verified with coverage before removal.

Recommended correction:

- Generate call/coverage reports for CPU, CUDA, Metal, float32, and float64.
- Remove dead numerical paths only after tests prove they are unused.

### M5. Permutation testing has a grouped-design limitation

The implementation correctly uses the finite-sample `(b + 1)/(B + 1)`
correction and records failed permutations. Grouped permutations are limited to
exchange among groups of equal size. Studies with unequal subject block sizes
may therefore have no useful permutation set.

Recommended correction:

- Make the exchangeability restriction prominent in the user documentation.
- Consider scientifically valid block-level schemes for unequal group sizes,
  but do not silently permute rows.
- Add tests for class balance, fixed folds, failed fits, and randomized solver
  seeds under the null.

### M6. Manuscript terminology and citation audits are not fully clean

The latest cross-reference audit finds all figures and tables cited, but the
notation audit still finds `SIMPLS-rSVD`, and typography checks find inconsistent
`Float32`/`float32` and `cpu`/`CPU`. Citation mapping remains uncertain for
CIFAR-100, ImageNet/DINOv2, and pathology statements.

Recommended correction:

- Standardize `PLS-SVD`, `SIMPLS with rSVD`, `rSVD`, `float32`, `float64`,
  `CPU`, `CUDA`, and `Metal` in source tables before document generation.
- Resolve references by citation keys rather than post-hoc numbered text.
- Rerun cross-reference, citation, notation, and rendered-page audits after the
  final regeneration.

### M7. Supplementary layout is technically valid but difficult to read

The supplement is portrait as requested and all 19 figures and 19 numbered
supplementary tables are cited, but early large tables and several component
path legends are too small at ordinary viewing scale.

Recommended correction:

- Keep compact summary tables in the PDF and deposit full grids as CSV.
- Split six-panel or multi-dataset figures when their scientific questions are
  different.
- Use consistent type sizes and repeated headers across page breaks.

### M8. The manuscript delivery folder is not synchronized

The current manuscript folder contains many iterative DOCX/PDF variants, while
`/Users/stefano/Desktop/manuscripts/project/fastPLS` does not contain the final
deliverables found during this audit.

Recommended correction:

- Designate exactly one manuscript DOCX/PDF and one supplement DOCX/PDF as
  current.
- Copy only the final manual and vignette alongside them after the release is
  frozen.
- Move intermediate document builds to a disposable build directory.

### M9. Repository hygiene needs attention

The R repository workspace contains many old package archives and check
directories. Some are ignored, but they create ambiguity and consume space.
The manuscript directory likewise contains many near-duplicate 6-13 MB DOCX
files and PDFs.

Recommended correction:

- Retain one current source archive plus immutable release evidence outside the
  source repository.
- Remove old local build products only after confirming that unique benchmark
  evidence is preserved.
- Never delete raw benchmark evidence solely because it is old; archive it with
  a manifest when it supports a published claim.

### M10. The old public `fastPLS-cpp` repository creates product ambiguity

The old repository builds and its single test passes after downloading Eigen,
but it is not the same core distributed under `fastPLS/inst/include/fastpls`.
It has no description, release, topics, or synchronization mechanism.

Recommended correction:

- Either archive it with a notice pointing to the integrated core, or make it
  the canonical core and automatically vendor a pinned release into all
  wrappers.
- Avoid maintaining two independently evolving implementations with the same
  name.

## Manuscript-specific corrections

1. Freeze one release and update every version statement, figure caption,
   supplement row, and availability statement.
2. Correct the abstract's comparison language. Distinguish fastPLS versus R
   packages from fastPLS versus IKPLS; do not use an ambiguous “faster on five
   of nine datasets.”
3. State that Figure 1 is a workflow comparison when output objects differ.
4. Regenerate the IKPLS rows with the exact component contract.
5. Keep ImageNet as a foundation-model feature-matrix feasibility example, not
   evidence of biomedical predictive validity. Preserve its exploratory and
   provenance limitations.
6. Keep NMR as the primary biomedical high-response case study and separate
   predictive selection from fixed-workload implementation comparisons.
7. Report rSVD oversampling, power iterations, seed policy, and audit status
   beside every approximate result.
8. State whether timing includes preprocessing, host-to-device transfer,
   synchronization, result transfer, prediction, and R object assembly.
9. Report absolute and baseline-corrected process RSS without calling it pure
   algorithmic memory.
10. Reduce internal verification language such as “quarantined,” “definitive,”
    and “review object.”
11. Present a short user decision table: exploratory rSVD, repeated-seed
    diagnostics, and confirmatory higher-accuracy analysis.
12. Ensure author order, co-first authors, co-corresponding authors, funding,
    acknowledgements, and CRediT statements are final and approved.

## Vignette and manual corrections

1. Generate both from 0.99.66 or the next frozen release; do not distribute the
   0.99.64 manual.
2. Remove internal `xprod` terminology from the user pathway.
3. Consolidate the duplicated backend, Metal, float32, and implementation
   sections.
4. Make the capability table authoritative and generated from tested metadata.
5. Clarify Windows float32 behavior and distinguish native single-precision
   linear algebra from portable conversions.
6. Document the process-wide implications of `n.cores`, or make it call scoped.
7. Align the output list with the object actually returned.
8. Explain that a missing case-level rSVD audit is not a numerical certificate.
9. Keep Q2 definitions explicit for fitted, independent-test, and
   cross-validated contexts.
10. Add an end-to-end grouped permutation example and state the equal-size
    exchangeability restriction.

## GitHub and release corrections

1. Add repository-owned CI and platform-specific accelerator jobs.
2. Add a pkgdown GitHub Pages site for the R API and vignette.
3. Publish immutable tagged releases after package freeze.
4. Add concise topics and a description to `fastPLS-cpp`.
5. Correct the `fastPLS-extra` README statement that the repository is not
   published.
6. Do not create public Python/MATLAB repositories until their scope is clearly
   labelled and their license/dependency metadata are complete.
7. Create one canonical release matrix linking package, core, benchmark scripts,
   manuscript, manual, vignette, and wrapper commits.

## Recommended implementation and release plan

### Phase 1: establish one source of truth

1. Resolve the uncommitted CUDA patch.
2. Repair and run the integrated C++ core suite.
3. Repair fastPLSextra against the current public core API.
4. Decide whether the old fastPLS-cpp repository is canonical or archived.
5. Increment the package version and create a clean release-candidate commit.

Exit criterion: clean Git trees and all local CPU/core/wrapper tests passing.

### Phase 2: close numerical and API gaps

1. Add case-level or repeated-seed rSVD diagnostics.
2. Validate the exact control profiles used by NMR and ImageNet.
3. Make `n.cores` call scoped or explicitly session scoped.
4. Align public output fields with documentation.
5. Generate and test the capability matrix.
6. Verify compiled versus fallback CV equivalence.

Exit criterion: every public route has a tested status and no hidden fallback.

### Phase 3: platform qualification

1. macOS CPU and functional Metal.
2. Linux CPU with verified OpenBLAS and CUDA.
3. Windows CPU with R BLAS fallback and a separate verified OpenBLAS build.
4. Explicit unsupported-route failure tests.
5. Sanitizer and memory-safety tests for the core.

Exit criterion: one identical source archive passes the intended platform
matrix, with skipped accelerator tests not counted as accelerator validation.

### Phase 4: benchmark freeze

1. Enforce the component contract programmatically.
2. Rerun central analyses from the frozen archive.
3. Store raw results outside `tkcaccia/fastPLS`.
4. Commit organized benchmark and figure-generation code to fastPLS-extra.
5. Create an immutable evidence bundle with a machine-readable manifest.

Exit criterion: every plotted cell maps to raw evidence, source version,
dataset hash, controls, hardware, and command.

### Phase 5: publication regeneration

1. Rebuild Figure 1, Figure 2, NMR, ImageNet, and supplementary figures from the
   frozen summaries.
2. Regenerate manuscript, supplement, vignette, and reference manual.
3. Run citation, cross-reference, notation, accessibility, and rendered-page
   audits.
4. Reduce the abstract and main text to journal limits.

Exit criterion: one submission folder containing only the final source archive,
manuscript, supplement, vignette, manual, and evidence manifest.

## Strengths to preserve

- Explicit accelerator requests fail rather than silently falling back to CPU.
- The permutation p-value uses the finite-sample +1 correction.
- Q2 definitions are tested and separated by fitted, test, and CV context.
- CPU package tests are extensive and currently clean.
- Float32 and float64 are both exercised across the four PLS families on CPU.
- Python and MATLAB wrappers already show promising deterministic CPU parity.
- The benchmark work retains failures and unsupported runs rather than hiding
  them.
- The manuscript has a strong biomedical anchor in the NMR application.

## Final release gate

Do not freeze or regenerate final performance claims until all of the following
are true:

- The R package tree is clean.
- The integrated core compiles and passes.
- fastPLS-extra installs against the release candidate.
- All benchmark workers consume one component contract.
- Central results use one package version.
- Functional CUDA and Metal jobs have run, not skipped.
- rSVD controls used by headline workloads are covered by numerical evidence.
- The current vignette and manual are generated from the same archive.
- The manuscript and supplement have passed final numerical, citation,
  cross-reference, notation, and visual audits.
