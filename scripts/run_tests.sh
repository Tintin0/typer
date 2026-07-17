#!/usr/bin/env bash
# Typer test suite — headless, no Accessibility, no keystrokes.
#
#   scripts/run_tests.sh                 unit tests only (pure text helpers; fast, no model)
#   scripts/run_tests.sh --with-helper   + integration tests against the built helper (needs a model)
#
# The unit tests compile scripts/llama_server.cpp with -DTYPER_TEXT_TEST, which strips out
# llama.cpp / the engine / main() and leaves only the pure string logic (mid-word overlap
# trim, mid-line bridge, echo removal, word limiting, number/percentage gate, …).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${TMPDIR:-/tmp}/typer-tests"; mkdir -p "$BUILD"

echo "==> Unit tests: pure text helpers (C++, no model)"
clang++ -std=c++17 -O1 -Wno-unused-function "$ROOT/scripts/tests/text_utils_test.cpp" -o "$BUILD/text_utils_test"
"$BUILD/text_utils_test"
echo

if [ "${1:-}" = "--with-helper" ]; then
    echo "==> Integration tests: helper JSONL protocol (loads a model — slower)"
    python3 "$ROOT/scripts/tests/helper_integration_test.py"
    echo
fi
echo "ALL TESTS PASSED"
