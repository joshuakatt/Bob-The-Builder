# Bob the Builder

Concurrent task orchestrator for [Kiro](https://kiro.dev) specs. Takes a spec with a `tasks.md`, analyzes dependencies, builds a DAG, and executes tasks in parallel using git worktrees for isolation.

Each task gets its own worktree and agent process. A planner assigns models per task, a reviewer audits completed work, and everything syncs back to your main branch automatically.

## Prerequisites

- **kiro-cli** — installed and authenticated
- **git** — any recent version
- **python3** — for DAG analysis
- **perl** — for TUI keyboard input (optional, use `--no-tui` without it)

Run `setup.sh` in your target repo to validate prerequisites and install agent configs:

```sh
/path/to/btb/setup.sh
```

## Usage

```sh
# By spec name (looks in .kiro/specs/<name>)
./btb.sh my-feature

# By explicit path
./btb.sh --spec-dir path/to/spec

# Sequential mode (one task at a time)
./btb.sh my-feature --sequential

# Dry run (analyze DAG only, no execution)
./btb.sh my-feature --dry-run

# Skip the review gate
./btb.sh my-feature --no-review

# Plain log output instead of TUI
./btb.sh my-feature --no-tui

# Set max parallel workers
./btb.sh my-feature --max-parallel 6

# Clean up all worktrees, branches, and locks
./btb.sh --cleanup
```

## Spec Structure

Your spec directory needs at minimum a `tasks.md`. The planner also reads `design.md` and `requirements.md` if present.

```
.kiro/specs/my-feature/
├── tasks.md          # required — task list with checkboxes
├── design.md         # recommended — architecture and implementation guidance
└── requirements.md   # recommended — acceptance criteria
```

Tasks in `tasks.md` use this format:

```markdown
- [ ] 1. Set up project infrastructure
  - [ ] 1.1 Initialize project with TypeScript config
  - [ ] 1.2 Set up database schema
- [ ] 2. Implement core features
  - [ ] 2.1 Build the API layer
  - [ ] 2.2 Add authentication
```

The planner analyzes dependencies between tasks and groups them into waves for parallel execution. Subtasks (1.1, 1.2, etc.) are the units of work — parent tasks auto-complete when all their subtasks finish.

## Configuration

All settings live in `config.sh`. Most can be overridden via environment variables.

### Concurrency

| Setting                   | Default | Description                                           |
| ------------------------- | ------- | ----------------------------------------------------- |
| `MAX_PARALLEL`            | `4`     | Total concurrent agent processes (workers + reviewer) |
| `REVIEW_RESERVED_SLOTS`   | `1`     | Slots reserved for the reviewer agent                 |
| `MAX_ITERATIONS_PER_TASK` | `20`    | Max agent iterations per task before giving up        |

Effective worker slots = `MAX_PARALLEL` - `REVIEW_RESERVED_SLOTS`. With defaults, that's 3 workers + 1 reviewer.

### Models

| Setting              | Default                             | Description                                  |
| -------------------- | ----------------------------------- | -------------------------------------------- |
| `AVAILABLE_MODELS`   | `claude-sonnet-4.5,claude-opus-4.6` | Models the planner can assign to tasks       |
| `DEFAULT_TASK_MODEL` | `claude-opus-4.5`                   | Fallback when planner doesn't assign a model |
| `STEERING_MODEL`     | `claude-opus-4.6`                   | Model used to generate steering docs         |
| `REVIEWER_MODEL`     | `claude-opus-4.6`                   | Model used for the review gate               |

The planner picks a model per task based on complexity. Simple tasks get cheaper models, complex ones get more capable models.

### Review Gate

| Setting              | Default | Description                                       |
| -------------------- | ------- | ------------------------------------------------- |
| `ENABLE_REVIEW`      | `true`  | Master switch for post-batch quality review       |
| `REVIEW_BATCH_SIZE`  | `3`     | Number of synced tasks before triggering a review |
| `MAX_REVIEW_RETRIES` | `2`     | Review→fix cycles before accepting                |

The reviewer audits completed work against the spec after every batch of synced tasks. If it finds issues, the player agent gets a fix attempt. Use `--no-review` to skip entirely.

### Retry and Safety

| Setting            | Default | Description                                   |
| ------------------ | ------- | --------------------------------------------- |
| `MAX_RETRIES`      | `10`    | Retries per task on failure                   |
| `STALE_THRESHOLD`  | `600`   | Seconds of inactivity before killing a worker |
| `RATE_LIMIT_PAUSE` | `3`     | Seconds between spawning workers              |

The stale threshold is activity-based, not wall-clock. A worker is considered active if its log file is growing, it has child processes running (e.g. a long test suite), or the process is alive. Tasks can run for hours as long as something is happening.

When a task fails and retries, the failure context (last 30 lines of output, exit code, failure type) is injected into the retry prompt so the agent can learn from the previous attempt.

## Steering Docs

On first run, if your repo doesn't have `.kiro/steering/` docs, they're auto-generated from your spec and codebase. These give all agents persistent project context — architecture decisions, conventions, tech stack, etc.

If you already have steering docs, they're used as-is.

## How It Works

1. **Analysis** — The planner agent reads your tasks and design docs, builds a dependency DAG, and assigns models per task
2. **Execution** — Tasks are spawned as workers in isolated git worktrees. A task becomes ready the moment all its dependencies are synced to main
3. **Sync** — Completed tasks are merged back to main immediately (serialized by lock). Merge conflicts are resolved by a dedicated resolver agent
4. **Review** — After a batch of tasks sync, the reviewer audits the work. If issues are found, a fix agent addresses them
5. **Completion** — Parent tasks auto-complete when all subtasks finish. The run ends when all tasks are resolved

## Logs

All logs go to `.ralph-logs/` in your repo:

- `debug_<timestamp>.log` — orchestrator debug log (scheduler decisions, spawn/sync events)
- `task_<id>_<timestamp>.log` — per-task agent output (full kiro-cli conversation)
- `dag_<timestamp>.json` — the dependency DAG produced by the planner
- `steering_<timestamp>.log` — steering doc generation output

## Cleanup

If a run is interrupted or you need to reset:

```sh
./btb.sh --cleanup
```

This removes all worktrees, ralph branches, and lock files.
