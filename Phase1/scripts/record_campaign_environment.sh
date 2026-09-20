#!/usr/bin/env bash

# Record benchmark-relevant software and hardware without host credentials.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 PACKAGE_LIBRARY OUTPUT_DIRECTORY" >&2
    exit 2
fi

package_library="$1"
output_directory="$2"
mkdir -p "${output_directory}"

R_LIBS_USER="${package_library}${R_LIBS_USER:+:${R_LIBS_USER}}" \
Rscript --vanilla - "${output_directory}" <<'RSCRIPT'
args <- commandArgs(TRUE)
out <- args[[1L]]
.libPaths(unique(c(Sys.getenv("R_LIBS_USER"), .libPaths())))
required <- c(
    "fastPLS", "float", "pls", "plsgenomics", "mdatools", "plsdepot",
    "pcv", "chemometrics", "mixOmics", "spls"
)
installed <- vapply(required, requireNamespace, logical(1), quietly = TRUE)
versions <- vapply(required, function(package) {
    if (requireNamespace(package, quietly = TRUE)) {
        as.character(utils::packageVersion(package))
    } else {
        NA_character_
    }
}, character(1))
write.csv(
    data.frame(package = required, installed = installed, version = versions),
    file.path(out, "r_package_versions.csv"), row.names = FALSE, na = ""
)
require_independent <- identical(
    tolower(Sys.getenv("FASTPLS_REQUIRE_INDEPENDENT_PACKAGES", "true")),
    "true"
)
independent <- setdiff(required, c("fastPLS", "float"))
if (!all(installed[c("fastPLS", "float")])) {
    stop(
        "Missing required campaign packages: ",
        paste(required[!installed & required %in% c("fastPLS", "float")],
              collapse = ", "), call. = FALSE
    )
}
if (require_independent && !all(installed[independent])) {
    stop(
        "Missing independent-comparison packages: ",
        paste(independent[!installed[independent]], collapse = ", "),
        call. = FALSE
    )
}
suppressPackageStartupMessages(library(fastPLS))
blas <- fastPLS_blas()
write.csv(data.frame(
    field = c(
        "R_version", "platform", "fastPLS_version", "cpu_library",
        "cpu_library_version", "cpu_library_configuration",
        "cpu_library_core", "cpu_library_parallel", "cpu_library_threads",
        "cpu_library_path"
    ),
    value = c(
        R.version.string, R.version$platform,
        as.character(utils::packageVersion("fastPLS")),
        blas$backend, blas$version, blas$configuration, blas$core,
        blas$parallel, blas$threads, blas$library
    )
), file.path(out, "r_runtime.csv"), row.names = FALSE)
writeLines(capture.output(sessionInfo()), file.path(out, "sessionInfo.txt"))
RSCRIPT

{
    printf 'field\tvalue\n'
    printf 'benchmark_host_id\t%s\n' "${BENCHMARK_HOST_ID:-unrecorded}"
    printf 'kernel\t%s\n' "$(uname -srmo 2>/dev/null || true)"
    printf 'compiler\t%s\n' "$(c++ --version 2>/dev/null | head -n 1 || true)"
    printf 'python\t%s\n' "$(python3 --version 2>&1 || true)"
    printf 'cpu_model\t%s\n' "$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    printf 'physical_cores\t%s\n' "$(lscpu -p=CORE 2>/dev/null | awk '!/^#/ {seen[$1]=1} END{print length(seen)}')"
    printf 'logical_cpus\t%s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    printf 'gpu\t%s\n' "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd ';' - || true)"
    printf 'cuda_driver\t%s\n' "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | paste -sd ';' - || true)"
} >"${output_directory}/native_runtime.tsv"
