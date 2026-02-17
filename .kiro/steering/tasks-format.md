---
inclusion: manual
---

# tasks.md Authoring Guide

How to write `tasks.md` files that btb can parse, schedule, and execute correctly.

## Line Format

Every task line must be a markdown checkbox. Lines without checkboxes are ignored by the parser.

```
- [ ] N. Parent task description
  - [ ] N.M Subtask description
```

- `[ ]` = incomplete, `[x]` = complete. Workers flip `[ ]` → `[x]` on completion.
- Parent IDs are bare integers: `1`, `2`, `3`
- Subtask IDs are dotted: `1.1`, `1.2`, `2.1`, `2.10`
- The dot-space after parent IDs (`1. `) is required. Subtask IDs use dot-digit (`1.1`) with no dot-space.
- Descriptions must be on the same line as the checkbox. Multi-line descriptions are not parsed.
- IDs must be unique across the entire file.

## What Gets Executed

Only leaf tasks are scheduled as workers:

- If a parent has subtasks, only the subtasks run. The parent auto-completes when all its children finish.
- If a parent has no subtasks (e.g. a standalone checkpoint), it runs as a leaf task itself.

```markdown
- [ ] 1. Setup infrastructure ← NOT executed (has children)
  - [ ] 1.1 Create database schema ← executed
  - [ ] 1.2 Add seed data ← executed
- [ ] 2. Verify setup works ← executed (no children = leaf)
```

## Implicit Ordering

Subtasks within the same parent are treated as sequential: `2.1 → 2.2 → 2.3`. The planner and fallback DAG builder both enforce this. Cross-group dependencies (e.g. 3.1 depends on 1.2) are inferred by the planner agent from file overlap and semantic analysis.

## Context and References

Workers receive the full spec directory. Each worker prompt includes:

1. `tasks.md` — the task list
2. `design.md` — architecture and implementation guidance
3. `requirements.md` — acceptance criteria

Additionally, if `.kiro/steering/` docs exist (auto-generated on first run), every agent gets persistent project context.

Use free-form markdown around the checkbox lines to give workers the context they need. The parser ignores non-checkbox lines, so you can add whatever you want between tasks:

### Reference blocks

Point workers to files they should read before starting. This is especially useful when tasks touch unfamiliar code:

```markdown
## Task 2: Refactor the query engine

**Context gathering**: Before making changes, read:

- Reference: docs/architecture.md (query pipeline section)
- Reference: src/engine/parser.rs (the `parse_query` method)
- Reference: src/engine/types.rs (`QueryNode` enum variants)

- [ ] 2.1 Split the parser into streaming and batch paths
- [ ] 2.2 Add error recovery to the streaming path
```

### Non-regression warnings

Flag constraints that workers must respect. These appear as free text and are included in the worker's prompt context when it reads the task file:

```markdown
- [ ] 3.1 Add `shed_lowest_phase3` method
- [ ] 3.2 Insert into shedding hierarchy between step 1 and step 2

⚠️ **Non-regression:** Existing shedding methods must keep working.
The relative order of existing steps must be preserved.
```

### Acceptance criteria references

Link tasks back to requirements so the reviewer can verify correctness:

```markdown
- [ ] 4.1 Update conversion to merge phase3 items into the items vec

**Refs: AC-1.6, AC-3.1**
```

### External document references

The `design.md` supports Kiro's file reference syntax for pulling in external docs:

```markdown
> **Key Reference**: #[[file:docs/architecture.md]]
```

Workers can read any file in the repo. Reference paths in tasks.md are plain text (not parsed), but workers follow them as instructions.

### Global constraints

Add a blockquote at the top of the file for constraints that apply to every task:

```markdown
> **Global Constraint:** Every task must preserve existing functionality.
> Existing tests must continue to pass after each task.
```

## Complete Example

```markdown
# Feature Name — Implementation Tasks

> **Key Reference**: Reference: docs/spec.md

> **Global Constraint:** Existing tests must pass after each task.

## Task 1: Add data model

**Context gathering**: Read src/models.rs and src/types.rs first.

- Reference: src/models.rs (`User` struct, `new()` method)
- Reference: src/types.rs (`Role` enum)

- [ ] 1.1 Add `permissions` field to `User` struct
- [ ] 1.2 Add `Permission` enum with CRUD variants
- [ ] 1.3 Update `User::new()` to accept optional permissions

⚠️ **Non-regression:** Existing `User` construction sites must still compile.

**Refs: AC-1.1, AC-1.2**

## Task 2: Checkpoint — Data model compiles

- [ ] 2. Run `cargo check` and verify no errors

## Task 3: Add authorization logic

- Reference: src/middleware/auth.rs (current auth flow)

- [ ] 3.1 Add `has_permission(&self, perm: Permission) -> bool` to `User`
- [ ] 3.2 Wire permission check into request middleware
- [ ] 3.3 Write unit tests for permission checks

**Refs: AC-2.1, AC-2.3**
```

## Things That Break the Parser

- Missing checkbox: `- 1.1 Do something` — invisible to the parser.
- Wrong checkbox format: `- () 1.1` or `* [ ] 1.1` — not matched.
- Dot-space in subtask ID: `- [ ] 1. 1 Do something` — parsed as parent `1`, not subtask `1.1`.
- Duplicate IDs: two lines with `1.1` — completion detection becomes unreliable.
- Non-numeric IDs: `- [ ] A.1 Do something` — not matched by `\d+\.\d+`.
