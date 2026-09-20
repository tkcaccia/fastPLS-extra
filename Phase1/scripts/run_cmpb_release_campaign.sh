#!/usr/bin/env bash

# Run the complete CMPB evidence campaign from one frozen fastPLS archive.
# Generated results are always written outside the Git checkout. Individual
# workers enforce a 1,800-second limit and retain timeout/failure records.

set -uo pipefail

PHASE1_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PHASE1_ROOT}"
: "${PACKAGE_ARCHIVE:?Set PACKAGE_ARCHIVE to the frozen fastPLS source archive}"
: "${CAMPAIGN_ROOT:?Set CAMPAIGN_ROOT outside every Git checkout}"
: "${NMR_INPUT:?Set NMR_INPUT to the prepared NMR RData file}"
: "${IMAGENET_TASK_RDS:?Set IMAGENET_TASK_RDS to the ImageNet task descriptor}"

TIMEOUT_SEC="${TIMEOUT_SEC:-1800}"
TESTTHAT_TIMEOUT_SEC="${TESTTHAT_TIMEOUT_SEC:-180}"
EXPECTED_VERSION="${EXPECTED_VERSION:-0.3}"
EXPECTED_SHA256="${EXPECTED_SHA256:-}"
SOURCE_ID="${SOURCE_ID:-unrecorded}"
BENCHMARK_HOST_ID="${BENCHMARK_HOST_ID:-}"
PACKAGE_LIB="${CAMPAIGN_ROOT}/library"
TASK_ROOT="${CAMPAIGN_ROOT}/inputs/tasks"
PYTHON_SITE="${PYTHON_SITE:-${CAMPAIGN_ROOT}/python/site-packages}"
REUSE_PYTHON_SITE="${REUSE_PYTHON_SITE:-0}"
OPENBLAS_ROOT="${OPENBLAS_ROOT:-${CAMPAIGN_ROOT}/dependencies/openblas}"
EXPECTED_OPENBLAS_VERSION="${EXPECTED_OPENBLAS_VERSION:-0.3.29}"
EXPECTED_OPENBLAS_CORE="${EXPECTED_OPENBLAS_CORE:-Haswell}"
OPENBLAS_TARGET="${OPENBLAS_TARGET:-HASWELL}"
LEAN_ELAN_HOME="${LEAN_ELAN_HOME:-${CAMPAIGN_ROOT}/dependencies/elan}"
CAMPAIGN_SCOPE="${CAMPAIGN_SCOPE:-full}"
FIGURE1_EVIDENCE_ROOT="${FIGURE1_EVIDENCE_ROOT:-}"
RESULTS_ROOT="${CAMPAIGN_ROOT}/results"
LOG_ROOT="${CAMPAIGN_ROOT}/logs"
STATUS_FILE="${CAMPAIGN_ROOT}/stage_status.tsv"
CONTRACT="${PHASE1_ROOT}/config/cmpb_component_contract.csv"
SELECTED="${PHASE1_ROOT}/benchmark/gpu_cross_validation/selected_component_contract.csv"

mkdir -p "${PACKAGE_LIB}" "${TASK_ROOT}" "${RESULTS_ROOT}" "${LOG_ROOT}"
export R_LIBS_USER="${PACKAGE_LIB}${R_LIBS_USER:+:${R_LIBS_USER}}"
printf 'stage\tstarted_utc\tfinished_utc\texit_status\n' >"${STATUS_FILE}"

run_stage() {
    local name="$1"
    shift
    local started finished status
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[START] ${name} ${started}"
    "$@" >"${LOG_ROOT}/${name}.log" 2>&1
    status=$?
    finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\t%s\t%s\t%s\n' \
        "${name}" "${started}" "${finished}" "${status}" >>"${STATUS_FILE}"
    echo "[END] ${name} status=${status} ${finished}"
    LAST_STAGE_STATUS="${status}"
    return 0
}

run_required_stage() {
    run_stage "$@"
    if [ "${LAST_STAGE_STATUS}" -ne 0 ]; then
        echo "Required stage $1 failed; no benchmark results are valid." >&2
        exit "${LAST_STAGE_STATUS}"
    fi
}

verify_source() {
    local observed
    if [ "${BENCHMARK_HOST_ID}" != "chiamaka" ]; then
        echo "CMPB benchmarks must run on the Chiamaka host." >&2
        return 2
    fi
    if [ "$(uname -s)" != "Linux" ]; then
        echo "CMPB benchmarks require the Chiamaka Linux environment." >&2
        return 2
    fi
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "CMPB benchmarks require the Chiamaka CUDA environment." >&2
        return 2
    fi
    observed="$(sha256sum "${PACKAGE_ARCHIVE}" | awk '{print $1}')"
    if [ -n "${EXPECTED_SHA256}" ] && [ "${observed}" != "${EXPECTED_SHA256}" ]; then
        echo "Archive SHA-256 mismatch" >&2
        return 2
    fi
    printf '%s  %s\n' "${observed}" "${PACKAGE_ARCHIVE}" \
        >"${CAMPAIGN_ROOT}/source_archive.sha256"
    python3 "${PHASE1_ROOT}/config/validate_contract.py"
}

install_package() {
    FASTPLS_USE_OPENBLAS=1 OPENBLAS_ROOT="${OPENBLAS_ROOT}" \
        R CMD INSTALL --preclean --library="${PACKAGE_LIB}" "${PACKAGE_ARCHIVE}"
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla -e '
.libPaths(c(Sys.getenv("FASTPLS_BENCH_LIB"), .libPaths()))
library(fastPLS)
stopifnot(as.character(packageVersion("fastPLS")) == Sys.getenv("EXPECTED_VERSION"))
stopifnot(identical(fastPLS_blas(details = FALSE), "OpenBLAS"))
cat(normalizePath(find.package("fastPLS")), "\n")
print(fastPLS_blas())
'
}

prepare_dependencies() {
    local source_root="${CAMPAIGN_ROOT}/dependencies/OpenBLAS-${EXPECTED_OPENBLAS_VERSION}"
    mkdir -p "${CAMPAIGN_ROOT}/dependencies"
    if [ ! -e "${OPENBLAS_ROOT}/lib/libopenblas.so" ]; then
        rm -rf "${source_root}"
        git clone --depth 1 --branch "v${EXPECTED_OPENBLAS_VERSION}" \
            https://github.com/OpenMathLib/OpenBLAS.git "${source_root}" || \
            return $?
        make -C "${source_root}" -j8 \
            DYNAMIC_ARCH=0 TARGET="${OPENBLAS_TARGET}" USE_OPENMP=0 \
            NUM_THREADS=64 NO_AFFINITY=1 BINARY=64 INTERFACE64=0 || \
            return $?
        make -C "${source_root}" \
            DYNAMIC_ARCH=0 TARGET="${OPENBLAS_TARGET}" USE_OPENMP=0 \
            NUM_THREADS=64 NO_AFFINITY=1 BINARY=64 INTERFACE64=0 \
            PREFIX="${OPENBLAS_ROOT}" install || return $?
    fi
    test -e "${OPENBLAS_ROOT}/include/openblas_config.h"
    test -e "${OPENBLAS_ROOT}/lib/libopenblas.so"
    FASTPLS_BENCH_BLAS_DESCRIPTION="$(
        python3 "${PHASE1_ROOT}/config/inspect_openblas.py" \
            --library "${OPENBLAS_ROOT}/lib/libopenblas.so" \
            --require-version "${EXPECTED_OPENBLAS_VERSION}" \
            --require-core "${EXPECTED_OPENBLAS_CORE}"
    )" || return 2
    export FASTPLS_BENCH_BLAS_DESCRIPTION
    printf '%s\n' "${FASTPLS_BENCH_BLAS_DESCRIPTION}" \
        >"${CAMPAIGN_ROOT}/openblas_configuration.txt"
FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla -e '
.libPaths(c(Sys.getenv("FASTPLS_BENCH_LIB"), .libPaths()))
cran_required <- c(
    "data.table", "float", "testthat", "knitr", "rmarkdown", "pls",
    "plsgenomics", "mdatools", "plsdepot", "pcv", "chemometrics", "spls",
    "BiocManager"
)
missing_cran <- cran_required[
    !vapply(cran_required, requireNamespace, logical(1L), quietly = TRUE)
]
if (length(missing_cran)) {
    install.packages(
        missing_cran,
        lib = Sys.getenv("FASTPLS_BENCH_LIB"),
        repos = "https://cloud.r-project.org",
        type = "source"
    )
}
stopifnot(all(vapply(
    cran_required, requireNamespace, logical(1L), quietly = TRUE
)))
if (!requireNamespace("mixOmics", quietly = TRUE)) {
    BiocManager::install(
        "mixOmics",
        lib = Sys.getenv("FASTPLS_BENCH_LIB"),
        ask = FALSE,
        update = FALSE,
        type = "source"
    )
}
stopifnot(requireNamespace("mixOmics", quietly = TRUE))
cat(as.character(packageVersion("float")), "\n")
'
}

prepare_lean() {
    local elan_home="${LEAN_ELAN_HOME}"
    local installer="${CAMPAIGN_ROOT}/dependencies/elan-init.sh"
    if [ ! -x "${elan_home}/bin/elan" ]; then
        curl --proto '=https' --tlsv1.2 -sSf \
            https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
            -o "${installer}" || return $?
        ELAN_HOME="${elan_home}" sh "${installer}" \
            -y --no-modify-path --default-toolchain none || return $?
    fi
    export ELAN_HOME="${elan_home}"
    export PATH="${ELAN_HOME}/bin:${PATH}"
    (
        cd "${PHASE1_ROOT}/formal/lean" || exit 1
        lake exe cache get
    ) || return $?
    elan --version >"${CAMPAIGN_ROOT}/lean_environment.txt"
    (
        cd "${PHASE1_ROOT}/formal/lean" || exit 1
        lean --version
    ) >>"${CAMPAIGN_ROOT}/lean_environment.txt"
}

run_package_tests() {
    local check_root="${CAMPAIGN_ROOT}/package_check"
    local source_root package_dir started finished status check_log
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
            FASTPLS_USE_OPENBLAS=1 OPENBLAS_ROOT="${OPENBLAS_ROOT}" \
            R_LIBS_USER="${R_LIBS_USER}" \
            R CMD check --no-manual "${PACKAGE_ARCHIVE}"
    ) || return $?
    check_log="${check_root}/fastPLS.Rcheck/00check.log"
    if [ ! -f "${check_log}" ] || \
       ! grep -qx 'Status: OK' "${check_log}"; then
        echo "R CMD check did not report Status: OK." >&2
        return 2
    fi
}

prepare_tasks() {
    FASTPLS_DATA_ROOT="$(dirname "${NMR_INPUT}")" \
    FASTPLS_IMAGENET_TASK_RDS="${IMAGENET_TASK_RDS}" \
    Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/current_release_evidence/prepare_figure1_tasks.R" \
        "${CONTRACT}" "${TASK_ROOT}" || return $?
    cp "${IMAGENET_TASK_RDS}" "${TASK_ROOT}/imagenet_task.rds"
    Rscript --vanilla \
        "${PHASE1_ROOT}/scripts/write_prepared_task_manifest.R" \
        "${TASK_ROOT}"
}

prepare_python() {
    if [ "${REUSE_PYTHON_SITE}" != "1" ]; then
        mkdir -p "${PYTHON_SITE}"
        python3 -m pip install --upgrade --target "${PYTHON_SITE}" -r \
            "${PHASE1_ROOT}/benchmark/ikpls_cross_language/requirements.txt" || \
            return $?
        python3 -m pip install --upgrade --target "${PYTHON_SITE}" -r \
            "${PHASE1_ROOT}/benchmark/ikpls_cross_language/requirements-cuda.txt" || \
            return $?
    elif [ ! -d "${PYTHON_SITE}" ]; then
        echo "The requested reusable Python site does not exist" >&2
        return 2
    fi
    PYTHONPATH="${PYTHON_SITE}" python3 - <<'PY' || return $?
import ikpls
import jax
import numpy
import pandas
import psutil
import sklearn

devices = jax.devices()
if not any(device.platform == "gpu" for device in devices):
    raise RuntimeError(f"CUDA JAX device is unavailable: {devices}")
expected = {
    "ikpls": "6.1.2",
    "jax": "0.6.2",
    "numpy": "2.2.6",
    "pandas": "2.3.3",
    "psutil": "7.1.3",
    "sklearn": "1.7.2",
}
observed = {
    "ikpls": getattr(ikpls, "__version__", "unknown"),
    "jax": jax.__version__,
    "numpy": numpy.__version__,
    "pandas": pandas.__version__,
    "psutil": psutil.__version__,
    "sklearn": sklearn.__version__,
}
if observed != expected:
    raise RuntimeError(f"Python dependency mismatch: {observed}")
print(observed)
print("jax_devices", devices)
PY
    PYTHONPATH="${PYTHON_SITE}" python3 -m pip freeze \
        --path "${PYTHON_SITE}" >"${CAMPAIGN_ROOT}/python_requirements_frozen.txt"
}

run_figure1_fastpls() {
    python3 \
        "${PHASE1_ROOT}/benchmark/current_release_evidence/run_figure1_fastpls.py" \
        --library "${PACKAGE_LIB}" --tasks "${TASK_ROOT}" \
        --component-contract "${CONTRACT}" \
        --output "${RESULTS_ROOT}/figure1/fastpls_cpu_raw.csv" \
        --package-version "${EXPECTED_VERSION}" --repetitions 10 \
        --methods simpls
}

run_figure1_imagenet() {
    timeout --signal=TERM "${TIMEOUT_SEC}s" \
        "${PHASE1_ROOT}/benchmark/current_release_evidence/run_figure1_imagenet_cpu.sh" \
        "${PACKAGE_LIB}" "${TASK_ROOT}/imagenet_task.rds" \
        "${RESULTS_ROOT}/figure1/imagenet_cpu" \
        "${PHASE1_ROOT}/benchmark/current_release_evidence/figure1_imagenet_cpu_worker.R"
}

run_figure1_independent_r() {
    python3 \
        "${PHASE1_ROOT}/benchmark/current_release_evidence/run_figure1_r_packages.py" \
        --repo "${PHASE1_ROOT}" --library "${PACKAGE_LIB}" \
        --tasks "${TASK_ROOT}" --contract "${CONTRACT}" \
        --results "${RESULTS_ROOT}/figure1/independent_r" \
        --repetitions 3 --timeout "${TIMEOUT_SEC}" \
        --memory-limit-mib 28672
}

prepare_ikpls_inputs() {
    local standard_contract="${CAMPAIGN_ROOT}/inputs/standard_contract.csv"
    local standard_inputs="${CAMPAIGN_ROOT}/inputs/ikpls_standard"
    local large_inputs="${CAMPAIGN_ROOT}/inputs/ikpls_large"
    awk -F, 'NR == 1 || ($1 != "nmr" && $1 != "imagenet")' \
        "${CONTRACT}" >"${standard_contract}" || return $?
    Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/export_panel_float32.R" \
        "${TASK_ROOT}" "${standard_contract}" "${standard_inputs}" || return $?
    mkdir -p "${large_inputs}/nmr" "${large_inputs}/imagenet"
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/export_large_float32.R" \
        nmr "${NMR_INPUT}" "${large_inputs}/nmr" || return $?
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/export_large_float32.R" \
        imagenet "${TASK_ROOT}/imagenet_task.rds" \
        "${large_inputs}/imagenet" || return $?
    PYTHONPATH="${PYTHON_SITE}" python3 \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/prepare_imagenet_float32.py" \
        "${large_inputs}/imagenet" 10000 || return $?
    local cuda_inputs="${CAMPAIGN_ROOT}/inputs/ikpls_cuda"
    mkdir -p "${cuda_inputs}"
    for dataset_path in "${standard_inputs}"/*; do
        [ -d "${dataset_path}" ] || continue
        ln -sfn "${dataset_path}" "${cuda_inputs}/$(basename "${dataset_path}")"
    done
    ln -sfn "${large_inputs}/nmr" "${cuda_inputs}/nmr"
    ln -sfn "${large_inputs}/imagenet" "${cuda_inputs}/imagenet"
}

run_ikpls() {
    prepare_ikpls_inputs || return $?
    PYTHONPATH="${PYTHON_SITE}" IKPLS_PYTHON=python3 python3 \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/run_panel.py" \
        --inputs "${CAMPAIGN_ROOT}/inputs/ikpls_standard" \
        --results "${RESULTS_ROOT}/figure1/ikpls_standard" \
        --repetitions 10 --timeout "${TIMEOUT_SEC}" || return $?
    PYTHONPATH="${PYTHON_SITE}" python3 \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/run_large_float32.py" \
        --data-root "${CAMPAIGN_ROOT}/inputs/ikpls_large" \
        --results "${RESULTS_ROOT}/figure1/ikpls_large" \
        --datasets nmr,imagenet --nmr-components 50 \
        --imagenet-components 1000 --timeout "${TIMEOUT_SEC}"
}

run_cuda_software_comparison() {
    PYTHONPATH="${PYTHON_SITE}" python3 \
        "${PHASE1_ROOT}/benchmark/current_release_evidence/run_cuda_ikpls_comparison.py" \
        --library "${PACKAGE_LIB}" --tasks "${TASK_ROOT}" \
        --ikpls-inputs "${CAMPAIGN_ROOT}/inputs/ikpls_cuda" \
        --component-contract "${CONTRACT}" \
        --output "${RESULTS_ROOT}/supplement/cuda_software" \
        --package-version "${EXPECTED_VERSION}" --python python3 \
        --repetitions 10 --large-repetitions 1 --timeout "${TIMEOUT_SEC}"
}

run_python_independent() {
    PYTHONPATH="${PYTHON_SITE}" PYTHON_PLS_BENCH_PYTHON=python3 python3 \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/run_python_pls_panel.py" \
        --inputs "${CAMPAIGN_ROOT}/inputs/ikpls_standard" \
        --results "${RESULTS_ROOT}/figure1/python_standard" \
        --repetitions 10 --timeout "${TIMEOUT_SEC}"
    PYTHONPATH="${PYTHON_SITE}" PYTHON_PLS_BENCH_PYTHON=python3 python3 \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/run_python_pls_large.py" \
        --data-root "${CAMPAIGN_ROOT}/inputs/ikpls_large" \
        --results "${RESULTS_ROOT}/figure1/python_large" \
        --datasets nmr,imagenet --nmr-components 50 \
        --imagenet-components 1000 --repetitions 1 \
        --timeout "${TIMEOUT_SEC}"
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

run_cross_validation() {
    local image_tasks="${CAMPAIGN_ROOT}/inputs/imagenet_task_only"
    mkdir -p "${image_tasks}"
    cp "${TASK_ROOT}/imagenet_task.rds" "${image_tasks}/imagenet_task.rds"
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/gpu_cross_validation/run_selected_matrix.R" \
        --library="${PACKAGE_LIB}" --tasks="${TASK_ROOT}" \
        --selection="${SELECTED}" \
        --output="${RESULTS_ROOT}/figure2/cv_standard" \
        --backends=cpu,cuda --repetitions=5 --kfold=10 --seed=123 \
        --precision=float32 --n-cores=1 --timeout-sec="${TIMEOUT_SEC}" \
        --exclude-datasets=imagenet --source-id="${SOURCE_ID}"
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/gpu_cross_validation/run_selected_matrix.R" \
        --library="${PACKAGE_LIB}" --tasks="${image_tasks}" \
        --selection="${SELECTED}" \
        --output="${RESULTS_ROOT}/figure2/cv_imagenet" \
        --backends=cpu,cuda --repetitions=1 --kfold=10 --seed=123 \
        --precision=float32 --n-cores=1 --timeout-sec="${TIMEOUT_SEC}" \
        --source-id="${SOURCE_ID}"
}

run_component_paths() {
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" \
    FASTPLS_COMPONENT_TASK_ROOT="${TASK_ROOT}" \
    FASTPLS_SELECTED_COMPONENTS_CSV="${SELECTED}" \
    FASTPLS_COMPONENT_GRID_CONTRACT="${PHASE1_ROOT}/config/cmpb_selection_grids.csv" \
    FASTPLS_COMPONENT_ACCELERATOR=cuda \
    FASTPLS_COMPONENT_REPLICATES=3 \
    FASTPLS_COMPONENT_PRECISION=float32 \
    FASTPLS_COMPONENT_NCORES=1 \
    FASTPLS_BENCHMARK_TIMEOUT="${TIMEOUT_SEC}" \
    Rscript --vanilla "${PHASE1_ROOT}/benchmark/run_current_component_path.R" \
        "${RESULTS_ROOT}/component_paths/standard" || return $?
    python3 \
        "${PHASE1_ROOT}/benchmark/supplement_component_paths/run_nmr_backend_component_paths.py" \
        --library "${PACKAGE_LIB}" --task "${TASK_ROOT}/nmr_task.rds" \
        --output "${RESULTS_ROOT}/component_paths/nmr_cpu_cuda.csv" \
        --platform linux_nvidia --backends cpu cuda \
        --expected-version "${EXPECTED_VERSION}" --source-id "${SOURCE_ID}" \
        --precision float32 --repetitions 3 --timeout-sec "${TIMEOUT_SEC}"
}

run_training_component_selection() {
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" \
    FASTPLS_COMPONENT_TASK_ROOT="${TASK_ROOT}" \
    FASTPLS_COMPONENT_GRID_CONTRACT="${PHASE1_ROOT}/config/cmpb_selection_grids.csv" \
    FASTPLS_COMPONENT_KFOLD=10 \
    FASTPLS_COMPONENT_SEED=123 \
    FASTPLS_COMPONENT_NCORES=1 \
    FASTPLS_COMPONENT_PRECISION=float32 \
    FASTPLS_BENCHMARK_TIMEOUT="${TIMEOUT_SEC}" \
    Rscript --vanilla \
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

run_nmr() {
    local output="${RESULTS_ROOT}/figure3"
    mkdir -p "${output}"
    for family in plssvd simpls; do
        if [ "${family}" = plssvd ]; then ncomp=100; else ncomp=50; fi
        for backend in cpu cuda; do
            timeout --signal=TERM "${TIMEOUT_SEC}s" \
                env FASTPLS_LIB="${PACKAGE_LIB}" \
                FASTPLS_SOURCE_ARCHIVE_SHA256="${EXPECTED_SHA256}" \
                Rscript --vanilla \
                "${PHASE1_ROOT}/benchmark/benchmark_nmr_qualified_solver.R" \
                --input="${NMR_INPUT}" \
                --output="${output}/${family}_${backend}.csv" \
                --prediction_output="${output}/${family}_${backend}_prediction.rds" \
                --family="${family}" --backend="${backend}" --solver=rsvd \
                --precision=float32 --ncomp="${ncomp}" --seed=123 \
                --replicates=3
        done
    done
    if [ -n "${DEPOSITED_REFERENCE_R:-}" ]; then
        TIMEOUT_SEC="${TIMEOUT_SEC}" \
        "${PHASE1_ROOT}/scripts/run_nmr_deposited_reference.sh" \
            "${NMR_INPUT}" "${DEPOSITED_REFERENCE_R}" \
            "${output}/deposited" "${PACKAGE_LIB}"
    else
        echo "DEPOSITED_REFERENCE_R is required for the deposited comparator" >&2
        return 2
    fi
}

run_imagenet() {
    SOURCE_ROOT="${PHASE1_ROOT}" PACKAGE_LIB="${PACKAGE_LIB}" \
    DEPENDENCY_LIB="${PACKAGE_LIB}" TASK_RDS="${TASK_ROOT}/imagenet_task.rds" \
    OUTPUT_DIR="${RESULTS_ROOT}/figure4" TIMEOUT_SEC="${TIMEOUT_SEC}" \
    FASTPLS_SOURCE_ID="${SOURCE_ID}" \
        "${PHASE1_ROOT}/benchmark/run_imagenet_four_family_paths.sh"
}

run_simpls_validation() {
    timeout --signal=TERM "${TIMEOUT_SEC}s" env \
        FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/benchmark_simpls_exact_reference.R" \
        --root="${PHASE1_ROOT}" \
        --out="${RESULTS_ROOT}/validation/simpls_dense_reference"
}

run_rsvd_validation() {
    local backend="$1"
    timeout --signal=TERM "${TIMEOUT_SEC}s" env \
        FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/benchmark_rsvd_current_qualification.R" \
        --backend="${backend}" \
        --out="${RESULTS_ROOT}/validation/rsvd_qualification_${backend}"
}

run_opls_kernel_estimator_validation() {
    timeout --signal=TERM "${TIMEOUT_SEC}s" env \
        FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/benchmark_opls_kernel_estimator_validation.R" \
        --root="${PHASE1_ROOT}" \
        --out="${RESULTS_ROOT}/validation/opls_kernel_estimator"
}

run_opls_kernel_setting_validation() {
    timeout --signal=TERM "${TIMEOUT_SEC}s" env \
        FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/benchmark_opls_kernel_setting_reliability.R" \
        --root="${PHASE1_ROOT}" \
        --out="${RESULTS_ROOT}/validation/opls_kernel_settings"
}

run_precision_validation() {
    local backend="$1"
    timeout --signal=TERM "${TIMEOUT_SEC}s" env \
        FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/benchmark_float32_backend_agreement.R" \
        --backend="${backend}" \
        --out="${RESULTS_ROOT}/validation/precision_${backend}"
}

run_formal() {
    export ELAN_HOME="${LEAN_ELAN_HOME}"
    export PATH="${ELAN_HOME}/bin:${PATH}"
    (
        cd "${PHASE1_ROOT}/formal/lean" || exit 1
        ./check.sh
    )
}

import_figure1_evidence() {
    local source_root="${FIGURE1_EVIDENCE_ROOT}"
    local source_hash observed_hash required legacy_root
    if [ -z "${source_root}" ] || [ ! -d "${source_root}" ]; then
        echo "FIGURE1_EVIDENCE_ROOT must identify the completed Figure 1 campaign" >&2
        return 2
    fi
    if [ ! -f "${source_root}/source_archive.sha256" ]; then
        echo "The Figure 1 campaign has no source archive checksum" >&2
        return 2
    fi
    source_hash="$(awk 'NR == 1 {print $1}' "${source_root}/source_archive.sha256")"
    observed_hash="$(sha256sum "${PACKAGE_ARCHIVE}" | awk '{print $1}')"
    if [ "${source_hash}" != "${observed_hash}" ]; then
        echo "Figure 1 and continuation archives do not match" >&2
        return 2
    fi
    if ! grep -q "OpenBLAS 0.3.29" \
        "${source_root}/openblas_configuration.txt" || \
       ! grep -qi "HASWELL" \
        "${source_root}/openblas_configuration.txt"; then
        echo "Figure 1 was not generated with the required OpenBLAS build" >&2
        return 2
    fi
    mkdir -p "${RESULTS_ROOT}/figure1" "${CAMPAIGN_ROOT}/provenance"
    if [ -f "${source_root}/results/figure1/fastpls_cpu_raw.csv" ]; then
        for required in \
            fastpls_cpu_raw.csv \
            imagenet_cpu/simpls_lda.csv \
            independent_r/figure1_r_packages_raw.csv \
            ikpls_standard/ikpls_panel_all_runs.csv \
            python_standard/python_pls_panel_all_runs.csv; do
            if [ ! -f "${source_root}/results/figure1/${required}" ]; then
                echo "Missing Figure 1 evidence: ${required}" >&2
                return 2
            fi
        done
        cp -a "${source_root}/results/figure1/." "${RESULTS_ROOT}/figure1/"
        imported_layout="raw_campaign"
    else
        legacy_root="${source_root}/results/table1"
        for required in \
            fastpls_cpu_raw.csv \
            fastpls_imagenet/simpls_lda.csv \
            independent_r_summary.csv \
            ikpls_standard/ikpls_panel_all_runs.csv \
            ikpls_large/imagenet_ikpls_f32_n1000.csv \
            ikpls_large/nmr_ikpls_f32_n50.csv \
            scikit_standard/python_pls_panel_all_runs.csv \
            scikit_large/python_pls_large_all_runs.csv \
            figure1_data.csv Figure1_corrected.pdf Figure1_corrected.png; do
            if [ ! -f "${legacy_root}/${required}" ]; then
                echo "Missing finalized Figure 1 evidence: ${required}" >&2
                return 2
            fi
        done
        mkdir -p \
            "${RESULTS_ROOT}/figure1/final" \
            "${RESULTS_ROOT}/figure1/imagenet_cpu" \
            "${RESULTS_ROOT}/figure1/independent_r"
        cp "${legacy_root}/fastpls_cpu_raw.csv" \
            "${RESULTS_ROOT}/figure1/fastpls_cpu_raw.csv"
        cp "${legacy_root}/fastpls_imagenet/simpls_lda.csv" \
            "${RESULTS_ROOT}/figure1/imagenet_cpu/simpls_lda.csv"
        cp "${legacy_root}/independent_r_summary.csv" \
            "${RESULTS_ROOT}/figure1/independent_r/figure1_r_packages_summary.csv"
        cp -a "${legacy_root}/ikpls_standard" \
            "${RESULTS_ROOT}/figure1/ikpls_standard"
        cp -a "${legacy_root}/ikpls_large" \
            "${RESULTS_ROOT}/figure1/ikpls_large"
        cp -a "${legacy_root}/scikit_standard" \
            "${RESULTS_ROOT}/figure1/python_standard"
        cp -a "${legacy_root}/scikit_large" \
            "${RESULTS_ROOT}/figure1/python_large"
        cp "${legacy_root}/figure1_data.csv" \
            "${legacy_root}/Figure1_corrected.pdf" \
            "${legacy_root}/Figure1_corrected.png" \
            "${legacy_root}/Table1_prepared_benchmark_dimensions.csv" \
            "${legacy_root}/fastpls_cpu_summary.csv" \
            "${legacy_root}/fastpls_imagenet_summary.csv" \
            "${legacy_root}/independent_r_summary.csv" \
            "${legacy_root}/table1_three_method_status.csv" \
            "${RESULTS_ROOT}/figure1/final/"
        imported_layout="final_table1_bundle"
    fi
    cat >"${CAMPAIGN_ROOT}/provenance/imported_figure1.txt" <<EOF
source_campaign=${source_root}
source_archive_sha256=${source_hash}
source_id=${SOURCE_ID}
layout=${imported_layout}
imported_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

record_imported_figure1_stages() {
    local timestamp stage
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for stage in \
        figure1_fastpls figure1_imagenet figure1_independent_r \
        figure1_ikpls figure1_python; do
        printf '%s\t%s\t%s\t0\n' \
            "${stage}" "${timestamp}" "${timestamp}" >>"${STATUS_FILE}"
        printf 'Imported without recomputation from %s after archive and BLAS validation.\n' \
            "${FIGURE1_EVIDENCE_ROOT}" >"${LOG_ROOT}/${stage}.log"
    done
}

record_environment() {
    local require_independent="true"
    if [ "${CAMPAIGN_SCOPE}" = "remaining" ]; then
        require_independent="false"
    fi
    BENCHMARK_HOST_ID="${BENCHMARK_HOST_ID}" \
        FASTPLS_REQUIRE_INDEPENDENT_PACKAGES="${require_independent}" \
        "${PHASE1_ROOT}/scripts/record_campaign_environment.sh" \
        "${PACKAGE_LIB}" "${CAMPAIGN_ROOT}/provenance"
}

run_common_setup() {
    run_required_stage verify_source verify_source
    run_required_stage prepare_dependencies prepare_dependencies
    run_required_stage prepare_lean prepare_lean
    run_required_stage install_package install_package
    run_required_stage package_test_suite run_package_tests
    run_required_stage prepare_tasks prepare_tasks
    run_required_stage record_environment record_environment
}

run_full_campaign() {
    run_common_setup
    run_required_stage prepare_python prepare_python
    run_stage figure1_fastpls run_figure1_fastpls
    run_stage figure1_imagenet run_figure1_imagenet
    run_stage figure1_independent_r run_figure1_independent_r
    run_stage figure1_ikpls run_ikpls
    run_stage figure1_python run_python_independent
    run_stage supplementary_cuda_software run_cuda_software_comparison
    run_stage figure2_selected_backends run_selected_backends
    run_stage figure2_cross_validation run_cross_validation
    run_stage supplementary_component_paths run_component_paths
    run_stage training_component_selection run_training_component_selection
    run_stage nmr_selection_plssvd run_nmr_training_selection plssvd
    run_stage nmr_selection_simpls run_nmr_training_selection simpls
    run_stage figure3_nmr run_nmr
    run_stage figure4_imagenet run_imagenet
    run_stage validation_simpls_dense run_simpls_validation
    run_stage validation_rsvd_cpu run_rsvd_validation cpu
    run_stage validation_rsvd_cuda run_rsvd_validation cuda
    run_stage validation_opls_kernel_estimator \
        run_opls_kernel_estimator_validation
    run_stage validation_opls_kernel_settings \
        run_opls_kernel_setting_validation
    run_stage validation_precision_cpu run_precision_validation cpu
    run_stage validation_precision_cuda run_precision_validation cuda
    run_stage formal_invariants run_formal
    run_required_stage campaign_audit python3 \
        "${PHASE1_ROOT}/scripts/audit_cmpb_campaign.py" "${CAMPAIGN_ROOT}"
}

run_verified_fastpls_timings() {
    run_common_setup
    run_required_stage prepare_python prepare_python
    run_required_stage prepare_ikpls_inputs prepare_ikpls_inputs
    run_required_stage figure1_fastpls run_figure1_fastpls
    run_required_stage figure1_imagenet run_figure1_imagenet
    run_required_stage supplementary_cuda_software \
        run_cuda_software_comparison
    run_required_stage figure2_selected_backends run_selected_backends
    run_required_stage figure2_cross_validation run_cross_validation
    run_required_stage supplementary_component_paths run_component_paths
    run_required_stage figure3_nmr run_nmr
    run_required_stage figure4_imagenet run_imagenet
}

run_remaining_campaign() {
    run_common_setup
    run_required_stage prepare_python prepare_python
    run_required_stage import_figure1_evidence import_figure1_evidence
    record_imported_figure1_stages
    run_required_stage prepare_ikpls_inputs prepare_ikpls_inputs
    run_stage supplementary_cuda_software run_cuda_software_comparison
    run_stage figure2_selected_backends run_selected_backends
    run_stage figure2_cross_validation run_cross_validation
    run_stage supplementary_component_paths run_component_paths
    run_stage training_component_selection run_training_component_selection
    run_stage nmr_selection_plssvd run_nmr_training_selection plssvd
    run_stage nmr_selection_simpls run_nmr_training_selection simpls
    run_stage figure3_nmr run_nmr
    run_stage figure4_imagenet run_imagenet
    run_stage validation_simpls_dense run_simpls_validation
    run_stage validation_rsvd_cpu run_rsvd_validation cpu
    run_stage validation_rsvd_cuda run_rsvd_validation cuda
    run_stage validation_opls_kernel_estimator \
        run_opls_kernel_estimator_validation
    run_stage validation_opls_kernel_settings \
        run_opls_kernel_setting_validation
    run_stage validation_precision_cpu run_precision_validation cpu
    run_stage validation_precision_cuda run_precision_validation cuda
    run_stage formal_invariants run_formal
    run_required_stage campaign_audit python3 \
        "${PHASE1_ROOT}/scripts/audit_cmpb_campaign.py" "${CAMPAIGN_ROOT}"
}

export EXPECTED_VERSION
case "${CAMPAIGN_SCOPE}" in
    full)
        run_full_campaign
        ;;
    fastpls-timing)
        run_verified_fastpls_timings
        ;;
    remaining)
        run_remaining_campaign
        ;;
    *)
        echo "CAMPAIGN_SCOPE must be full, fastpls-timing, or remaining" >&2
        exit 2
        ;;
esac

echo "Campaign scope ${CAMPAIGN_SCOPE} completed."
echo "Inspect ${STATUS_FILE} and every retained result row."
