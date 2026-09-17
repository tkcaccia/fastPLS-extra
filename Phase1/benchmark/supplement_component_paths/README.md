# Supplementary component-path benchmark

This workflow regenerates Supplementary Figures S1-S12 with one frozen
fastPLS release. Numerical results are written outside this repository.

## Selection

For the eleven general benchmark datasets, component counts are selected from
training data only with ten fixed folds (`seed = 123`). Classification evaluates
both argmax and LDA at every admissible component count and selects the
component/classifier pair with the greatest pooled out-of-fold accuracy.
Regression selects the component count with the smallest pooled out-of-fold
RMSD. Ties retain the first (smallest-component) entry returned by the ordered
grid. PLS-SVD classification is limited to `q - 1` components. The reproducible
TCGA-HNSC float32 path is limited to 42 components because larger prefixes
terminate at the observed numerical rank under the fixed folds. Other intrinsic
rank limits are recorded. A selected count at the largest evaluated grid value
or an intrinsic rank limit is labelled explicitly rather than called an
unconstrained optimum. OPLS uses one orthogonal component and kernel PLS uses
the linear kernel.

The canonical NMR training set uses five fixed 80/20 training-only splits
(`123, 456, 789, 1011, 2027`) for component selection. That selection remains
separate from Figure S12. For Figure S12, each maximal model is fitted only on
the predefined 1,200-spectrum training partition. Every requested prefix is
then scored against the predefined 321-spectrum test partition, and test RMSD
is summarized over three fixed rSVD seeds (`7, 29, 123`). Dotted lines show the
component counts selected from the training-only analysis; test responses are
never used for selection or fitting.

## Component paths

Figures S1-S11 compare PLS-SVD, SIMPLS, OPLS and linear kernel PLS on matched
float32 inputs. Each point is the median of three fresh-process
fitting-plus-prediction runs. Mac CPU and Metal are measured on the same Apple
computer; Linux CPU and CUDA are measured on the same CUDA workstation.
Explicit accelerator requests fail instead of falling back to CPU. The
architecture palette is:

- Mac CPU: `#0072B2`
- Metal: `#E69F00`
- Linux CPU: `#009E73`
- CUDA: `#CC79A7`

Argmax uses a solid line and LDA a dashed line. Regression paths use a solid
line because classification heads do not apply.

## Scripts

- `../run_current_component_selection.R`: training-only selection for the
  eleven general tasks.
- `../run_current_component_path.R`: fresh-process CPU/accelerator paths.
- `../summarize_current_component_paths.R`: combines CUDA and Metal outputs and
  writes Figures S1-S11.
- `../benchmark_nmr_component_selection.R`: repeated NMR selection.
- `run_nmr_test_component_path.R`: fits the four NMR component paths on the
  predefined training partition and scores held-out test predictions.
- `run_nmr_backend_component_paths.py`: runs every NMR component count in a
  monitored fresh process on the selected CPU and accelerator routes.
- `plot_nmr_component_selection.R`: writes Figure S12 from held-out test RMSD,
  fitting-plus-prediction time, incremental peak host RSS and the independently
  computed training-only component selections.
- `validate_nmr_prefix_scoring.R`: verifies the response-blocked NMR scoring
  path against public `predict()` for all four PLS families.
