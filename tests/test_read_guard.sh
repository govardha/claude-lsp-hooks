#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${HOME}/.local/share/lsp-hooks/state"
PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
}

fail() {
  FAIL=$((FAIL + 1))
}

cleanup() {
  rm -f "${STATE_DIR}"/lsp-ready-*
}

assert_exit() {
  local expected="$1" actual="$2" desc="$3"
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "PASS: ${desc}"
    pass
  else
    echo "FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    fail
  fi
}

run_read_guard() {
  echo "$1" | python3 "${SCRIPT_DIR}/hooks/lsp_first_read_guard.py" > /dev/null 2>&1
}

cleanup

set +e

# Test 1: Gate 1 — no state → block code file
run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"src/main.py"}}'
assert_exit 2 $? "Gate 1: blocks code file with no warmup"

# Test 2: Non-code file always passes regardless of gate
run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}'
assert_exit 0 $? "non-code file (md) always allowed"

run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"config.json"}}'
assert_exit 0 $? "non-code file (json) always allowed"

# Test 3: After warmup — allow code file reads
echo '{"tool_name":"LSP","tool_input":{"operation":"goToDefinition"}}' \
  | python3 "${SCRIPT_DIR}/hooks/lsp_usage_tracker.py"

run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"src/main.py"}}'
assert_exit 0 $? "Gate 2: allows first code read after warmup"

run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"src/utils.py"}}'
assert_exit 0 $? "Gate 2: allows second code read"

# Test 4: Third read — nav=1, so gate 3 (nav=0 check) doesn't trigger
run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"src/lib.py"}}'
assert_exit 0 $? "allows third read (nav_count=1)"

# Test 5: Fourth read — nav=1 satisfies gate 4 (nav >= 1)
run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"src/more.py"}}'
assert_exit 0 $? "allows fourth read (nav_count=1 >= 1)"

run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"src/another.py"}}'
assert_exit 0 $? "allows fifth read"

# Test 6: Gate 5 — 6th+ read requires nav >= 2, should block
run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"src/deep.py"}}'
assert_exit 2 $? "Gate 5: blocks when nav_count < 2 after 5 reads"

# Test 7: After second LSP call, reads unblocked
echo '{"tool_name":"LSP","tool_input":{"operation":"findReferences"}}' \
  | python3 "${SCRIPT_DIR}/hooks/lsp_usage_tracker.py"

run_read_guard '{"tool_name":"Read","tool_input":{"file_path":"src/deep.py"}}'
assert_exit 0 $? "allows read after second LSP call (nav_count=2)"

set -e
cleanup
echo "---"
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
