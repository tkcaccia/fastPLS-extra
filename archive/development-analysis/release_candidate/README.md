# Release-candidate backend validation

These scripts compare the candidate `fastPLS` implementation across model
families, precisions, and supported CPU or accelerator backends. They write all
measurements to a caller-provided output directory; result files are not stored
in the `fastPLS` source repository.

`run_backend_matrix.R` records fitting and prediction separately, retains
unsupported routes as explicit errors, tests argmax and LDA for classification,
and captures the route and effective randomized-solver controls reported by the
fitted model. Every row records the resolved package library, package version,
and caller-supplied source identifier; execution stops if R loads `fastPLS`
outside the requested library. Dataset loaders deliberately use fixed, named
benchmark objects so that a result cannot silently switch inputs.

`run_fixed_panel.sh` applies that worker to the eleven fixed biomedical and
image-embedding task objects. A selected-component manifest supplies one
training-selected component count per dataset and PLS family. Precision
conversion is completed before fitting is timed.

`run_nmr_power_audit.R` compares the extreme-response fresh rank-one controls
on the fixed masked NMR task and records the requested and effective controls.
Its default `--controls=automatic` mode does not pass oversampling or power
arguments, so it audits the public package default. Use `--controls=explicit`
only for a separate control experiment.

Example:

```sh
Rscript benchmark/release_candidate/run_backend_matrix.R \
  --library=/path/to/candidate/library \
  --source-id=git-or-archive-identifier \
  --dataset=/path/to/CIFAR100.RData \
  --name=CIFAR-100 \
  --output=/path/outside/the/repository/cifar_backend_matrix.csv \
  --ncomp=50 --repetitions=5 \
  --classifiers=argmax,lda
```
