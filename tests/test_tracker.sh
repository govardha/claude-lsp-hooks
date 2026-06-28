#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${HOME}/.local/share/lsp-hooks/state"
PASS=0
FAIL=0

cleanup() {
  rm -f "${STATE_DIR}"/lsp-ready-*
}

pass() {
  PASS=$((PASS + 1))
}

fail() {
  FAIL=$((FAIL + 1))
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

cleanup

# Test 1: LSP call sets warmup_done and increments nav_count
echo '{"tool_name":"LSP","tool_input":{"operation":"goToDefinition"}}' \
  | python3 "${SCRIPT_DIR}/hooks/lsp_usage_tracker.py"
assert_exit 0 $? "tracker exits 0 on LSP call"

STATE_FILE="$(ls "${STATE_DIR}"/lsp-ready-* 2>/dev/null | head -1)"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get('warmup_done') == True, 'warmup_done not set'
assert d.get('nav_count') == 1, f'nav_count={d.get(\"nav_count\")}, expected 1'
print('PASS: state file correct after first call')
" "${STATE_FILE}"
pass

# Test 2: Second call increments
echo '{"tool_name":"LSP","tool_input":{"operation":"findReferences"}}' \
  | python3 "${SCRIPT_DIR}/hooks/lsp_usage_tracker.py"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get('nav_count') == 2, f'nav_count={d.get(\"nav_count\")}, expected 2'
print('PASS: nav_count incremented to 2')
" "${STATE_FILE}"
pass

# Test 3: Non-LSP tool is ignored
echo '{"tool_name":"Grep","tool_input":{"pattern":"foo"}}' \
  | python3 "${SCRIPT_DIR}/hooks/lsp_usage_tracker.py"
assert_exit 0 $? "tracker exits 0 on non-LSP tool"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get('nav_count') == 2, 'nav_count should still be 2'
print('PASS: non-LSP tool did not increment')
" "${STATE_FILE}"
pass

cleanup
echo "---"
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
