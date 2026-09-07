# Analysis and publication tools

This directory contains code that summarizes benchmark evidence, creates
figures and tables, builds the manuscript and Supplementary Material, and runs
notation/citation/layout audits.

`build_current_09939_figures.R` assembles the independent-implementation,
backend, NMR and ImageNet figures from external result roots. The current NMR
root must be supplied through `FASTPLS_CURRENT_NMR_ROOT`; this prevents older
package-version measurements from entering Figure 3. Run
`build_current_09940_evidence.R` afterwards to replace the general benchmark
panels with the current-release evidence. It reads the independent R, IKPLS,
nirs4all-methods and scikit-learn result tables and writes generated tables and
figures to the external manuscript directory. Finally,
`build_current_09939_documents.py` reads those artifacts and writes the DOCX
files to that directory. None of these tools reads results from or writes
results to the `fastPLS` repository.

Generated output is intentionally absent from this repository until the
package is frozen. The later evidence repository will contain the selected
results, rendered documents, environment records, and a frozen manifest.

Earlier document-assembly utilities are isolated in `../archive/`. They are
not part of the current figure, table, or manuscript workflow.

Run `audit_repository_boundary.py` before committing either source repository.
It rejects tracked result directories and generated tables, serialized objects,
figures, documents, logs, and source archives.
