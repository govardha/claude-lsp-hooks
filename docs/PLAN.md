# claude-lsp-hooks — Build Plan & Reference (v2)

**Goal:** Enforce LSP-first code navigation in Claude Code via Python hook scripts
that hard-block grep/glob and force use of Claude Code's **native built-in LSP tool**.
LSP servers (pyrefly for Python, bash-language-server for Bash) are wired via a
self-hosted plugin config living in this repo. No MCP bridge binary. No third-party
plugin marketplace. RHEL8 on-prem.

---

## 1. Background Decisions (Don't Revisit These)

| Decision                                                   | Rationale                                                                                                                                           |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Drop all MCP LSP bridges (t3ta, isaacphi, rockerBOO, etc.) | Claude Code v2.0.74+ has native LSP built in. MCP bridge is dead weight.                                                                            |
| Drop cclsp                                                 | Hardcoded to pylsp. README lies. Source confirmed. Moot anyway.                                                                                     |
| Drop Serena                                                | Massive feature surface you'll use 5% of. Project model, memory system, onboarding ceremony, system prompt override patch — all baggage. Wrong fit. |
| Native LSP tool only                                       | Claude Code exposes LSP as a single built-in tool named `LSP` since v2.0.74. Confirmed in official Anthropic tools reference.                       |
| Self-hosted plugin config                                  | One `lsp/lsp.json` in this repo. No marketplace installs, no tweakcc patches, no third-party supply chain. You own every file.                      |
| Python not JavaScript                                      | Your tool of choice. Auditable. You own every line.                                                                                                 |
| 3 hooks not 5                                              | bash-grep-block merged into guard via dual matcher. lsp-pre-delegation irrelevant for single-agent use.                                             |
| pyrefly for Python LSP                                     | Meta's Rust-based LSP. Fast. `pyrefly lsp` speaks stdio natively, no flags needed.                                                                  |
| bash-language-server for Bash                              | find_definition across sourced files. Worth the Node dep.                                                                                           |
| Global scope                                               | LSP plugin config installed at user scope — works across all projects without per-project wiring.                                                   |
| Hooks enforce, CLAUDE.md nudges                            | Hard block via exit 2 is deterministic. System prompt nudges are probabilistic. Both layers used.                                                   |

---

## 2. Architecture

```
Claude Code session (v2.0.74+, you are on v2.1.180)
       │
       ├─ PreToolUse: Grep / Bash(grep)
       │       └─→  lsp_first_guard.py
       │               detects code symbols in pattern
       │               blocks (exit 2) + tells model to use LSP tool instead
       │
       ├─ PreToolUse: Read
       │       └─→  lsp_first_read_guard.py
       │               reads state file
       │               gates file reads until LSP is warmed up
       │
       └─ PostToolUse: LSP
               └─→  lsp_usage_tracker.py
                       writes nav_count to state file
                       keyed by MD5(cwd) — auto project-scoped

Native LSP layer (built into Claude Code — no separate process):
  Claude Code LSP client  [tool name: LSP — confirmed, Anthropic docs]
       ├─ pyrefly lsp          → *.py *.pyi
       └─ bash-language-server → *.sh *.bash
  Configured via: lsp/lsp.json in this repo (installed at user scope)
```

**Key architectural point:** The model's training bias toward grep/glob is unchanged
by LSP availability. Hooks provide hard enforcement. CLAUDE.md provides a soft
nudge as a secondary layer. Both are needed.

---

## 3. Confirmed Tool Names — What To Use In Hook Matchers

### Top-level tool name: CONFIRMED

From the official Anthropic Claude Code tools reference at `code.claude.com/docs/en/tools-reference`:

```
LSP
```

That is the exact string for hook matchers, permission rules, and deny lists.
One tool. One name. No underscores, no sub-operation suffixes.

This means:

- **PostToolUse matcher:** `"matcher": "LSP"` — fires after every LSP tool call
- **PreToolUse deny (if needed):** `"LSP"` in deny array disables it entirely
- **Block message suggestion to model:** `"Use the LSP tool for symbol navigation"`

### Sub-operation names: NOT YET CONFIRMED

Community sources and blog posts reference operation names like `goToDefinition`,
`findReferences`, `hover` — these are camelCase names used in narrative descriptions
of what the model does internally. They may appear in the `tool_input.operation`
field of the hook payload, or they may not exist as discrete field values at all.

**Do not use these as hook matchers. `LSP` is the matcher.**

What they might look like in the payload (unconfirmed — dump first):

```json
{
  "tool_name": "LSP",
  "tool_input": {
    "operation": "goToDefinition",
    "symbol": "parse_config",
    "file": "src/main.py"
  }
}
```

The Day One payload dump (Section 9) confirms the exact `tool_input` field names.
Record them in `docs/tool_names.md` once confirmed.

---

## 4. Hook I/O Contract

Same contract for all three hook scripts:

```
STDIN:   JSON payload from Claude Code
STDOUT:  JSON response (only needed for block)
EXIT:    0 = allow,  2 = block
```

Block pattern:

```python
import json, sys

def block(reason: str):
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(2)

def allow():
    sys.exit(0)
```

**Hook fail-open:** If a hook script crashes (import error, syntax error, unhandled
exception), Claude Code treats it as exit 0 and allows the tool call. Enforcement
silently disappears. Log all exceptions to stderr in every script.

```python
import traceback, sys

try:
    main()
except Exception:
    traceback.print_exc()   # goes to stderr, visible in CC logs
    sys.exit(0)             # fail open, don't block on script bugs
```

---

## 5. State File Contract

All three scripts share one state file per project, derived from CWD hash.
Never hardcode a path.

```python
import os, hashlib, json

def state_file_path() -> str:
    cwd = os.getcwd()
    h = hashlib.md5(cwd.encode()).hexdigest()
    state_dir = os.path.expanduser("~/.claude/state")
    os.makedirs(state_dir, exist_ok=True)
    return os.path.join(state_dir, f"lsp-ready-{h}")

def read_state(path: str) -> dict:
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        data = json.load(f)
    # Guard against stale state from a deleted+recreated project at same path
    if data.get("cwd") != os.getcwd():
        return {}
    return data

def write_state(path: str, data: dict) -> None:
    data["cwd"] = os.getcwd()
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
```

State file schema:

```json
{
  "cwd": "/your/project",
  "warmup_done": true,
  "nav_count": 4,
  "read_count": 6,
  "read_files": ["src/foo.py", "lib/bar.sh"],
  "last_tool": "LSP"
}
```

---

## 6. Repo Structure

```
~/claude-lsp-hooks/
    hooks/
        lsp_first_guard.py        ← PreToolUse: blocks grep on code symbols
        lsp_first_read_guard.py   ← PreToolUse: gates Read until LSP warmed
        lsp_usage_tracker.py      ← PostToolUse: tracks LSP nav calls
    lsp/
        lsp.json                  ← LSP server config (installed at user scope)
    tests/
        payloads/
            .gitkeep
            grep_payload.json     ← captured after Day One dump
            read_payload.json
            post_lsp_payload.json ← confirms tool_input field names for LSP calls
        test_tracker.sh
        test_guard.sh
        test_read_guard.sh
    docs/
        tool_names.md             ← confirmed tool_input field names from live payloads
    settings_fragment.json        ← hook registration block to merge into settings.json
    CLAUDE.md                     ← soft nudge instructions for the model
    README.md
```

```bash
mkdir claude-lsp-hooks && cd claude-lsp-hooks
git init
mkdir -p hooks lsp tests/payloads docs
touch hooks/lsp_usage_tracker.py hooks/lsp_first_guard.py hooks/lsp_first_read_guard.py
touch lsp/lsp.json
touch tests/payloads/.gitkeep
touch tests/test_tracker.sh tests/test_guard.sh tests/test_read_guard.sh
touch docs/tool_names.md settings_fragment.json CLAUDE.md README.md
chmod +x hooks/*.py
git add . && git commit -m "init: repo structure"
```

---

## 7. LSP Plugin Config (lsp/lsp.json)

This file is the only wiring between Claude Code and your LSP binaries.
No MCP. No marketplace. No third-party anything.

```json
{
  "python": {
    "command": "pyrefly",
    "args": ["lsp"],
    "extensionToLanguage": {
      ".py": "python",
      ".pyi": "python"
    },
    "transport": "stdio",
    "startupTimeout": 60000,
    "shutdownTimeout": 15000,
    "maxRestarts": 3
  },
  "bash": {
    "command": "bash-language-server",
    "args": ["start"],
    "extensionToLanguage": {
      ".sh": "bash",
      ".bash": "bash"
    },
    "transport": "stdio",
    "startupTimeout": 30000,
    "shutdownTimeout": 10000,
    "maxRestarts": 3
  }
}
```

Install at user scope (global, works across all projects):

```bash
# From inside a Claude Code session
/plugin install ~/claude-lsp-hooks@local
```

Or wire directly in `~/.claude/settings.json` under the `lsp` key — verify
the exact settings.json field name from Claude Code docs, as the plugin system
schema may differ from direct config injection.

---

## 8. CLAUDE.md — Soft Nudge Layer

Place in `~/.claude/CLAUDE.md` for global effect (or per-project `CLAUDE.md`).
This is secondary enforcement — hooks are primary. Note operation names here are
descriptive for the model, not hook matcher strings.

```markdown
## Code Navigation Policy

The LSP tool is available. Use it instead of text search for all code navigation.

| Task                    | Use                         | Never use                 |
| ----------------------- | --------------------------- | ------------------------- |
| Find where X is defined | LSP tool (goToDefinition)   | Grep, Glob                |
| Find all callers of X   | LSP tool (findReferences)   | Grep                      |
| List symbols in file    | LSP tool (documentSymbols)  | Read entire file          |
| Check for errors        | LSP tool (diagnostics)      | Running compiler manually |
| Search by symbol name   | LSP tool (workspaceSymbols) | Grep                      |

Only use Grep for: log file patterns, string literals, comments, non-code files.
```

---

## 9. Day One Task — Payload Dump (Before Any Hook Code)

Wire a throwaway dumper. Every field name in your hook scripts comes from here.
The top-level LSP tool name `LSP` is already confirmed — what you need from this
dump is the `tool_input` field structure for LSP calls (operation names, parameter
names, file path fields) and verification of Grep/Read payload field names.

Do not skip this.

```python
#!/usr/bin/env python3
# /tmp/dump_payload.py
import json, sys, os

payload = json.load(sys.stdin)

dump_file = "/tmp/hook_payloads.json"
existing = []
if os.path.exists(dump_file):
    with open(dump_file) as f:
        try:
            existing = json.load(f)
        except json.JSONDecodeError:
            existing = []

existing.append(payload)
with open(dump_file, "w") as f:
    json.dump(existing, f, indent=2)

sys.exit(0)
```

Register temporarily in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Grep",
        "hooks": [
          { "type": "command", "command": "python3 /tmp/dump_payload.py" }
        ]
      },
      {
        "matcher": "Read",
        "hooks": [
          { "type": "command", "command": "python3 /tmp/dump_payload.py" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "python3 /tmp/dump_payload.py" }
        ]
      }
    ]
  }
}
```

PostToolUse matcher is empty string to catch everything including LSP calls.

Fire each tool type in a CC session: trigger a Grep, trigger a Read, trigger an
LSP navigation (ask Claude "where is X defined"). Then:

```bash
cat /tmp/hook_payloads.json | python3 -m json.tool
```

What you're looking for in the LSP payload — example of what it might look like,
unconfirmed until you run this:

```json
{
  "tool_name": "LSP",
  "tool_input": {
    "operation": "goToDefinition",
    "symbol": "parse_config",
    "file": "src/main.py",
    "line": 42
  }
}
```

Save results:

- `tests/payloads/grep_payload.json`
- `tests/payloads/read_payload.json`
- `tests/payloads/post_lsp_payload.json`

Record confirmed `tool_input` field names in `docs/tool_names.md`. These are
permanent test fixtures. Re-run after every Claude Code version upgrade.

---

## 10. Build Order

### Script 1: lsp_usage_tracker.py

Simplest. PostToolUse only. No blocking. Reads stdin, writes state file.
Warmup signal: first LSP call (any operation) sets `warmup_done: true`.

What to learn: PostToolUse payload shape, state persistence, CWD derivation.

Acceptance test:

```bash
# tool_name is confirmed: LSP
echo "{\"cwd\":\"$(pwd)\",\"tool_name\":\"LSP\"}" \
  | python3 hooks/lsp_usage_tracker.py
echo "Exit: $?"
cat ~/.claude/state/lsp-ready-* | python3 -m json.tool
# warmup_done should be true, nav_count should be 1
```

---

### Script 2: lsp_first_guard.py

Core enforcement. PreToolUse on Grep AND Bash matchers. Blocks on code symbols,
allows non-symbol patterns.

Symbol detection:

```python
import re

SYMBOL_PATTERNS = [
    r'\b[a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*\b',  # camelCase
    r'\b[A-Z][a-zA-Z0-9]+\b',                      # PascalCase
    r'\b[a-z][a-z0-9]*_[a-z][a-z0-9_]*\b',        # snake_case
    r'\b\w+\.\w+\b',                                # dotted.symbol
]

ALLOW_PATTERNS = [
    r'^[A-Z][A-Z0-9_]+$',                    # SCREAMING_SNAKE env vars
    r'TODO|FIXME|HACK|NOTE',                  # comment keywords
    r'flex-\w+|text-\w+',                     # CSS classes
    r'\*\.(md|json|sql|yaml|css|html)$',      # non-code file globs
]
```

Block message references the confirmed top-level tool name `LSP`:

```python
def block_with_lsp_suggestion(symbol: str, lang: str) -> None:
    block(
        f"Symbol navigation detected. Use the LSP tool instead of Grep. "
        f"Ask Claude to find definition or references for '{symbol}' "
        f"using LSP (language: {lang or 'auto-detected from file extension'})."
    )
```

Language detection from payload (verify field names against dumped payload):

`pyrefly", "lsp"]``python
EXT_TO_LANG = {
    'py': 'python', 'pyi': 'python',
    'sh': 'bash',   'bash': 'bash',
}

def detect_language(payload: dict) -> str | None:
    path = payload.get("tool_input", {}).get("path", "")
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    return EXT_TO_LANG.get(ext)
```

Acceptance tests:

```bash
# Should block (symbol pattern)
echo '{"tool_name":"Grep","tool_input":{"pattern":"getUserById","path":"src/api.py"}}' \
  | python3 hooks/lsp_first_guard.py
echo "Exit should be 2: $?"

# Should allow (non-symbol)
echo '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":"src/api.py"}}' \
  | python3 hooks/lsp_first_guard.py
echo "Exit should be 0: $?"

# Should allow (env var pattern)
echo '{"tool_name":"Grep","tool_input":{"pattern":"DATABASE_URL","path":".env"}}' \
  | python3 hooks/lsp_first_guard.py
echo "Exit should be 0: $?"
```

---

### Script 3: lsp_first_read_guard.py

Reads state file. Gates Read calls until LSP is warmed up. Always allows non-code
files regardless of gate state.

Gate logic:

```
Gate 1 — warmup_done not set → BLOCK (trigger an LSP call first)
Gate 2 — reads 1-2           → ALLOW freely
Gate 3 — read 3, nav=0       → WARN (next read will block)
Gate 4 — reads 4-5, nav<1   → BLOCK (need 1 LSP call first)
Gate 5 — reads 6+, nav<2    → BLOCK (need 2 LSP calls first)
Gate 5 passed                → ALLOW forever (surgical mode unlocked)
```

Non-code file passthrough (always allow, regardless of gate):

```python
NON_CODE_EXTENSIONS = {
    'md', 'json', 'yaml', 'yml', 'env', 'sql',
    'css', 'html', 'toml', 'ini', 'cfg', 'txt', 'log'
}
```

Acceptance tests:

```bash
# Gate 1: no state file → block
rm -f ~/.claude/state/lsp-ready-*
echo '{"tool_name":"Read","tool_input":{"file_path":"src/main.py"}}' \
  | python3 hooks/lsp_first_read_guard.py
echo "Exit should be 2: $?"

# Non-code file → always allow regardless of gate state
echo '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}' \
  | python3 hooks/lsp_first_read_guard.py
echo "Exit should be 0: $?"

# After warmup written by tracker → allow
echo "{\"cwd\":\"$(pwd)\",\"tool_name\":\"LSP\"}" \
  | python3 hooks/lsp_usage_tracker.py
echo '{"tool_name":"Read","tool_input":{"file_path":"src/main.py"}}' \
  | python3 hooks/lsp_first_read_guard.py
echo "Exit should be 0: $?"
```

---

## 11. settings.json — Final Registration

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Grep",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/YOUR_USER/claude-lsp-hooks/hooks/lsp_first_guard.py"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/YOUR_USER/claude-lsp-hooks/hooks/lsp_first_guard.py"
          }
        ]
      },
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/YOUR_USER/claude-lsp-hooks/hooks/lsp_first_read_guard.py"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "LSP",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/YOUR_USER/claude-lsp-hooks/hooks/lsp_usage_tracker.py"
          }
        ]
      }
    ]
  }
}
```

PostToolUse matcher `"LSP"` is confirmed from the official Anthropic tools
reference. No payload dump required to fill this in — it is known.

---

## 12. Dependency Install Checklist (RHEL8)

```bash
# pyrefly — Python LSP
pip install pyrefly
pyrefly --help   # confirm 'lsp' subcommand exists before wiring

# bash-language-server — Bash LSP (Node required)
npm install -g bash-language-server
bash-language-server --version

# shellcheck + shfmt (PostToolUse formatting pipeline — separate concern)
dnf install shellcheck
curl -L https://github.com/mvdan/sh/releases/latest/download/shfmt_v3.8.0_linux_amd64 \
  -o /usr/local/bin/shfmt && chmod +x /usr/local/bin/shfmt

# Verify full chain
which pyrefly bash-language-server shellcheck shfmt
python3 --version

# Verify Claude Code version (needs 2.0.74+ for native LSP)
claude --version
```

No Go toolchain needed. No binary to build or pin.

---

## 13. Known Risks — Don't Get Surprised

| Risk                                                  | Detail                                                                                                                                                                                                       |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| LSP tool_input field names unknown until payload dump | Top-level tool name `LSP` is confirmed. The `tool_input` field structure (operation names, parameter names) is not documented — dump first before writing tracker or guard logic that inspects LSP payloads. |
| pyrefly LSP invocation                                | `pyrefly lsp` speaks stdio natively — no `--stdio` flag. Verify with `pyrefly --help` first.                                                                                                                 |
| pyrefly config                                        | `project-includes` in `pyrefly.toml` fails hard on zero glob matches. If a configured directory doesn't exist, pyrefly refuses to start.                                                                     |
| Hook fail-open                                        | Script crash = exit 0 = allow. Add stderr logging and top-level exception handler to every script.                                                                                                           |
| State file stale                                      | Project deleted and recreated at same path = same MD5 hash = stale warmup state. `read_state()` must verify `cwd` field matches `os.getcwd()`.                                                               |
| bash-language-server ceiling                          | Works within-file and across sourced files for find_definition. Complex heredocs and dynamic `source` calls will confuse it. Not a blocker, just a known limit.                                              |
| CC LSP still maturing                                 | Native LSP added in v2.0.74. The `tool_input` payload schema may shift across CC updates. Re-run payload dump after CC upgrades and diff against saved fixtures.                                             |
| Model drift                                           | In long sessions, Claude Code may revert to grep despite hooks. Hooks catch and block the attempt — but watch for the pattern across sessions.                                                               |

---

## 14. Test Discipline — One Rule

Every hook must have a test that pipes a saved payload fixture and asserts exit
code before being wired into a live session. No exceptions.

```bash
#!/bin/bash
# tests/test_tracker.sh
set -euo pipefail

# tool_name is confirmed: LSP
PAYLOAD="{\"cwd\":\"$(pwd)\",\"tool_name\":\"LSP\"}"

echo "$PAYLOAD" | python3 hooks/lsp_usage_tracker.py
[[ $? -eq 0 ]] && echo "PASS: tracker exit 0" || { echo "FAIL: tracker non-zero exit"; exit 1; }

STATE=$(cat ~/.claude/state/lsp-ready-* 2>/dev/null)
echo "$STATE" | python3 -m json.tool
echo "$STATE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('nav_count', 0) >= 1, 'nav_count not incremented'
assert d.get('warmup_done') == True, 'warmup_done not set'
print('PASS: state file correct')
"
```

---

## 15. Milestone Checklist

```
[ ] Repo created, structure committed
[ ] lsp/lsp.json written with pyrefly + bash-language-server config
[ ] pyrefly and bash-language-server installed and on PATH
[ ] CLAUDE.md written and placed in ~/.claude/CLAUDE.md
[ ] Payload dumper wired to settings.json temporarily
[ ] Real payloads captured: grep, read, post-lsp — saved to tests/payloads/
[ ] LSP tool_input field names confirmed and recorded in docs/tool_names.md
[ ] Payload dumper removed from settings.json
[ ] lsp_usage_tracker.py written and passing test
[ ] lsp_first_guard.py written and passing tests (block + allow cases)
[ ] lsp_first_read_guard.py written and passing gate tests
[ ] settings.json finalized with confirmed hook registrations
[ ] LSP plugin config installed at user scope in Claude Code
[ ] End-to-end: ask Claude "where is X defined" → see LSP tool call, not Grep
[ ] End-to-end: grep attempt on symbol → blocked, block message shown
[ ] PostToolUse tracker fires and nav_count increments after LSP call
```

---

## 16. Reference Links

- [Claude Code tools reference](https://code.claude.com/docs/en/tools-reference) — Confirms `LSP` as the exact built-in tool name
- [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) — Anthropic's official plugin marketplace (pyright-lsp is here; pyrefly is not)
- [Piebald-AI/claude-code-lsps](https://github.com/Piebald-AI/claude-code-lsps) — Community LSP plugin marketplace (bash-language-server, basedpyright)
- [michael-denyer/pyrefly-lsp-cc-plugin](https://github.com/michael-denyer/pyrefly-lsp-cc-plugin) — Community pyrefly plugin (reference for lsp.json schema)
- [pyrefly](https://pyrefly.org) — Python LSP (Meta/Facebook, Rust-based)
- [bash-language-server](https://github.com/bash-lsp/bash-language-server) — Bash LSP
- [Claude Code hooks docs](https://docs.anthropic.com/en/docs/claude-code/hooks) — Hook payload spec, exit codes, matcher syntax
- [Claude Code changelog](https://docs.anthropic.com/en/docs/claude-code/changelog) — Track LSP behavior changes across CC versions
