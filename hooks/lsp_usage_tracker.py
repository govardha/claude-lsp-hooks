#!/usr/bin/env python3
"""PostToolUse hook: tracks LSP navigation calls and sets warmup state."""
import hashlib
import json
import os
import sys
import traceback


STATE_DIR = os.path.expanduser("~/.local/share/lsp-hooks/state")


def state_file_path() -> str:
    cwd = os.getcwd()
    h = hashlib.md5(cwd.encode()).hexdigest()
    os.makedirs(STATE_DIR, exist_ok=True)
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
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def main() -> None:
    payload = json.load(sys.stdin)
    tool_name = payload.get("tool_name", "")

    if tool_name != "LSP":
        sys.exit(0)

    sf = state_file_path()
    state = read_state(sf)
    state["warmup_done"] = True
    state["nav_count"] = state.get("nav_count", 0) + 1
    state["last_tool"] = "LSP"
    write_state(sf, state)
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(0)
