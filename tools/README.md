# Analysis and publication tools

This directory contains code that summarizes benchmark evidence, creates
figures and tables, builds the manuscript and Supplementary Material, and runs
notation/citation/layout audits.

`build_current_09939_figures.R` reads numerical evidence from
`FASTPLS_EVIDENCE_ROOT` and writes generated tables and figures below
`FASTPLS_MANUSCRIPT_OUTPUT`. `build_current_09939_documents.py` reads those
generated artifacts and writes DOCX files to the same external output tree.
Neither tool reads results from or writes results to the `fastPLS` repository.

Generated output is intentionally absent from this repository until the
package is frozen. The later evidence repository will contain the selected
results, rendered documents, environment records, and a frozen manifest.

Earlier document-assembly utilities are isolated in `../archive/`. They are
not part of the current figure, table, or manuscript workflow.

Run `audit_repository_boundary.py` before committing either source repository.
It rejects tracked result directories and generated tables, serialized objects,
figures, documents, logs, and source archives.
