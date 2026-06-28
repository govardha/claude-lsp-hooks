#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

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

run_guard() {
  echo "$1" | python3 "${SCRIPT_DIR}/hooks/lsp_first_guard.py" > /dev/null 2>&1
}

# Test 1: blocks camelCase symbol in Grep
set +e
run_guard '{"tool_name":"Grep","tool_input":{"pattern":"getUserById","path":"src/api.py"}}'
assert_exit 2 $? "blocks camelCase symbol"

# Test 2: blocks snake_case symbol
run_guard '{"tool_name":"Grep","tool_input":{"pattern":"parse_config","path":"src/main.py"}}'
assert_exit 2 $? "blocks snake_case symbol"

# Test 3: blocks PascalCase symbol
run_guard '{"tool_name":"Grep","tool_input":{"pattern":"UserService","path":"src/service.py"}}'
assert_exit 2 $? "blocks PascalCase symbol"

# Test 4: allows TODO
run_guard '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":"src/main.py"}}'
assert_exit 0 $? "allows TODO keyword"

# Test 5: allows SCREAMING_SNAKE env var
run_guard '{"tool_name":"Grep","tool_input":{"pattern":"DATABASE_URL","path":".env"}}'
assert_exit 0 $? "allows SCREAMING_SNAKE env var"

# Test 6: allows non-code file glob
run_guard '{"tool_name":"Grep","tool_input":{"pattern":"*.md","path":"docs/"}}'
assert_exit 0 $? "allows non-code file glob"

# Test 7: blocks grep in Bash tool
run_guard '{"tool_name":"Bash","tool_input":{"command":"grep -r getUserById src/"}}'
assert_exit 2 $? "blocks grep in Bash command with symbol"

# Test 8: allows non-grep Bash command
run_guard '{"tool_name":"Bash","tool_input":{"command":"ls -la src/"}}'
assert_exit 0 $? "allows non-grep Bash command"

# Test 9: blocks dotted symbol
run_guard '{"tool_name":"Grep","tool_input":{"pattern":"app.config","path":"src/"}}'
assert_exit 2 $? "blocks dotted symbol"

set -e
echo "---"
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
