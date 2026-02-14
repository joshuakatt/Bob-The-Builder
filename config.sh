#!/bin/bash
# config.sh - Bob the Builder Configuration
# All tunable parameters in one place.

# ─── Spec Settings ───────────────────────────────────────────
# SPEC_DIR can be set directly (any path) or derived from SPEC_NAME.
# Priority: explicit SPEC_DIR > SPEC_NAME-based lookup
if [ -z "${SPEC_DIR:-}" ]; then
    SPEC_NAME="${SPEC_NAME:-}"
    if [ -n "$SPEC_NAME" ]; then
        # Try .kiro/specs/<name> first, then specs/<name>, then <name> as-is
        if [ -d ".kiro/specs/${SPEC_NAME}" ]; then
            SPEC_DIR=".kiro/specs/${SPEC_NAME}"
        elif [ -d "specs/${SPEC_NAME}" ]; then
            SPEC_DIR="specs/${SPEC_NAME}"
        elif [ -d "${SPEC_NAME}" ]; then
            SPEC_DIR="${SPEC_NAME}"
        else
            SPEC_DIR=".kiro/specs/${SPEC_NAME}"  # default, will fail at validation
        fi
    fi
fi
TASK_FILE="${SPEC_DIR}/tasks.md"
DESIGN_FILE="${SPEC_DIR}/design.md"
REQUIREMENTS_FILE="${SPEC_DIR}/requirements.md"

# ─── Concurrency Settings ────────────────────────────────────
MAX_PARALLEL=${MAX_PARALLEL:-6}           # Max total concurrent agent processes
REVIEW_RESERVED_SLOTS=${REVIEW_RESERVED_SLOTS:-1}  # Slots reserved for reviewer/fixer agents
MAX_ITERATIONS_PER_TASK=${MAX_ITERS:-20}  # Max iterations per task loop
SYNC_INTERVAL=${SYNC_INTERVAL:-5}         # Seconds between orchestrator polls
WORKTREE_BASE="../.ralph-worktrees"       # Where git worktrees live (outside repo)

# Derived: effective worker slots = total - reserved (minimum 1)
WORKER_SLOTS=$((MAX_PARALLEL - REVIEW_RESERVED_SLOTS))
[ "$WORKER_SLOTS" -lt 1 ] && WORKER_SLOTS=1

# ─── Agent Settings ──────────────────────────────────────────
PLANNER_AGENT="planner"
WORKER_AGENT="player"
REVIEWER_AGENT="reviewer"

# ─── Steering Settings ───────────────────────────────────────
# Steering docs give agents persistent project context.
# Generated automatically from spec + codebase if missing.
STEERING_AGENT="${STEERING_AGENT:-planner}"       # Agent used to generate steering
STEERING_MODEL="${STEERING_MODEL:-claude-opus-4.6}" # Model for steering generation

# ─── Model Settings ──────────────────────────────────────────
# Available models for the planner to choose from (kiro-cli --model values).
# Valid models: auto, claude-haiku-4.5, claude-sonnet-4, claude-sonnet-4.5, claude-opus-4.6
# Ordered cheapest → most expensive. The planner assigns one per task.
AVAILABLE_MODELS="claude-sonnet-4.5,claude-opus-4.6"
DEFAULT_TASK_MODEL="claude-opus-4.6"  # Fallback when planner doesn't assign a model

# ─── Review Settings ─────────────────────────────────────────
# Post-wave quality gate. Reviewer audits each wave's work against the spec.
# If rejected, the player gets a fix attempt before re-review.
ENABLE_REVIEW=${ENABLE_REVIEW:-true}          # Master switch for review gate
MAX_REVIEW_RETRIES=${MAX_REVIEW_RETRIES:-4}   # Review→fix cycles per wave
REVIEWER_MODEL="${REVIEWER_MODEL:-claude-opus-4.6}"  # Model override for reviewer
REVIEW_FIX_AGENT="${REVIEW_FIX_AGENT:-player}" # Agent used to fix review rejections
REVIEW_BATCH_SIZE=${REVIEW_BATCH_SIZE:-3}     # Review after this many tasks are synced

# ─── Completion Tokens ───────────────────────────────────────
TASK_COMPLETE_PREFIX="TASK_COMPLETE"      # Worker outputs TASK_COMPLETE::<task_id>
ALL_COMPLETE="ALL_TASKS_COMPLETE"         # Final completion signal

# ─── Retry / Safety ─────────────────────────────────────────
MAX_RETRIES=${MAX_RETRIES:-10}            # Retries per task on failure
MAX_DAG_REPAIR_ATTEMPTS=${MAX_DAG_REPAIR_ATTEMPTS:-3}  # Planner re-prompts to patch missing tasks
RATE_LIMIT_PAUSE=${RATE_LIMIT_PAUSE:-3}   # Seconds between loop spawns
STALE_THRESHOLD=${STALE_THRESHOLD:-600}   # Seconds of inactivity before a worker is killed
                                          # This is an inactivity-based kill mechanism.
                                          # "Activity" = log output, descendant processes, or CPU usage.
                                          # Set high enough for long builds/tests (10 min default).
                                          # NOTE: LLM health check (below) is a separate wall-clock-based mechanism.
JOB_TIMEOUT=${JOB_TIMEOUT:-43200}         # Hard wall-clock timeout per task (seconds, 0=disabled)
                                          # Kills worker regardless of activity after this many seconds.
                                          # Safety net for verification loops where the agent stays
                                          # "active" but never converges. Default 2 hours.

# ─── LLM Health Check ───────────────────────────────────────
HEALTH_CHECK_ENABLED=${HEALTH_CHECK_ENABLED:-true}
HEALTH_CHECK_INTERVAL=${HEALTH_CHECK_INTERVAL:-1800}    # Seconds between health checks (30 min)
HEALTH_CHECK_MODEL=${HEALTH_CHECK_MODEL:-claude-sonnet-4.5}
HEALTH_CHECK_LOG_LINES=${HEALTH_CHECK_LOG_LINES:-50}    # Log lines in context

# ─── Shared Build Cache ─────────────────────────────────────
# Worktrees share a single build cache to avoid duplicating multi-GB
# build artifacts (Rust target/, Node node_modules/, Python .venv/, etc.)
# across parallel workers. Set to empty string to disable.
SHARED_BUILD_CACHE_DIR="${SHARED_BUILD_CACHE_DIR:-../.ralph-build-cache}"

# ─── Logging ─────────────────────────────────────────────────
LOG_DIR=".ralph-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
