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

    local models_list="${AVAILABLE_MODELS:-claude-sonnet-4.5,claude-opus-4.6}"

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

CRITICAL: You MUST include EVERY SINGLE incomplete task (marked with [ ]) in your output. Do not skip or omit any tasks.

First, list all incomplete tasks you found to verify completeness.
Then analyze their dependencies.

Rules for dependency analysis:
1. Setup/infrastructure tasks (creating directories, config files) have NO dependencies
2. Type definition tasks depend on project setup
3. Implementation tasks depend on type definitions and the files they import
4. Test tasks depend on the implementation they test
5. Documentation tasks depend on the code they document
6. Tasks that write to the SAME file CANNOT be parallel (file conflict)
7. Tasks within the same parent group that are numbered sequentially MAY have implicit ordering
8. Parent tasks (like \"2. Phase 1: Model Profiler\") are NOT executable - only include leaf tasks (2.1, 2.2, etc.)
9. Checkpoint tasks (like \"3. Checkpoint - Profiler Complete\") ARE executable and should be included

Rules for model assignment — you MUST assign a \"model\" field to each task.
Pick ONLY from this EXACT list (do NOT invent or modify model names): ${models_list}
Guidelines:
- claude-sonnet-4.5: Simple tasks — standard implementation, writing functions, tests, config, boilerplate, straightforward code
- claude-opus-4.6: Hard tasks — research, hard algorithms, architectural decisions, tricky debugging, security-critical code, complex multi-file refactoring
default to claude-opus-4.6 when unsure.
WARNING: 'claude-opus-4.5' does NOT exist. Only use the exact model names listed above.

Output ONLY a JSON object (no markdown, no explanation) with this structure:
{
  \"waves\": [
    {
      \"id\": 0,
      \"tasks\": [
        {
          \"id\": \"1.1\",
          \"description\": \"task description\",
          \"parent\": \"1\",
          \"dependencies\": [],
          \"model\": \"claude-sonnet-4.5\"
        }
      ]
    }
  ]
}

VERIFICATION: Before outputting, count the incomplete tasks in the input and verify your JSON includes the same number of tasks." 2>/dev/null) || true

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

You previously analyzed this task file and produced a DAG, but you MISSED the following ${missing_count} tasks:
${missing_detail}

You MUST now produce a DAG fragment containing ONLY these missing tasks.
For each missing task, determine which wave it belongs to and what its dependencies are.
Use the same wave numbering scheme — if a missing task depends on a task already in wave 2, place it in wave 3 or later.

The existing DAG already covers these task IDs (do NOT include them again):
${existing_ids_str}

Rules for model assignment — assign a \"model\" field to each task.
Pick ONLY from: ${models_list}
Guidelines:
- claude-sonnet-4.5: Simple tasks
- claude-opus-4.6: Hard tasks
Default to claude-opus-4.6 when unsure.

Output ONLY a JSON object (no markdown) with the same structure:
{
  \"waves\": [
    {
      \"id\": <wave_number>,
      \"tasks\": [
        {
          \"id\": \"<task_id>\",
          \"description\": \"<description>\",
          \"parent\": \"<parent_id>\",
          \"dependencies\": [\"<dep_id>\", ...],
          \"model\": \"<model>\"
        }
      ]
    }
  ]
}

Include ALL ${missing_count} missing tasks. Do NOT include any tasks that are already in the existing DAG." 2>/dev/null) || true

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

# Append missing tasks as sequential waves at the tail of the DAG.
# This is the last-resort fallback so no task is ever lost.
_append_missing_as_sequential() {
    local dag_json="$1"
    local task_file="$2"
    local missing_ids="$3"
    local default_model="${DEFAULT_TASK_MODEL:-claude-sonnet-4.5}"

    local dag_file
    dag_file=$(mktemp)
    echo "$dag_json" > "$dag_file"

    local result
    result=$(python3 -c "
import sys, json, re

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

max_wid = max((w['id'] for w in dag.get('waves', [])), default=-1)

for tid in missing:
    max_wid += 1
    parent = tid.split('.')[0]
    desc = desc_map.get(tid, '')
    dag['waves'].append({
        'id': max_wid,
        'tasks': [{
            'id': tid,
            'description': desc,
            'parent': parent,
            'dependencies': [],
            'model': default_model
        }]
    })

print(json.dumps(dag))
" 2>/dev/null)

    rm -f "$dag_file"
    echo "$result"
}

# ─── JSON Extraction ─────────────────────────────────────────

# Extract JSON object from a string that might contain surrounding text
extract_json() {
    local input="$1"
    echo "$input" | python3 -c "
import sys, json

text = sys.stdin.read()

# Find the outermost { ... } pair
depth = 0
start = -1
for i, ch in enumerate(text):
    if ch == '{':
        if depth == 0:
            start = i
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0 and start >= 0:
            candidate = text[start:i+1]
            try:
                parsed = json.loads(candidate)
                print(json.dumps(parsed))
                sys.exit(0)
            except json.JSONDecodeError:
                start = -1
                continue

sys.exit(1)
"
}

# ─── Fallback DAG Builder ───────────────────────────────────
# If the planner agent fails, build a conservative sequential DAG

build_fallback_dag() {
    local task_file="$1"
    log_warn "Using fallback sequential DAG (no parallelism)" >&2

    local tasks
    tasks=$(get_all_leaf_tasks "$task_file")

    local wave_id=0
    local json='{"waves":['
    local first_wave=true

    for task_id in $tasks; do
        if is_task_complete "$task_file" "$task_id"; then
            continue
        fi

        local desc
        desc=$(get_task_description "$task_file" "$task_id")
        local parent
        parent=$(echo "$task_id" | cut -d. -f1)

        if [ "$first_wave" = true ]; then
            first_wave=false
        else
            json="${json},"
        fi

        json="${json}{\"id\":${wave_id},\"tasks\":[{\"id\":\"${task_id}\",\"description\":\"${desc}\",\"parent\":\"${parent}\",\"dependencies\":[],\"model\":\"${DEFAULT_TASK_MODEL:-claude-sonnet-4.5}\"}]}"
        ((wave_id++))
    done

    json="${json}]}"
    echo "$json"
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
    local default="${DEFAULT_TASK_MODEL:-claude-sonnet-4.5}"
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
    
    local allowed="${AVAILABLE_MODELS:-claude-sonnet-4.5,claude-opus-4.6}"
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
