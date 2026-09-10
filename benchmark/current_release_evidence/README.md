# Current-release supplementary evidence

These scripts produce the precision and solver comparisons used to audit the
fastPLS 0.99.42 manuscript. Results must be written outside the Git checkout by
setting `FASTPLS_RESULTS_ROOT`.

`run_precision.py` compares float32 and float64 after conversion, so conversion
time is not part of fitting or prediction. It starts process-memory monitoring
only after the prepared matrices are resident and garbage collection has run.

`run_solver_comparison.py` compares public rSVD with the CPU float64 IRLBA
companion while holding data, PLS family, component count, preprocessing, and
prediction output fixed. IRLBA remains a GPL comparison route in fastPLSextra.

The verified one-, two-, and four-thread experiment remains in
`benchmark/multicore_scaling/` and requires an OpenBLAS-linked fastPLS build.

The public `metal` backend is the fixed CPU/Metal operation split. Fitting
products involving the training sample matrix execute through persistent Metal workspaces;
preprocessing, reduced decompositions, sequential PLS state, prediction, and
report assembly remain on CPU. The benchmark never substitutes an all-CPU
route according to dataset shape.

`run_figure1_fastpls.py` regenerates the four current fastPLS rows in the
independent-implementation figure using ten fresh float32 CPU processes per
dataset, PLS family, and classifier. Component counts are read by family from
the current release panel supplied with `--selected-panel`; the script does not
select components from held-out responses. The rows fit centred SIMPLS or
PLS-SVD with rSVD, `oversample = 32`, `power = 5`, and `seed = 123`, followed
by argmax or LDA classification. The worker requests no fitted responses,
variance summaries, projections, or loading matrices.
Supply the release with `--package-version`; each worker verifies the loaded
package before fitting, so the same scripts can be reused without relabelling
older evidence.

`summarize_figure1.R` reduces the fresh-process output to one row per dataset,
PLS family, and classifier, retaining timing quartiles, predictive metrics,
successful-run counts, and baseline-corrected peak host memory.
