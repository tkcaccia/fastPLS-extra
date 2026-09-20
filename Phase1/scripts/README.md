# CMPB workflow launchers

These launchers orchestrate the runners in `../benchmark`. Run them from the
`Phase1` directory after loading `../config/benchmark.env` from the repository
root. Remote launchers require explicit package-library, data, and result roots
and must not write generated evidence into either Git repository.

Current entry points include:

- `run_cmpb_release_campaign.sh` for the complete one-archive Linux CPU/CUDA
  evidence campaign;
- `finalize_cmpb_campaign.sh` for replacing any provisional independent-R
  exclusions with bounded attempts, validating the vignette-enabled archive,
  rebuilding the pinned Lean proofs, rerunning the strict audit, and building
  assets only after the primary campaign process has stopped. Set
  `DISTRIBUTION_ARCHIVE` to the built source archive; finalization proves
  package-code equivalence to the benchmark archive before accepting its clean
  `R CMD check` result;
- `audit_cmpb_campaign.py` for strict coverage, no-skip, numerical-tolerance,
  source, platform, and component-grid checks;
- `build_cmpb_campaign_assets.sh` and `build_cmpb_campaign_tables.py` for the
  final audited figures, vector files, source tables, and asset checksums; the
  asset builder uses a fresh staging directory and publishes it only after
  `audit_cmpb_assets.py` verifies the exact numbered inventory and core table
  dimensions;
- `build_cmpb_submission.sh` for rebuilding those assets, assembling the main
  manuscript and supplement from their DOCX templates, and running every
  quantitative-text, cross-reference, reference-order, language/notation,
  pseudocode-contract, and document-layout audit. PDF rendering and visual
  page inspection remain explicit final checks after this command succeeds;
- `summarize_cmpb_narrative.py` for manuscript-ready quantitative facts derived
  from those same audited figure and table sources;
- `verify_distribution_archive_equivalence.py` for proving that a
  vignette-enabled distribution archive preserves the benchmarked package code
  while adding only generated documentation and build metadata;
- `remote_run_pls_package_comparison.sh` for the independent R comparison;
- `run_controlled_scaling.sh` for numerical and rSVD qualification;
- `run_current_component_path_remote.sh` for held-out component paths;
- `run_current_release_ikpls_remote.sh` for the IKPLS comparison;
- `run_candidate_nmr_cuda.sh`, `run_current_release_nmr_remote.sh`, and
  `run_nmr_deposited_reference.sh` for the NMR evidence;
- `run_imagenet_current_fused_lda_remote.sh` for the ImageNet paths.

One-off queue orchestration and superseded release-specific launchers are in
`../../archive/development-analysis/scripts` and are not current evidence
generators.
