# Corrected Tabula Muris benchmark

This benchmark requires the merged droplet/FACS Tabula Muris PCA50 object with
100,102 cells, 50 predictors, 32 complete class labels, and no missing labels.
`helpers_dataset_memory_compare.R` validates the dimensions and exact class
counts and rejects any nonmatching object. It does not infer that absent cells
are unlabelled or remove rows.
All classification loaders used by this workflow also require one nonblank
label per predictor row and reject missing labels or held-out classes that are
absent from training; benchmark scripts never repair these cases by dropping
samples.

The split is stratified with seed 123 and contains 50,043 training cells and
50,059 held-out cells. Component counts are selected from training data for
each fastPLS family before the package panel is run. Raw results must remain
outside the Git repository.

Each method is run in a monitored process. After the first hard failure or
10,000-second timeout, later repetitions of that method are recorded as
skipped rather than silently omitted. If `mixOmics::plsda` reaches this limit,
the more complex `mixOmics::splsda` route is recorded as not evaluated after
the related package timeout; independent implementations continue normally.

```sh
FASTPLS_TABULA_RDATA=/path/to/TabulaMuris_float32.RData \
Rscript benchmark/tabula_corrected/prepare_task.R \
    /path/to/tasks/tabula_task.rds /path/to/task_manifest

FASTPLS_BENCH_LIB=/path/to/Rlib \
FASTPLS_COMPONENT_TASK_ROOT=/path/to/tasks \
FASTPLS_COMPONENT_DATASETS=tabula \
FASTPLS_COMPONENT_FAMILIES=plssvd,simpls,opls,kernelpls \
Rscript benchmark/run_current_component_selection.R \
    /path/to/component_selection

python3 benchmark/tabula_corrected/run_r_panel.py \
    --repo . --library /path/to/Rlib --tasks /path/to/tasks \
    --selected /path/to/component_selection/selected_components.csv \
    --results /path/to/r_panel --precision float32 --repetitions 10
```

Use `benchmark/ikpls_cross_language/export_panel_float32.R`, `run_panel.py`,
and `run_python_pls_panel.py` for the component-matched IKPLS,
nirs4all-methods, and scikit-learn rows.
