#!/usr/bin/env bash

# Add current post-launch stages to an existing campaign produced from the same
# frozen fastPLS archive. Run only after the original campaign process exits.

set -uo pipefail

PHASE1_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${CAMPAIGN_ROOT:?Set CAMPAIGN_ROOT to the completed campaign}"
: "${SEED_TASK_ROOT:?Set SEED_TASK_ROOT to the fixed ordinary task objects}"
: "${NMR_INPUT:?Set NMR_INPUT to the prepared NMR RData file}"
: "${IMAGENET_TASK_RDS:?Set IMAGENET_TASK_RDS to the ImageNet descriptor}"

TIMEOUT_SEC="${TIMEOUT_SEC:-1800}"
TESTTHAT_TIMEOUT_SEC="${TESTTHAT_TIMEOUT_SEC:-180}"
EXPECTED_VERSION="${EXPECTED_VERSION:-0.3}"
SOURCE_ID="${SOURCE_ID:-unrecorded}"
BENCHMARK_HOST_ID="${BENCHMARK_HOST_ID:-}"
PACKAGE_ARCHIVE="${PACKAGE_ARCHIVE:-}"
PACKAGE_LIB="${CAMPAIGN_ROOT}/library"
TASK_ROOT="${CAMPAIGN_ROOT}/inputs/tasks"
PYTHON_SITE="${CAMPAIGN_ROOT}/python/site-packages"
RESULTS_ROOT="${CAMPAIGN_ROOT}/results"
LOG_ROOT="${CAMPAIGN_ROOT}/logs"
STATUS_FILE="${CAMPAIGN_ROOT}/stage_status.tsv"
CONTRACT="${PHASE1_ROOT}/config/cmpb_component_contract.csv"
SELECTED="${PHASE1_ROOT}/benchmark/gpu_cross_validation/selected_component_contract.csv"

test -f "${STATUS_FILE}"
test -d "${PACKAGE_LIB}/fastPLS"
test "${BENCHMARK_HOST_ID}" = "chiamaka"
test "$(uname -s)" = "Linux"
command -v nvidia-smi >/dev/null 2>&1
mkdir -p "${LOG_ROOT}" "${CAMPAIGN_ROOT}/provenance"
export R_LIBS_USER="${PACKAGE_LIB}${R_LIBS_USER:+:${R_LIBS_USER}}"

run_stage() {
    local name="$1"
    shift
    local started finished status
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "$@" >"${LOG_ROOT}/${name}.log" 2>&1
    status=$?
    finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\t%s\t%s\t%s\n' \
        "${name}" "${started}" "${finished}" "${status}" >>"${STATUS_FILE}"
    return "${status}"
}

refresh_tasks() {
    FASTPLS_DATA_ROOT="$(dirname "${NMR_INPUT}")" \
    FASTPLS_SEED_TASK_ROOT="${SEED_TASK_ROOT}" \
    FASTPLS_IMAGENET_TASK_RDS="${IMAGENET_TASK_RDS}" \
    Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/current_release_evidence/prepare_figure1_tasks.R" \
        "${CONTRACT}" "${TASK_ROOT}"
}

run_package_tests() {
    if [ -z "${PACKAGE_ARCHIVE}" ] || [ ! -f "${PACKAGE_ARCHIVE}" ]; then
        echo "PACKAGE_ARCHIVE must identify the frozen source archive" >&2
        return 2
    fi
    local check_root="${CAMPAIGN_ROOT}/package_check"
    local source_root package_dir started finished status
    mkdir -p "${check_root}"
    source_root="${check_root}/source"
    mkdir -p "${source_root}"
    tar -xzf "${PACKAGE_ARCHIVE}" -C "${source_root}"
    package_dir="$(tar -tzf "${PACKAGE_ARCHIVE}" | head -n 1 | cut -d/ -f1)"
    started="$(date +%s)"
    (
        cd "${source_root}/${package_dir}/tests" || exit 1
        timeout --signal=TERM "${TESTTHAT_TIMEOUT_SEC}s" env \
            R_LIBS_USER="${R_LIBS_USER}" Rscript --vanilla testthat.R
    )
    status=$?
    finished="$(date +%s)"
    printf 'elapsed_seconds\t%s\nexit_status\t%s\nlimit_seconds\t%s\n' \
        "$((finished - started))" "${status}" "${TESTTHAT_TIMEOUT_SEC}" \
        >"${check_root}/testthat_timing.tsv"
    if [ "${status}" -ne 0 ] ||
       [ "$((finished - started))" -gt "${TESTTHAT_TIMEOUT_SEC}" ]; then
        echo "The compact CRAN testthat suite exceeded its contract." >&2
        return 2
    fi
    (
        cd "${check_root}" || exit 1
        timeout --signal=TERM "${TIMEOUT_SEC}s" env \
            R_LIBS_USER="${R_LIBS_USER}" \
            R CMD check --no-manual "${PACKAGE_ARCHIVE}"
    )
}

run_python_independent() {
    "${PHASE1_ROOT}/scripts/run_python_independent_campaign.sh" \
        "${PHASE1_ROOT}" "${CAMPAIGN_ROOT}" "${PYTHON_SITE}" \
        "${TIMEOUT_SEC}"
}

run_selected_backends() {
    python3 \
        "${PHASE1_ROOT}/benchmark/current_release_evidence/run_selected_backends.py" \
        --library "${PACKAGE_LIB}" --task-dir "${TASK_ROOT}" \
        --selected "${SELECTED}" \
        --output "${RESULTS_ROOT}/figure2/selected_cpu_cuda.csv" \
        --backends cpu cuda --precision float32 --classifiers argmax \
        --repetitions 3 --timeout-sec "${TIMEOUT_SEC}" \
        --source-id "${SOURCE_ID}" --expected-version "${EXPECTED_VERSION}"
}

run_training_component_selection() {
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" \
    FASTPLS_COMPONENT_TASK_ROOT="${TASK_ROOT}" \
    FASTPLS_COMPONENT_GRID_CONTRACT="${PHASE1_ROOT}/config/cmpb_selection_grids.csv" \
    FASTPLS_COMPONENT_KFOLD=10 FASTPLS_COMPONENT_SEED=123 \
    FASTPLS_COMPONENT_NCORES=1 FASTPLS_COMPONENT_PRECISION=float32 \
    FASTPLS_BENCHMARK_TIMEOUT="${TIMEOUT_SEC}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/run_current_component_selection.R" \
        "${RESULTS_ROOT}/component_selection/ordinary"
}

run_nmr_training_selection() {
    local family="$1"
    timeout --signal=TERM "${TIMEOUT_SEC}s" env \
        FASTPLS_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/benchmark_nmr_component_selection.R" \
        --input="${NMR_INPUT}" \
        --out="${RESULTS_ROOT}/component_selection/nmr_${family}" \
        --backend=cuda --method="${family}" --precision=float32 \
        --seeds=123,456,789,1011,2027 \
        --grid=1,2,3,5,8,10,25,50,75,100,125,150,165,175,200,250,300 \
        --validation_fraction=0.2 --fit_seed=123
}

validation() {
    local script="$1"
    local output="$2"
    shift 2
    timeout --signal=TERM "${TIMEOUT_SEC}s" env \
        FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/${script}" "$@" --out="${output}"
}

run_stage package_test_suite run_package_tests || exit $?
run_stage prepare_tasks refresh_tasks || exit $?
run_stage record_environment \
    env BENCHMARK_HOST_ID="${BENCHMARK_HOST_ID}" \
    "${PHASE1_ROOT}/scripts/record_campaign_environment.sh" \
    "${PACKAGE_LIB}" "${CAMPAIGN_ROOT}/provenance" || exit $?
run_stage figure1_python run_python_independent || true
run_stage figure2_selected_backends run_selected_backends || true
run_stage training_component_selection run_training_component_selection || true
run_stage nmr_selection_plssvd run_nmr_training_selection plssvd || true
run_stage nmr_selection_simpls run_nmr_training_selection simpls || true
run_stage validation_simpls_dense validation \
    benchmark_simpls_exact_reference.R \
    "${RESULTS_ROOT}/validation/simpls_dense_reference" \
    --root="${PHASE1_ROOT}" || true
run_stage validation_rsvd_cpu validation \
    benchmark_rsvd_current_qualification.R \
    "${RESULTS_ROOT}/validation/rsvd_qualification_cpu" --backend=cpu || true
run_stage validation_rsvd_cuda validation \
    benchmark_rsvd_current_qualification.R \
    "${RESULTS_ROOT}/validation/rsvd_qualification_cuda" --backend=cuda || true
run_stage validation_opls_kernel_estimator validation \
    benchmark_opls_kernel_estimator_validation.R \
    "${RESULTS_ROOT}/validation/opls_kernel_estimator" \
    --root="${PHASE1_ROOT}" || true
run_stage validation_opls_kernel_settings validation \
    benchmark_opls_kernel_setting_reliability.R \
    "${RESULTS_ROOT}/validation/opls_kernel_settings" \
    --root="${PHASE1_ROOT}" || true
run_stage validation_precision_cpu validation \
    benchmark_float32_backend_agreement.R \
    "${RESULTS_ROOT}/validation/precision_cpu" --backend=cpu || true
run_stage validation_precision_cuda validation \
    benchmark_float32_backend_agreement.R \
    "${RESULTS_ROOT}/validation/precision_cuda" --backend=cuda || true
run_stage formal_invariants "${PHASE1_ROOT}/formal/lean/check.sh" || true
run_stage campaign_audit python3 \
    "${PHASE1_ROOT}/scripts/audit_cmpb_campaign.py" "${CAMPAIGN_ROOT}"
