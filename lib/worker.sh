#!/bin/bash
# lib/worker.sh - Single task worker
# Runs inside a git worktree, focused on ONE task.
# Exits with 0 on success, 1 on failure.

set -euo pipefail

# Ignore SIGPIPE — worker pipes kiro-cli output through tee to log files,
# and early reader close should not kill the worker process.
trap '' PIPE

# ─── Error Tracing ───────────────────────────────────────────
# Capture the exact line and command that caused set -e to exit.
# This writes to both stderr (captured in task log) and LOG_FILE if set.
_worker_err_handler() {
    local exit_code=$?
    local line_no=$1
    local cmd=$2
    local msg="[WORKER CRASH] line ${line_no}: '${cmd}' exited with code ${exit_code}"
    echo "$msg" >&2
    if [ -n "${LOG_FILE:-}" ] && [ "$LOG_FILE" != "/dev/null" ]; then
        echo "$(date +%Y-%m-%dT%H:%M:%S) ${msg}" >> "$LOG_FILE" 2>/dev/null || true
    fi
}
trap '_worker_err_handler ${LINENO} "${BASH_COMMAND}"' ERR

# ─── Arguments ───────────────────────────────────────────────
TASK_ID="${1:?Usage: worker.sh <task_id> <task_file> <spec_dir> [max_iterations] [log_file] [model]}"
TASK_FILE="${2:?Missing task_file argument}"
SPEC_DIR="${3:?Missing spec_dir argument}"
MAX_ITERATIONS="${4:-20}"
LOG_FILE="${5:-/dev/null}"
TASK_MODEL="${6:-}"  # Model override (e.g. claude-haiku-4.5, claude-sonnet-4)

# Source utils from the original repo (not the worktree)
# The worktree has a copy of everything, so source locally
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/utils.sh" ]; then
    source "${SCRIPT_DIR}/utils.sh"
else
    # Minimal logging fallback
    log_info()    { echo "[INFO]  $(date +%H:%M:%S) $*"; }
    log_success() { echo "[OK]    $(date +%H:%M:%S) $*"; }
    log_warn()    { echo "[WARN]  $(date +%H:%M:%S) $*"; }
    log_error()   { echo "[ERROR] $(date +%H:%M:%S) $*"; }
    log_task()    { echo "[TASK]  $(date +%H:%M:%S) $*"; }
fi

# ─── Worker Loop ─────────────────────────────────────────────

log_task "Worker started for task ${TASK_ID} (max ${MAX_ITERATIONS} iterations)"
echo "$(date +%Y-%m-%dT%H:%M:%S) STARTED task=${TASK_ID}" >> "$LOG_FILE"

TASK_DESC=$(awk -v tid="$TASK_ID" '
    $0 ~ "\\[.\\][[:space:]]+" tid "[[:space:]]" {
        sub(/.*\[.\][[:space:]]+[0-9.]+[[:space:]]+/, "")
        print; exit
    }
' "$TASK_FILE" 2>/dev/null)
TASK_DESC="${TASK_DESC:-Unknown task}"

for ((i=1; i<=MAX_ITERATIONS; i++)); do
    log_task "Task ${TASK_ID} - Iteration ${i}/${MAX_ITERATIONS}"
    echo "$(date +%Y-%m-%dT%H:%M:%S) ITERATION i=${i} task=${TASK_ID}" >> "$LOG_FILE"

    # Touch heartbeat so orchestrator knows we're actively working
    touch "${HEARTBEAT_FILE:-/dev/null}" 2>/dev/null || true

    # Check if task is already complete (another worker or previous iteration)
    echo "$(date +%Y-%m-%dT%H:%M:%S) DEBUG checking_completion task=${TASK_ID}" >> "$LOG_FILE"
    if awk -v tid="$TASK_ID" '$0 ~ "\\[x\\][[:space:]]+" tid { found=1; exit } END { exit !found }' "$TASK_FILE" 2>/dev/null; then
        log_success "Task ${TASK_ID} already marked complete"
        echo "$(date +%Y-%m-%dT%H:%M:%S) ALREADY_COMPLETE task=${TASK_ID}" >> "$LOG_FILE"
        echo "${TASK_COMPLETE_PREFIX:-TASK_COMPLETE}::${TASK_ID}"
        exit 0
    fi

    # Build the prompt - focused on ONE task only
    # If steering docs exist, agents already have project context.
    # Reference spec files for task-specific details.
    echo "$(date +%Y-%m-%dT%H:%M:%S) DEBUG building_prompt task=${TASK_ID}" >> "$LOG_FILE"
    steering_context=""
    if [ -d ".kiro/steering" ] && [ -n "$(ls -A .kiro/steering 2>/dev/null)" ]; then
        steering_context="You have project context in .kiro/steering/ — read those files first for architecture, conventions, and spec summary."
    fi

    # Check for failure context from a previous attempt (set by orchestrator)
    retry_context=""
    fail_ctx_file="${FAIL_CONTEXT_FILE:-}"
    if [ -n "$fail_ctx_file" ] && [ -f "$fail_ctx_file" ]; then
        fail_output=$(cat "$fail_ctx_file" 2>/dev/null || true)
        if [ -n "$fail_output" ]; then
            retry_context="
IMPORTANT — PREVIOUS ATTEMPT FAILED:
This is a RETRY. The previous attempt at this task failed. Here is what happened:
${fail_output}

LEARN FROM THIS FAILURE:
- If the error was 'N occurrences of old_str were found when only 1 is expected', use a MORE SPECIFIC old_str that includes extra surrounding context lines to uniquely identify the target, or use a different editing approach (e.g. read the file first, use line numbers, or rewrite the whole file).
- If the error was a timeout/kill, the previous agent likely got stuck in a loop. Take a DIFFERENT approach.
- Do NOT repeat the same sequence of actions that led to the failure.
"
        fi
    fi

    PROMPT="You are working on a specific task from a spec.

${steering_context}
${retry_context}
READ these spec files for task details:
1. ${TASK_FILE} - the full task list
2. ${SPEC_DIR}/design.md - architecture and implementation guidance (if it exists)
3. ${SPEC_DIR}/requirements.md - acceptance criteria (if it exists)

YOUR TASK: Implement ONLY task ${TASK_ID}: ${TASK_DESC}

RULES:
- Focus ONLY on task ${TASK_ID}. Do NOT work on other tasks.
- Implement it fully with no placeholders or TODOs.
- If this task involves writing code, write complete working code.
- If this task involves tests, write and RUN the tests.
- After implementation, verify your work compiles/runs correctly.
- When editing files, always read the file first to understand its full content. If a string replacement fails because of ambiguity, use a more specific match string with additional context lines, or rewrite the section differently.
- Update ${TASK_FILE} to mark task ${TASK_ID} as complete: change '- [ ] ${TASK_ID}' to '- [x] ${TASK_ID}'
- Output '${TASK_COMPLETE_PREFIX:-TASK_COMPLETE}::${TASK_ID}' when the task is done and verified."

    # Run the agent with fresh context (core Ralph principle)
    # Use tee to stream output to log file in real-time so TUI can tail it
    # If a model was assigned by the planner, override the agent's default model
    model_flag=""
    if [ -n "$TASK_MODEL" ]; then
        model_flag="--model ${TASK_MODEL}"
    fi
    echo "$(date +%Y-%m-%dT%H:%M:%S) DEBUG launching_agent task=${TASK_ID} model=${TASK_MODEL:-default} agent=${WORKER_AGENT:-player}" >> "$LOG_FILE"
    echo "$(date +%Y-%m-%dT%H:%M:%S) RESPONSE_START task=${TASK_ID} iter=${i} model=${TASK_MODEL:-default}" >> "$LOG_FILE"

    response_file=$(mktemp "${TMPDIR:-/tmp}/ralph-response.XXXXXX")

    # Run kiro-cli in a background subshell, capture output to file + log
    (
        kiro-cli chat --no-interactive --agent "${WORKER_AGENT:-player}" $model_flag --trust-all-tools \
            "$PROMPT" 2>&1 | tee -a "$LOG_FILE" > "$response_file"
    ) &
    kiro_bg_pid=$!

    # Activity-aware heartbeat: updates the heartbeat file as long as the
    # worker shows signs of life. The orchestrator's STALE_THRESHOLD check
    # is the ONLY kill mechanism — no dumb wall-clock watchdog.
    #
    # "Activity" means ANY of:
    #   1. The log file was modified (agent is producing output)
    #   2. The kiro-cli process has child processes (a shell command is running,
    #      e.g. a long test suite or build that produces no log output)
    #   3. The kiro-cli process itself is alive and consuming CPU
    #
    # This lets tasks run for hours if they're genuinely working, while the
    # orchestrator still kills truly stuck workers via STALE_THRESHOLD.
    (
        prev_log_size=0
        while kill -0 "$kiro_bg_pid" 2>/dev/null; do
            active=false

            # Check 1: log file growing (agent producing output)
            if [ -f "$LOG_FILE" ]; then
                cur_log_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo "0")
                if [ "$cur_log_size" -gt "$prev_log_size" ]; then
                    active=true
                    prev_log_size=$cur_log_size
                fi
            fi

            # Check 2: kiro-cli has child processes (running a shell command)
            if [ "$active" = false ]; then
                child_count=$(pgrep -P "$kiro_bg_pid" 2>/dev/null | wc -l || echo "0")
                if [ "$child_count" -gt 0 ]; then
                    active=true
                fi
            fi

            # Check 3: process is alive (fallback — covers edge cases like
            # network waits for API responses where there's no output yet)
            if [ "$active" = false ] && kill -0 "$kiro_bg_pid" 2>/dev/null; then
                active=true
            fi

            if [ "$active" = true ]; then
                touch "${HEARTBEAT_FILE:-/dev/null}" 2>/dev/null || true
            fi

            sleep 15
        done
    ) &
    heartbeat_keeper_pid=$!

    # Wait for kiro-cli to finish (or be killed by orchestrator's stale check)
    wait "$kiro_bg_pid" 2>/dev/null || true

    # Kill the heartbeat keeper
    kill "$heartbeat_keeper_pid" 2>/dev/null || true
    wait "$heartbeat_keeper_pid" 2>/dev/null || true

    RESPONSE=$(cat "$response_file" 2>/dev/null || true)
    rm -f "$response_file"
    echo "$(date +%Y-%m-%dT%H:%M:%S) RESPONSE_END" >> "$LOG_FILE"

    # Touch heartbeat so orchestrator knows we're still active
    touch "${HEARTBEAT_FILE:-/dev/null}" 2>/dev/null || true

    # Check for completion signal in response
    if [[ "$RESPONSE" == *"${TASK_COMPLETE_PREFIX:-TASK_COMPLETE}::${TASK_ID}"* ]]; then
        log_success "Task ${TASK_ID} completed (iteration ${i})"
        echo "$(date +%Y-%m-%dT%H:%M:%S) COMPLETED task=${TASK_ID} iterations=${i}" >> "$LOG_FILE"

        # Commit the work (exclude log files to avoid merge conflicts)
        git add --all -- ':!.ralph-logs' 2>/dev/null || true
        git commit -m "Completed task ${TASK_ID}: ${TASK_DESC}" --allow-empty 2>/dev/null || true

        echo "${TASK_COMPLETE_PREFIX:-TASK_COMPLETE}::${TASK_ID}"
        exit 0
    fi

    # Also check if the task was marked complete in the file even without the signal
    if awk -v tid="$TASK_ID" '$0 ~ "\\[x\\][[:space:]]+" tid { found=1; exit } END { exit !found }' "$TASK_FILE" 2>/dev/null; then
        log_success "Task ${TASK_ID} marked complete in tasks.md (iteration ${i})"
        echo "$(date +%Y-%m-%dT%H:%M:%S) COMPLETED_VIA_FILE task=${TASK_ID} iterations=${i}" >> "$LOG_FILE"

        git add --all -- ':!.ralph-logs' 2>/dev/null || true
        git commit -m "Completed task ${TASK_ID}: ${TASK_DESC}" --allow-empty 2>/dev/null || true

        echo "${TASK_COMPLETE_PREFIX:-TASK_COMPLETE}::${TASK_ID}"
        exit 0
    fi

    # Commit progress even if not complete
    git add --all -- ':!.ralph-logs' 2>/dev/null || true
    git commit -m "Task ${TASK_ID} iteration ${i}: in progress" --allow-empty 2>/dev/null || true

    # Rate limit pause
    sleep "${RATE_LIMIT_PAUSE:-3}"
done

# Exhausted iterations
log_error "Task ${TASK_ID} failed after ${MAX_ITERATIONS} iterations"
echo "$(date +%Y-%m-%dT%H:%M:%S) FAILED task=${TASK_ID} reason=max_iterations" >> "$LOG_FILE"
exit 1
