#!/usr/bin/env bash

# Run the complete CMPB evidence campaign from one frozen fastPLS archive.
# Generated results are always written outside the Git checkout. Individual
# workers enforce a 1,800-second limit and retain timeout/failure records.

set -uo pipefail

PHASE1_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PHASE1_ROOT}"
: "${PACKAGE_ARCHIVE:?Set PACKAGE_ARCHIVE to the frozen fastPLS source archive}"
: "${CAMPAIGN_ROOT:?Set CAMPAIGN_ROOT outside every Git checkout}"
: "${SEED_TASK_ROOT:?Set SEED_TASK_ROOT to the fixed ordinary task objects}"
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
PYTHON_SITE="${CAMPAIGN_ROOT}/python/site-packages"
OPENBLAS_ROOT="${CAMPAIGN_ROOT}/dependencies/openblas"
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
stopifnot(identical(fastPLS_blas(), "OpenBLAS"))
cat(normalizePath(find.package("fastPLS")), "\n")
cat("BLAS:", fastPLS_blas(), "\n")
'
}

prepare_dependencies() {
    local deb_dir="${CAMPAIGN_ROOT}/dependencies/openblas_debs"
    local extract_root="${CAMPAIGN_ROOT}/dependencies/openblas_root"
    mkdir -p "${deb_dir}" "${extract_root}" \
        "${OPENBLAS_ROOT}/include" "${OPENBLAS_ROOT}/lib"
    if [ ! -e "${OPENBLAS_ROOT}/lib/libopenblas.so" ]; then
        (
            cd "${deb_dir}" || exit 1
            apt-get download \
                libopenblas-dev libopenblas-pthread-dev libopenblas0-pthread
            for package in ./*.deb; do
                dpkg-deb -x "${package}" "${extract_root}"
            done
        )
        cp -a \
            "${extract_root}/usr/include/x86_64-linux-gnu/openblas-pthread/." \
            "${OPENBLAS_ROOT}/include/"
        cp -a \
            "${extract_root}/usr/lib/x86_64-linux-gnu/openblas-pthread/." \
            "${OPENBLAS_ROOT}/lib/"
    fi
    test -e "${OPENBLAS_ROOT}/include/openblas_config.h"
    test -e "${OPENBLAS_ROOT}/lib/libopenblas.so"
FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla -e '
.libPaths(c(Sys.getenv("FASTPLS_BENCH_LIB"), .libPaths()))
required <- c("float", "testthat", "knitr", "rmarkdown")
missing <- required[!vapply(required, requireNamespace, logical(1L), quietly = TRUE)]
if (length(missing)) {
    install.packages(
        missing,
        lib = Sys.getenv("FASTPLS_BENCH_LIB"),
        repos = "https://cloud.r-project.org",
        type = "source"
    )
}
stopifnot(all(vapply(required, requireNamespace, logical(1L), quietly = TRUE)))
cat(as.character(packageVersion("float")), "\n")
'
}

run_package_tests() {
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
            FASTPLS_USE_OPENBLAS=1 OPENBLAS_ROOT="${OPENBLAS_ROOT}" \
            R_LIBS_USER="${R_LIBS_USER}" \
            R CMD check --no-manual "${PACKAGE_ARCHIVE}"
    )
}

prepare_tasks() {
    FASTPLS_DATA_ROOT="$(dirname "${NMR_INPUT}")" \
    FASTPLS_SEED_TASK_ROOT="${SEED_TASK_ROOT}" \
    FASTPLS_IMAGENET_TASK_RDS="${IMAGENET_TASK_RDS}" \
    Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/current_release_evidence/prepare_figure1_tasks.R" \
        "${CONTRACT}" "${TASK_ROOT}"
}

prepare_python() {
    mkdir -p "${PYTHON_SITE}"
    python3 -m pip install --upgrade --target "${PYTHON_SITE}" -r \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/requirements.txt" || \
        return $?
    python3 -m pip install --upgrade --target "${PYTHON_SITE}" -r \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/requirements-cuda.txt" || \
        return $?
    PYTHONPATH="${PYTHON_SITE}" python3 - <<'PY' || return $?
import ikpls
import jax
import numpy

devices = jax.devices()
if not any(device.platform == "gpu" for device in devices):
    raise RuntimeError(f"CUDA JAX device is unavailable: {devices}")
print("ikpls", getattr(ikpls, "__version__", "unknown"))
print("numpy", numpy.__version__)
print("jax", jax.__version__)
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
        --timeout "${TIMEOUT_SEC}" --methods simpls
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
        --repetitions 3 --timeout "${TIMEOUT_SEC}"
}

run_ikpls() {
    local standard_contract="${CAMPAIGN_ROOT}/inputs/standard_contract.csv"
    local standard_inputs="${CAMPAIGN_ROOT}/inputs/ikpls_standard"
    local large_inputs="${CAMPAIGN_ROOT}/inputs/ikpls_large"
    awk -F, 'NR == 1 || ($1 != "nmr" && $1 != "imagenet")' \
        "${CONTRACT}" >"${standard_contract}"
    Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/export_panel_float32.R" \
        "${TASK_ROOT}" "${standard_contract}" "${standard_inputs}"
    PYTHONPATH="${PYTHON_SITE}" IKPLS_PYTHON=python3 python3 \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/run_panel.py" \
        --inputs "${standard_inputs}" \
        --results "${RESULTS_ROOT}/figure1/ikpls_standard" \
        --repetitions 10 --timeout "${TIMEOUT_SEC}"
    mkdir -p "${large_inputs}/nmr" "${large_inputs}/imagenet"
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/export_large_float32.R" \
        nmr "${NMR_INPUT}" "${large_inputs}/nmr"
    FASTPLS_BENCH_LIB="${PACKAGE_LIB}" Rscript --vanilla \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/export_large_float32.R" \
        imagenet "${TASK_ROOT}/imagenet_task.rds" "${large_inputs}/imagenet"
    PYTHONPATH="${PYTHON_SITE}" python3 \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/prepare_imagenet_float32.py" \
        "${large_inputs}/imagenet" 10000
    PYTHONPATH="${PYTHON_SITE}" python3 \
        "${PHASE1_ROOT}/benchmark/ikpls_cross_language/run_large_float32.py" \
        --data-root "${large_inputs}" \
        --results "${RESULTS_ROOT}/figure1/ikpls_large" \
        --datasets nmr,imagenet --nmr-components 50 \
        --imagenet-components 1000 --timeout "${TIMEOUT_SEC}"

    local cuda_inputs="${CAMPAIGN_ROOT}/inputs/ikpls_cuda"
    mkdir -p "${cuda_inputs}"
    for dataset_path in "${standard_inputs}"/*; do
        [ -d "${dataset_path}" ] || continue
        ln -sfn "${dataset_path}" "${cuda_inputs}/$(basename "${dataset_path}")"
    done
    ln -sfn "${large_inputs}/nmr" "${cuda_inputs}/nmr"
    ln -sfn "${large_inputs}/imagenet" "${cuda_inputs}/imagenet"
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
        "${RESULTS_ROOT}/component_paths/standard"
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
    "${PHASE1_ROOT}/formal/lean/check.sh"
}

record_environment() {
    BENCHMARK_HOST_ID="${BENCHMARK_HOST_ID}" \
        "${PHASE1_ROOT}/scripts/record_campaign_environment.sh" \
        "${PACKAGE_LIB}" "${CAMPAIGN_ROOT}/provenance"
}

export EXPECTED_VERSION
run_required_stage verify_source verify_source
run_required_stage prepare_dependencies prepare_dependencies
run_required_stage install_package install_package
run_required_stage package_test_suite run_package_tests
run_required_stage prepare_tasks prepare_tasks
run_required_stage prepare_python prepare_python
run_required_stage record_environment record_environment
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
run_stage validation_opls_kernel_estimator run_opls_kernel_estimator_validation
run_stage validation_opls_kernel_settings run_opls_kernel_setting_validation
run_stage validation_precision_cpu run_precision_validation cpu
run_stage validation_precision_cuda run_precision_validation cuda
run_stage formal_invariants run_formal
run_required_stage campaign_audit python3 \
    "${PHASE1_ROOT}/scripts/audit_cmpb_campaign.py" "${CAMPAIGN_ROOT}"

echo "Campaign completed. Inspect ${STATUS_FILE} and every retained result row."
