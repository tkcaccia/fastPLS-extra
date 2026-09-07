# Current-release supplementary evidence

These scripts produce the precision and solver comparisons used to audit the
fastPLS 0.99.40 manuscript. Results must be written outside the Git checkout by
setting `FASTPLS_RESULTS_ROOT`.

`run_precision.py` compares float32 and float64 after conversion, so conversion
time is not part of fitting or prediction. It starts process-memory monitoring
only after the prepared matrices are resident and garbage collection has run.

`run_solver_comparison.py` compares public rSVD with the CPU float64 IRLBA
companion while holding data, PLS family, component count, preprocessing, and
prediction output fixed. IRLBA remains a GPL comparison route in fastPLSextra.

The verified one-, two-, and four-thread experiment remains in
`benchmark/multicore_scaling/` and requires an OpenBLAS-linked fastPLS build.

`run_figure1_fastpls.py` regenerates the two current fastPLS rows in the
independent-implementation figure using ten fresh float32 CPU processes per
dataset and classifier. Component counts are read from the current release
panel supplied with `--selected-panel`; the script does not select components
from held-out responses. Both rows fit centred SIMPLS with rSVD,
`oversample = 32`, `power = 5`, and `seed = 123`; they differ only in whether
argmax or LDA maps the retained scores to class labels. The worker requests no
fitted responses, variance summaries, projections, or loading matrices.
