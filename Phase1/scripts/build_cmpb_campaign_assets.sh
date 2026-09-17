#!/usr/bin/env bash

# Regenerate every CMPB figure and its source table from one campaign root.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 PHASE1_ROOT CAMPAIGN_ROOT" >&2
    exit 2
fi

phase1_root="$(cd "$1" && pwd)"
campaign_root="$(cd "$2" && pwd)"
results="${campaign_root}/results"
assets="${campaign_root}/assets"
tables="${assets}/tables"
figures="${assets}/figures"
mkdir -p "${tables}" "${figures}"
export R_LIBS_USER="${campaign_root}/library${R_LIBS_USER:+:${R_LIBS_USER}}"

python3 "${phase1_root}/scripts/audit_cmpb_campaign.py" "${campaign_root}"

Rscript --vanilla \
    "${phase1_root}/benchmark/current_release_evidence/summarize_figure1.R" \
    "${results}/figure1/fastpls_cpu_raw.csv" \
    "${tables}/figure1_fastpls_summary.csv"
python3 \
    "${phase1_root}/benchmark/current_release_evidence/summarize_figure1_imagenet.py" \
    "${results}/figure1/imagenet_cpu" \
    "${tables}/figure1_fastpls_imagenet.csv"
python3 \
    "${phase1_root}/benchmark/current_release_evidence/summarize_figure1_r_packages.py" \
    "${results}/figure1/independent_r/figure1_r_packages_raw.csv" \
    "${tables}/figure1_r_packages_summary.csv"

ikpls_large=("${results}/figure1/ikpls_large/"*.csv)
python3 \
    "${phase1_root}/benchmark/current_release_evidence/assemble_figure1_data.py" \
    --fastpls "${tables}/figure1_fastpls_summary.csv" \
    --fastpls-imagenet "${tables}/figure1_fastpls_imagenet.csv" \
    --ikpls "${results}/figure1/ikpls_standard/ikpls_panel_summary.csv" \
    --ikpls-large "${ikpls_large[@]}" \
    --r-packages "${tables}/figure1_r_packages_summary.csv" \
    --python "${results}/figure1/python_standard/python_pls_panel_summary.csv" \
    --python-status "${results}/figure1/python_standard/python_pls_panel_status.csv" \
    --python-large "${results}/figure1/python_large/python_pls_large_all_runs.csv" \
    --output "${tables}/figure1_six_panel_data.csv"
Rscript --vanilla "${phase1_root}/tools/build_figure1_six_panel.R" \
    "${tables}/figure1_six_panel_data.csv" \
    "${figures}/Figure1.png" "${figures}/Figure1.pdf"

python3 "${phase1_root}/scripts/summarize_cmpb_campaign.py" \
    "${campaign_root}" "${tables}"
python3 "${phase1_root}/scripts/build_cmpb_campaign_tables.py" \
    "${campaign_root}" "${tables}"
Rscript --vanilla \
    "${phase1_root}/benchmark/current_release_evidence/build_figure2_with_cv.R" \
    "${tables}/figure2_cpu_cuda_ratios.csv" \
    "${tables}/figure2_cv_comparison.csv" "${figures}/figure2_build"
cp "${figures}/figure2_build/figure2_backend_and_cv.png" "${figures}/Figure2.png"
cp "${figures}/figure2_build/figure2_backend_and_cv.pdf" "${figures}/Figure2.pdf"

FASTPLS_COMPONENT_PATH_SCOPE=cmpb Rscript --vanilla \
    "${phase1_root}/benchmark/summarize_current_component_paths.R" \
    "${results}/component_paths/standard/component_path_raw.csv" \
    "${phase1_root}/benchmark/gpu_cross_validation/selected_component_contract.csv" \
    "${assets}/component_paths"
while read -r number dataset; do
    cp "${assets}/component_paths/component_path_plots/component_path_${dataset}.pdf" \
        "${figures}/FigureS${number}.pdf"
done <<'EOF'
1 ccle
2 cifar100
3 gtex_v8
4 metref
5 retina
6 tabula
7 tcga_brca
8 tcga_hnsc_methylation
9 tcga_pan_cancer
10 cbmc_citeseq
11 prism
EOF
cp "${assets}/component_paths/"*.csv "${tables}/"

Rscript --vanilla \
    "${phase1_root}/benchmark/supplement_component_paths/plot_nmr_component_selection.R" \
    "${results}/component_paths/nmr_cpu_cuda.csv" \
    "${phase1_root}/benchmark/gpu_cross_validation/selected_component_contract.csv" \
    "${assets}/nmr_component_path"
cp "${assets}/nmr_component_path/figureS12_nmr_test_component_path.pdf" \
    "${figures}/FigureS12.pdf"
cp "${assets}/nmr_component_path/"*.csv "${tables}/"
cp "${results}/component_selection/ordinary/selected_components.csv" \
    "${tables}/training_selected_components.csv"
for family in plssvd simpls; do
    for source in "${results}/component_selection/nmr_${family}/"*.csv; do
        cp "${source}" \
            "${tables}/nmr_${family}_$(basename "${source}")"
    done
done

Rscript --vanilla "${phase1_root}/tools/build_nmr_figure3_family_components.R" \
    "${results}/component_paths/nmr_cpu_cuda.csv" \
    "${results}/figure3" "${results}/figure3/deposited" \
    "${assets}/figure3_build"
cp "${assets}/figure3_build/figures/figure3_nmr_family_components.png" \
    "${figures}/Figure3.png"
cp "${assets}/figure3_build/figures/figure3_nmr_family_components.pdf" \
    "${figures}/Figure3.pdf"
cp "${assets}/figure3_build/tables/"*.csv "${tables}/"

Rscript --vanilla "${phase1_root}/benchmark/plot_imagenet_current.R" \
    "${results}/figure4/imagenet_four_family_component_paths.csv" \
    "${figures}/Figure4"

Rscript --vanilla "${phase1_root}/tools/build_supplement_cuda_ikpls_figure.R" \
    "${results}/supplement/cuda_software/cuda_software_comparison_summary.csv" \
    "${figures}/FigureS13.png" "${figures}/FigureS13.pdf"

Rscript --vanilla "${phase1_root}/benchmark/analyze_nmr_localized_error.R" \
    "${results}/figure3" \
    "${results}/figure3/deposited/deposited_plssvd_cpu_irlba_k165_rep1_prediction.rds" \
    "${assets}/nmr_localized_error"
cp "${assets}/nmr_localized_error/figureS14_nmr_localized_error.pdf" \
    "${figures}/FigureS14.pdf"
cp "${assets}/nmr_localized_error/"*.csv "${tables}/"

find "${results}/validation" -type f -name '*.csv' -exec cp {} "${tables}/" \;
printf 'asset\tsha256\n' >"${assets}/asset_manifest.tsv"
find "${figures}" "${tables}" -type f -print0 | sort -z | while IFS= read -r -d '' path; do
    printf '%s\t%s\n' "${path#${assets}/}" "$(sha256sum "${path}" | awk '{print $1}')"
done >>"${assets}/asset_manifest.tsv"

echo "Built current-release CMPB assets under ${assets}"
