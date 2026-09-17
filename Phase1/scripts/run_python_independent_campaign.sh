#!/usr/bin/env bash

# Run the independent scikit-learn rows after the portable NumPy inputs have
# been exported by the authoritative CMPB campaign.

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 PHASE1_ROOT CAMPAIGN_ROOT PYTHON_SITE TIMEOUT_SECONDS" >&2
    exit 2
fi

phase1_root="$(cd "$1" && pwd)"
campaign_root="$(cd "$2" && pwd)"
python_site="$(cd "$3" && pwd)"
timeout_sec="$4"

PYTHONPATH="${python_site}" PYTHON_PLS_BENCH_PYTHON=python3 python3 \
    "${phase1_root}/benchmark/ikpls_cross_language/run_python_pls_panel.py" \
    --inputs "${campaign_root}/inputs/ikpls_standard" \
    --results "${campaign_root}/results/figure1/python_standard" \
    --repetitions 10 --timeout "${timeout_sec}"

PYTHONPATH="${python_site}" PYTHON_PLS_BENCH_PYTHON=python3 python3 \
    "${phase1_root}/benchmark/ikpls_cross_language/run_python_pls_large.py" \
    --data-root "${campaign_root}/inputs/ikpls_large" \
    --results "${campaign_root}/results/figure1/python_large" \
    --datasets nmr,imagenet --nmr-components 50 --imagenet-components 1000 \
    --repetitions 1 --timeout "${timeout_sec}"
