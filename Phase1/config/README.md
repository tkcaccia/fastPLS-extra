# CMPB release contract

`cmpb_component_contract.csv` is the single component-count contract used by
all Phase 1 fixed-workload benchmarks. The values are the counts reported in
the CMPB manuscript. Training-only component-path analyses remain separate and
must report if a rerun selects a different value within its evaluated grid.

Run `python3 validate_contract.py` from this directory to regenerate and check
the derived long-format and Figure 1 contracts. The generated files are kept
under version control because they are inputs to independent benchmark tools.

`independent_method_contract.csv` and `measurement_contract.csv` define the
software adapters and measurement rules used to regenerate Supplementary
Tables S3 and S4. Package versions are joined from the frozen campaign during
asset assembly rather than stored in these contracts.

`cmpb_selection_grids.csv` is the executable version of the candidate grids
reported in the Supplement. Training-only selection and held-out path figures
must both read this contract; retained benchmark counts remain in
`cmpb_component_contract.csv`.
