# CMPB manuscript and supplementary-material audit

Date: 2026-09-15

## Scope and status

Audited files:

- `fastPLS_CMPB_manuscript_restructured.docx` and its PDF
- `fastPLS_CMPB_supplement_restructured.docx` and its PDF
- the machine-readable tables and figure inputs used by the document generator
- the current PLS-SVD, SIMPLS-family, OPLS, kernel-PLS and cross-validation
  pseudocode
- the Lean 4 algebraic-invariant project

The manuscript renders cleanly to 17 portrait pages and the supplement to 24
portrait pages. No clipping, overlap or landscape pages were found. The
structured abstract contains approximately 334 words. The main text from the
Introduction through the declarations contains approximately 4,000 words when
captions and tables are excluded, so it remains above the journal's usual
3,500-word target.

## Resolved during this pass

### 1. Table S1 and Figure 1 now use the same benchmark contract

The previous Table S1 retained older IKPLS and scikit-learn component counts.
It has been regenerated from the same fixed-component result object used by
Figure 1. The replacement contains 24 directly matched Python rows and one
separately labelled scikit-learn NMR feasibility row. Only the 1,000-component
ImageNet comparison shown in Figure 1 is retained.

Automated validation confirms that all 24 Figure 1 rows have identical
component counts in Table S1. The document generator now constructs the table
from the shared result CSV rather than retaining a manually copied table.

### 2. NMR timing and CPU/CUDA ratios now use one source

The three conflicting 50-component SIMPLS values were traced to an older
version-0.99.65 Figure 1 run and two independent version-0.99.66 repetitions.
All manuscript displays now use the dedicated NMR component-path benchmark:
1.619 s on CPU and 0.463 s on CUDA. The corresponding CPU/CUDA ratio is 3.50.

Figure 2 and Table S4 now also use the 100-component NMR PLS-SVD records from
the same benchmark: 6.128 s on CPU and 0.500 s on CUDA, or 12.26-fold. The
previous 150-component ratio of 19.15 has been removed. A reconciliation script
generates the Figure 1 and Figure 2 input tables directly from the NMR summary
and raw process records.

### 3. Figures 2 and 4 are version-neutral

The Figure 2 and Figure 4 assets were regenerated and reinserted without an
embedded development-version label. The manuscript therefore follows the
policy of naming only version 0.3 in Supplementary Section S7.

## Remaining submission-blocking findings

### 4. Supplementary dataset citations are shifted

The following in-text citations in Supplementary Section S1 refer to the wrong
sources:

| Item | Current | Required |
|---|---:|---:|
| CIFAR-100 | 23 | 22 |
| MetRef source | 24 | 23 |
| Probabilistic quotient normalization | 25 | 24 |
| GTEx | 26 | 25 |
| Pan-Cancer | 27 | 26 |
| CCLE | 28 | 27 |
| TCGA-BRCA | 29 | 28 |
| TCGA-HNSC | 30 | 29 |
| CITE-seq | 31 | 30 |
| Retina | 32 | 31 |
| Tabula Muris | 33 | 32 |

The PRISM/DepMap citation remains reference 33. This is a source-attribution
error, not merely a numbering preference.

### 5. The public formal-verification link is not yet reproducible

The manuscript points to `fastPLS-extra/Phase1/formal/lean`, and the local Lean project
successfully checks all ten stated theorems without `sorry`, admitted axioms or
unproved declarations. However, the `formal/` directory is currently untracked
locally and therefore is not available at the public URL cited by the paper.
The link must not appear in a submitted manuscript until the exact checked
project, lock file and toolchain are published.

### 6. Several software states are presented as one coherent study

The earlier stale component grids and inconsistent NMR ratios show that the
manuscript was assembled from more than one benchmark state. A
final submission needs one immutable version-0.3 source archive, one result
manifest and a generated provenance mapping from every reported value to its
source row. Numbers should not be manually copied between figures and tables.

## Major scientific findings

### 7. Approximate rSVD evidence is insufficient for the headline route

rSVD supplies the principal performance results, but the consolidated
supplement no longer contains a compact numerical-qualification analysis. It
does not report repeated-seed variability, convergence status, relative
prediction error, label agreement, score-subspace agreement or failure counts.
Endpoint accuracy and RMSD alone cannot establish that an approximate fit is
numerically acceptable.

Reinstate one concise, authoritative rSVD table covering several seeds and
matrix regimes. Report controls, diagnostics and failures. Exact dense or
high-accuracy small-problem checks should be separate from approximate-rSVD
qualification.

### 8. Estimator and backend agreement claims exceed the displayed evidence

The abstract says that numerical agreement was assessed across implementations
and hardware. Table S4 reports only endpoint metrics, with no prediction-level
agreement or numerical-status column. Some differences warrant explanation,
including CIFAR-100 SIMPLS accuracy (0.8690 CPU versus 0.8712 CUDA), CBMC
SIMPLS RMSD (1043.33 versus 1047.78), and NMR SIMPLS RMSD (0.0007376 versus
0.0007230).

Add one compact agreement table with explicit tolerances, prediction agreement,
relative prediction error and execution status, or narrow the abstract and
Methods claims.

### 9. The name SIMPLS is still used too broadly

The Methods and Supplement correctly disclose that the bounded-block direction
route is an approximate SIMPLS-family estimator rather than classical de Jong
SIMPLS. The title, abstract and Algorithm 1 nevertheless use unqualified
`SIMPLS` or `accelerated SIMPLS` language. This can be interpreted as exact
estimator preservation.

Use `SIMPLS-family` for the bounded-block route and reserve `SIMPLS` for the
one-direction recurrence. Add a short abstract qualification; do not make the
reader wait until the supplement to learn that the fastest route changes the
direction-extraction procedure.

### 10. Lean proves algebraic identities, not the compiled implementation

The Lean files correctly prove exact-real identities used by the algorithms:
associativity-based latent prediction, symmetric Gram structure, selected
deflation identities, OPLS orthogonality, centered fold sums and related
properties. They do not prove floating-point correctness, rSVD accuracy,
algorithmic convergence, equivalence to de Jong SIMPLS, or correspondence
between the specification and the C++/CUDA implementation.

The present scope statement is appropriately cautious and should be preserved.
Describe this as machine-checked algebraic invariants, not formal verification
of the software or estimator.

### 11. OPLS and nonlinear kernel PLS still need numerical validation

These families appear in the CPU/CUDA benchmark and component paths, but the
current supplement does not provide an independent estimator-validation panel.
Linear-kernel agreement with SIMPLS does not validate nonlinear kernels, and an
endpoint comparison does not establish OPLS orthogonal-score correctness.

Add deterministic float64 CPU checks for OPLS orthogonality, predictive-score
agreement and each nonlinear kernel setting before using these routes to
support general package-reliability claims.

### 12. Cross-validation pseudocode is missing

Cross-validation acceleration is a central result, but Supplementary Section S5
contains prose rather than executable pseudocode. Add one compact algorithm
that shows full-data sufficient statistics, held-out subtraction, fold-specific
centering/scaling without leakage, family-specific fold-local fitting, nested
outer-fold isolation and the fallback used when sufficient-statistic caching is
not valid.

The phrase that PLS-SVD reuses one maximal decomposition must say explicitly
that reuse occurs within each training fold, never across held-out folds.

### 13. Permutation testing is promised but absent

The main Methods says that permutation-testing conventions are documented
separately, but the present supplement contains no such section. Either remove
this software-level feature from the CMPB manuscript and reserve it for JSS, or
document the +1 finite-permutation correction, exchangeability unit, grouped
permutation, fixed-fold policy, randomized-solver seeds and failed-fit handling.

### 14. ImageNet comparisons need clearer hardware qualification

The abstract states 63.3 s for fastPLS versus 197.1 s for IKPLS, while Figure 4
shows approximately 5.8 s for the CUDA analysis. These are different
experiments, but the abstract does not explicitly label the 63.3-s comparison
as the single-CPU software benchmark. Add `single-CPU` there and retain the
single-run exploratory qualification.

The claim that ImageNet represents foundation-model-derived matrices is useful,
but it should remain a computational feasibility example rather than evidence
of biomedical predictive validity.

## Reproducibility and presentation findings

### 15. Main-text citation order is not consecutive

The first-use order is 1-21, then 34-35 for Lean, then 22, followed by 36-39.
References 23-33 are used only in the supplement. Either give the supplement a
separate reference list and remove supplement-only dataset references from the
main bibliography, or renumber the complete manuscript and supplement together.

### 16. Table S8 contains internal check-report language

Rows describing local R checks and Bioconductor notes are development records,
not scientific reproducibility metadata. Replace them with the exact OS, R and
Python versions, compiler and flags, OpenBLAS version, CUDA toolkit/driver and
libraries, thread environment and benchmark command. The exhaustive interface
capability matrix belongs in the future JSS article.

### 17. `cold` and `warm` GPU terminology is ambiguous

Supplementary Section S2 uses `cold` and `warm` for first and repeated GPU
execution. Because direction warm starts were removed from the algorithm, use
`first execution` and `context-initialized repeated execution` instead, and say
that this terminology concerns runtime initialization only.

### 18. Authorship symbols are incomplete

Stefano Cacciatore and Leonardo Tenori carry a dagger, but the author note
defines only the asterisk for equal contribution. Add `dagger: co-corresponding
authors` explicitly and retain both correspondence addresses.

### 19. Internal and historical wording remains

Phrases such as `unavailable historical releases`, `archived release` and CI
status make parts of the supplement read like a development audit. Keep exact
data-release identifiers where scientifically necessary, but rewrite review-
cycle and repository-status language as neutral provenance.

### 20. Long tables remain difficult to read

Tables S4-S7 are dense and use small type. Ensure continuation pages repeat
column headers and use one body font size. Split tables by scientific question
before reducing type further.

### 21. The main manuscript needs modest compression

The abstract is compliant, but the main text is approximately 500 words above
the journal's usual target. Remove repeated caveats and software-interface
details after the quantitative inconsistencies are corrected. Do not shorten
the description of benchmark contracts or numerical validation.

## Findings that passed audit

- The abstract is below 350 words.
- Both documents are portrait and render without clipping or overlap.
- Main Figures 1-4 and Table 1 are cited.
- Supplementary Tables S1-S9 and Figures S1-S13 are all cited from the main
  Results in numerical order.
- The PLS-SVD equations are dimensionally consistent.
- The one-direction SIMPLS recurrence and latent prediction formula are
  dimensionally consistent.
- The cached Gram update is correct when its unit-vector precondition holds.
- The pooled-covariance LDA discriminant is mathematically correct; the number
  of classes should still be defined explicitly.
- The NMR predictor-water-region handling is clearly described and does not
  alter the response metric.
- The local Lean project compiles and contains no admitted proofs.

## Required correction order

1. Freeze version 0.3 and define one result manifest and output contract.
2. Rebuild Figure 2 and Tables S4-S5 from that manifest.
3. Reconcile the NMR SIMPLS timing discrepancy.
4. Regenerate figures to remove obsolete version labels.
5. Correct dataset citations and global reference order.
6. Add compact rSVD, backend, OPLS and kernel-PLS numerical validation.
7. Add cross-validation pseudocode or narrow the CV methodological claim.
8. Publish the checked Lean project before citing its public URL.
9. Replace internal CI text with benchmark reproducibility metadata.
10. Perform a final number-to-source, rendered-page and word-count audit.
