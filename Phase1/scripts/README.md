# CMPB workflow launchers

These launchers orchestrate the runners in `../benchmark`. Run them from the
`Phase1` directory after loading `../config/benchmark.env` from the repository
root. Remote launchers require explicit package-library, data, and result roots
and must not write generated evidence into either Git repository.

Current entry points include:

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
