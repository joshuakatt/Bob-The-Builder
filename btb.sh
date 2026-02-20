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
BTB_MODE="${BTB_MODE:-optimal}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --spec-dir)      export SPEC_DIR="$2"; shift 2 ;;
        --max-parallel)  export MAX_PARALLEL="$2"; shift 2 ;;
        --max-iters)     export MAX_ITERS="$2"; shift 2 ;;
        --sequential)    FORCE_SEQUENTIAL=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --no-tui)        USE_TUI=false; shift ;;
        --no-review)     SKIP_REVIEW=true; shift ;;
        --low)           BTB_MODE="low"; shift ;;
        --optimal)       BTB_MODE="optimal"; shift ;;
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
            echo "  --low                Low credits mode (haiku+sonnet+opus, default sonnet)"
            echo "  --optimal            Optimal mode (sonnet+opus, default opus) [default]"
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

export BTB_MODE
source "${SCRIPT_DIR}/config.sh"

# ─── Non-Interactive Environment ─────────────────────────────
# Force CI mode so all child tools (vitest, pnpm, cargo, etc.) run
# non-interactively. Without this, vitest defaults to watch mode,
# pnpm prompts for input, and builds can hang indefinitely.
export CI=true

# ─── Validate Spec Files Are Committed ───────────────────────
# Worktrees are created from git commits. If spec files aren't committed,
# they won't exist in the worktree and workers will crash.
_validate_spec_committed() {
    local spec_dir="${SPEC_DIR:-}"
    [ -z "$spec_dir" ] && return 0
    [ ! -d "$spec_dir" ] && return 0  # Will fail later with proper error

    # Check if any spec files are untracked or modified
    local untracked modified
    untracked=$(git ls-files --others --exclude-standard "$spec_dir" 2>/dev/null | head -5)
    modified=$(git diff --name-only "$spec_dir" 2>/dev/null | head -5)

    if [ -n "$untracked" ] || [ -n "$modified" ]; then
        echo ""
        echo "⚠️  Spec files are not committed to git!"
        echo ""
        echo "btb creates git worktrees for parallel task execution. Uncommitted files"
        echo "won't exist in the worktrees, causing workers to crash."
        echo ""
        if [ -n "$untracked" ]; then
            echo "Untracked files in ${spec_dir}:"
            echo "$untracked" | sed 's/^/  /'
        fi
        if [ -n "$modified" ]; then
            echo "Modified files in ${spec_dir}:"
            echo "$modified" | sed 's/^/  /'
        fi
        echo ""
        echo "Auto-committing spec files..."
        git add "$spec_dir" 2>/dev/null || true
        if git commit -m "btb: auto-commit spec files for ${SPEC_NAME:-unknown}" >/dev/null 2>&1; then
            echo "✓ Spec files committed successfully."
        else
            echo "⚠️  Could not auto-commit. Please commit manually:"
            echo "   git add ${spec_dir} && git commit -m 'Add spec'"
            exit 1
        fi
        echo ""
    fi
}
_validate_spec_committed

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
        # Track consecutive worktree failures per task
        local _wt_fail_file="${STATE_DIR}/${task_id}.wt_failures"
        local _wt_fails=0
        [ -f "$_wt_fail_file" ] && _wt_fails=$(cat "$_wt_fail_file")
        _wt_fails=$((_wt_fails + 1))
        echo "$_wt_fails" > "$_wt_fail_file"

        dbg "worktree creation failed for task ${task_id} — deferring (worktree_path='${worktree_path}') [wt_fail=${_wt_fails}]"
        dbg "  git status: $(git status --porcelain 2>/dev/null | head -3 | tr '\n' ' ')"
        dbg "  git branch: $(git branch --show-current 2>/dev/null || echo '?')"
        dbg "  index.lock exists: $([ -f .git/index.lock ] && echo 'YES' || echo 'no')"
        dbg "  worktree list: $(git worktree list 2>/dev/null | head -5 | tr '\n' ' ')"

        # After 3 consecutive worktree failures, mark the task as failed
        # to avoid infinite retry loops
        if [ "$_wt_fails" -ge 3 ]; then
            dbg "task ${task_id} worktree creation failed ${_wt_fails} times — marking FAILED"
            tui_event "✗ task ${task_id} FAILED — worktree creation failed ${_wt_fails} times"
            set_task_state "$task_id" "failed"
            tui_set_task_state "$task_id" "failed"
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
            return 1
        fi

        tui_event "⚠ worktree creation failed for ${task_id}, will retry next cycle"
        set_task_state "$task_id" "pending"
        return 1
    fi

    # Reset worktree failure counter on success
    rm -f "${STATE_DIR}/${task_id}.wt_failures" 2>/dev/null || true

    set_task_wt "$task_id" "$worktree_path"

    # Copy .kiro/ artifacts into the worktree — these may not be committed
    # to git yet, so git worktree add won't include them. Without this,
    # kiro-cli inside the worktree can't find agent definitions or steering docs.
    # Retry the copy with verification — disk pressure can cause silent failures.
    local _kiro_copy_ok=false
    for _kiro_copy_attempt in 1 2 3; do
        for _kiro_sub in agents steering settings; do
            if [ -d ".kiro/${_kiro_sub}" ]; then
                mkdir -p "${worktree_path}/.kiro/${_kiro_sub}" 2>/dev/null || true
                cp -a ".kiro/${_kiro_sub}/." "${worktree_path}/.kiro/${_kiro_sub}/" 2>/dev/null || true
            fi
        done
        # Verify the critical file landed
        if [ -f "${worktree_path}/.kiro/agents/${WORKER_AGENT:-player}.json" ]; then
            _kiro_copy_ok=true
            break
        fi
        dbg "WARNING: .kiro/agents/${WORKER_AGENT:-player}.json missing after copy attempt ${_kiro_copy_attempt} for task ${task_id}"
        sleep 5
    done
    if [ "$_kiro_copy_ok" = false ]; then
        dbg "CRITICAL: agent files failed to copy after 3 attempts for task ${task_id} — deferring"
        tui_event "⚠ agent copy failed for ${task_id}, deferring"
        cleanup_worktree "$task_id" "$WORKTREE_BASE" 2>/dev/null || true
        set_task_state "$task_id" "pending"
        return 1
    fi

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

        # Shared build cache — point language-specific build dirs to a shared
        # location so parallel worktrees don't each create multi-GB copies.
        if [ -n "${SHARED_BUILD_CACHE_DIR_ABS:-}" ]; then
            # Rust: CARGO_TARGET_DIR overrides per-project target/
            export CARGO_TARGET_DIR="${SHARED_BUILD_CACHE_DIR_ABS}/cargo-target"
            # Gradle
            export GRADLE_USER_HOME="${SHARED_BUILD_CACHE_DIR_ABS}/gradle"
            # Go
            export GOPATH="${SHARED_BUILD_CACHE_DIR_ABS}/go"
            export GOCACHE="${SHARED_BUILD_CACHE_DIR_ABS}/go-cache"
            # Python pip cache
            export PIP_CACHE_DIR="${SHARED_BUILD_CACHE_DIR_ABS}/pip-cache"
            mkdir -p "$CARGO_TARGET_DIR" "$GRADLE_USER_HOME" "$GOCACHE" "$PIP_CACHE_DIR" 2>/dev/null || true

            # Node.js: symlink node_modules from cache (or main repo) into worktree.
            # Unlike Rust/Go which have env-var redirects, Node requires node_modules
            # to physically exist in the project tree.
            if [ -f "package.json" ] && [ ! -d "node_modules" ]; then
                _main_repo_root=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
                if [ -d "${SHARED_BUILD_CACHE_DIR_ABS}/node_modules" ]; then
                    ln -sf "${SHARED_BUILD_CACHE_DIR_ABS}/node_modules" node_modules 2>/dev/null || true
                elif [ -n "$_main_repo_root" ] && [ -d "${_main_repo_root}/node_modules" ]; then
                    ln -sf "${_main_repo_root}/node_modules" node_modules 2>/dev/null || true
                fi
            fi
        fi

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

# ─── Health Check Context Assembly ───────────────────────────
# Builds a diagnostic payload for the health-checker agent.
# Output: structured text to stdout — no side effects.
assemble_health_context() {
    local task_id="$1"
    local task_desc elapsed log_tail descendants

    task_desc=$(get_task_description "$TASK_FILE" "$task_id")
    local started=$(cat "${STATE_DIR}/${task_id}.started" 2>/dev/null || echo "$(date +%s)")
    elapsed=$(( $(date +%s) - started ))

    # Get log tail, strip ANSI codes
    local task_log=$(tui_get_task_log "$task_id" 2>/dev/null || echo "")
    if [ -n "$task_log" ] && [ -f "$task_log" ]; then
        log_tail=$(tail -n "${HEALTH_CHECK_LOG_LINES}" "$task_log" 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' || echo "(no log output)")
    else
        log_tail="(no log file found)"
    fi

    # Get descendant processes — include full command line for richer context
    local pid=$(get_task_pid "$task_id")
    descendants=$(python3 -c "
import subprocess, sys
def descendants(pid):
    try:
        out = subprocess.check_output(['pgrep', '-P', str(pid)], stderr=subprocess.DEVNULL, text=True)
        children = [int(p) for p in out.strip().split() if p]
    except: children = []
    result = list(children)
    for c in children: result.extend(descendants(c))
    return result
for d in descendants(int(sys.argv[1])):
    try:
        cmd = subprocess.check_output(['ps', '-p', str(d), '-o', 'command='], stderr=subprocess.DEVNULL, text=True).strip()
        # Truncate long command lines to keep context manageable
        if len(cmd) > 300: cmd = cmd[:300] + '...'
        print(f'  PID {d}: {cmd}')
    except: pass
" "$pid" 2>/dev/null || echo "  (unable to enumerate)")

    # Analyze tool-call repetition patterns in the full log.
    # This detects "verification loops" where the agent keeps running
    # similar commands (e.g. cargo test with different filters) without
    # making forward progress toward marking the task complete.
    local repetition_analysis=""
    if [ -n "$task_log" ] && [ -f "$task_log" ]; then
        repetition_analysis=$(python3 -c "
import re, sys, collections

log_file = sys.argv[1]
with open(log_file, 'r', errors='replace') as f:
    lines = f.readlines()

# Extract shell commands (the most common loop pattern)
shell_cmds = []
for line in lines:
    m = re.search(r'I will run the following command: (.+?) \(using tool: shell\)', line)
    if m:
        shell_cmds.append(m.group(1).strip())

if not shell_cmds:
    sys.exit(0)

# Normalize commands: strip timeout wrappers, collapse whitespace
def normalize(cmd):
    cmd = re.sub(r'^timeout \d+ ', '', cmd)
    cmd = re.sub(r'\s+', ' ', cmd).strip()
    # Collapse specific test filter args to detect 'same intent' commands
    cmd = re.sub(r'(cargo test[^|]*?)--test property_tests[^|]*', r'\1--test property_tests <filters>', cmd)
    cmd = re.sub(r'(cargo test[^|]*?)-- [^|]+', r'\1-- <filters>', cmd)
    return cmd

normalized = [normalize(c) for c in shell_cmds]
counts = collections.Counter(normalized)

# Find commands repeated 3+ times
repeated = [(cmd, cnt) for cmd, cnt in counts.most_common(10) if cnt >= 3]
if not repeated:
    sys.exit(0)

total_cmds = len(shell_cmds)
total_repeated = sum(cnt for _, cnt in repeated)

print(f'Total shell commands: {total_cmds}')
print(f'Commands repeated 3+ times: {total_repeated}/{total_cmds} ({100*total_repeated//total_cmds}%)')
print()
for cmd, cnt in repeated:
    print(f'  {cnt}x: {cmd[:120]}')

# Check if the task was ever marked complete
has_complete = any('TASK_COMPLETE' in line for line in lines[-50:])
print()
print(f'Task marked complete in last 50 lines: {\"YES\" if has_complete else \"NO\"}')
" "$task_log" 2>/dev/null) || true
    fi

    cat <<EOF
TASK HEALTH CHECK REQUEST
=========================
Task ID: ${task_id}
Task Description: ${task_desc}
Spec: ${SPEC_NAME}
Task File: ${TASK_FILE}
Elapsed Runtime: ${elapsed} seconds ($((elapsed / 60)) minutes)

DESCENDANT PROCESSES:
${descendants:-  (none)}

REPETITIVE COMMAND ANALYSIS:
${repetition_analysis:-  (no repetitive patterns detected)}

LAST ${HEALTH_CHECK_LOG_LINES} LINES OF TASK LOG:
${log_tail}
EOF
}

# ─── Health Check Verdict Parsing ────────────────────────────
# Reads an LLM response from stdin and outputs verdict="X" reason="Y"
# on stdout, suitable for eval. Searches for KILL_AND_FAIL first,
# then KILL_AND_RETRY, then CONTINUE (most specific first).
# Defaults to CONTINUE with reason "unparseable response" if no keyword found.
# Truncates reason to 200 chars.
parse_health_verdict() {
    python3 -c '
import sys, re

response = sys.stdin.read()

for line in response.split("\n"):
    line_upper = line.strip().upper()
    for v in ["KILL_AND_FAIL", "KILL_AND_RETRY", "CONTINUE"]:
        if v in line_upper:
            # Extract reasoning: strip everything up to and including the verdict keyword
            reason = re.sub(r".*(" + v + r")[:\s]*", "", line, flags=re.IGNORECASE).strip()
            reason = reason[:200]
            # Escape backslashes and double quotes for safe shell eval
            reason = reason.replace("\\", "\\\\").replace("\"", "\\\"")
            print("verdict=\"{}\"".format(v))
            print("reason=\"{}\"".format(reason))
            sys.exit(0)

# No verdict keyword found
print("verdict=\"CONTINUE\"")
print("reason=\"unparseable response\"")
' 2>/dev/null
}

# ─── Health Check Trigger ────────────────────────────────────
# Called for each running worker during poll_and_sync. Checks
# wall-clock eligibility and spawns a background kiro-cli call
# with the health-checker agent if a check is due.
# Non-blocking — the kiro-cli call runs in a background subshell.
maybe_start_health_check() {
    local task_id="$1"

    # Skip if disabled
    [ "${HEALTH_CHECK_ENABLED:-true}" != "true" ] && return 0

    # Skip if a health check is already in progress for this task
    local hc_pid_file="${STATE_DIR}/${task_id}.hc_pid"
    if [ -f "$hc_pid_file" ]; then
        local hc_pid=$(cat "$hc_pid_file")
        if kill -0 "$hc_pid" 2>/dev/null; then
            return 0  # still running
        fi
    fi

    # Check wall-clock eligibility
    local started=$(cat "${STATE_DIR}/${task_id}.started" 2>/dev/null || echo "")
    [ -z "$started" ] && return 0
    local now=$(date +%s)
    local elapsed=$((now - started))
    [ "$elapsed" -lt "${HEALTH_CHECK_INTERVAL}" ] && return 0

    # Check cooldown from last health check
    local last_hc=$(cat "${STATE_DIR}/${task_id}.last_hc" 2>/dev/null || echo "0")
    local since_last=$((now - last_hc))
    [ "$since_last" -lt "${HEALTH_CHECK_INTERVAL}" ] && return 0

    # Assemble context and spawn background check
    local context=$(assemble_health_context "$task_id")
    local result_file="${STATE_DIR}/${task_id}.hc_result"
    rm -f "$result_file"

    tui_event "🏥 health check for task ${task_id} (running ${elapsed}s)"
    dbg "health_check: starting for task ${task_id}, elapsed=${elapsed}s"

    (
        local response
        response=$(kiro-cli chat --no-interactive \
            --agent health-checker \
            --model "${HEALTH_CHECK_MODEL}" \
            --trust-all-tools \
            "$context" 2>/dev/null) || response="ERROR: kiro-cli failed"
        echo "$response" > "$result_file"
    ) &

    echo "$!" > "$hc_pid_file"
    echo "$now" > "${STATE_DIR}/${task_id}.last_hc"
}

# ─── Health Check Result Processing ──────────────────────────
# Called for each running worker during poll_and_sync. Checks if
# a background health check has completed and processes the verdict.
# Uses parse_health_verdict (from task 2.3) to extract the verdict.
process_health_check_result() {
    local task_id="$1"
    local hc_pid_file="${STATE_DIR}/${task_id}.hc_pid"
    local result_file="${STATE_DIR}/${task_id}.hc_result"

    # No health check was started
    [ ! -f "$hc_pid_file" ] && return 0

    # Check if still running
    local hc_pid=$(cat "$hc_pid_file")
    if kill -0 "$hc_pid" 2>/dev/null; then
        return 0  # still in progress
    fi

    # Clean up PID file
    rm -f "$hc_pid_file"

    # Read result
    if [ ! -f "$result_file" ]; then
        dbg "health_check: no result file for ${task_id}, treating as CONTINUE"
        return 0
    fi

    local response=$(cat "$result_file")
    rm -f "$result_file"

    # Parse verdict using inline python3 parser (parse_health_verdict from task 2.3)
    local verdict reason
    eval $(echo "$response" | parse_health_verdict) || { verdict="CONTINUE"; reason="parse error"; }

    dbg "health_check: task=${task_id} verdict=${verdict} reason=${reason}"

    local pid=$(get_task_pid "$task_id")

    case "$verdict" in
        CONTINUE)
            tui_event "🏥 ${task_id}: CONTINUE — ${reason}"
            ;;
        KILL_AND_RETRY)
            tui_event "🏥 ${task_id}: KILL_AND_RETRY — ${reason}"
            tui_event "⚠ killing task ${task_id} (health check: retry)"
            kill_tree "$pid" 2>/dev/null || true
            # Save failure context
            local fail_ctx="${STATE_DIR}/${task_id}.fail_context"
            echo "FAILURE_TYPE=health_check_kill" > "$fail_ctx"
            echo "VERDICT=KILL_AND_RETRY" >> "$fail_ctx"
            echo "REASON=${reason}" >> "$fail_ctx"
            # Let poll_and_sync's normal exit-code handling do the retry
            ;;
        KILL_AND_FAIL)
            tui_event "🏥 ${task_id}: KILL_AND_FAIL — ${reason}"
            tui_event "✗ task ${task_id} FAILED (health check: permanent)"
            kill_tree "$pid" 2>/dev/null || true
            set_task_state "$task_id" "failed"
            tui_set_task_state "$task_id" "failed"
            cleanup_worktree "$task_id" "$WORKTREE_BASE"
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
            ;;
    esac
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

    # Kill any orphaned health check background processes before removing STATE_DIR
    for hc_pid_file in "${STATE_DIR}"/*.hc_pid; do
        [ -f "$hc_pid_file" ] || continue
        local hc_pid
        hc_pid=$(cat "$hc_pid_file" 2>/dev/null)
        if [ -n "$hc_pid" ] && kill -0 "$hc_pid" 2>/dev/null; then
            kill "$hc_pid" 2>/dev/null || true
        fi
    done

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
validate_tasks_format "$TASK_FILE" || exit 1
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
# btb-specific directories
_ensure_gitignore ".ralph-logs/"
_ensure_gitignore ".ralph-worktrees/"
_ensure_gitignore ".ralph-build-cache/"

# Common build directories to prevent worktree bloat
_ensure_gitignore "target/"
_ensure_gitignore "build/"
_ensure_gitignore "dist/"
_ensure_gitignore "out/"
_ensure_gitignore ".next/"
_ensure_gitignore "node_modules/"
_ensure_gitignore "__pycache__/"
_ensure_gitignore "*.pyc"
_ensure_gitignore ".pytest_cache/"
_ensure_gitignore ".cargo/"
_ensure_gitignore "*.class"
_ensure_gitignore "bin/"
_ensure_gitignore "obj/"

# ─── Shared Build Cache ──────────────────────────────────────
# Create a shared build cache directory so all worktrees reuse compiled
# artifacts instead of each building from scratch (saves disk + time).
if [ -n "${SHARED_BUILD_CACHE_DIR:-}" ]; then
    # Resolve to absolute path relative to repo root
    SHARED_BUILD_CACHE_DIR_ABS="$(cd "$(dirname "$SHARED_BUILD_CACHE_DIR")" 2>/dev/null && pwd)/$(basename "$SHARED_BUILD_CACHE_DIR")"
    mkdir -p "$SHARED_BUILD_CACHE_DIR_ABS" 2>/dev/null || true
    export SHARED_BUILD_CACHE_DIR_ABS
fi

# ─── Phase 0: Steering Docs ─────────────────────────────────
# Check for .kiro/steering/ in the target repo. If missing, generate
# steering docs from the spec + codebase before any task execution.
# This gives all agents persistent project context.
ensure_steering_docs "$SPEC_DIR"

# ─── Phase 0.5: Dependency Installation ─────────────────────
# Auto-detect project dependencies and install them once on the main
# repo before any workers spawn. This ensures worktrees (and the
# reviewer) have access to installed packages.
#
# Supports: Node.js (pnpm/yarn/npm/bun), Python (pip/poetry),
#           Rust (cargo — build cache handled separately),
#           Go (go mod download).
#
# Each ecosystem is detected by its lockfile or manifest. Install
# runs only if the dependency directory is missing.
install_project_deps() {
    local installed=0

    # ── Node.js ──────────────────────────────────────────────
    if [ -f "package.json" ] && [ ! -d "node_modules" ]; then
        local pkg_mgr=""
        local install_cmd=""
        if [ -f "pnpm-lock.yaml" ]; then
            pkg_mgr="pnpm"
            install_cmd="pnpm install --frozen-lockfile"
        elif [ -f "yarn.lock" ]; then
            pkg_mgr="yarn"
            install_cmd="yarn install --frozen-lockfile"
        elif [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then
            pkg_mgr="bun"
            install_cmd="bun install --frozen-lockfile"
        elif [ -f "package-lock.json" ]; then
            pkg_mgr="npm"
            install_cmd="npm ci"
        else
            # No lockfile — use npm install as fallback
            pkg_mgr="npm"
            install_cmd="npm install"
        fi

        if command -v "$pkg_mgr" &>/dev/null; then
            echo -e "  \033[37m·\033[0m  installing node dependencies (${pkg_mgr})..."
            if $install_cmd >/dev/null 2>&1; then
                echo -e "  \033[37m✓\033[0m  node dependencies installed"
                installed=$((installed + 1))

                # Cache node_modules in shared build cache for worktrees
                if [ -n "${SHARED_BUILD_CACHE_DIR_ABS:-}" ] && [ -d "node_modules" ]; then
                    local cache_nm="${SHARED_BUILD_CACHE_DIR_ABS}/node_modules"
                    if [ ! -d "$cache_nm" ]; then
                        cp -a node_modules "$cache_nm" 2>/dev/null || true
                    fi
                fi
            else
                echo -e "  \033[93m⚠\033[0m  node dependency install failed (${pkg_mgr}) — agents will handle it"
            fi
        else
            echo -e "  \033[93m⚠\033[0m  ${pkg_mgr} not found — skipping node dependency install"
        fi
    fi

    # ── Python ───────────────────────────────────────────────
    if [ -f "requirements.txt" ] && [ ! -d ".venv" ] && command -v python3 &>/dev/null; then
        echo -e "  \033[37m·\033[0m  installing python dependencies..."
        if python3 -m venv .venv >/dev/null 2>&1 && .venv/bin/pip install -r requirements.txt >/dev/null 2>&1; then
            echo -e "  \033[37m✓\033[0m  python dependencies installed"
            installed=$((installed + 1))
        else
            echo -e "  \033[93m⚠\033[0m  python dependency install failed — agents will handle it"
        fi
    elif [ -f "pyproject.toml" ] && [ ! -d ".venv" ]; then
        if command -v poetry &>/dev/null; then
            echo -e "  \033[37m·\033[0m  installing python dependencies (poetry)..."
            if poetry install >/dev/null 2>&1; then
                echo -e "  \033[37m✓\033[0m  python dependencies installed"
                installed=$((installed + 1))
            else
                echo -e "  \033[93m⚠\033[0m  poetry install failed — agents will handle it"
            fi
        fi
    fi

    # ── Go ───────────────────────────────────────────────────
    if [ -f "go.mod" ] && command -v go &>/dev/null; then
        echo -e "  \033[37m·\033[0m  downloading go modules..."
        if go mod download >/dev/null 2>&1; then
            echo -e "  \033[37m✓\033[0m  go modules downloaded"
            installed=$((installed + 1))
        fi
    fi

    if [ "$installed" -gt 0 ]; then
        echo ""
    fi
}
install_project_deps

# ─── Phase 0.6: Credential Check ────────────────────────────
# Verify kiro-cli is authenticated before spawning workers. If credentials
# are expired, every worker will fail immediately and spawn retry loops
# that consume all system resources. Fail fast with a clear message instead.
_check_kiro_credentials() {
    # Try the 'auth status' subcommand first (available in newer kiro-cli versions).
    # If the subcommand doesn't exist (exit code 2 + "unrecognized subcommand"),
    # fall back to checking for the credential database file.
    local auth_output
    auth_output=$(kiro-cli auth status 2>&1) && {
        echo -e "  \033[37m✓\033[0m  kiro-cli authenticated"
        return 0
    }

    # Exit code 2 with "unrecognized subcommand" means older kiro-cli — check db file
    if echo "$auth_output" | awk '/unrecognized subcommand/ { found=1 } END { exit !found }'; then
        local db_path="${XDG_DATA_HOME:-$HOME/.local/share}/kiro-cli/data.sqlite3"
        if [ -f "$db_path" ]; then
            echo -e "  \033[37m✓\033[0m  kiro-cli credentials found"
            return 0
        fi
    fi

    echo ""
    echo -e "  \033[91m✗  kiro-cli is not authenticated.\033[0m"
    echo ""
    echo "  Workers need valid credentials to run. Please authenticate:"
    echo ""
    echo "    kiro-cli login --use-device-flow"
    echo ""
    echo "  Then re-run btb."
    exit 1
}
_check_kiro_credentials

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
    DAG_JSON=$(analyze_dependencies "$TASK_FILE" "$DESIGN_FILE" "$REQUIREMENTS_FILE") || true
    # If analyze_dependencies returned empty or failed, fall back to sequential
    if [ -z "$DAG_JSON" ] || ! echo "$DAG_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        log_warn "planner failed or returned invalid DAG, falling back to sequential"
        DAG_JSON=$(build_fallback_dag "$TASK_FILE")
    fi
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

# Validate DAG completeness (informational — repair loop already ran in analyze_dependencies)
INCOMPLETE_COUNT=$(count_incomplete_tasks "$TASK_FILE")
DAG_TASK_COUNT=$(echo "$DAG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
count = 0
for wave in data.get('waves', []):
    count += len(wave.get('tasks', []))
print(count)
" 2>/dev/null)

if [ "$DAG_TASK_COUNT" -lt "$INCOMPLETE_COUNT" ]; then
    log_warn "DAG has ${DAG_TASK_COUNT} tasks but ${INCOMPLETE_COUNT} are incomplete — $(($INCOMPLETE_COUNT - $DAG_TASK_COUNT)) still missing"
    log_warn "Execution will proceed but missing tasks won't run. Use --sequential to guarantee all tasks."
fi

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
done

# Batch-write all dependency files in a single python3 call
echo "$DAG_JSON" | python3 -c "
import sys, json, os
data = json.load(sys.stdin)
state_dir = '${STATE_DIR}'
for wave in data.get('waves', []):
    for task in wave.get('tasks', []):
        tid = task['id']
        deps = ' '.join(task.get('dependencies', []))
        with open(os.path.join(state_dir, tid + '.deps'), 'w') as f:
            f.write(deps)
" 2>/dev/null || true

# Initialize all tasks as pending
for task_id in $ALL_TASKS; do
    set_task_state "$task_id" "pending"
done

# Batch-check completion for all tasks in a single python3 call
# instead of spawning one python3 per task
_completed_ids=""
if [ -n "$ALL_TASKS" ]; then
    _completed_ids=$(python3 - "$TASK_FILE" $ALL_TASKS <<'PYEOF'
import re, sys

task_file = sys.argv[1]
task_ids = sys.argv[2:]

with open(task_file) as f:
    lines = f.readlines()

for tid in task_ids:
    pattern = re.compile(r'\[x\]\s+' + re.escape(tid) + r'(?:\.?\s)')
    for line in lines:
        m = pattern.search(line)
        if m:
            prefix = line[:m.start()]
            stripped = prefix.rstrip()
            if stripped and stripped[-1].isdigit():
                continue
            print(tid)
            break
PYEOF
) || true
fi

# Mark completed tasks
for task_id in $_completed_ids; do
    set_task_state "$task_id" "synced"
    tui_set_task_state "$task_id" "completed"
    TOTAL_COMPLETED=$((TOTAL_COMPLETED + 1))
    dbg "task ${task_id} already complete"
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
                dbg "are_deps_satisfied: task=${task_id} blocked by dep=${dep} state=${dep_state}"
                return 2
                ;;
            unknown)
                # Dependency not in DAG (planner error) — treat as satisfied
                # to avoid permanent deadlock. The task will handle missing
                # artifacts on its own.
                dbg "WARNING: dep ${dep} for task ${task_id} not in DAG (state=unknown), ignoring"
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
    local _pending_count=0
    local _skip_count=0
    for task_id in $ALL_TASKS; do
        local state
        state=$(get_task_state "$task_id")
        [ "$state" != "pending" ] && continue
        _pending_count=$((_pending_count + 1))

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
            _skip_count=$((_skip_count + 1))
            dbg "compute_ready: task ${task_id} SKIPPED (dep failed)"
        else
            : # task not ready yet — silent (deps unsatisfied)
        fi
    done
    _READY_TASKS=$(echo "$_READY_TASKS" | xargs)
    # Only log when tasks are newly skipped (ready tasks logged at spawn time)
    if [ "$_skip_count" -gt 0 ]; then
        dbg "compute_ready: pending=${_pending_count} ready='${_READY_TASKS}' newly_skipped=${_skip_count}"
    fi
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
        # instead of spawn time, so actively-working workers don't get killed.
        #
        # ADDITIONALLY: check for live descendant processes. Long-running builds
        # (cargo, gradle, webpack), training scripts, and test suites may run for
        # hours with no log output. As long as the worker's process tree has active
        # descendants, it's not stale — something is genuinely working.
        local heartbeat_file="${STATE_DIR}/${tid}.heartbeat"
        local last_activity_file="$heartbeat_file"
        # Fall back to start time if no heartbeat exists
        [ ! -f "$last_activity_file" ] && last_activity_file="${STATE_DIR}/${tid}.started"
        if [ -f "$last_activity_file" ]; then
            local last_activity
            last_activity=$(cat "$last_activity_file")
            local idle_time=$((now - last_activity))
            if [ "$idle_time" -gt "${STALE_THRESHOLD:-300}" ]; then
                # Before killing, check if the process tree has active descendants.
                # Walk the full tree recursively — a cargo build spawned by kiro-cli
                # is a grandchild+ process that pgrep -P (direct children only) misses.
                local _has_descendants=false
                local _desc_count=0
                _desc_count=$(python3 -c "
import subprocess, sys
def descendants(pid):
    try:
        out = subprocess.check_output(['pgrep', '-P', str(pid)], stderr=subprocess.DEVNULL, text=True)
        children = [int(p) for p in out.strip().split() if p]
    except (subprocess.CalledProcessError, ValueError):
        children = []
    result = list(children)
    for c in children:
        result.extend(descendants(c))
    return result
descs = descendants(int(sys.argv[1]))
print(len(descs))
" "$pid" 2>/dev/null) || _desc_count=0

                if [ "$_desc_count" -gt 0 ]; then
                    _has_descendants=true
                    # Descendant processes are alive — refresh heartbeat, not stale
                    echo "$(date +%s)" > "$heartbeat_file"
                    dbg "task ${tid} idle ${idle_time}s but has ${_desc_count} descendant process(es) — refreshing heartbeat"
                fi

                if [ "$_has_descendants" = false ]; then
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
                        tui_event "⚠ task ${tid} stale (idle ${idle_time}s, 0 descendants), sending SIGKILL"
                        kill -9 "$pid" 2>/dev/null || true
                        echo "$((kill_attempts + 1))" > "$kill_attempts_file"
                        sleep 1
                    else
                        # First attempt — graceful kill
                        tui_event "⚠ task ${tid} stale (idle ${idle_time}s, 0 descendants), killing"
                        kill_tree "$pid" 2>/dev/null || true
                        echo "$((kill_attempts + 1))" > "$kill_attempts_file"
                        sleep 1
                    fi
                fi
            fi
        fi

        # LLM health check — wall-clock based, runs alongside stale detection
        maybe_start_health_check "$tid"
        process_health_check_result "$tid"

        # Hard wall-clock timeout — safety net for verification loops where
        # the agent stays "active" (producing output, spawning processes) but
        # never converges toward marking the task complete. This is separate
        # from stale detection (which only catches inactivity) and the LLM
        # health check (which can misjudge active-but-unproductive workers).
        if [ "${JOB_TIMEOUT:-0}" -gt 0 ]; then
            local started_at=$(cat "${STATE_DIR}/${tid}.started" 2>/dev/null || echo "$now")
            local wall_elapsed=$((now - started_at))
            if [ "$wall_elapsed" -gt "${JOB_TIMEOUT}" ]; then
                dbg "JOB_TIMEOUT: task ${tid} exceeded ${JOB_TIMEOUT}s wall-clock (elapsed=${wall_elapsed}s) — killing"
                tui_event "⏰ task ${tid} hit wall-clock timeout (${wall_elapsed}s > ${JOB_TIMEOUT}s), killing"
                kill_tree "$pid" 2>/dev/null || true
                # Save failure context so retry knows it was a timeout
                local _timeout_ctx="${STATE_DIR}/${tid}.fail_context"
                {
                    echo "FAILURE_TYPE=wall_clock_timeout"
                    echo "ELAPSED=${wall_elapsed}s"
                    echo "HINT=The previous attempt was killed after exceeding the ${JOB_TIMEOUT}s wall-clock timeout. The agent was still active but never marked the task complete. It likely got stuck in a verification loop — re-running tests or checks repeatedly instead of concluding. On this retry: once your implementation is done and tests pass, IMMEDIATELY mark the task complete and output the completion signal. Do NOT re-verify passing tests."
                } > "$_timeout_ctx"
                sleep 1
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

    # 2. Update TUI (never let TUI errors kill the scheduler)
    TUI_CURRENT_WAVE=$_HIGHEST_SYNCED_WAVE
    TUI_ELAPSED=$(($(date +%s) - START_TIME))
    tui_update_counts || true
    tui_render || true

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
        spawn_worker "$task_id" || {
            dbg "step4: spawn_worker FAILED for ${task_id}, state now=$(get_task_state "$task_id")"
            true
        }
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
                tui_update_counts || true
                tui_render || true
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
            dbg "review_wave START batch tasks='${_REVIEW_BATCH_TASKS}' base_sha='${_REVIEW_BATCH_BASE_SHA}'"
            review_wave "batch" "$_REVIEW_BATCH_TASKS" "$_REVIEW_BATCH_BASE_SHA" || review_result=$?
            dbg "review_wave END result=${review_result}"

            kill $_REVIEW_POLL_PID 2>/dev/null || true
            wait $_REVIEW_POLL_PID 2>/dev/null || true

            if [ "$review_result" -eq 0 ]; then
                TOTAL_REVIEW_PASSES=$((TOTAL_REVIEW_PASSES + 1))
            else
                TOTAL_REVIEW_FIXES=$((TOTAL_REVIEW_FIXES + 1))
                tui_event "⚠ review gate flagged issues — check logs"
            fi

            # Snapshot git & task state after review for debugging
            dbg "post-review git HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo '?') branch=$(git branch --show-current 2>/dev/null || echo '?')"
            dbg "post-review git dirty=$(git status --porcelain 2>/dev/null | head -5 | tr '\n' ' ')"
            dbg "post-review TOTAL_COMPLETED=${TOTAL_COMPLETED} TOTAL_FAILED=${TOTAL_FAILED} TOTAL_SKIPPED=${TOTAL_SKIPPED}"

            _SYNCED_SINCE_REVIEW=0
            _REVIEW_BATCH_TASKS=""
            _REVIEW_BATCH_BASE_SHA=""
            _REVIEW_DEFERRALS=0
            TUI_PHASE="executing"
            dbg "review cleanup done, resuming scheduler"

            # Re-compute ready tasks after review — the forced-wait loop may have
            # synced tasks that satisfy dependencies for other tasks
            compute_ready_tasks
            dbg "post-review compute_ready: _READY_TASKS='${_READY_TASKS}'"
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
        dbg "DEADLOCK: remaining=${local_remaining_now} running=false ready='${_READY_TASKS}'"
        # Dump every task's state and deps for post-mortem
        for task_id in $ALL_TASKS; do
            _ds="" _dd=""
            _ds=$(get_task_state "$task_id")
            _dd=$(cat "${STATE_DIR}/${task_id}.deps" 2>/dev/null || echo "none")
            [ "$_ds" = "synced" ] || [ "$_ds" = "failed" ] || [ "$_ds" = "skipped" ] || \
                dbg "  DEADLOCK task=${task_id} state=${_ds} deps=[${_dd}]"
        done
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
        tui_render || true
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
tui_update_counts || true

TOTAL=$(count_total_tasks "$TASK_FILE")
INCOMPLETE_FINAL=$(count_incomplete_tasks "$TASK_FILE")

dbg "FINAL: total=${TOTAL} incomplete=${INCOMPLETE_FINAL} completed=${TOTAL_COMPLETED} failed=${TOTAL_FAILED} skipped=${TOTAL_SKIPPED}"

if [ "$TOTAL_FAILED" -gt 0 ] || [ "$TOTAL_SKIPPED" -gt 0 ]; then
    tui_event "⚠ ${TOTAL_FAILED} failed, ${TOTAL_SKIPPED} skipped"
    dbg "EXIT 1: failed=${TOTAL_FAILED} skipped=${TOTAL_SKIPPED}"
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
