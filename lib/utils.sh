#!/bin/bash
# lib/utils.sh - Shared utility functions for concurrent task execution
# NOTE: All text matching uses awk instead of grep to avoid exit-code-1-on-zero-matches
#       which breaks set -euo pipefail.

set -euo pipefail

# ─── Colors (muted, classy palette) ──────────────────────────
RED='\033[91m'
GREEN='\033[37m'       # using light gray instead of green
YELLOW='\033[93m'
BLUE='\033[94m'
CYAN='\033[96m'
MAGENTA='\033[95m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
GRAY='\033[90m'
WHITE='\033[97m'
LGRAY='\033[37m'

# ─── Logging ─────────────────────────────────────────────────
# When TUI is active, route messages to the TUI ring buffer.
# Otherwise, print to stdout with muted styling.

log_info() {
    if [ "${TUI_ACTIVE:-false}" = true ]; then
        tui_event "· $*"
    else
        echo -e "${DIM}${GRAY}  ·${NC}  $(date +%H:%M:%S) $*"
    fi
}
log_success() {
    if [ "${TUI_ACTIVE:-false}" = true ]; then
        tui_event "✓ $*"
    else
        echo -e "${DIM}${LGRAY}  ✓${NC}  $(date +%H:%M:%S) $*"
    fi
}
log_warn() {
    if [ "${TUI_ACTIVE:-false}" = true ]; then
        tui_event "⚠ $*"
    else
        echo -e "${DIM}${YELLOW}  ⚠${NC}  $(date +%H:%M:%S) $*"
    fi
}
log_error() {
    if [ "${TUI_ACTIVE:-false}" = true ]; then
        tui_event "✗ $*"
    else
        echo -e "${RED}  ✗${NC}  $(date +%H:%M:%S) $*"
    fi
}
log_task() {
    if [ "${TUI_ACTIVE:-false}" = true ]; then
        tui_event "→ $*"
    else
        echo -e "${DIM}${CYAN}  →${NC}  $(date +%H:%M:%S) $*"
    fi
}
log_wave() {
    if [ "${TUI_ACTIVE:-false}" = true ]; then
        tui_event "═ $*"
    else
        echo -e "${BOLD}${WHITE}  ═${NC}  $(date +%H:%M:%S) $*"
    fi
}

log_to_file() {
    local log_file="$1"
    shift
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*" >> "$log_file"
}

# ─── Task Parsing ────────────────────────────────────────────

# Extract all leaf task IDs (subtasks like 1.1, 2.3)
get_all_leaf_tasks() {
    local task_file="$1"
    awk '/^[[:space:]]+-[[:space:]]\[.\][[:space:]][0-9]+\.[0-9]+/ {
        match($0, /[0-9]+\.[0-9]+/)
        print substr($0, RSTART, RLENGTH)
    }' "$task_file"
}

# Extract all parent task IDs (top-level like 1, 2, 3)
get_all_parent_tasks() {
    local task_file="$1"
    awk '/^-[[:space:]]\[.\][[:space:]][0-9]+\./ {
        match($0, /[0-9]+/)
        print substr($0, RSTART, RLENGTH)
    }' "$task_file" | sort -u
}

# Check if a specific task is complete (returns 0=yes, 1=no)
is_task_complete() {
    local task_file="$1"
    local task_id="$2"
    awk -v tid="$task_id" '
        $0 ~ "\\[x\\][[:space:]]+" tid { found=1; exit }
        END { exit !found }
    ' "$task_file"
}

# Check if ALL subtasks of a parent are complete
is_parent_complete() {
    local task_file="$1"
    local parent_id="$2"
    awk -v pid="$parent_id" '
        BEGIN { total=0; done=0 }
        $0 ~ "^[[:space:]]+-[[:space:]]\\[.\\][[:space:]]+" pid "\\.[0-9]+" { total++ }
        $0 ~ "^[[:space:]]+-[[:space:]]\\[x\\][[:space:]]+" pid "\\.[0-9]+" { done++ }
        END { exit !(total > 0 && total == done) }
    ' "$task_file"
}

# Get task description by ID
get_task_description() {
    local task_file="$1"
    local task_id="$2"
    awk -v tid="$task_id" '
        $0 ~ "\\[.\\][[:space:]]+" tid "[[:space:]]" {
            sub(/.*\[.\][[:space:]]+[0-9.]+[[:space:]]+/, "")
            print
            exit
        }
    ' "$task_file"
}

# Count incomplete leaf tasks
count_incomplete_tasks() {
    local task_file="$1"
    awk '/^[[:space:]]+-[[:space:]]\[ \][[:space:]][0-9]+\.[0-9]+/ { n++ } END { print n+0 }' "$task_file"
}

# Count completed leaf tasks
count_completed_tasks() {
    local task_file="$1"
    awk '/^[[:space:]]+-[[:space:]]\[x\][[:space:]][0-9]+\.[0-9]+/ { n++ } END { print n+0 }' "$task_file"
}

# Count total leaf tasks
count_total_tasks() {
    local task_file="$1"
    awk '/^[[:space:]]+-[[:space:]]\[.\][[:space:]][0-9]+\.[0-9]+/ { n++ } END { print n+0 }' "$task_file"
}

# ─── Git Helpers ─────────────────────────────────────────────

# Detect the primary branch name (main, master, or whatever the repo uses).
# Caches the result in PRIMARY_BRANCH for the session.
get_primary_branch() {
    if [ -n "${PRIMARY_BRANCH:-}" ]; then
        echo "$PRIMARY_BRANCH"
        return
    fi

    # 1. If we have a HEAD, use the current branch
    local current
    current=$(git branch --show-current 2>/dev/null || echo "")
    if [ -n "$current" ]; then
        # If on a ralph/* branch, find the non-ralph branch
        if [[ "$current" == ralph/* ]]; then
            # Check for main, then master, then first non-ralph branch
            for candidate in main master; do
                if git show-ref --verify --quiet "refs/heads/${candidate}" 2>/dev/null; then
                    PRIMARY_BRANCH="$candidate"
                    echo "$PRIMARY_BRANCH"
                    return
                fi
            done
            # Fall back to first non-ralph branch
            PRIMARY_BRANCH=$(git branch 2>/dev/null | awk '!/ralph/ { gsub(/^[* ]+/, ""); print; exit }')
            PRIMARY_BRANCH="${PRIMARY_BRANCH:-main}"
        else
            PRIMARY_BRANCH="$current"
        fi
        echo "$PRIMARY_BRANCH"
        return
    fi

    # 2. No current branch (detached HEAD or bare init) — check refs
    for candidate in main master; do
        if git show-ref --verify --quiet "refs/heads/${candidate}" 2>/dev/null; then
            PRIMARY_BRANCH="$candidate"
            echo "$PRIMARY_BRANCH"
            return
        fi
    done

    # 3. Default to main
    PRIMARY_BRANCH="main"
    echo "$PRIMARY_BRANCH"
}

ensure_git_ready() {
    if [ ! -d ".git" ]; then
        log_info "Initializing git repository..."
        git init -b main >/dev/null 2>&1
        git add . >/dev/null 2>&1
        git commit -m "Initial commit" --allow-empty >/dev/null 2>&1
    else
        # Ensure there's at least one commit (handles bare git init)
        if ! git rev-parse HEAD >/dev/null 2>&1; then
            log_info "No commits found, creating initial commit..."
            git add . >/dev/null 2>&1
            git commit -m "Initial commit" --allow-empty >/dev/null 2>&1
        fi
    fi
    # Cache the primary branch for the session
    get_primary_branch >/dev/null
}

create_worktree() {
    local task_id="$1"
    local worktree_base="$2"
    local branch_name="ralph/task-${task_id//\./-}"
    local dir_name="task-${task_id//\./-}"

    # Resolve worktree_base to absolute path FIRST, creating it if needed
    mkdir -p "$worktree_base"
    local abs_base
    abs_base=$(cd "$worktree_base" && pwd)
    local worktree_path="${abs_base}/${dir_name}"

    # Clean up any stale worktree at this path
    if [ -d "$worktree_path" ]; then
        git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
    fi
    git branch -D "$branch_name" >/dev/null 2>&1 || true

    # Retry loop: git worktree add can fail if the index is locked by a
    # concurrent git operation (sync, merge, commit). Retry with backoff.
    local max_attempts=5
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        if git worktree add "$worktree_path" -b "$branch_name" >/dev/null 2>&1; then
            break
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep "$attempt"  # linear backoff: 1s, 2s, 3s, 4s
            # Clean up partial state from failed attempt
            git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
            git branch -D "$branch_name" >/dev/null 2>&1 || true
        fi
    done

    # Verify the worktree actually exists
    if [ ! -d "$worktree_path" ]; then
        echo "" # return empty string to signal failure
        return 1
    fi

    echo "$worktree_path"
}

merge_worktree() {
    local task_id="$1"
    local branch_name="ralph/task-${task_id//\./-}"
    local current_branch
    current_branch=$(git branch --show-current)

    git add . >/dev/null 2>&1 || true
    git diff --cached --quiet || git commit -m "Pre-merge checkpoint" >/dev/null 2>&1 || true

    if git merge "$branch_name" --no-edit -m "Merge task ${task_id}" >/dev/null 2>&1; then
        log_success "Merged task ${task_id} branch into ${current_branch}"
        return 0
    else
        log_warn "Merge conflict for task ${task_id}, attempting auto-resolve..."
        git checkout --theirs -- "$TASK_FILE" >/dev/null 2>&1 || true
        git add . >/dev/null 2>&1 || true
        git commit -m "Merge task ${task_id} (auto-resolved)" --no-edit >/dev/null 2>&1 || true
        return 0
    fi
}

cleanup_worktree() {
    local task_id="$1"
    local worktree_base="$2"
    local branch_name="ralph/task-${task_id//\./-}"
    local dir_name="task-${task_id//\./-}"

    # Resolve to absolute, matching what create_worktree produced
    local worktree_path
    if [ -d "$worktree_base" ]; then
        worktree_path="$(cd "$worktree_base" && pwd)/${dir_name}"
    else
        worktree_path="${worktree_base}/${dir_name}"
    fi

    git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
    git branch -D "$branch_name" >/dev/null 2>&1 || true
}

# Nuke ALL ralph worktrees, branches, locks — for manual recovery
cleanup_all_ralph() {
    log_info "Cleaning up all Ralph artifacts..."

    # Kill any running ralph worker processes
    local pids
    pids=$(ps aux | awk '/lib\/worker\.sh/ && !/awk/ { print $2 }')
    for pid in $pids; do
        log_warn "Killing worker PID ${pid}"
        kill_tree "$pid" 2>/dev/null || true
    done

    # Remove all ralph worktrees
    git worktree list 2>/dev/null | awk '/ralph/ { print $1 }' | while read wt; do
        git worktree remove "$wt" --force >/dev/null 2>&1 || true
    done
    git worktree prune >/dev/null 2>&1 || true

    # Remove all ralph branches
    git branch 2>/dev/null | awk '/ralph/ { gsub(/^[* ]+/, ""); print }' | while read br; do
        git branch -D "$br" >/dev/null 2>&1 || true
    done

    # Remove lock and state files
    rm -f .ralph-merge-lock 2>/dev/null || true
    rm -rf ../.ralph-worktrees 2>/dev/null || true

    log_success "All Ralph artifacts cleaned up"
}

# ─── Process Management ──────────────────────────────────────

is_pid_alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

kill_tree() {
    local pid="$1"
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for child in $children; do
        kill_tree "$child"
    done
    kill "$pid" 2>/dev/null || true
}

# ─── Validation ──────────────────────────────────────────────

validate_spec() {
    local spec_dir="$1"
    local errors=0

    if [ ! -f "${spec_dir}/tasks.md" ]; then
        log_error "Missing: ${spec_dir}/tasks.md"
        ((errors++))
    fi
    if [ ! -f "${spec_dir}/design.md" ]; then
        log_warn "Missing: ${spec_dir}/design.md (optional but recommended)"
    fi
    if [ ! -f "${spec_dir}/requirements.md" ]; then
        log_warn "Missing: ${spec_dir}/requirements.md (optional but recommended)"
    fi

    return $errors
}

validate_dag_json() {
    local json="$1"
    echo "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    assert 'waves' in data, 'Missing waves key'
    assert isinstance(data['waves'], list), 'waves must be array'
    for wave in data['waves']:
        assert 'id' in wave, 'Wave missing id'
        assert 'tasks' in wave, 'Wave missing tasks'
    print('valid')
except Exception as e:
    print(f'invalid: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# ─── Progress Display ────────────────────────────────────────

print_progress_bar() {
    local completed="$1"
    local total="$2"
    local width=40
    local pct=0

    if [ "$total" -gt 0 ]; then
        pct=$((completed * 100 / total))
    fi

    local filled=$((completed * width / (total > 0 ? total : 1)))
    local empty=$((width - filled))

    printf "\r  ${BOLD}${WHITE}"
    printf '%0.s█' $(seq 1 $filled 2>/dev/null) || true
    printf "${NC}${DIM}"
    printf '%0.s░' $(seq 1 $empty 2>/dev/null) || true
    printf "${NC} ${DIM}%d/%d (%d%%)${NC}" "$completed" "$total" "$pct"
}

print_status_table() {
    local task_file="$1"
    local total completed incomplete
    total=$(count_total_tasks "$task_file")
    completed=$(count_completed_tasks "$task_file")
    incomplete=$(count_incomplete_tasks "$task_file")

    echo ""
    echo -e "  ${DIM}${GRAY}─────────────────────────────────${NC}"
    echo -e "  ${DIM}total${NC}      ${total}"
    echo -e "  ${DIM}done${NC}       ${completed}"
    echo -e "  ${DIM}remaining${NC}  ${incomplete}"
    print_progress_bar "$completed" "$total"
    echo ""
    echo -e "  ${DIM}${GRAY}─────────────────────────────────${NC}"
    echo ""
}
