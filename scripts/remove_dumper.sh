#!/bin/bash
set -euo pipefail

# Removes the temporary payload dumper hooks from settings.json

SETTINGS="${HOME}/.claude/settings.json"

if [[ ! -f "${SETTINGS}" ]]; then
  echo "ERROR: ${SETTINGS} not found"
  exit 1
fi

python3 -c "
import json, sys

with open(sys.argv[1]) as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})

# Remove entries that reference dump_payload.py
for event_type in ('PreToolUse', 'PostToolUse'):
    if event_type in hooks:
        hooks[event_type] = [
            entry for entry in hooks[event_type]
            if not any(
                'dump_payload.py' in h.get('command', '')
                for h in entry.get('hooks', [])
            )
        ]

with open(sys.argv[1], 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')

print('Dumper hooks removed from settings.json')
" "${SETTINGS}"
