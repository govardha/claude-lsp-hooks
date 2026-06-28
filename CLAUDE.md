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
