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
    # Returns all executable task IDs:
    # 1. Subtasks with dotted IDs like "1.1", "2.3" (indented or not)
    # 2. Top-level tasks that have NO subtasks (e.g. checkpoints like "- [ ] 3. Checkpoint...")
    python3 - "$task_file" <<'PYEOF'
import re, sys

with open(sys.argv[1]) as f:
    lines = f.readlines()

# Pass 1: collect all dotted subtask IDs (e.g. 1.1, 2.3, 7.4)
# These can be indented or not — handle both formats:
#   "  - [ ] 1.1 ..."  (indented under parent)
#   "- [ ] 1.1 ..."    (flat format, no parent header)
subtask_ids = []
parents_with_children = set()
for line in lines:
    # Match any line with [.] followed by a dotted ID (N.M)
    m = re.match(r'^[\s]*-\s+\[.\]\s+(\d+)\.(\d+\S*)', line)
    if m:
        parent_id = m.group(1)
        sub_part = m.group(2)
        # Only treat as subtask if sub_part starts with a digit
        # (distinguishes "1.1 task" from "3. Checkpoint" where "." is punctuation)
        if sub_part and sub_part[0].isdigit():
            full_id = parent_id + '.' + sub_part
            subtask_ids.append(full_id)
            parents_with_children.add(parent_id)

# Pass 2: collect top-level tasks that have NO children (childless parents = leaf)
# These look like "- [ ] 3. Checkpoint..." where the ID is just "3"
childless_ids = []
for line in lines:
    # Top-level task: "- [ ] N. description" where N has no subtasks
    m = re.match(r'^-\s+\[.\]\s+(\d+)\.\s', line)
    if m:
        tid = m.group(1)
        if tid not in parents_with_children:
            childless_ids.append(tid)

# Output subtasks first, then childless top-level tasks
for tid in subtask_ids:
    print(tid)
for tid in childless_ids:
    print(tid)
PYEOF
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
# Handles both subtask IDs (1.1, 2.3) and top-level IDs (3, 7)
is_task_complete() {
    local task_file="$1"
    local task_id="$2"
    # Use python for reliable boundary-aware matching.
    # Bash heredoc with <<'PYEOF' prevents any shell interpolation inside.
    python3 - "$task_file" "$task_id" <<'PYEOF'
import re, sys

task_file = sys.argv[1]
tid = sys.argv[2]

with open(task_file) as f:
    for line in f:
        # Match [x] followed by whitespace then the task ID
        # The ID must be followed by a dot-space (top-level "3. ") or whitespace (subtask "1.1 ")
        m = re.search(r'\[x\]\s+' + re.escape(tid) + r'(?:\.?\s)', line)
        if m:
            # Verify the ID is not a suffix of a larger number (e.g. "3" matching "13")
            prefix = line[:m.start()]
            # After [x] and spaces, the ID should not be preceded by a digit
            stripped = prefix.rstrip()
            if stripped and stripped[-1].isdigit():
                continue
            sys.exit(0)
sys.exit(1)
PYEOF
}

# Check if ALL subtasks of a parent are complete
# Handles both indented ("  - [x] 1.1") and flat ("- [x] 1.1") formats
is_parent_complete() {
    local task_file="$1"
    local parent_id="$2"
    python3 - "$task_file" "$parent_id" <<'PYEOF'
import re, sys

task_file = sys.argv[1]
pid = sys.argv[2]

total = 0
done = 0
# Match any line with [.] followed by parent_id.digit (subtask pattern)
pattern = re.compile(r'\[.\]\s+' + re.escape(pid) + r'\.(\d+)')
done_pattern = re.compile(r'\[x\]\s+' + re.escape(pid) + r'\.(\d+)')

with open(task_file) as f:
    for line in f:
        if pattern.search(line):
            total += 1
        if done_pattern.search(line):
            done += 1

sys.exit(0 if total > 0 and total == done else 1)
PYEOF
}

# Get task description by ID
# Handles both subtask IDs (1.1, 2.3) and top-level checkpoint IDs (3, 7)
get_task_description() {
    local task_file="$1"
    local task_id="$2"
    # Use python for boundary-aware matching — awk can't reliably distinguish
    # "3" from "13" or "3.1" without proper word boundary support.
    python3 - "$task_file" "$task_id" <<'PYEOF'
import re, sys

task_file = sys.argv[1]
tid = sys.argv[2]

with open(task_file) as f:
    for line in f:
        # Match [.] then whitespace then the task ID followed by dot-space or just space
        m = re.search(r'\[.\]\s+' + re.escape(tid) + r'(?:\.?\s)(.*)', line)
        if m:
            # Verify not a suffix of a larger number
            prefix = line[:m.start()]
            stripped = prefix.rstrip()
            if stripped and stripped[-1].isdigit():
                continue
            desc = m.group(1).strip()
            # For top-level tasks like "3. Checkpoint - Profiler Complete",
            # the regex already consumed the ". " so desc starts at the description
            print(desc)
            sys.exit(0)
# No match — print empty
PYEOF
}

# Count incomplete leaf tasks (subtasks + childless top-level tasks)
count_incomplete_tasks() {
    local task_file="$1"
    get_all_leaf_tasks "$task_file" | while read -r tid; do
        is_task_complete "$task_file" "$tid" || echo "$tid"
    done | wc -l | tr -d ' '
}

# Count completed leaf tasks (subtasks + childless top-level tasks)
count_completed_tasks() {
    local task_file="$1"
    get_all_leaf_tasks "$task_file" | while read -r tid; do
        is_task_complete "$task_file" "$tid" && echo "$tid"
    done | wc -l | tr -d ' '
}

# Count total leaf tasks (subtasks + childless top-level tasks)
count_total_tasks() {
    local task_file="$1"
    get_all_leaf_tasks "$task_file" | wc -l | tr -d ' '
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

    # Prune stale worktree metadata — git can refuse to create a worktree
    # if it thinks the branch is already checked out in a (now-deleted) worktree
    git worktree prune >/dev/null 2>&1 || true

    # Retry loop: git worktree add can fail if the index is locked by a
    # concurrent git operation (sync, merge, commit). Retry with backoff.
    local max_attempts=5
    local attempt=0
    local _wt_err=""
    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        _wt_err=$(git worktree add "$worktree_path" -b "$branch_name" 2>&1) && break
        # Log the actual error for diagnostics
        if declare -F dbg &>/dev/null; then
            dbg "create_worktree: attempt ${attempt}/${max_attempts} failed for ${task_id}: ${_wt_err}"
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep "$attempt"  # linear backoff: 1s, 2s, 3s, 4s
            # Clean up partial state from failed attempt
            git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
            git branch -D "$branch_name" >/dev/null 2>&1 || true
            git worktree prune >/dev/null 2>&1 || true
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

# Validate tasks.md format before DAG analysis.
# Catches common authoring mistakes that silently break the parser.
# On errors: prints a diagnostic block with issues + a concise format
# guide, then returns 1. On success: returns 0 silently.
validate_tasks_format() {
    local task_file="$1"
    [ ! -f "$task_file" ] && return 0  # validate_spec already handles missing file

    python3 - "$task_file" <<'PYEOF'
import re, sys

task_file = sys.argv[1]
with open(task_file) as f:
    lines = f.readlines()

errors = []
warnings = []
seen_ids = {}       # id -> line number
parent_ids = set()  # top-level parent IDs (bare integers)

for lineno, line in enumerate(lines, 1):
    stripped = line.rstrip('\n')

    # ── Detect lines that look like tasks but have broken checkbox format ──
    # Catches: "- 1.1 Do something", "- () 1.1", "* [ ] 1.1", "- [] 1.1"
    if re.match(r'^[\s]*[-*]\s+\d+[\.\s]', stripped) and not re.search(r'\[.\]', stripped):
        errors.append(f"  line {lineno}: missing checkbox — '{stripped.strip()}'")
        errors.append(f"           fix: add '[ ] ' after the dash → '- [ ] ...'")
        continue

    if re.match(r'^[\s]*[-*]\s+\(\)', stripped) or re.match(r'^[\s]*[-*]\s+\[\]', stripped):
        errors.append(f"  line {lineno}: malformed checkbox — '{stripped.strip()}'")
        errors.append(f"           fix: use '[ ]' (space between brackets) with a dash '- [ ] ...'")
        continue

    if re.match(r'^\s*\*\s+\[.\]', stripped):
        errors.append(f"  line {lineno}: wrong list marker — '{stripped.strip()}'")
        errors.append(f"           fix: use '- [ ]' not '* [ ]'")
        continue

    # ── Only process valid checkbox lines from here ──
    m_checkbox = re.match(r'^[\s]*-\s+\[.\]\s+(.*)', stripped)
    if not m_checkbox:
        continue  # non-task line (headings, context, blank) — fine

    after_checkbox = m_checkbox.group(1)

    # ── Try to extract a task ID ──
    # Subtask: "1.1 description" or "1.10 description"
    m_sub = re.match(r'^(\d+)\.(\d+)\s', after_checkbox)
    # Parent: "1. description" (dot-space)
    m_par = re.match(r'^(\d+)\.\s', after_checkbox)
    # Broken subtask: "1. 1 description" (dot-space-digit — common typo)
    m_broken = re.match(r'^(\d+)\.\s+(\d+)\s', after_checkbox)
    # Non-numeric ID
    m_alpha = re.match(r'^([A-Za-z])', after_checkbox)

    if m_broken:
        pid = m_broken.group(1)
        sid = m_broken.group(2)
        errors.append(f"  line {lineno}: dot-space in subtask ID — '- [ ] {pid}. {sid} ...'")
        errors.append(f"           fix: remove the space → '- [ ] {pid}.{sid} ...'")
        errors.append(f"           note: '{pid}. ' is parsed as parent task {pid}, not subtask {pid}.{sid}")
        continue

    if m_sub:
        full_id = f"{m_sub.group(1)}.{m_sub.group(2)}"
        parent_id = m_sub.group(1)
        if full_id in seen_ids:
            errors.append(f"  line {lineno}: duplicate ID '{full_id}' (first seen line {seen_ids[full_id]})")
        else:
            seen_ids[full_id] = lineno
        # Track that this parent has children
        parent_ids.add(parent_id)
    elif m_par:
        tid = m_par.group(1)
        if tid in seen_ids:
            errors.append(f"  line {lineno}: duplicate ID '{tid}' (first seen line {seen_ids[tid]})")
        else:
            seen_ids[tid] = lineno
    elif m_alpha:
        errors.append(f"  line {lineno}: non-numeric ID — '{stripped.strip()}'")
        errors.append(f"           fix: use numeric IDs like '1.1', '2.3', not letters")
    else:
        # Checkbox line with no recognizable ID
        errors.append(f"  line {lineno}: checkbox with no task ID — '{stripped.strip()}'")
        errors.append(f"           fix: add a numeric ID after the checkbox → '- [ ] 1.1 ...'")

# ── Check for orphan subtasks (parent ID never appears as a top-level task) ──
top_level_ids = set()
for tid in seen_ids:
    if '.' not in tid:
        top_level_ids.add(tid)

for tid in seen_ids:
    if '.' in tid:
        parent = tid.split('.')[0]
        if parent not in top_level_ids:
            warnings.append(f"  subtask {tid} references parent {parent}, but no '- [ ] {parent}. ...' line exists")

# ── Check that at least one leaf task exists ──
has_subtasks = len([t for t in seen_ids if '.' in t]) > 0
has_childless = len([t for t in seen_ids if '.' not in t and t not in parent_ids]) > 0
if not has_subtasks and not has_childless:
    errors.append(f"  no executable tasks found — file has no subtasks and no standalone parent tasks")

# ── Output ──
if not errors and not warnings:
    sys.exit(0)

print()
print("  \033[91m✗  tasks.md format issues\033[0m")
print()

if errors:
    for e in errors:
        print(e)
    print()

if warnings:
    print("  \033[93mwarnings:\033[0m")
    for w in warnings:
        print(w)
    print()

# ── Concise format guide ──
print("  \033[1m\033[97mtasks.md format:\033[0m")
print()
print("    parent task:    - [ ] N. Description        (N = integer, dot-space)")
print("    subtask:        - [ ] N.M Description       (N.M = dotted, no space after dot)")
print("    completed:      - [x] N.M Description       (x marks done)")
print()
print("  \033[2mrules:\033[0m")
print("    · every task line needs a checkbox: - [ ] or - [x]")
print("    · IDs must be numeric (1, 1.1, 2.3) — no letters")
print("    · IDs must be unique across the file")
print("    · subtask dot is part of the ID: 1.1 not 1. 1")
print("    · parent tasks with subtasks are not executed (subtasks are)")
print("    · parent tasks without subtasks run as leaf tasks")
print()
print("  \033[2mexample:\033[0m")
print("    - [ ] 1. Setup infrastructure")
print("      - [ ] 1.1 Create database schema")
print("      - [ ] 1.2 Add seed data")
print("    - [ ] 2. Verify setup works          ← runs as leaf (no children)")
print()

sys.exit(1)
PYEOF
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
