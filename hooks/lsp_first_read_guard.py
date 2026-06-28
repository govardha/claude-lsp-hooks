#!/usr/bin/env python3
"""PreToolUse hook: gates Read calls until LSP is warmed up."""
import hashlib
import json
import os
import sys
import traceback


STATE_DIR = os.path.expanduser("~/.local/share/lsp-hooks/state")

NON_CODE_EXTENSIONS = {
    "md", "json", "yaml", "yml", "env", "sql",
    "css", "html", "toml", "ini", "cfg", "txt", "log",
}


def state_file_path() -> str:
    cwd = os.getcwd()
    h = hashlib.md5(cwd.encode()).hexdigest()
    return os.path.join(STATE_DIR, f"lsp-ready-{h}")


def read_state(path: str) -> dict:
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        data = json.load(f)
    if data.get("cwd") != os.getcwd():
        return {}
    return data


def write_state(path: str, data: dict) -> None:
    data["cwd"] = os.getcwd()
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def block(reason: str) -> None:
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(2)


def get_extension(file_path: str) -> str:
    if "." in file_path:
        return file_path.rsplit(".", 1)[-1].lower()
    return ""


def main() -> None:
    payload = json.load(sys.stdin)
    tool_input = payload.get("tool_input", {})
    file_path = tool_input.get("file_path", "")

    # Non-code files always pass
    if get_extension(file_path) in NON_CODE_EXTENSIONS:
        sys.exit(0)

    sf = state_file_path()
    state = read_state(sf)

    # Gate 1: no warmup yet
    if not state.get("warmup_done"):
        block(
            "LSP not warmed up yet. Use the LSP tool first (e.g., find a symbol "
            "definition) before reading code files."
        )

    nav_count = state.get("nav_count", 0)
    read_count = state.get("read_count", 0)

    # Gate 2: reads 1-2 — allow freely
    if read_count < 2:
        state["read_count"] = read_count + 1
        write_state(sf, state)
        sys.exit(0)

    # Gate 3: read 3, nav=0 — warn (allow but next will block)
    if read_count == 2 and nav_count == 0:
        state["read_count"] = read_count + 1
        write_state(sf, state)
        # Allow but the model sees this is getting close
        sys.exit(0)

    # Gate 4: reads 3-4, nav < 1 — block
    if read_count < 5 and nav_count < 1:
        block(
            "Too many file reads without LSP navigation. Use the LSP tool "
            "(goToDefinition or findReferences) before reading more code files."
        )

    # Gate 5: reads 5+, nav < 2 — block
    if read_count >= 5 and nav_count < 2:
        block(
            "Heavy file reading detected. Use the LSP tool at least twice "
            "for symbol navigation before continuing to read code files."
        )

    # All gates passed — allow
    state["read_count"] = read_count + 1
    write_state(sf, state)
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(0)
