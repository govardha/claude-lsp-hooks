#!/bin/bash
set -euo pipefail

# Temporary: adds payload dumper to Claude Code settings.json
# Run this, trigger Grep/Read/LSP in a CC session, then run remove_dumper.sh

SETTINGS="${HOME}/.claude/settings.json"
BACKUP="${HOME}/.claude/settings.json.bak.$(date +%Y%m%d%H%M%S)"

if [[ ! -f "${SETTINGS}" ]]; then
  echo "ERROR: ${SETTINGS} not found"
  exit 1
fi

cp "${SETTINGS}" "${BACKUP}"
echo "Backup: ${BACKUP}"

python3 -c "
import json, sys

with open(sys.argv[1]) as f:
    settings = json.load(f)

hooks = settings.setdefault('hooks', {})

# Add dumper to PostToolUse with empty matcher to catch LSP calls
post = hooks.setdefault('PostToolUse', [])
dumper_entry = {
    'matcher': '',
    'hooks': [{'type': 'command', 'command': 'python3 /tmp/dump_payload.py'}]
}
# Add at beginning so it fires first
post.insert(0, dumper_entry)

# Also add to PreToolUse for Grep and Read (already have entries, just prepend dumper)
pre = hooks.setdefault('PreToolUse', [])
pre.insert(0, {
    'matcher': 'Grep|Read',
    'hooks': [{'type': 'command', 'command': 'python3 /tmp/dump_payload.py'}]
})

with open(sys.argv[1], 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')

print('Dumper hooks added to settings.json')
print('Trigger Grep, Read, and LSP in a Claude Code session, then:')
print('  cat /tmp/hook_payloads.json | python3 -m json.tool')
" "${SETTINGS}"
