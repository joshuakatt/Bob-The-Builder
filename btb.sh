#!/bin/bash
# btb.sh - Bob the Builder: Concurrent Task Orchestrator
#
# DAG-based parallel task execution using git worktrees for isolation
# and a planner agent for dependency analysis.
# Features a full-screen TUI dashboard with DAG visualization.
#
# Usage:
#   ./btb.sh <spec_name_or_path> [options]
#   ./btb.sh --spec-dir path/to/spec [options]

set -euo pipefail

# Ignore SIGPIPE — the orchestrator manages many pipelines (TUI rendering,
# git commands, tee, etc.) where a downstream reader can close early. SIGPIPE
# is fatal by default and combined with set -e would kill the entire process.
# Individual pipeline failures are already handled with || true throughout.
trap '' PIPE

# ─── Error Tracing ───────────────────────────────────────────
# Capture the exact line and command that caused set -e to exit.
_btb_err_handler() {
    local exit_code=$?
    local line_no=$1
    local cmd=$2
    local msg="[BTB CRASH] line ${line_no}: '${cmd}' exited with code ${exit_code}"
    echo "$msg" >&2
    # Also write to debug log if available
    if [ -n "${DEBUG_LOG:-}" ]; then
        echo "[$(date +%H:%M:%S)] ${msg}" >> "$DEBUG_LOG" 2>/dev/null || true
    fi
}
trap '_btb_err_handler ${LINENO} "${BASH_COMMAND}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Parse Arguments ─────────────────────────────────────────
SPEC_NAME=""
DRY_RUN=false
FORCE_SEQUENTIAL=false
USE_TUI=true
SKIP_REVIEW=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --spec-dir)      export SPEC_DIR="$2"; shift 2 ;;
        --max-parallel)  export MAX_PARALLEL="$2"; shift 2 ;;
        --max-iters)     export MAX_ITERS="$2"; shift 2 ;;
        --sequential)    FORCE_SEQUENTIAL=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --no-tui)        USE_TUI=false; shift ;;
        --no-review)     SKIP_REVIEW=true; shift ;;
        --cleanup)
            source "${SCRIPT_DIR}/lib/utils.sh"
            cleanup_all_ralph
            exit 0 ;;
        --help|-h)
            echo "Usage: $0 <spec_name_or_path> [options]"
            echo "       $0 --spec-dir path/to/spec [options]"
            echo ""
            echo "  <spec_name_or_path>  Spec name (.kiro/specs/<name>) or direct path to spec dir"
            echo "  --spec-dir PATH      Explicit path to spec directory (has tasks.md)"
            echo "  --max-parallel N     Max total concurrent agents (default: 3)"
            echo "  --max-iters N        Max iterations per task (default: 20)"
            echo "  --sequential         Force sequential execution"
            echo "  --dry-run            Analyze dependencies only"
            echo "  --no-tui             Disable full-screen TUI (plain log output)"
            echo "  --no-review          Skip post-wave quality review"
            echo "  --cleanup            Remove all worktrees/branches/locks"
            exit 0 ;;
        -*)  echo "Unknown option: $1" >&2; exit 1 ;;
        *)   SPEC_NAME="$1"; shift ;;
    esac
done

# Require either SPEC_NAME or SPEC_DIR
if [ -z "$SPEC_NAME" ] && [ -z "${SPEC_DIR:-}" ]; then
    echo "Error: spec required. Usage: $0 <spec_name_or_path> or $0 --spec-dir <path>" >&2
    exit 1
fi

export SPEC_NAME

# ─── Install agents into target repo ─────────────────────────
# Agents must live in .kiro/agents/ of the working directory for kiro-cli
# to discover them. Copy ours in, preserving any existing agents.
_install_agents() {
    local src="${SCRIPT_DIR}/.kiro/agents"
    local dst=".kiro/agents"
    [ ! -d "$src" ] && return 0
    mkdir -p "$dst"
    for agent_file in "${src}"/*.json; do
        [ -f "$agent_file" ] || continue
        local name
        name=$(basename "$agent_file")
        if [ ! -f "${dst}/${name}" ]; then
            cp "$agent_file" "${dst}/${name}"
        fi
    done
}
_install_agents

source "${SCRIPT_DIR}/config.sh"

# Derive SPEC_NAME for display if only SPEC_DIR was given
if [ -z "$SPEC_NAME" ] && [ -n "${SPEC_DIR:-}" ]; then
    SPEC_NAME=$(basename "$SPEC_DIR")
fi

# Apply CLI overrides that affect config
if [ "$SKIP_REVIEW" = true ]; then
    ENABLE_REVIEW=false
    # No reviewer agent → no need to reserve slots
    REVIEW_RESERVED_SLOTS=0
    WORKER_SLOTS=$MAX_PARALLEL
fi

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/dag.sh"
source "${SCRIPT_DIR}/lib/syncer.sh"
source "${SCRIPT_DIR}/lib/tui.sh"
source "${SCRIPT_DIR}/lib/reviewer.sh"
source "${SCRIPT_DIR}/lib/steering.sh"

# ═════════════════════════════════════════════════════════════
# State directory (flat files instead of associative arrays)
# ═════════════════════════════════════════════════════════════
STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/btb-state.XXXXXX")

set_task_state()  { echo "$2" > "${STATE_DIR}/${1}.status"; }
get_task_state()  { cat "${STATE_DIR}/${1}.status" 2>/dev/null || echo "unknown"; }
set_task_pid()    { echo "$2" > "${STATE_DIR}/${1}.pid"; }
get_task_pid()    { cat "${STATE_DIR}/${1}.pid" 2>/dev/null || echo ""; }
set_task_retries(){ echo "$2" > "${STATE_DIR}/${1}.retries"; }
get_task_retries(){ cat "${STATE_DIR}/${1}.retries" 2>/dev/null || echo "0"; }
set_task_wt()     { echo "$2" > "${STATE_DIR}/${1}.worktree"; }
get_task_wt()     { cat "${STATE_DIR}/${1}.worktree" 2>/dev/null || echo ""; }

# ═════════════════════════════════════════════════════════════
# Worker Management
# ═════════════════════════════════════════════════════════════

spawn_worker() {
    local task_id="$1"
    local task_desc
    task_desc=$(get_task_description "$TASK_FILE" "$task_id")

    # Get the planner-assigned model for this task
    local task_model
    task_model=$(get_task_model "$DAG_JSON" "$task_id")

    log_task "spawning worker for ${task_id}"

    local worktree_path
    worktree_path=$(create_worktree "$task_id" "$WORKTREE_BASE") || true

    # If worktree creation failed (index lock, etc.), defer the task
    if [ -z "$worktree_path" ] || [ ! -d "$worktree_path" ]; then
        dbg "worktree creation failed for task ${task_id} — deferring"
        tui_event "⚠ worktree creation failed for ${task_id}, will retry next cycle"
        set_task_state "$task_id" "pending"
        return 1
    fi

    set_task_wt "$task_id" "$worktree_path"

    local task_log
    task_log="$(pwd)/${LOG_DIR}/task_${task_id//\./_}_${TIMESTAMP}.log"

    export TASK_COMPLETE_PREFIX WORKER_AGENT RATE_LIMIT_PAUSE

    # Heartbeat file: worker touches this each iteration so the orchestrator
    # can distinguish "actively working" from "truly stuck"
    local heartbeat_file="${STATE_DIR}/${task_id}.heartbeat"
    echo "$(date +%s)" > "$heartbeat_file"

    # Pass failure context from previous attempt (if any) so the worker
    # can inject it into the agent prompt and avoid repeating the same mistake.
    local fail_ctx_file="${STATE_DIR}/${task_id}.fail_context"

    (
        cd "$worktree_path"
        HEARTBEAT_FILE="$heartbeat_file" \
        FAIL_CONTEXT_FILE="$fail_ctx_file" \
        bash "${SCRIPT_DIR}/lib/worker.sh" \
            "$task_id" "$TASK_FILE" "$SPEC_DIR" \
            "$MAX_ITERATIONS_PER_TASK" "$task_log" "$task_model"
    ) >>"$task_log" 2>&1 &

    local pid=$!
    set_task_pid "$task_id" "$pid"
    set_task_state "$task_id" "running"
    # Only initialize retries on first spawn — preserve counter during retries
    [ ! -f "${STATE_DIR}/${task_id}.retries" ] && set_task_retries "$task_id" "0"
    echo "$(date +%s)" > "${STATE_DIR}/${task_id}.started"

    dbg "spawn_worker task=${task_id} pid=${pid} model=${task_model} worktree=${worktree_path} log=${task_log}"

    # Update TUI
    tui_set_task_state "$task_id" "running"
    tui_set_task_log "$task_id" "$task_log"
    tui_event "→ worker pid ${pid} assigned to ${task_id} [${task_model}]: ${task_desc:0:50}"
}

count_running() {
    local count=0
    for f in "${STATE_DIR}"/*.status; do
        [ -f "$f" ] || continue
        [ "$(cat "$f")" = "running" ] && count=$((count + 1))
    done
    echo "$count"
}

# ─── Cleanup Trap ────────────────────────────────────────────
cleanup_on_exit() {
    local exit_code=$?

    echo "[$(date +%H:%M:%S)] cleanup_on_exit called with exit_code=${exit_code}" >> "${LOG_DIR:-".ralph-logs"}/debug_${TIMESTAMP:-latest}.log" 2>/dev/null || true

    # Restore terminal and tear down TUI
    tui_restore_input 2>/dev/null || true
    tui_cleanup

    log_info "cleaning up..."

    for f in "${STATE_DIR}"/*.pid; do
        [ -f "$f" ] || continue
        local pid
        pid=$(cat "$f")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill_tree "$pid" 2>/dev/null || true
        fi
    done

    ps aux 2>/dev/null | awk '/lib\/worker\.sh/ && !/awk/ { print $2 }' | while read opid; do
        kill "$opid" 2>/dev/null || true
    done

    sleep 1

    git worktree prune >/dev/null 2>&1 || true
    git branch 2>/dev/null | awk '/ralph/ { gsub(/^[* ]+/, ""); print }' | while read br; do
        git branch -D "$br" >/dev/null 2>&1 || true
    done
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
    rm -rf "$STATE_DIR" 2>/dev/null || true
    rm -f ".ralph-merge-lock" 2>/dev/null || true

    # Print final summary to restored terminal
    TUI_ELAPSED=$(($(date +%s) - ${START_TIME:-$(date +%s)}))
    tui_update_counts
    tui_print_summary

    [ $exit_code -eq 0 ] || exit "$exit_code"
}
trap cleanup_on_exit EXIT INT TERM

# ═════════════════════════════════════════════════════════════
# Main Execution
# ═════════════════════════════════════════════════════════════

validate_spec "$SPEC_DIR" || { log_error "Invalid spec: ${SPEC_DIR}"; exit 1; }
ensure_git_ready
mkdir -p "$LOG_DIR"

# Ensure .gitignore covers build artifacts in the target repo
_ensure_gitignore() {
    local pattern="$1"
    if [ -f .gitignore ]; then
        if ! awk -v p="$pattern" '$0 == p { found=1; exit } END { exit !found }' .gitignore 2>/dev/null; then
            echo "$pattern" >> .gitignore
        fi
    else
        echo "$pattern" > .gitignore
    fi
}
_ensure_gitignore ".ralph-logs/"
_ensure_gitignore ".ralph-worktrees/"

# ─── Phase 0: Steering Docs ─────────────────────────────────
# Check for .kiro/steering/ in the target repo. If missing, generate
# steering docs from the spec + codebase before any task execution.
# This gives all agents persistent project context.
ensure_steering_docs "$SPEC_DIR"

# ─── Pre-TUI banner (shown briefly before TUI takes over) ───
echo ""
echo -e "  \033[1m\033[97mBOB THE BUILDER\033[0m \033[2mconcurrent task orchestrator\033[0m"
echo -e "  \033[37mspec\033[0m ${SPEC_NAME}  \033[37mmode\033[0m $([ "$FORCE_SEQUENTIAL" = true ] && echo "sequential" || echo "concurrent")  \033[37mworkers\033[0m ${WORKER_SLOTS}+${REVIEW_RESERVED_SLOTS}r  \033[37mreview\033[0m $([ "${ENABLE_REVIEW:-true}" = "true" ] && echo "on" || echo "off")"
echo ""

# ─── Phase 1: Dependency Analysis ────────────────────────────

# Background spinner during analysis (lightweight, killed when done)
_analysis_spinner() {
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
        printf "\r  \033[37m  %s  analyzing...\033[0m" "${frames[$i]}"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.12
    done
}
_analysis_spinner &
_SPINNER_PID=$!
# Ensure spinner is killed on any exit path
trap 'kill $_SPINNER_PID 2>/dev/null || true; trap - EXIT INT TERM; cleanup_on_exit' EXIT INT TERM

DAG_JSON=""
if [ "$FORCE_SEQUENTIAL" = true ]; then
    DAG_JSON=$(build_fallback_dag "$TASK_FILE")
else
    DAG_JSON=$(analyze_dependencies "$TASK_FILE" "$DESIGN_FILE" "$REQUIREMENTS_FILE") || {
        log_warn "planner failed, falling back to sequential"
        DAG_JSON=$(build_fallback_dag "$TASK_FILE")
    }
fi

# Kill spinner and clear its line
kill $_SPINNER_PID 2>/dev/null || true
wait $_SPINNER_PID 2>/dev/null || true
printf "\r\033[K"
# Restore normal cleanup trap
trap cleanup_on_exit EXIT INT TERM

CYCLE_CHECK=$(check_cycles "$DAG_JSON" 2>/dev/null || echo "CYCLE_DETECTED")
if [ "$CYCLE_CHECK" = "CYCLE_DETECTED" ]; then
    log_error "circular dependency detected, falling back to sequential"
    DAG_JSON=$(build_fallback_dag "$TASK_FILE")
fi

WAVE_COUNT=$(get_wave_count "$DAG_JSON")
log_info "analysis complete: ${WAVE_COUNT} execution waves"

echo "$DAG_JSON" | python3 -m json.tool > "${LOG_DIR}/dag_${TIMESTAMP}.json" 2>/dev/null || true

if [ "$DRY_RUN" = true ]; then
    echo ""
    log_info "dry run complete. ${WAVE_COUNT} waves, DAG saved to ${LOG_DIR}/dag_${TIMESTAMP}.json"
    exit 0
fi

# Skip straight to TUI — the execution graph is shown live there
log_info "starting execution..."

# ─── Debug trace (writes to file so TUI alt-screen doesn't hide it) ──
DEBUG_LOG="${LOG_DIR}/debug_${TIMESTAMP}.log"
dbg() { echo "[$(date +%H:%M:%S)] $*" >> "$DEBUG_LOG"; }
dbg "=== btb debug start ==="

# ─── Initialize TUI ──────────────────────────────────────────
TUI_SPEC_NAME="$SPEC_NAME"
TUI_MODE=$([ "$FORCE_SEQUENTIAL" = true ] && echo "sequential" || echo "concurrent")
TUI_MAX_PARALLEL="$MAX_PARALLEL"
TUI_WORKER_SLOTS="$WORKER_SLOTS"
TUI_REVIEW_RESERVED="$REVIEW_RESERVED_SLOTS"
TUI_REVIEW_STATUS=$([ "${ENABLE_REVIEW:-true}" = "true" ] && echo "on" || echo "off")

# Load DAG data into TUI arrays
dbg "loading DAG into TUI arrays..."
tui_load_dag "$DAG_JSON" "$TASK_FILE"
dbg "tui_load_dag done. TUI_TOTAL_TASKS=${TUI_TOTAL_TASKS} TUI_TOTAL_WAVES=${TUI_TOTAL_WAVES}"
dbg "TUI_TASK_IDS=(${TUI_TASK_IDS[*]:-empty})"
dbg "TUI_WAVE_TASKS=(${TUI_WAVE_TASKS[*]:-empty})"

if [ "$USE_TUI" = true ]; then
    dbg "calling tui_init..."
    tui_init
    dbg "tui_init done. TUI_ACTIVE=${TUI_ACTIVE}"
fi

START_TIME=$(date +%s)
dbg "calling tui_event..."
tui_event "dependency analysis complete — ${WAVE_COUNT} waves"
dbg "calling tui_render..."
tui_render
dbg "first render done"

# ─── Phase 2: Dependency-Ready Scheduler ─────────────────────
# Instead of executing wave-by-wave, we track each task's dependencies
# individually. A task becomes "ready" the moment ALL its dependencies
# are completed+synced. This maximizes parallelism — fast tasks don't
# wait for slow siblings in the same wave.
#
# Invariants:
#   - A task is only spawned when ALL its dependencies are "synced"
#   - A completed task is synced to main immediately (serialized by lock)
#   - Review runs periodically after batches of syncs
#   - WORKER_SLOTS is always respected (MAX_PARALLEL minus reserved review slots)
#   - Failed tasks are retried up to MAX_RETRIES, then marked failed
#   - If a task fails permanently, all tasks that depend on it are skipped

mkdir -p "$WORKTREE_BASE"
dbg "entering dependency-ready scheduler"

TOTAL_COMPLETED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
TOTAL_REVIEW_PASSES=0
TOTAL_REVIEW_FIXES=0

# ─── Build task sets ─────────────────────────────────────────
# ALL_TASKS: every task ID from the DAG
# TASK_DEPS_<id>: dependencies for each task (stored in state dir)
# Task states: pending → ready → running → completed/failed/skipped

ALL_TASKS=$(get_all_dag_tasks "$DAG_JSON")
ALL_TASK_COUNT=0

for task_id in $ALL_TASKS; do
    ALL_TASK_COUNT=$((ALL_TASK_COUNT + 1))

    # Store dependencies in state dir for fast lookup
    local_deps=$(get_task_dependencies "$DAG_JSON" "$task_id")
    echo "$local_deps" > "${STATE_DIR}/${task_id}.deps"

    # Check if already complete from a previous run
    if is_task_complete "$TASK_FILE" "$task_id"; then
        set_task_state "$task_id" "synced"
        tui_set_task_state "$task_id" "completed"
        TOTAL_COMPLETED=$((TOTAL_COMPLETED + 1))
        dbg "task ${task_id} already complete"
    else
        set_task_state "$task_id" "pending"
    fi
done

dbg "total tasks: ${ALL_TASK_COUNT}, already completed: ${TOTAL_COMPLETED}"

# ─── Helper: check if a task's dependencies are all synced ───
are_deps_satisfied() {
    local task_id="$1"
    local deps_file="${STATE_DIR}/${task_id}.deps"
    local deps=""
    [ -f "$deps_file" ] && deps=$(cat "$deps_file")

    # No dependencies = always ready
    [ -z "$deps" ] && return 0

    for dep in $deps; do
        local dep_state
        dep_state=$(get_task_state "$dep")
        case "$dep_state" in
            synced) ;; # good
            failed|skipped)
                # Dependency failed — this task can never run
                return 2
                ;;
            unknown)
                # Dependency not in DAG (planner error) — treat as satisfied
                # to avoid permanent deadlock. The task will handle missing
                # artifacts on its own.
                dbg "WARNING: dep ${dep} for task ${task_id} not in DAG, ignoring"
                ;;
            *)
                # Dependency not yet synced
                return 1
                ;;
        esac
    done
    return 0
}

# ─── Helper: find all ready tasks ────────────────────────────
# Sets _READY_TASKS (space-separated) instead of echoing, to avoid subshell.
compute_ready_tasks() {
    _READY_TASKS=""
    for task_id in $ALL_TASKS; do
        local state
        state=$(get_task_state "$task_id")
        [ "$state" != "pending" ] && continue

        local dep_result=0
        are_deps_satisfied "$task_id" || dep_result=$?
        if [ "$dep_result" -eq 0 ]; then
            _READY_TASKS="${_READY_TASKS} ${task_id}"
        elif [ "$dep_result" -eq 2 ]; then
            # Dependency permanently failed — skip this task
            set_task_state "$task_id" "skipped"
            tui_set_task_state "$task_id" "failed"
            tui_event "⊘ task ${task_id} skipped (dependency failed)"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        fi
    done
    _READY_TASKS=$(echo "$_READY_TASKS" | xargs)
}

# ─── Helper: sync a completed task immediately ───────────────
sync_completed_task() {
    local task_id="$1"
    dbg "syncing completed task ${task_id}"
    TUI_PHASE="syncing"
    tui_event "· syncing task ${task_id} to main..."

    sync_task_to_main "$task_id" "$WORKTREE_BASE"
    set_task_state "$task_id" "synced"

    # Update parent tasks after each sync
    update_parent_tasks "$TASK_FILE"
    git add --all -- ':!.ralph-logs' >/dev/null 2>&1 || true
    git commit -m "Synced task ${task_id}" --allow-empty >/dev/null 2>&1 || true

    TOTAL_COMPLETED=$((TOTAL_COMPLETED + 1))

    # Track for review batching
    _REVIEW_BATCH_TASKS="${_REVIEW_BATCH_TASKS} ${task_id}"

    # Record the commit before the first sync in this batch for accurate review diffs
    if [ -z "${_REVIEW_BATCH_BASE_SHA:-}" ]; then
        # The merge commit just happened, so the base is its parent on main
        _REVIEW_BATCH_BASE_SHA=$(git rev-parse HEAD~1 2>/dev/null || echo "")
    fi

    # Track which wave this task belongs to for TUI
    local task_wave
    task_wave=$(get_task_wave "$DAG_JSON" "$task_id")
    if [ "$task_wave" -gt "${_HIGHEST_SYNCED_WAVE:-0}" ]; then
        _HIGHEST_SYNCED_WAVE=$task_wave
    fi

    TUI_PHASE="executing"
}

# ─── Helper: check workers and sync completed ones ───────────
# Writes results to state files to avoid subshell variable loss.
# Caller reads ${STATE_DIR}/_poll_synced for the count.
poll_and_sync() {
    local synced_count=0
    local now
    now=$(date +%s)

    for f in "${STATE_DIR}"/*.pid; do
        [ -f "$f" ] || continue
        local tid
        tid=$(basename "$f" .pid)
        [ "$(get_task_state "$tid")" != "running" ] && continue
        local pid
        pid=$(cat "$f")

        # Check if process exited
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            local ec=0
            wait "$pid" 2>/dev/null || ec=$?
            dbg "worker pid ${pid} for task ${tid} exited with code ${ec}"

            if [ "$ec" -eq 0 ]; then
                tui_set_task_state "$tid" "completed"
                tui_event "✓ task ${tid} completed"
                # Sync immediately
                sync_completed_task "$tid"
                synced_count=$((synced_count + 1))
            else
                # Before treating as failure, check if the task actually completed.
                # The worker may have finished the work and marked the task [x] in
                # tasks.md but then got killed by the watchdog (exit 143) before it
                # could cleanly exit. In that case, treat it as success.
                local _wt_path
                _wt_path=$(get_task_wt "$tid")
                local _wt_task_file="${_wt_path}/${TASK_FILE}"
                if [ -n "$_wt_path" ] && [ -f "$_wt_task_file" ] && is_task_complete "$_wt_task_file" "$tid"; then
                    dbg "task ${tid} exited ${ec} but is marked complete in worktree — treating as success"
                    tui_set_task_state "$tid" "completed"
                    tui_event "✓ task ${tid} completed (recovered from exit ${ec})"
                    sync_completed_task "$tid"
                    synced_count=$((synced_count + 1))
                    continue
                fi

                # Log the tail of the task log for debugging
                local _task_log="${LOG_DIR}/task_${tid//\./_}_${TIMESTAMP}.log"
                if [ -f "$_task_log" ]; then
                    dbg "task ${tid} last 5 log lines:"
                    tail -5 "$_task_log" 2>/dev/null | while IFS= read -r _line; do
                        dbg "  | ${_line}"
                    done
                fi

                # Handle failure with retries
                local retries
                retries=$(get_task_retries "$tid")
                if [ "$retries" -lt "$MAX_RETRIES" ]; then
                    set_task_retries "$tid" "$((retries + 1))"

                    # Save failure context so the retried worker knows what went wrong.
                    # Capture the last 30 lines of the task log — this typically includes
                    # the tool error, the agent's last reasoning, and the kill signal.
                    local _fail_ctx_file="${STATE_DIR}/${tid}.fail_context"
                    if [ -f "$_task_log" ]; then
                        {
                            echo "EXIT_CODE=${ec}"
                            if [ "$ec" -eq 143 ]; then
                                echo "FAILURE_TYPE=timeout_killed"
                                echo "HINT=The previous attempt was killed (SIGTERM) after exceeding the iteration timeout. The agent likely got stuck on a tool error loop."
                            else
                                echo "FAILURE_TYPE=error_exit"
                            fi
                            echo "---LAST_OUTPUT---"
                            # Strip ANSI escape codes for cleaner context
                            tail -30 "$_task_log" 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' || true
                        } > "$_fail_ctx_file"
                    fi

                    tui_event "⚠ task ${tid} failed exit=${ec} (attempt $((retries + 1))/${MAX_RETRIES}), will retry"
                    cleanup_worktree "$tid" "$WORKTREE_BASE"
                    # Mark as pending so it gets picked up by the main spawn loop
                    # This ensures WORKER_SLOTS is respected
                    set_task_state "$tid" "pending"
                    sleep 2
                else
                    set_task_state "$tid" "failed"
                    tui_set_task_state "$tid" "failed"
                    tui_event "✗ task ${tid} FAILED exit=${ec} after ${MAX_RETRIES} retries"
                    cleanup_worktree "$tid" "$WORKTREE_BASE"
                    TOTAL_FAILED=$((TOTAL_FAILED + 1))
                fi
            fi
            continue
        fi

        # Check for stale workers — use heartbeat file (updated each iteration)
        # instead of spawn time, so actively-working workers don't get killed
        local heartbeat_file="${STATE_DIR}/${tid}.heartbeat"
        local last_activity_file="$heartbeat_file"
        # Fall back to start time if no heartbeat exists
        [ ! -f "$last_activity_file" ] && last_activity_file="${STATE_DIR}/${tid}.started"
        if [ -f "$last_activity_file" ]; then
            local last_activity
            last_activity=$(cat "$last_activity_file")
            local idle_time=$((now - last_activity))
            if [ "$idle_time" -gt "${STALE_THRESHOLD:-300}" ]; then
                local kill_attempts_file="${STATE_DIR}/${tid}.kill_attempts"
                local kill_attempts=0
                [ -f "$kill_attempts_file" ] && kill_attempts=$(cat "$kill_attempts_file")

                if [ "$kill_attempts" -ge 2 ]; then
                    # Exhausted kill attempts — force-fail the task
                    tui_event "✗ task ${tid} unkillable after ${kill_attempts} attempts, marking failed"
                    set_task_state "$tid" "failed"
                    tui_set_task_state "$tid" "failed"
                    cleanup_worktree "$tid" "$WORKTREE_BASE"
                    TOTAL_FAILED=$((TOTAL_FAILED + 1))
                    rm -f "$kill_attempts_file"
                elif [ "$kill_attempts" -ge 1 ]; then
                    # Second attempt — escalate to SIGKILL
                    tui_event "⚠ task ${tid} stale (idle ${idle_time}s), sending SIGKILL"
                    kill -9 "$pid" 2>/dev/null || true
                    echo "$((kill_attempts + 1))" > "$kill_attempts_file"
                    sleep 1
                else
                    # First attempt — graceful kill
                    tui_event "⚠ task ${tid} stale (idle ${idle_time}s), killing"
                    kill_tree "$pid" 2>/dev/null || true
                    echo "$((kill_attempts + 1))" > "$kill_attempts_file"
                    sleep 1
                fi
            fi
        fi
    done

    # Return value without subshell — caller reads this directly
    _POLL_SYNCED_COUNT=$synced_count
}

# ─── Main scheduler loop ─────────────────────────────────────
_HIGHEST_SYNCED_WAVE=0
_SYNCED_SINCE_REVIEW=0
_REVIEW_BATCH_TASKS=""
_REVIEW_BATCH_BASE_SHA=""
_REVIEW_DEFERRALS=0
MAX_REVIEW_DEFERRALS=${MAX_REVIEW_DEFERRALS:-3}  # Force review after this many deferrals
REVIEW_BATCH_SIZE=${REVIEW_BATCH_SIZE:-5}  # Review after this many synced tasks

tui_event "scheduler started — ${ALL_TASK_COUNT} tasks, ${WORKER_SLOTS} worker slots + ${REVIEW_RESERVED_SLOTS} review reserved"
TUI_PHASE="executing"

while true; do
    # 1. Poll workers, sync completed tasks
    _POLL_SYNCED_COUNT=0
    poll_and_sync
    _SYNCED_SINCE_REVIEW=$((_SYNCED_SINCE_REVIEW + _POLL_SYNCED_COUNT))

    # 2. Update TUI
    TUI_CURRENT_WAVE=$_HIGHEST_SYNCED_WAVE
    TUI_ELAPSED=$(($(date +%s) - START_TIME))
    tui_update_counts
    tui_render

    # 3. Check if we're done
    local_remaining=0
    local_has_running=false
    for task_id in $ALL_TASKS; do
        state=""
        state=$(get_task_state "$task_id")
        case "$state" in
            synced|failed|skipped) ;;
            running) local_has_running=true; local_remaining=$((local_remaining + 1)) ;;
            *) local_remaining=$((local_remaining + 1)) ;;
        esac
    done

    if [ "$local_remaining" -eq 0 ]; then
        dbg "all tasks resolved — exiting scheduler"
        break
    fi

    # 4. Find ready tasks and spawn workers for them
    compute_ready_tasks
    for task_id in $_READY_TASKS; do
        # Respect WORKER_SLOTS (MAX_PARALLEL minus reserved review slots)
        running_count=$(count_running)
        if [ "$running_count" -ge "$WORKER_SLOTS" ]; then
            break
        fi

        dbg "spawning ready task ${task_id}"
        spawn_worker "$task_id" || true
        sleep "$RATE_LIMIT_PAUSE"
    done

    # 5. Periodic review gate — after a batch of synced tasks
    if [ "$_SYNCED_SINCE_REVIEW" -ge "$REVIEW_BATCH_SIZE" ] && [ "${ENABLE_REVIEW:-true}" = "true" ]; then
        running_count=$(count_running)
        _force_review=false

        # If deferred too many times, force a review pause
        if [ "$running_count" -gt 0 ] && [ "$_REVIEW_DEFERRALS" -ge "$MAX_REVIEW_DEFERRALS" ]; then
            tui_event "⏸ review deferred ${_REVIEW_DEFERRALS}x — waiting for ${running_count} workers to finish"
            _force_review=true
            # Wait for all running workers to complete before reviewing
            while [ "$(count_running)" -gt 0 ]; do
                _POLL_SYNCED_COUNT=0
                poll_and_sync
                _SYNCED_SINCE_REVIEW=$((_SYNCED_SINCE_REVIEW + _POLL_SYNCED_COUNT))
                TUI_ELAPSED=$(($(date +%s) - START_TIME))
                tui_update_counts
                tui_render
                sleep 1
            done
            running_count=0
        fi

        if [ "$running_count" -eq 0 ]; then
            TUI_PHASE="reviewing"
            review_label="batch (${_SYNCED_SINCE_REVIEW} tasks)"
            tui_event "🔍 starting quality review — ${review_label}"

            # Keep TUI responsive during review — only handle input, don't render
            # (review_wave calls tui_event which renders; concurrent renders cause garbled output)
            _review_poll() {
                while true; do
                    TUI_ELAPSED=$(($(date +%s) - START_TIME))
                    sleep 0.5
                done
            }
            _review_poll &
            _REVIEW_POLL_PID=$!

            # Build task list for review from recently synced
            review_result=0
            review_wave "batch" "$_REVIEW_BATCH_TASKS" "$_REVIEW_BATCH_BASE_SHA" || review_result=$?

            kill $_REVIEW_POLL_PID 2>/dev/null || true
            wait $_REVIEW_POLL_PID 2>/dev/null || true

            if [ "$review_result" -eq 0 ]; then
                TOTAL_REVIEW_PASSES=$((TOTAL_REVIEW_PASSES + 1))
            else
                TOTAL_REVIEW_FIXES=$((TOTAL_REVIEW_FIXES + 1))
                tui_event "⚠ review gate flagged issues — check logs"
            fi

            _SYNCED_SINCE_REVIEW=0
            _REVIEW_BATCH_TASKS=""
            _REVIEW_BATCH_BASE_SHA=""
            _REVIEW_DEFERRALS=0
            TUI_PHASE="executing"
        else
            # Workers still running and not yet forced — defer review
            _REVIEW_DEFERRALS=$((_REVIEW_DEFERRALS + 1))
            dbg "review deferred (${_REVIEW_DEFERRALS}/${MAX_REVIEW_DEFERRALS}), workers still running"
        fi
    fi

    # 6. If nothing is running and nothing is ready, check for deadlock
    #    Re-check running count here — spawns in step 4 may have changed it
    local_has_running_now=false
    local_remaining_now=0
    for task_id in $ALL_TASKS; do
        state=""
        state=$(get_task_state "$task_id")
        case "$state" in
            synced|failed|skipped) ;;
            running) local_has_running_now=true; local_remaining_now=$((local_remaining_now + 1)) ;;
            *) local_remaining_now=$((local_remaining_now + 1)) ;;
        esac
    done

    if [ "$local_has_running_now" = false ] && [ -z "$_READY_TASKS" ] && [ "$local_remaining_now" -gt 0 ]; then
        # Deadlock: tasks remain but none are ready and none are running
        # This means all remaining tasks have unsatisfied deps that will never resolve
        tui_event "⚠ deadlock detected — ${local_remaining_now} tasks blocked by failed dependencies"
        for task_id in $ALL_TASKS; do
            state=""
            state=$(get_task_state "$task_id")
            if [ "$state" = "pending" ]; then
                set_task_state "$task_id" "skipped"
                tui_set_task_state "$task_id" "failed"
                TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
            fi
        done
        break
    fi

    # 7. Input polling — keep TUI responsive
    for ((poll=0; poll<5; poll++)); do
        tui_handle_input || true
        tui_render
        sleep 0.2
    done
done

# ─── Final review for any remaining unreviewed work ──────────
if [ "$_SYNCED_SINCE_REVIEW" -gt 0 ] && [ "${ENABLE_REVIEW:-true}" = "true" ]; then
    TUI_PHASE="reviewing"
    tui_event "🔍 final quality review — ${_SYNCED_SINCE_REVIEW} tasks"

    _review_poll() {
        while true; do
            TUI_ELAPSED=$(($(date +%s) - START_TIME))
            sleep 0.5
        done
    }
    _review_poll &
    _REVIEW_POLL_PID=$!

    review_result=0
    review_wave "final" "$_REVIEW_BATCH_TASKS" "$_REVIEW_BATCH_BASE_SHA" || review_result=$?

    kill $_REVIEW_POLL_PID 2>/dev/null || true
    wait $_REVIEW_POLL_PID 2>/dev/null || true

    if [ "$review_result" -eq 0 ]; then
        TOTAL_REVIEW_PASSES=$((TOTAL_REVIEW_PASSES + 1))
    else
        TOTAL_REVIEW_FIXES=$((TOTAL_REVIEW_FIXES + 1))
    fi
fi

# ─── Phase 3: Done ───────────────────────────────────────────
TUI_PHASE="done"
TUI_ELAPSED=$(($(date +%s) - START_TIME))
TUI_REVIEW_PASSES=$TOTAL_REVIEW_PASSES
TUI_REVIEW_FIXES=$TOTAL_REVIEW_FIXES
TUI_SKIPPED=$TOTAL_SKIPPED
tui_update_counts

TOTAL=$(count_total_tasks "$TASK_FILE")
INCOMPLETE_FINAL=$(count_incomplete_tasks "$TASK_FILE")

if [ "$TOTAL_FAILED" -gt 0 ] || [ "$TOTAL_SKIPPED" -gt 0 ]; then
    tui_event "⚠ ${TOTAL_FAILED} failed, ${TOTAL_SKIPPED} skipped"
    sleep 2
    exit 1
elif [ "$INCOMPLETE_FINAL" -eq 0 ]; then
    tui_event "✓ all tasks completed"
    sleep 2
    exit 0
else
    tui_event "⚠ some tasks incomplete"
    sleep 2
    exit 1
fi
