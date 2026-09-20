#!/usr/bin/env bash

# Build the definitive CMPB assets and audited DOCX files from one campaign.

set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "Usage: $0 PHASE1_ROOT CAMPAIGN_ROOT MAIN_TEMPLATE \\" >&2
    echo "    SUPPLEMENT_TEMPLATE PACKAGE_ROOT OUTPUT_DIRECTORY" >&2
    exit 2
fi

phase1_root="$(cd "$1" && pwd)"
campaign_root="$(cd "$2" && pwd)"
main_template="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
supplement_template="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"
package_root="$(cd "$5" && pwd)"
output_directory="$6"

mkdir -p "${output_directory}"
output_directory="$(cd "${output_directory}" && pwd)"

bash "${phase1_root}/formal/lean/check.sh"
bash "${phase1_root}/scripts/build_cmpb_campaign_assets.sh" \
    "${phase1_root}" "${campaign_root}"

python3 "${phase1_root}/tools/assemble_cmpb_documents.py" \
    "${main_template}" "${supplement_template}" \
    "${campaign_root}/assets" "${output_directory}"

main_document="${output_directory}/fastPLS_CMPB.docx"
supplement_document="${output_directory}/fastPLS_CMPB_supplement.docx"
narrative="${campaign_root}/assets/cmpb_narrative_summary.json"

python3 "${phase1_root}/tools/audit_cmpb_quantitative_text.py" \
    "${main_document}" "${narrative}"
python3 "${phase1_root}/tools/audit_document_crossrefs.py" \
    "${main_document}" "${supplement_document}"
python3 "${phase1_root}/tools/audit_cmpb_references.py" \
    "${main_document}" "${supplement_document}"
python3 "${phase1_root}/tools/audit_cmpb_language_notation.py" \
    "${main_document}" "${supplement_document}"
python3 "${phase1_root}/tools/audit_cmpb_pseudocode_contract.py" \
    "${main_document}" "${supplement_document}" "${package_root}"
python3 "${phase1_root}/tools/audit_cmpb_document_layout.py" \
    "${main_document}" "${supplement_document}"

printf 'Built and audited CMPB submission documents under %s\n' \
    "${output_directory}"
