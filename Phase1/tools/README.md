# CMPB figure table and manuscript tools

This directory contains the publication-specific tools used to summarize Phase
1 evidence, generate figures and tables, and audit the CMPB manuscript and
Supplementary Material. Run commands from the `Phase1` directory.

Principal builders are:

- `build_figure1_six_panel.R` for the independent-software figure;
- `../scripts/build_cmpb_campaign_assets.sh` for the complete audited figure
  and table asset set;
- `assemble_cmpb_documents.py` for deterministic insertion of Table 1,
  Figures 1-4, Supplementary Tables S1-S8, and Supplementary Figures S1-S14;
- `../benchmark/current_release_evidence/build_figure2_with_cv.R` for the CPU/CUDA
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
`audit_cmpb_pseudocode_contract.py` checks the assembled main and supplementary
algorithm tables against the active C++ source contracts for PLS-SVD, the
SIMPLS-family route, OPLS, kernel PLS and sufficient-statistics cross-validation.
Run it after document assembly so notation or procedural edits cannot drift from
the frozen package source.
`audit_cmpb_document_layout.py` verifies that every assembled DOCX section is
portrait and retains continuous line numbering at every line.
