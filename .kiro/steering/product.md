# Bob the Builder (btb)

Concurrent task orchestrator for Kiro specs. Reads a spec's `tasks.md`, analyzes task dependencies via a planner agent, builds a DAG, and executes tasks in parallel using git worktrees for isolation.

Each task runs in its own worktree with a dedicated agent process. A planner assigns AI models per task based on complexity, a reviewer audits completed work, and results sync back to the main branch automatically.

## Key Concepts

- **Specs**: Feature definitions in `.kiro/specs/<name>/` containing `tasks.md`, `design.md`, and `requirements.md`
- **DAG**: Directed acyclic graph of task dependencies, built by the planner agent, organized into execution waves
- **Worktrees**: Git worktrees provide isolation so parallel tasks don't conflict
- **Review gate**: Post-batch quality audit by a reviewer agent with fix-retry cycles
- **Steering docs**: Auto-generated project context files in `.kiro/steering/` consumed by all agents

## Workflow

1. Planner reads spec files, builds dependency DAG, assigns models per task
2. Tasks spawn as workers in isolated git worktrees, becoming ready when all dependencies are synced
3. Completed tasks merge back to main immediately (serialized by lock)
4. Reviewer audits batches of synced tasks; rejected work gets fix attempts
5. Parent tasks auto-complete when all subtasks finish
