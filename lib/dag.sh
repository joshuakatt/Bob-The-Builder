#!/bin/bash
# lib/dag.sh - DAG (Directed Acyclic Graph) dependency analysis
# Uses the planner agent to analyze tasks and build execution waves.
# Includes a repair loop: if the planner misses tasks, it is re-prompted
# to patch the DAG until all incomplete tasks are covered.

set -euo pipefail

# utils.sh is already sourced by the caller (btb.sh)
# Guard against double-sourcing
if ! declare -F log_info &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
fi

# ─── DAG Analysis ────────────────────────────────────────────

# Ask the planner agent to analyze task dependencies and produce a DAG.
# Returns JSON with waves of parallelizable tasks.
# On failure returns non-zero so the caller can fall back to sequential.
analyze_dependencies() {
    local task_file="$1"
    local design_file="${2:-}"
    local requirements_file="${3:-}"
    local max_repair_attempts="${MAX_DAG_REPAIR_ATTEMPTS:-3}"
    local context_files=""

    # Build context string for planner
    if [ -n "$design_file" ] && [ -f "$design_file" ]; then
        context_files="Also read ${design_file} for implementation context. "
    fi
    if [ -n "$requirements_file" ] && [ -f "$requirements_file" ]; then
        context_files="${context_files}Also read ${requirements_file} for requirements context. "
    fi

    local models_list="${AVAILABLE_MODELS:-claude-sonnet-4.6,claude-opus-4.6}"

    # Build model assignment instructions based on available models
    local model_hints=""
    if echo ",$models_list," | awk 'index($0, ",claude-haiku-4.5,") { found=1 } END { exit !found }' 2>/dev/null; then
        model_hints="- claude-haiku-4.5: trivial/boilerplate tasks (config, renaming, simple wiring)
- claude-sonnet-4.6: standard implementation tasks
- claude-opus-4.6: complex/architectural tasks"
    else
        model_hints="- claude-sonnet-4.6: simple/standard tasks
- claude-opus-4.6: complex/architectural tasks"
    fi

    local steering_hint=""
    if [ -d ".kiro/steering" ] && [ -n "$(ls -A .kiro/steering 2>/dev/null)" ]; then
        steering_hint="You have project context in .kiro/steering/ — read those files first for architecture and conventions context before analyzing dependencies."
    fi

    # ── Step 1: Initial analysis ─────────────────────────────
    # (spinner in btb.sh already shows "analyzing..." — no log here)

    local raw_response
    raw_response=$(kiro-cli chat --no-interactive --agent planner --trust-all-tools \
        "${steering_hint}

Read ${task_file}. ${context_files}

Analyze ALL incomplete tasks (marked with [ ]) and output a dependency DAG as JSON.

Rules:
1. Include EVERY incomplete leaf task (subtasks like 1.1, 2.3 — NOT parent headers)
2. Tasks writing to the SAME file cannot be parallel
3. Sequential subtasks within a group (2.1→2.2→2.3) have implicit ordering
4. Setup tasks have no dependencies; tests depend on their implementation

Model assignment — pick ONLY from: ${models_list}
${model_hints}
WARNING: 'claude-opus-4.5' does NOT exist.

Output ONLY valid JSON, no markdown fences, no explanation:
{\"waves\":[{\"id\":0,\"tasks\":[{\"id\":\"1.1\",\"description\":\"...\",\"parent\":\"1\",\"dependencies\":[],\"model\":\"claude-sonnet-4.6\"}]}]}" 2>/dev/null) || true

    local json
    json=$(extract_json "$raw_response" 2>/dev/null) || true

    if [ -z "$json" ]; then
        log_error "Planner returned no valid JSON" >&2
        return 1
    fi

    if ! validate_dag_json "$json" >/dev/null 2>&1; then
        log_error "Invalid DAG JSON structure" >&2
        return 1
    fi

    # ── Step 2: Repair loop — patch missing tasks ────────────
    local attempt=0
    while [ "$attempt" -lt "$max_repair_attempts" ]; do
        local missing_ids
        missing_ids=$(_compute_missing_tasks "$task_file" "$json") || true

        # Trim whitespace
        missing_ids=$(echo "$missing_ids" | xargs)

        if [ -z "$missing_ids" ]; then
            # All tasks accounted for
            break
        fi

        local missing_count
        missing_count=$(echo "$missing_ids" | wc -w | tr -d ' ')
        attempt=$((attempt + 1))
        log_warn "DAG repair ${attempt}/${max_repair_attempts}: ${missing_count} tasks missing, asking planner to patch" >&2

        # Build a human-readable list of missing tasks with descriptions
        local missing_detail=""
        for mid in $missing_ids; do
            local mdesc
            mdesc=$(get_task_description "$task_file" "$mid" 2>/dev/null || echo "(no description)")
            missing_detail="${missing_detail}
- ${mid}: ${mdesc}"
        done

        # Build the list of existing task IDs for the prompt
        local existing_ids_str
        existing_ids_str=$(echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ids = []
for wave in data.get('waves', []):
    for task in wave.get('tasks', []):
        ids.append(task['id'])
print(', '.join(sorted(ids, key=lambda x: [int(p) if p.isdigit() else p for p in x.split('.')])))
" 2>/dev/null) || true

        # Ask the planner to produce a DAG fragment for ONLY the missing tasks
        local patch_response
        patch_response=$(kiro-cli chat --no-interactive --agent planner --trust-all-tools \
            "Read ${task_file}. ${context_files}

Your previous DAG missed ${missing_count} tasks. Produce a DAG fragment for ONLY these:
${missing_detail}

Already in DAG (do NOT include): ${existing_ids_str}

Output ONLY valid JSON, no markdown fences:
{\"waves\":[{\"id\":<wave>,\"tasks\":[{\"id\":\"<id>\",\"description\":\"...\",\"parent\":\"<parent>\",\"dependencies\":[],\"model\":\"claude-sonnet-4.6\"}]}]}

${model_hints}
Models: pick from ${models_list} only. 'claude-opus-4.5' does NOT exist." 2>/dev/null) || true

        local patch_json
        patch_json=$(extract_json "$patch_response" 2>/dev/null) || true

        if [ -z "$patch_json" ]; then
            log_warn "DAG repair ${attempt}: planner returned no valid JSON for patch" >&2
            continue
        fi

        if ! validate_dag_json "$patch_json" >/dev/null 2>&1; then
            log_warn "DAG repair ${attempt}: invalid patch JSON structure" >&2
            continue
        fi

        # Merge the patch into the existing DAG — guard against empty result
        local merged
        merged=$(_merge_dag_json "$json" "$patch_json") || true

        if [ -z "$merged" ]; then
            log_warn "DAG repair ${attempt}: merge failed, keeping previous DAG" >&2
            continue
        fi

        json="$merged"

        local new_count
        new_count=$(echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(sum(len(w.get('tasks',[])) for w in data.get('waves',[])))
" 2>/dev/null) || new_count="?"
        log_info "DAG repair ${attempt}: DAG now has ${new_count} tasks" >&2
    done

    # Final check — append any remaining missing tasks as sequential fallback
    local final_missing
    final_missing=$(_compute_missing_tasks "$task_file" "$json") || true
    final_missing=$(echo "$final_missing" | xargs)

    if [ -n "$final_missing" ]; then
        local final_missing_count
        final_missing_count=$(echo "$final_missing" | wc -w | tr -d ' ')
        log_warn "DAG still missing ${final_missing_count} tasks after ${max_repair_attempts} repair attempts" >&2
        log_warn "Appending as sequential fallback tail" >&2

        local appended
        appended=$(_append_missing_as_sequential "$json" "$task_file" "$final_missing") || true

        if [ -n "$appended" ]; then
            json="$appended"
        else
            log_warn "Sequential append failed, DAG will be incomplete" >&2
        fi
    fi

    # Final safety: never return empty
    if [ -z "$json" ]; then
        log_error "DAG is empty after all processing" >&2
        return 1
    fi

    echo "$json"
}

# ─── DAG Completeness Helpers ────────────────────────────────

# Compute the list of incomplete task IDs that are NOT in the DAG.
# Prints space-separated task IDs (empty string if none missing).
_compute_missing_tasks() {
    local task_file="$1"
    local dag_json="$2"

    # Get all incomplete leaf task IDs from the task file (one per line, sorted)
    local incomplete_file
    incomplete_file=$(mktemp)
    get_all_leaf_tasks "$task_file" | while read -r tid; do
        is_task_complete "$task_file" "$tid" || echo "$tid"
    done | sort > "$incomplete_file"

    # Get all task IDs present in the DAG (one per line, sorted)
    local dag_file
    dag_file=$(mktemp)
    echo "$dag_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for wave in data.get('waves', []):
        for task in wave.get('tasks', []):
            print(task['id'])
except:
    pass
" 2>/dev/null | sort > "$dag_file"

    # comm -23 gives lines only in the first file (incomplete but not in DAG)
    local missing
    missing=$(comm -23 "$incomplete_file" "$dag_file" | tr '\n' ' ')
    rm -f "$incomplete_file" "$dag_file"
    echo "$missing"
}

# Merge a patch DAG into an existing DAG.
# Tasks from the patch are inserted into existing waves (by wave id) or
# new waves are appended. Duplicate task IDs are skipped.
_merge_dag_json() {
    local base="$1"
    local patch="$2"

    # Write to temp files to avoid any quoting/escaping issues
    local base_file patch_file
    base_file=$(mktemp)
    patch_file=$(mktemp)
    echo "$base" > "$base_file"
    echo "$patch" > "$patch_file"

    local result
    result=$(python3 -c "
import sys, json

with open('${base_file}') as f:
    base = json.load(f)
with open('${patch_file}') as f:
    patch = json.load(f)

# Index existing task IDs for dedup
existing_ids = set()
wave_map = {}
max_wave_id = -1
for wave in base.get('waves', []):
    wid = wave['id']
    wave_map[wid] = wave
    if wid > max_wave_id:
        max_wave_id = wid
    for task in wave.get('tasks', []):
        existing_ids.add(task['id'])

# Merge patch waves
for pwave in patch.get('waves', []):
    pwid = pwave['id']
    new_tasks = [t for t in pwave.get('tasks', []) if t['id'] not in existing_ids]
    if not new_tasks:
        continue
    for t in new_tasks:
        existing_ids.add(t['id'])
    if pwid in wave_map:
        wave_map[pwid]['tasks'].extend(new_tasks)
    else:
        new_wid = pwid if pwid > max_wave_id else max_wave_id + 1
        max_wave_id = max(max_wave_id, new_wid)
        wave_map[new_wid] = {'id': new_wid, 'tasks': new_tasks}

# Rebuild sorted wave list with contiguous IDs
base['waves'] = [wave_map[k] for k in sorted(wave_map.keys())]
for i, wave in enumerate(base['waves']):
    wave['id'] = i

print(json.dumps(base))
" 2>/dev/null)

    rm -f "$base_file" "$patch_file"
    echo "$result"
}

# Append missing tasks into the DAG with inferred dependencies.
# Instead of making everything sequential, groups tasks by parent and
# infers ordering: subtasks within the same parent are sequential
# (2.1 → 2.2 → 2.3), but different parent groups run in parallel waves.
# Also respects existing DAG tasks as dependencies where appropriate.
_append_missing_as_sequential() {
    local dag_json="$1"
    local task_file="$2"
    local missing_ids="$3"
    local default_model="${DEFAULT_TASK_MODEL:-claude-sonnet-4.6}"

    local dag_file
    dag_file=$(mktemp)
    echo "$dag_json" > "$dag_file"

    local result
    result=$(python3 -c "
import sys, json, re
from collections import defaultdict

with open('${dag_file}') as f:
    dag = json.load(f)

missing = '${missing_ids}'.split()
default_model = '${default_model}'

# Read task descriptions from file
desc_map = {}
with open('${task_file}') as f:
    for line in f:
        m = re.search(r'\[.\]\s+(\d+\.\S+)\s+(.*)', line)
        if m:
            desc_map[m.group(1)] = m.group(2).strip()

# Collect existing task IDs and the max wave ID
existing_ids = set()
max_wid = -1
for wave in dag.get('waves', []):
    max_wid = max(max_wid, wave['id'])
    for task in wave.get('tasks', []):
        existing_ids.add(task['id'])

# Group missing tasks by parent
groups = defaultdict(list)
for tid in missing:
    parent = tid.split('.')[0]
    groups[parent].append(tid)

# Sort subtasks within each group numerically
def sort_key(tid):
    parts = tid.split('.')
    return [int(p) if p.isdigit() else p for p in parts]

for parent in groups:
    groups[parent].sort(key=sort_key)

# Find the last existing task ID for each parent group (if any)
# so we can chain the first missing subtask after it
last_existing_per_parent = {}
for wave in dag.get('waves', []):
    for task in wave.get('tasks', []):
        p = task['id'].split('.')[0]
        last_existing_per_parent[p] = task['id']

# Build waves: tasks at the same position within their parent group
# can run in parallel. E.g., 2.1 and 3.1 can be parallel, then
# 2.2 and 3.2 can be parallel, etc.
# First, determine the max depth across all groups
max_depth = max(len(tasks) for tasks in groups.values())

for depth_idx in range(max_depth):
    wave_tasks = []
    for parent in sorted(groups.keys(), key=lambda x: int(x) if x.isdigit() else x):
        subtasks = groups[parent]
        if depth_idx >= len(subtasks):
            continue
        tid = subtasks[depth_idx]
        # Determine dependency
        deps = []
        if depth_idx == 0:
            # First missing subtask in this group — depends on last existing task in same parent
            if parent in last_existing_per_parent:
                deps = [last_existing_per_parent[parent]]
        else:
            # Depends on previous subtask in same group
            deps = [subtasks[depth_idx - 1]]

        wave_tasks.append({
            'id': tid,
            'description': desc_map.get(tid, ''),
            'parent': parent,
            'dependencies': deps,
            'model': default_model
        })

    if wave_tasks:
        max_wid += 1
        dag['waves'].append({
            'id': max_wid,
            'tasks': wave_tasks
        })

print(json.dumps(dag))
" 2>/dev/null)

    rm -f "$dag_file"
    echo "$result"
}

# ─── JSON Extraction ─────────────────────────────────────────

# Extract JSON object from a string that might contain surrounding text.
# Handles: raw JSON, markdown-fenced JSON (```json ... ```), JSON with
# surrounding explanation text, and multiple JSON candidates (picks the
# one with a "waves" key if present).
extract_json() {
    local input="$1"
    echo "$input" | python3 -c "
import sys, json, re

text = sys.stdin.read()

# Strategy 1: Strip markdown fences first — LLMs love wrapping in \`\`\`json
cleaned = re.sub(r'\`\`\`(?:json)?\s*\n?', '', text)

# Strategy 2: Try to find all { ... } candidates and pick the best one
candidates = []
depth = 0
start = -1
for i, ch in enumerate(cleaned):
    if ch == '{':
        if depth == 0:
            start = i
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0 and start >= 0:
            candidate = cleaned[start:i+1]
            try:
                parsed = json.loads(candidate)
                candidates.append(parsed)
            except json.JSONDecodeError:
                pass
            start = -1

if not candidates:
    sys.exit(1)

# Prefer the candidate that has a 'waves' key (our DAG schema)
for c in candidates:
    if 'waves' in c:
        print(json.dumps(c))
        sys.exit(0)

# Fall back to the largest candidate (most likely the full response)
best = max(candidates, key=lambda c: len(json.dumps(c)))
print(json.dumps(best))
"
}

# ─── Fallback DAG Builder ───────────────────────────────────
# If the planner agent fails entirely, build a DAG with inferred
# dependencies from task numbering. Subtasks within the same parent
# are sequential; different parent groups run in parallel.

build_fallback_dag() {
    local task_file="$1"
    local default_model="${DEFAULT_TASK_MODEL:-claude-sonnet-4.6}"
    log_warn "Using fallback DAG (inferred dependencies from task numbering)" >&2

    python3 - "$task_file" "$default_model" <<'PYEOF'
import sys, json, re, subprocess
from collections import defaultdict

task_file = sys.argv[1]
default_model = sys.argv[2]

# Get all leaf task IDs using the same logic as get_all_leaf_tasks
with open(task_file) as f:
    lines = f.readlines()

subtask_ids = []
parents_with_children = set()
desc_map = {}
for line in lines:
    m = re.match(r'^[\s]*-\s+\[.\]\s+(\d+)\.(\d+\S*)\s+(.*)', line)
    if m:
        parent_id = m.group(1)
        sub_part = m.group(2)
        if sub_part and sub_part[0].isdigit():
            full_id = parent_id + '.' + sub_part
            subtask_ids.append(full_id)
            parents_with_children.add(parent_id)
            desc_map[full_id] = m.group(3).strip()

childless_ids = []
for line in lines:
    m = re.match(r'^-\s+\[.\]\s+(\d+)\.\s+(.*)', line)
    if m:
        tid = m.group(1)
        if tid not in parents_with_children:
            childless_ids.append(tid)
            desc_map[tid] = m.group(2).strip()

all_ids = subtask_ids + childless_ids

# Filter to incomplete tasks only
def is_complete(tid):
    pattern = re.compile(r'\[x\]\s+' + re.escape(tid) + r'(?:\.?\s)')
    for line in lines:
        if pattern.search(line):
            return True
    return False

incomplete = [tid for tid in all_ids if not is_complete(tid)]

if not incomplete:
    print(json.dumps({"waves": []}))
    sys.exit(0)

# Group by parent
groups = defaultdict(list)
for tid in incomplete:
    parent = tid.split('.')[0]
    groups[parent].append(tid)

def sort_key(tid):
    parts = tid.split('.')
    return [int(p) if p.isdigit() else p for p in parts]

for parent in groups:
    groups[parent].sort(key=sort_key)

# Build waves: tasks at the same depth within their parent group
# can run in parallel
max_depth = max(len(tasks) for tasks in groups.values())
waves = []
wave_id = 0

for depth_idx in range(max_depth):
    wave_tasks = []
    for parent in sorted(groups.keys(), key=lambda x: int(x) if x.isdigit() else x):
        subtasks = groups[parent]
        if depth_idx >= len(subtasks):
            continue
        tid = subtasks[depth_idx]
        deps = []
        if depth_idx > 0:
            deps = [subtasks[depth_idx - 1]]
        wave_tasks.append({
            'id': tid,
            'description': desc_map.get(tid, ''),
            'parent': parent,
            'dependencies': deps,
            'model': default_model
        })

    if wave_tasks:
        waves.append({'id': wave_id, 'tasks': wave_tasks})
        wave_id += 1

print(json.dumps({"waves": waves}))
PYEOF
}

# ─── DAG Queries ─────────────────────────────────────────────

# Get tasks for a specific wave
get_wave_tasks() {
    local dag_json="$1"
    local wave_id="$2"
    echo "$dag_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
wave_id = int(${wave_id})
for wave in data['waves']:
    if wave['id'] == wave_id:
        for task in wave['tasks']:
            print(task['id'])
        break
"
}

# Get total number of waves
get_wave_count() {
    local dag_json="$1"
    echo "$dag_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len(data['waves']))
"
}

# Get task info as JSON
get_task_info() {
    local dag_json="$1"
    local task_id="$2"
    echo "$dag_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
task_id = '${task_id}'
for wave in data['waves']:
    for task in wave['tasks']:
        if task['id'] == task_id:
            print(json.dumps(task))
            sys.exit(0)
print('{}')
"
}

# Get the assigned model for a task (falls back to DEFAULT_TASK_MODEL)
get_task_model() {
    local dag_json="$1"
    local task_id="$2"
    local default="${DEFAULT_TASK_MODEL:-claude-sonnet-4.6}"
    local model
    model=$(echo "$dag_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
task_id = '${task_id}'
for wave in data['waves']:
    for task in wave['tasks']:
        if task['id'] == task_id:
            print(task.get('model', '${default}'))
            sys.exit(0)
print('${default}')
" 2>/dev/null) || echo "$default"
    
    local allowed="${AVAILABLE_MODELS:-claude-sonnet-4.6,claude-opus-4.6}"
    if echo ",$allowed," | awk -v m="$model" 'index($0, "," m ",") { found=1 } END { exit !found }' 2>/dev/null; then
        echo "$model"
    else
        echo "$default"
    fi
}

# Get all task IDs from the DAG (space-separated)
get_all_dag_tasks() {
    local dag_json="$1"
    echo "$dag_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for wave in data['waves']:
    for task in wave['tasks']:
        print(task['id'])
"
}

# Get dependencies for a specific task (space-separated task IDs)
get_task_dependencies() {
    local dag_json="$1"
    local task_id="$2"
    echo "$dag_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
task_id = '${task_id}'
for wave in data['waves']:
    for task in wave['tasks']:
        if task['id'] == task_id:
            deps = task.get('dependencies', [])
            print(' '.join(deps))
            sys.exit(0)
print('')
" 2>/dev/null
}

# Get the wave index for a specific task
get_task_wave() {
    local dag_json="$1"
    local task_id="$2"
    echo "$dag_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
task_id = '${task_id}'
for wave in data['waves']:
    for task in wave['tasks']:
        if task['id'] == task_id:
            print(wave['id'])
            sys.exit(0)
print('0')
" 2>/dev/null
}

# Check for circular dependencies (safety check)
check_cycles() {
    local dag_json="$1"
    if [ -z "$dag_json" ]; then
        echo "OK"
        return 0
    fi
    echo "$dag_json" | python3 -c "
import sys, json

data = json.load(sys.stdin)
graph = {}
all_tasks = set()
for wave in data.get('waves', []):
    for task in wave.get('tasks', []):
        tid = task['id']
        all_tasks.add(tid)
        graph[tid] = [d for d in task.get('dependencies', []) if d != tid]

if not all_tasks:
    print('OK')
    sys.exit(0)

in_degree = {t: 0 for t in all_tasks}
for tid, deps in graph.items():
    for dep in deps:
        if dep in in_degree:
            in_degree[tid] += 1

queue = [t for t, d in in_degree.items() if d == 0]
visited = 0
while queue:
    node = queue.pop(0)
    visited += 1
    for tid, deps in graph.items():
        if node in deps:
            in_degree[tid] -= 1
            if in_degree[tid] == 0:
                queue.append(tid)

if visited == len(all_tasks):
    print('OK')
else:
    print('CYCLE_DETECTED')
    sys.exit(1)
" 2>/dev/null || echo "OK"
}
