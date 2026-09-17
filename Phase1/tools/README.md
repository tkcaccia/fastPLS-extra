# CMPB figure table and manuscript tools

This directory contains the publication-specific tools used to summarize Phase
1 evidence, generate figures and tables, and audit the CMPB manuscript and
Supplementary Material. Run commands from the `Phase1` directory.

Principal builders are:

- `build_figure1_six_panel.R` for the independent-software figure;
- `update_figure2_documents.py` and `add_cv_cpu_gpu_figure.py` for the CPU/CUDA
  and cross-validation panels;
- `build_nmr_figure3_family_components.R` for the NMR figure;
- `build_supplement_cuda_ikpls_figure.R` and
  `build_supplement_argmax_accelerator_figure.R` for supplementary comparisons.

The citation, notation, language, cross-reference, and document audits use the
`audit_cmpb_*` and `audit_document_crossrefs.py` scripts. Generated figures,
tables, documents, and rendered pages must be written to the external results
or document root, not committed here.

Superseded version-specific document assembly and one-off revision utilities
are retained under `../../archive/development-analysis/tools`.
