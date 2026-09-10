# Analysis and publication tools

This directory contains code that summarizes benchmark evidence, creates
figures and tables, builds the manuscript and Supplementary Material, and runs
notation/citation/layout audits.

`build_manuscript_assets.sh` is the stable publication entry point. It rebuilds
every generated table and figure, replaces the independent-implementation
panels with current-release evidence, builds the six-route NMR Figure 3, and
then regenerates the DOCX files. Its environment variables point to external
evidence directories, so new benchmark results never require edits to the
figure or document code.

`benchmark/current_release_evidence/run_nmr_fixed_workload.py` creates the NMR
evidence used by Figure 3. Every repetition runs in a separate R process.
Three unmonitored processes provide fitting-plus-prediction timing; one
additional monitored process provides memory measurements and is excluded from
the timing summary.
`build_nmr_figure3.R` accepts only PLS-SVD and SIMPLS results for CPU, CUDA, and
Metal, uses a linear runtime axis beginning at zero, and writes the source table
next to the figure. The Linux evidence root supplies CPU and CUDA results; the
Mac evidence root supplies Metal results. Hardware is recorded in each root's
`run_manifest.json`.

The lower-level scripts remain available for auditability:
`build_current_09939_figures.R` assembles the general panels,
`build_current_09940_evidence.R` replaces them with current-release benchmark
evidence, and `build_current_09939_documents.py` assembles the manuscript and
Supplementary Material. They should not be edited for routine result updates.
None of these tools reads results from or writes results to the `fastPLS`
repository.

Generated output is intentionally absent from this repository until the
package is frozen. The later evidence repository will contain the selected
results, rendered documents, environment records, and a frozen manifest.

Earlier document-assembly utilities are isolated in `../archive/`. They are
not part of the current figure, table, or manuscript workflow.

Run `audit_repository_boundary.py` before committing either source repository.
It rejects tracked result directories and generated tables, serialized objects,
figures, documents, logs, and source archives.
