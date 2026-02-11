# Tech Stack

- **Language**: Bash (compatible with bash 3.2+ for macOS)
- **Runtime dependencies**: `kiro-cli`, `git`, `python3`, `perl` (optional, for TUI input)
- **Python usage**: Inline python3 scripts for JSON parsing, DAG analysis, task file manipulation, and cycle detection — no external Python packages required
- **Terminal UI**: Pure ANSI escape codes, no curses or external TUI libraries
- **Process model**: Background subshells with PID tracking, heartbeat files for activity detection
- **Isolation**: Git worktrees for parallel task execution
- **Concurrency control**: File-based locks (`.ralph-merge-lock`), PID-aware with stale detection

## Configuration

All settings live in `config.sh` as shell variables with env-var overrides. Key groups: concurrency, models, review gate, retry/safety, logging.

## Common Commands

```sh
# Run against a spec
./btb.sh <spec-name>

# Dry run (DAG analysis only)
./btb.sh <spec-name> --dry-run

# Sequential mode (bypasses DAG)
./btb.sh <spec-name> --sequential

# Clean up worktrees, branches, locks
./btb.sh --cleanup

# Validate DAG completeness
./validate-dag.sh <spec-name> [dag.json]

# Bootstrap btb into a target repo
/path/to/btb/setup.sh
```

## Logging

All logs go to `.ralph-logs/` — debug logs, per-task agent output, DAG JSON snapshots, steering generation logs, and review logs.
