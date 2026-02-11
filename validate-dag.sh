#!/bin/bash
# validate-dag.sh - Validate DAG completeness against tasks.md
#
# Usage: ./validate-dag.sh <spec_name_or_path> [dag.json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/utils.sh"

SPEC_NAME="${1:-}"
DAG_FILE="${2:-}"

if [ -z "$SPEC_NAME" ]; then
    echo "Usage: $0 <spec_name_or_path> [dag.json]" >&2
    exit 1
fi

# Resolve spec directory
if [ -d "$SPEC_NAME" ]; then
    SPEC_DIR="$SPEC_NAME"
elif [ -d ".kiro/specs/$SPEC_NAME" ]; then
    SPEC_DIR=".kiro/specs/$SPEC_NAME"
else
    echo "Error: spec not found: $SPEC_NAME" >&2
    exit 1
fi

TASK_FILE="${SPEC_DIR}/tasks.md"

if [ ! -f "$TASK_FILE" ]; then
    echo "Error: tasks.md not found in $SPEC_DIR" >&2
    exit 1
fi

# If no DAG file specified, find the latest one
if [ -z "$DAG_FILE" ]; then
    if [ -d ".ralph-logs" ]; then
        DAG_FILE=$(ls -t .ralph-logs/dag_*.json 2>/dev/null | head -1)
    fi
    if [ -z "$DAG_FILE" ] || [ ! -f "$DAG_FILE" ]; then
        echo "Error: no DAG file found. Run btb.sh first or specify a DAG file." >&2
        exit 1
    fi
    echo "Using DAG file: $DAG_FILE"
fi

# Get all incomplete tasks
echo "Analyzing tasks.md..."
INCOMPLETE_TASKS=$(get_all_leaf_tasks "$TASK_FILE" | while read tid; do
    is_task_complete "$TASK_FILE" "$tid" || echo "$tid"
done | sort)

INCOMPLETE_COUNT=$(echo "$INCOMPLETE_TASKS" | grep -c . || echo 0)

# Get all tasks from DAG
echo "Analyzing DAG..."
DAG_TASKS=$(python3 -c "
import sys, json
with open('$DAG_FILE') as f:
    data = json.load(f)
for wave in data.get('waves', []):
    for task in wave.get('tasks', []):
        print(task['id'])
" 2>/dev/null | sort)

DAG_COUNT=$(echo "$DAG_TASKS" | grep -c . || echo 0)

echo ""
echo "=== Validation Results ==="
echo "Incomplete tasks in tasks.md: $INCOMPLETE_COUNT"
echo "Tasks in DAG:                 $DAG_COUNT"
echo ""

if [ "$DAG_COUNT" -eq "$INCOMPLETE_COUNT" ]; then
    echo "✓ DAG is complete - all incomplete tasks are included"
    exit 0
fi

# Find missing tasks
echo "✗ DAG is incomplete - $(($INCOMPLETE_COUNT - $DAG_COUNT)) tasks missing"
echo ""
echo "Missing tasks:"
comm -23 <(echo "$INCOMPLETE_TASKS") <(echo "$DAG_TASKS") | while read tid; do
    desc=$(get_task_description "$TASK_FILE" "$tid" 2>/dev/null || echo "")
    echo "  $tid - $desc"
done

echo ""
echo "Extra tasks in DAG (not in tasks.md):"
comm -13 <(echo "$INCOMPLETE_TASKS") <(echo "$DAG_TASKS") | while read tid; do
    echo "  $tid"
done

exit 1
