#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "usage: $0 LIBRARY TASK_RDS BACKEND PRECISION REPLICATES OUTPUT_CSV" >&2
    exit 2
fi

library=$1
task_rds=$2
backend=$3
precision=$4
replicates=$5
output_csv=$6
script_dir=$(cd "$(dirname "$0")" && pwd)
worker=${FASTPLS_CIFAR_WORKER:-"${script_dir}/cifar_worker.R"}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/fastpls-cifar.XXXXXX")
trap 'rm -rf "${temporary_dir}"' EXIT

for replicate in $(seq 1 "${replicates}"); do
    replicate_csv="${temporary_dir}/replicate-${replicate}.csv"
    Rscript "${worker}" "${library}" "${task_rds}" "${backend}" \
        "${precision}" > "${replicate_csv}"
    if [[ ${replicate} -eq 1 ]]; then
        awk -v replicate="${replicate}" \
            'NR == 1 { print "replicate," $0 } NR == 2 { print replicate "," $0 }' \
            "${replicate_csv}" > "${output_csv}"
    else
        awk -v replicate="${replicate}" \
            'NR == 2 { print replicate "," $0 }' \
            "${replicate_csv}" >> "${output_csv}"
    fi
done

