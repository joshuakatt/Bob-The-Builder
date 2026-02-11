# Project Structure

```
btb.sh              # Main entry point — orchestrator, scheduler, cleanup trap
config.sh           # All tunable parameters (concurrency, models, review, retry)
setup.sh            # Bootstrap script — validates prereqs, installs agents into target repo
validate-dag.sh     # Standalone DAG completeness checker

lib/
  dag.sh            # DAG analysis, planner agent integration, repair loop, fallback builder
  worker.sh         # Single-task worker — runs in a worktree, iterates kiro-cli until complete
  syncer.sh         # Merge lock, worktree-to-main sync, agent-based conflict resolution
  reviewer.sh       # Post-batch review gate with fix-retry cycles
  steering.sh       # Auto-generates .kiro/steering/ docs from spec + codebase
  tui.sh            # Full-screen terminal UI — DAG tree, worker output, progress bar
  utils.sh          # Shared utilities — logging, task parsing, git helpers, process management

.kiro/agents/       # Agent config JSON files (planner, player, reviewer)
.kiro/specs/        # Spec directories with tasks.md, design.md, requirements.md
.kiro/steering/     # Project context docs consumed by all agents
```

## Architecture Patterns

- **Flat file state**: Task state (status, PID, retries, heartbeat) stored as individual files in a temp directory (`$STATE_DIR`) rather than associative arrays — avoids bash 3.2 limitations
- **Guard sourcing**: Each lib file checks if its functions are already defined before sourcing dependencies, preventing double-source issues
- **Fault isolation**: TUI functions wrap all logic in `set +eu` blocks so rendering bugs never crash the orchestrator
- **Inline Python**: Complex logic (JSON parsing, task matching, cycle detection) uses heredoc Python scripts — no external packages, no temp files where avoidable
- **Activity-based watchdog**: Workers are killed only after `STALE_THRESHOLD` seconds of inactivity (no log growth, no child processes), not wall-clock time
- **`awk` over `grep`**: All text matching uses `awk` to avoid exit-code-1-on-zero-matches breaking `set -euo pipefail`
