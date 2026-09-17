#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 4 ]; then
    echo "Usage: $0 NMR_RDATA DEPOSITED_REFERENCE_R OUTPUT_DIR FASTPLS_LIBRARY" >&2
    exit 2
fi

input="$1"
reference="$2"
out_dir="$3"
fastpls_library="$4"
root="$(cd "$(dirname "$0")/.." && pwd)"
runner="${root}/benchmark/benchmark_nmr_deposited_reference.R"

mkdir -p "${out_dir}"
for replicate in 1 2 3; do
    stem="deposited_plssvd_cpu_irlba_k165_rep${replicate}"
    row="${out_dir}/${stem}.csv"
    prediction="${out_dir}/${stem}_prediction.rds"
    time_log="${out_dir}/${stem}.time"
    FASTPLS_LIB="${fastpls_library}" R_LIBS_USER="${fastpls_library}" \
        /usr/bin/time -v -o "${time_log}" \
        Rscript "${runner}" \
        --input="${input}" \
        --reference_source="${reference}" \
        --output="${row}" \
        --prediction_output="${prediction}" \
        --ncomp=165 \
        --seed=123 \
        --replicate="${replicate}"

    rss_kb="$(awk -F: '/Maximum resident set size/ {gsub(/^[ \t]+/, "", $2); print $2}' "${time_log}")"
    ROW_FILE="${row}" RSS_KB="${rss_kb}" Rscript -e '
        path <- Sys.getenv("ROW_FILE")
        x <- read.csv(path, check.names = FALSE)
        x$process_peak_rss_mb <- as.numeric(Sys.getenv("RSS_KB")) / 1024
        write.csv(x, path, row.names = FALSE, na = "")
    '
done
