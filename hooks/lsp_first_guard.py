#!/usr/bin/env python3
"""PreToolUse hook: blocks grep/bash when pattern matches a code symbol."""
import json
import re
import sys
import traceback


SYMBOL_PATTERNS = [
    re.compile(r"\b[a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*\b"),  # camelCase
    re.compile(r"\b[A-Z][a-zA-Z0-9]+\b"),                     # PascalCase
    re.compile(r"\b[a-z][a-z0-9]*_[a-z][a-z0-9_]*\b"),       # snake_case
    re.compile(r"\b\w+\.\w+\b"),                               # dotted.symbol
]

ALLOW_PATTERNS = [
    re.compile(r"^[A-Z][A-Z0-9_]+$"),              # SCREAMING_SNAKE env vars
    re.compile(r"TODO|FIXME|HACK|NOTE"),            # comment keywords
    re.compile(r"flex-\w+|text-\w+"),               # CSS classes
    re.compile(r"\*\.(md|json|sql|yaml|css|html)$"),  # non-code file globs
]

EXT_TO_LANG = {
    "py": "python",
    "pyi": "python",
    "sh": "bash",
    "bash": "bash",
}


def block(reason: str) -> None:
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(2)


def is_allowed(pattern: str) -> bool:
    return any(ap.search(pattern) for ap in ALLOW_PATTERNS)


def is_symbol(pattern: str) -> bool:
    return any(sp.search(pattern) for sp in SYMBOL_PATTERNS)


def detect_language(payload: dict) -> str:
    path = payload.get("tool_input", {}).get("path", "")
    if "." in path:
        ext = path.rsplit(".", 1)[-1].lower()
        return EXT_TO_LANG.get(ext, "")
    return ""


def extract_pattern(payload: dict) -> str:
    tool_input = payload.get("tool_input", {})
    # Grep tool uses "pattern"
    pattern = tool_input.get("pattern", "")
    if pattern:
        return pattern
    # Bash tool — extract grep pattern from command string
    command = tool_input.get("command", "")
    if command and re.search(r"\b(grep|rg|ag)\b", command):
        parts = command.split()
        # Find the grep/rg/ag command, then grab the first non-flag arg after it
        cmd_names = {"grep", "rg", "ag"}
        found_cmd = False
        for part in parts:
            if part in cmd_names:
                found_cmd = True
                continue
            if found_cmd and not part.startswith("-"):
                return part
    return ""


def main() -> None:
    payload = json.load(sys.stdin)
    tool_name = payload.get("tool_name", "")

    if tool_name not in ("Grep", "Bash"):
        sys.exit(0)

    # For Bash, only intercept grep-like commands
    if tool_name == "Bash":
        command = payload.get("tool_input", {}).get("command", "")
        if not re.search(r"\b(grep|rg|ag)\b", command):
            sys.exit(0)

    pattern = extract_pattern(payload)
    if not pattern:
        sys.exit(0)

    if is_allowed(pattern):
        sys.exit(0)

    if is_symbol(pattern):
        lang = detect_language(payload)
        block(
            f"Symbol navigation detected. Use the LSP tool instead of Grep. "
            f"Ask Claude to find definition or references for '{pattern}' "
            f"using LSP{f' (language: {lang})' if lang else ''}."
        )

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(0)
