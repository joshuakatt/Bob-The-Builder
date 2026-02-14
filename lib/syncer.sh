#!/bin/bash
# lib/syncer.sh - Synchronization manager for concurrent task execution
# Handles merging worktree branches back to the primary branch.
# Uses an agent for non-trivial merge conflicts.

set -euo pipefail

# Guard: utils.sh already sourced by caller
if ! declare -F log_info &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
fi

MERGE_LOCK_FILE=".ralph-merge-lock"
RESOLVER_AGENT="${RESOLVER_AGENT:-resolver}"

# ─── PID-aware merge lock ────────────────────────────────────
# Writes "pid:timestamp" so we can detect stale locks from dead processes.

acquire_merge_lock() {
    local max_wait=60
    local waited=0
    while [ -f "$MERGE_LOCK_FILE" ]; do
        # Check if the holder is still alive
        local holder_pid
        holder_pid=$(awk -F: '{ print $1 }' "$MERGE_LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
            log_warn "Lock held by dead PID ${holder_pid}, releasing"
            rm -f "$MERGE_LOCK_FILE"
            break
        fi
        if [ $waited -ge $max_wait ]; then
            log_warn "Lock wait exceeded ${max_wait}s, forcing release"
            rm -f "$MERGE_LOCK_FILE"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "$$:$(date +%s)" > "$MERGE_LOCK_FILE"
}

release_merge_lock() {
    rm -f "$MERGE_LOCK_FILE"
}

# ─── Sync a completed task branch into the primary branch ────

sync_task_to_main() {
    local task_id="$1"
    local worktree_base="$2"
    local branch_name="ralph/task-${task_id//\./-}"
    local primary
    primary=$(get_primary_branch)

    acquire_merge_lock
    # Always release on return, even on error
    trap 'release_merge_lock' RETURN

    log_info "Syncing task ${task_id} to ${primary}..."

    # Make sure we're on the primary branch
    local current_branch
    current_branch=$(git branch --show-current)
    if [ "$current_branch" != "$primary" ]; then
        git checkout "$primary" >/dev/null 2>&1 || true
    fi

    # Try a clean merge first
    if git merge "$branch_name" --no-edit -m "Merge task ${task_id}" >/dev/null 2>&1; then
        log_success "Task ${task_id} merged cleanly"
    else
        log_warn "Merge conflict for task ${task_id} — invoking resolver agent"
        resolve_with_agent "$task_id" "$branch_name"
    fi

    # Clean up worktree and branch
    cleanup_worktree "$task_id" "$worktree_base"
    log_success "Task ${task_id} synced and cleaned up"
}

# ─── Agent-based conflict resolution ─────────────────────────
# Spawns the resolver agent with full context about the conflict.

resolve_with_agent() {
    local task_id="$1"
    local branch_name="$2"

    # Collect conflicted file list
    local conflicted
    conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

    if [ -z "$conflicted" ]; then
        git add . >/dev/null 2>&1 || true
        git commit -m "Merge task ${task_id}" --no-edit >/dev/null 2>&1 || true
        return 0
    fi

    local file_list
    file_list=$(echo "$conflicted" | tr '\n' ', ' | sed 's/,$//')
    log_info "Conflicted files: ${file_list}"

    # Build rich context: what was the task, what does the spec say
    local task_desc
    task_desc=$(get_task_description "${TASK_FILE:-}" "$task_id" 2>/dev/null || echo "unknown")

    local spec_dir
    spec_dir=$(dirname "${TASK_FILE:-tasks.md}")

    # Get the diff summary for each conflicted file so the resolver understands both sides
    local diff_context=""
    for cfile in $conflicted; do
        local ours_summary theirs_summary
        ours_summary=$(git diff HEAD -- "$cfile" 2>/dev/null | head -40 || true)
        theirs_summary=$(git diff "$branch_name" -- "$cfile" 2>/dev/null | head -40 || true)
        diff_context="${diff_context}
--- ${cfile} ---
OURS (main) changes summary:
${ours_summary}
THEIRS (${branch_name}) changes summary:
${theirs_summary}
"
    done

    local prompt="MERGE CONFLICT RESOLUTION NEEDED

CONTEXT:
- Task ${task_id}: ${task_desc}
- Branch being merged: ${branch_name}
- Spec directory: ${spec_dir}

CONFLICTED FILES: ${file_list}

STEP 1: Read these files for context:
- ${spec_dir}/design.md (architecture and interfaces)
- ${spec_dir}/requirements.md (acceptance criteria)
- ${spec_dir}/tasks.md (full task list and what's done)

STEP 2: Read each conflicted file to see the conflict markers.

STEP 3: For each file, understand what BOTH sides intended:
${diff_context}

STEP 4: Write resolved versions that keep ALL work from both sides.

STEP 5: Run 'git add' on each resolved file, then:
git commit -m 'Resolved merge for task ${task_id}: ${task_desc}' --no-edit

Output 'CONFLICTS_RESOLVED' when done."

    local response
    response=$(kiro-cli chat --no-interactive --agent "$RESOLVER_AGENT" --trust-all-tools \
        "$prompt" 2>&1) || true

    if [[ "$response" == *"CONFLICTS_RESOLVED"* ]]; then
        log_success "Resolver agent resolved conflicts for task ${task_id}"
        return 0
    fi

    # Fallback if agent didn't confirm
    log_warn "Resolver agent didn't confirm, falling back to auto-resolve"
    auto_resolve_conflicts "$task_id"
}

# ─── Fallback auto-resolve (last resort) ─────────────────────

auto_resolve_conflicts() {
    local task_id="$1"

    local conflicted
    conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

    local auto_resolved_count=0
    for file in $conflicted; do
        case "$file" in
            *tasks.md)
                # Smart merge: union of [x] marks from both sides
                merge_tasks_md_smart "$file"
                ;;
            dist/*)
                # Compiled output: just take theirs, we'll rebuild
                git checkout --theirs -- "$file" 2>/dev/null || true
                ;;
            *)
                # Source files: try content-level merge first, fall back to theirs
                local _base _ours _theirs
                _base=$(mktemp) _ours=$(mktemp) _theirs=$(mktemp)
                if git show ":1:${file}" > "$_base" 2>/dev/null \
                    && git show ":2:${file}" > "$_ours" 2>/dev/null \
                    && git show ":3:${file}" > "$_theirs" 2>/dev/null \
                    && git merge-file -p "$_ours" "$_base" "$_theirs" > "${file}" 2>/dev/null; then
                    : # content-level merge succeeded
                else
                    auto_resolved_count=$((auto_resolved_count + 1))
                    git checkout --theirs -- "$file" 2>/dev/null || true
                fi
                rm -f "$_base" "$_ours" "$_theirs"
                ;;
        esac
        git add "$file" >/dev/null 2>&1 || true
    done

    git commit -m "Merge task ${task_id} (auto-resolved)" --no-edit >/dev/null 2>&1 || true
    
    # Log summary instead of per-file warnings
    if [ "$auto_resolved_count" -gt 0 ]; then
        log_warn "Auto-resolved ${auto_resolved_count} conflicts (took branch version)"
    fi
}

# Smart tasks.md merge: union of completed checkmarks from both sides
merge_tasks_md_smart() {
    local task_file="$1"

    python3 -c "
import re, sys

def merge_blocks(ours, theirs):
    '''Use theirs as base, but mark [x] anything that is [x] in ours.'''
    ours_done = set()
    for line in ours:
        m = re.search(r'\[x\]\s+(\d+(?:\.\d+)*)', line)
        if m:
            ours_done.add(m.group(1))
    merged = []
    for line in theirs:
        m = re.search(r'\[ \]\s+(\d+(?:\.\d+)*)', line)
        if m and m.group(1) in ours_done:
            line = line.replace('[ ]', '[x]', 1)
        merged.append(line)
    return merged

with open('${task_file}', 'r') as f:
    content = f.read()

if '<<<<<<<' not in content:
    sys.exit(0)

lines = content.split('\n')
result = []
in_ours = False
in_theirs = False
ours_block = []
theirs_block = []

for line in lines:
    if line.startswith('<<<<<<<'):
        in_ours = True
        ours_block = []
        continue
    elif line.startswith('=======') and in_ours:
        in_ours = False
        in_theirs = True
        theirs_block = []
        continue
    elif line.startswith('>>>>>>>') and in_theirs:
        in_theirs = False
        merged = merge_blocks(ours_block, theirs_block)
        result.extend(merged)
        continue

    if in_ours:
        ours_block.append(line)
    elif in_theirs:
        theirs_block.append(line)
    else:
        result.append(line)

with open('${task_file}', 'w') as f:
    f.write('\n'.join(result))
" 2>/dev/null || {
        git checkout --theirs -- "$task_file" 2>/dev/null || true
    }
}

# ─── Update parent tasks after merge ─────────────────────────

update_parent_tasks() {
    local task_file="$1"

    python3 -c "
import re

with open('${task_file}', 'r') as f:
    content = f.read()

lines = content.split('\n')
result = []
i = 0
while i < len(lines):
    line = lines[i]
    parent_match = re.match(r'^- \[(.)\] (\d+)\. (.+)', line)
    if parent_match:
        status, parent_id, desc = parent_match.groups()
        children = []
        j = i + 1
        while j < len(lines):
            # Match child tasks — indented or flat format
            child_match = re.match(r'^[\s]*- \[(.)\] ' + re.escape(parent_id) + r'\.\d+', lines[j])
            if child_match:
                children.append(child_match.group(1))
                j += 1
            else:
                break
        if children and all(c == 'x' for c in children):
            line = f'- [x] {parent_id}. {desc}'
    result.append(line)
    i += 1

with open('${task_file}', 'w') as f:
    f.write('\n'.join(result))
" 2>/dev/null || log_warn "Could not auto-update parent tasks"
}

# ─── Batch sync ──────────────────────────────────────────────

sync_wave_results() {
    local worktree_base="$1"
    shift
    local completed_tasks=("$@")
    for task_id in "${completed_tasks[@]}"; do
        sync_task_to_main "$task_id" "$worktree_base"
    done
}
