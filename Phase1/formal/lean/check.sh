#!/usr/bin/env sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "${script_dir}"

sources="FastPLSFormal.lean FastPLSFormal/Invariants.lean"

if ! command -v lean >/dev/null 2>&1 && [ -x "${HOME}/.elan/bin/lean" ]; then
    PATH="${HOME}/.elan/bin:${PATH}"
    export PATH
fi

for command in lean lake; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required Lean command is unavailable: ${command}" >&2
        exit 127
    fi
done

if grep -n -E '(^|[^[:alnum:]_])(sorry|admit)([^[:alnum:]_]|$)' $sources; then
    echo "Incomplete Lean proof placeholder found." >&2
    exit 1
fi

theorem_count=$(grep -h -E '^theorem[[:space:]]' $sources | wc -l | tr -d ' ')

echo "Lean toolchain: $(lean --version | head -n 1)"
echo "Checked theorem declarations: ${theorem_count}"
lake build
echo "fastPLS algebraic-invariant audit: PASS"
