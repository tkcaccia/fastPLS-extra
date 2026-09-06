# fastPLS companion boundary

`fastPLS-extra` has two deliberately separate responsibilities:

1. It provides GPL-3 integration for the legacy IRLBA solver without copying
   that solver into the MIT-licensed `fastPLS` package.
2. It contains reproducible benchmark and publication-generation source code.

The dependency direction is always `fastPLS-extra -> fastPLS`. The main
package never loads or links against this companion package. Native rSVD,
PLS-SVD, SIMPLS, OPLS, kernel PLS, prediction, classification, and
cross-validation remain implemented in `fastPLS`.

Generated benchmark evidence is not versioned in either source repository.
During development it is written below `FASTPLS_RESULTS_ROOT`. After the main
package is frozen, selected evidence will be deposited in a separate immutable
results repository with its package version, task fingerprints, controls,
seeds, hardware metadata, and output contract.

Historical extraction snapshots are retained locally and are not part of this
repository. The distributed source files keep their original licensing notices
and the package-level license is GPL-3.
