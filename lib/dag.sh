#!/bin/bash
# lib/dag.sh - DAG (Directed Acyclic Graph) dependency analysis
# Uses the planner agent to analyze tasks and build execution waves.

set -euo pipefail

# utils.sh is already sourced by the caller (btb.sh)
# Guard against double-sourcing
if ! declare -F log_info &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
fi

# ─── DAG Analysis ────────────────────────────────────────────

# Ask the planner agent to analyze task dependencies and produce a DAG
# Returns JSON with waves of parallelizable tasks
analyze_dependencies() {
    local task_file="$1"
    local design_file="${2:-}"
    local requirements_file="${3:-}"
    local context_files=""

    # Build context string for planner
    if [ -n "$design_file" ] && [ -f "$design_file" ]; then
        context_files="Also read ${design_file} for implementation context. "
    fi
    if [ -n "$requirements_file" ] && [ -f "$requirements_file" ]; then
        context_files="${context_files}Also read ${requirements_file} for requirements context. "
    fi

    # Build the available models list for the planner prompt
    local models_list="${AVAILABLE_MODELS:-claude-haiku-4.5,claude-sonnet-4,claude-sonnet-4.5,claude-opus-4.5}"

    # Build steering context hint
    local steering_hint=""
    if [ -d ".kiro/steering" ] && [ -n "$(ls -A .kiro/steering 2>/dev/null)" ]; then
        steering_hint="You have project context in .kiro/steering/ — read those files first for architecture and conventions context before analyzing dependencies."
    fi

    local raw_response
    raw_response=$(kiro-cli chat --no-interactive --agent planner --trust-all-tools \
        "${steering_hint}

Read ${task_file}. ${context_files}

Analyze ONLY the incomplete tasks (marked with [ ]) and their dependencies.

Rules for dependency analysis:
1. Setup/infrastructure tasks (creating directories, config files) have NO dependencies
2. Type definition tasks depend on project setup
3. Implementation tasks depend on type definitions and the files they import
4. Test tasks depend on the implementation they test
5. Documentation tasks depend on the code they document
6. Tasks that write to the SAME file CANNOT be parallel (file conflict)
7. Tasks within the same parent group that are numbered sequentially MAY have implicit ordering

Rules for model assignment — you MUST assign a \"model\" field to each task.
Pick ONLY from this exact list: ${models_list}
Guidelines:
- claude-sonnet-4.5: Simple tasks — standard implementation, writing functions, tests, config, boilerplate, straightforward code
- claude-opus-4.6: Hard tasks — complex algorithms, architectural decisions, tricky debugging, security-critical code, complex multi-file refactoring
default to claude-opus-4.6 when unsure.

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
    },
    {
      \"id\": 1,
      \"tasks\": [
        {
          \"id\": \"2.1\",
          \"description\": \"task description\",
          \"parent\": \"2\",
          \"dependencies\": [\"1.1\"],
          \"model\": \"claude-sonnet-4.5\"
        }
      ]
    }
  ]
}" 2>/dev/null)

    # Extract JSON from response (planner might add some text despite instructions)
    local json
    json=$(extract_json "$raw_response")

    if [ -z "$json" ]; then
        log_error "Planner returned no valid JSON. Raw response:"
        echo "$raw_response" >&2
        return 1
    fi

    # Validate the JSON structure
    if ! validate_dag_json "$json" >/dev/null 2>&1; then
        log_error "Invalid DAG JSON structure"
        echo "$raw_response" >&2
        return 1
    fi

    echo "$json"
}

# Extract JSON object from a string that might contain surrounding text
extract_json() {
    local input="$1"
    # Try to find JSON between first { and last }
    echo "$input" | python3 -c "
import sys, json, re

text = sys.stdin.read()

# Try to find JSON object in the text
# Look for the outermost { ... } pair
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
" 2>/dev/null
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
    
    # Validate the model is in the allowed list
    # Valid kiro-cli models: auto, claude-haiku-4.5, claude-sonnet-4, claude-sonnet-4.5, claude-opus-4.5, claude-opus-4.6
    local allowed="${AVAILABLE_MODELS:-claude-sonnet-4.5,claude-opus-4.6}"
    if echo ",$allowed," | awk -v m="$model" 'index($0, "," m ",") { found=1 } END { exit !found }' 2>/dev/null; then
        echo "$model"
    else
        # Model not in allowed list, fall back to default
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
# Returns empty string if no dependencies
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

