#!/usr/bin/env sh

set -eu

sources="FastPLSFormal.lean FastPLSFormal/Invariants.lean"

if grep -n -E '(^|[^[:alnum:]_])(sorry|admit)([^[:alnum:]_]|$)' $sources; then
    echo "Incomplete Lean proof placeholder found." >&2
    exit 1
fi

theorem_count=$(grep -h -E '^theorem[[:space:]]' $sources | wc -l | tr -d ' ')

echo "Lean toolchain: $(lean --version | head -n 1)"
echo "Checked theorem declarations: ${theorem_count}"
lake build
echo "fastPLS algebraic-invariant audit: PASS"
