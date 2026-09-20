#!/usr/bin/env bash

# Finalize an existing CMPB campaign after all timed stages have stopped.
# This replaces any provisional independent-R exclusions with real bounded
# attempts, reruns the strict audit, and builds the definitive assets.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 PHASE1_ROOT CAMPAIGN_ROOT" >&2
    exit 2
fi

phase1_root="$(cd "$1" && pwd)"
campaign_root="$(cd "$2" && pwd)"
status_file="${campaign_root}/stage_status.tsv"
log_root="${campaign_root}/logs"
result_root="${campaign_root}/results/figure1/independent_r"
package_library="${campaign_root}/library"
task_root="${campaign_root}/inputs/tasks"
contract="${phase1_root}/config/cmpb_component_contract.csv"
distribution_archive="${DISTRIBUTION_ARCHIVE:-}"
distribution_root="${campaign_root}/distribution_check"
openblas_root="${OPENBLAS_ROOT:-${campaign_root}/dependencies/openblas}"

mkdir -p "${log_root}" "${result_root}"

if pgrep -f '[/]run_cmpb_release_campaign\.sh' >/dev/null 2>&1; then
    echo "The primary campaign is still running; finalization is unsafe." >&2
    exit 3
fi

if [ ! -f "${status_file}" ]; then
    echo "Campaign stage ledger is missing: ${status_file}" >&2
    exit 2
fi

record_stage() {
    local name="$1"
    local started="$2"
    local status="$3"
    local finished
    finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\t%s\t%s\t%s\n' \
        "${name}" "${started}" "${finished}" "${status}" >>"${status_file}"
}

run_recorded() {
    local name="$1"
    shift
    local started status
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set +e
    "$@" >"${log_root}/${name}.log" 2>&1
    status=$?
    set -e
    record_stage "${name}" "${started}" "${status}"
    if [ "${status}" -ne 0 ]; then
        echo "Finalization stage failed: ${name}" >&2
        return "${status}"
    fi
}

export R_LIBS_USER="${package_library}${R_LIBS_USER:+:${R_LIBS_USER}}"
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export BLIS_NUM_THREADS=1

validate_distribution_archive() {
    local benchmark_archive archive_copy check_root
    if [ -z "${distribution_archive}" ] || [ ! -f "${distribution_archive}" ]; then
        echo "Set DISTRIBUTION_ARCHIVE to the vignette-enabled source archive." >&2
        return 2
    fi
    benchmark_archive="$(awk 'NR == 1 {print $2}' \
        "${campaign_root}/source_archive.sha256")"
    if [ -z "${benchmark_archive}" ] || [ ! -f "${benchmark_archive}" ]; then
        echo "The recorded benchmark archive is unavailable." >&2
        return 2
    fi

    mkdir -p "${distribution_root}"
    archive_copy="${distribution_root}/$(basename "${distribution_archive}")"
    cp "${distribution_archive}" "${archive_copy}"
    sha256sum "${archive_copy}" >"${distribution_root}/source_archive.sha256"
    python3 \
        "${phase1_root}/scripts/verify_distribution_archive_equivalence.py" \
        "${benchmark_archive}" "${archive_copy}" \
        --json "${distribution_root}/archive_equivalence.json"

    check_root="${distribution_root}/check_$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "${check_root}"
    (
        cd "${check_root}" || exit 1
        timeout --signal=TERM 1800s env \
            LANG=C.UTF-8 LC_ALL=C.UTF-8 LC_CTYPE=C.UTF-8 \
            FASTPLS_USE_OPENBLAS=1 OPENBLAS_ROOT="${openblas_root}" \
            R_LIBS_USER="${R_LIBS_USER}" \
            R CMD check --no-manual "${archive_copy}"
    )
}

run_recorded distribution_archive_validation validate_distribution_archive

run_recorded figure1_independent_r_repair \
    python3 \
    "${phase1_root}/benchmark/current_release_evidence/run_figure1_r_packages.py" \
    --repo "${phase1_root}" \
    --library "${package_library}" \
    --tasks "${task_root}" \
    --contract "${contract}" \
    --results "${result_root}" \
    --repetitions 3 \
    --timeout 1800 \
    --memory-limit-mib 28672

run_recorded formal_invariants \
    bash "${phase1_root}/formal/lean/check.sh"

run_recorded campaign_audit_final \
    python3 "${phase1_root}/scripts/audit_cmpb_campaign.py" "${campaign_root}"

run_recorded campaign_assets_final \
    bash "${phase1_root}/scripts/build_cmpb_campaign_assets.sh" \
    "${phase1_root}" "${campaign_root}"

echo "CMPB campaign finalization completed: ${campaign_root}"
