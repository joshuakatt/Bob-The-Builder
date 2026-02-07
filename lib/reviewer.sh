#!/bin/bash
# lib/reviewer.sh - Post-wave quality gate for concurrent task execution
#
# After each wave's tasks are synced to main, the reviewer agent audits
# the work against the spec. If it rejects, the player agent gets a
# focused fix attempt. This repeats up to MAX_REVIEW_RETRIES times.
#
# Flow:
#   1. Reviewer reads the spec + changed files and audits
#   2. If AUDIT_PASSED → wave is approved, proceed
#   3. If REJECTED → player gets the rejection reason and fixes
#   4. Repeat until passed or retries exhausted
#   5. If retries exhausted → wave proceeds with warning (non-blocking)

set -euo pipefail

# Guard: utils.sh already sourced by caller
if ! declare -F log_info &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
fi

# ─── Configuration (sourced from config.sh via caller) ───────
# ENABLE_REVIEW        - master switch (default: true)
# MAX_REVIEW_RETRIES   - fix attempts before giving up (default: 2)
# REVIEWER_AGENT       - agent name (default: reviewer)
# REVIEW_FIX_AGENT     - agent for fixes (default: player)
# REVIEWER_MODEL       - model override for reviewer (default: "")

# ─── Wave Review Gate ────────────────────────────────────────
# Main entry point. Called after a wave's tasks are synced to main.
#
# Arguments:
#   $1 - wave index (0-based)
#   $2 - space-separated list of task IDs completed in this wave
#
# Returns:
#   0 - review passed (or review disabled)
#   1 - review failed after all retries (caller decides whether to abort)

review_wave() {
    local wave_label="$1"
    local task_ids="$2"
    local base_sha="${3:-}"
    local spec_dir="${SPEC_DIR:-.kiro/specs/unknown}"
    local task_file="${TASK_FILE:-${spec_dir}/tasks.md}"
    local log_dir="${LOG_DIR:-.ralph-logs}"
    local timestamp="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"

    # Skip if review is disabled
    if [ "${ENABLE_REVIEW:-true}" != "true" ]; then
        return 0
    fi

    local max_retries="${MAX_REVIEW_RETRIES:-2}"
    local reviewer="${REVIEWER_AGENT:-reviewer}"
    local fixer="${REVIEW_FIX_AGENT:-player}"
    local reviewer_model_flag=""
    if [ -n "${REVIEWER_MODEL:-}" ]; then
        reviewer_model_flag="--model ${REVIEWER_MODEL}"
    fi

    local review_log="${log_dir}/review_wave${wave_label}_${timestamp}.log"

    # Build the list of what was done in this wave
    local task_summary=""
    for tid in $task_ids; do
        local desc
        desc=$(get_task_description "$task_file" "$tid" 2>/dev/null || echo "unknown")
        task_summary="${task_summary}\n- Task ${tid}: ${desc}"
    done

    # Collect recently changed files across the entire review batch
    local diff_ref="${base_sha:-HEAD~1}"
    local changed_files
    changed_files=$(git diff --name-only "$diff_ref" HEAD 2>/dev/null || echo "")
    local changed_source
    changed_source=$(echo "$changed_files" | awk '/\.(ts|js|py|tsx|jsx|json|md)$/' | head -30)

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        tui_event "🔍 reviewing wave ${wave_label} (attempt ${attempt}/${max_retries})"

        # Build steering context hint
        local steering_hint=""
        if [ -d ".kiro/steering" ] && [ -n "$(ls -A .kiro/steering 2>/dev/null)" ]; then
            steering_hint="You have project context in .kiro/steering/ — read those files first for architecture, conventions, and spec summary."
        fi

        local review_prompt
        review_prompt="WAVE ${wave_label} QUALITY REVIEW

You are auditing work that was just completed. Review it against the spec.

${steering_hint}

SPEC FILES TO READ:
- ${spec_dir}/design.md (architecture and interfaces)
- ${spec_dir}/requirements.md (acceptance criteria)
- ${task_file} (task list — check which tasks should now be [x])

TASKS COMPLETED IN THIS WAVE:
$(echo -e "$task_summary")

FILES CHANGED:
${changed_source:-No source files changed}

REVIEW CHECKLIST:
1. Read each changed source file and verify it matches the spec
2. Check that implementations are complete (no TODOs, no placeholders, no stub functions)
3. Verify type safety — interfaces used correctly, no 'any' types unless justified
4. Check that imports/exports are correct and files reference each other properly
5. If test files were created, run them: npm test or npx jest
6. Verify tasks.md was updated — completed tasks should be marked [x]
7. Check for obvious bugs, missing error handling, or security issues

OUTPUT FORMAT:
- If everything passes: output exactly 'AUDIT_PASSED'
- If issues found: output 'REJECTED: ' followed by a numbered list of specific issues

Be thorough but pragmatic. Flag real problems, not style preferences."

        echo "$(date +%Y-%m-%dT%H:%M:%S) REVIEW_START wave=${wave_label} attempt=${attempt}" >> "$review_log"

        local review_response
        review_response=$(kiro-cli chat --no-interactive --agent "$reviewer" $reviewer_model_flag --trust-all-tools \
            "$review_prompt" 2>&1 | tee -a "$review_log") || true

        echo "$(date +%Y-%m-%dT%H:%M:%S) REVIEW_END" >> "$review_log"

        # Check result
        if echo "$review_response" | awk '/AUDIT_PASSED/ { found=1 } END { exit !found }' 2>/dev/null; then
            tui_event "✓ wave ${wave_label} review passed (attempt ${attempt})"
            echo "$(date +%Y-%m-%dT%H:%M:%S) REVIEW_PASSED wave=${wave_label} attempt=${attempt}" >> "$review_log"
            return 0
        fi

        # Extract rejection reason
        local rejection_reason
        rejection_reason=$(echo "$review_response" | awk '/REJECTED:/ { found=1 } found { print }' | head -30)
        if [ -z "$rejection_reason" ]; then
            rejection_reason="Reviewer did not output AUDIT_PASSED (ambiguous result)"
        fi

        tui_event "⚠ wave ${wave_label} review rejected (attempt ${attempt}/${max_retries})"
        echo "$(date +%Y-%m-%dT%H:%M:%S) REVIEW_REJECTED reason=${rejection_reason}" >> "$review_log"

        # If we have retries left, invoke the fixer
        if [ "$attempt" -lt "$max_retries" ]; then
            tui_event "🔧 fixing wave ${wave_label} issues..."

            local fix_prompt
            fix_prompt="CODE REVIEW FIX REQUEST

The reviewer found issues with the recent implementation. Fix them.

${steering_hint}

REJECTION DETAILS:
${rejection_reason}

SPEC FILES:
- ${spec_dir}/design.md
- ${spec_dir}/requirements.md
- ${task_file}

FILES TO CHECK/FIX:
${changed_source:-Check all source files}

INSTRUCTIONS:
1. Read the rejection details carefully
2. Read each file mentioned and fix the specific issues
3. If tests need to be fixed or run, do so: npm test or npx jest
4. Verify your fixes resolve ALL the listed issues
5. Do NOT modify tasks.md unless the reviewer specifically flagged it
6. Output 'FIXES_APPLIED' when done"

            local fix_log="${log_dir}/fix_wave${wave_label}_attempt${attempt}_${timestamp}.log"
            echo "$(date +%Y-%m-%dT%H:%M:%S) FIX_START wave=${wave_label} attempt=${attempt}" >> "$fix_log"

            local fix_response
            fix_response=$(kiro-cli chat --no-interactive --agent "$fixer" --trust-all-tools \
                "$fix_prompt" 2>&1 | tee -a "$fix_log") || true

            echo "$(date +%Y-%m-%dT%H:%M:%S) FIX_END" >> "$fix_log"

            # Commit the fixes
            git add --all -- ':!.ralph-logs' >/dev/null 2>&1 || true
            git commit -m "Wave ${wave_label} review fix (attempt ${attempt})" --allow-empty >/dev/null 2>&1 || true

            if echo "$fix_response" | awk '/FIXES_APPLIED/ { found=1 } END { exit !found }' 2>/dev/null; then
                tui_event "✓ fixes applied for wave ${wave_label}, re-reviewing..."
            else
                tui_event "⚠ fixer did not confirm fixes, re-reviewing anyway..."
            fi

            # Update changed_files for the next review iteration
            changed_files=$(git diff --name-only "$diff_ref" HEAD 2>/dev/null || echo "")
            changed_source=$(echo "$changed_files" | awk '/\.(ts|js|py|tsx|jsx|json|md)$/' | head -30)
        fi
    done

    # All retries exhausted
    tui_event "⚠ wave ${wave_label} review failed after ${max_retries} attempts — proceeding with warning"
    echo "$(date +%Y-%m-%dT%H:%M:%S) REVIEW_EXHAUSTED wave=${wave_label} retries=${max_retries}" >> "$review_log"

    # Non-blocking: return 0 so the run continues, but the warning is logged
    # Change to 'return 1' if you want review failures to abort the run
    return 0
}

# ─── Single Task Review (for future use) ─────────────────────
# Lighter-weight review for individual tasks. Not used in the wave
# flow but available for custom integrations.

review_task() {
    local task_id="$1"
    local spec_dir="${SPEC_DIR:-.kiro/specs/unknown}"
    local task_file="${TASK_FILE:-${spec_dir}/tasks.md}"

    if [ "${ENABLE_REVIEW:-true}" != "true" ]; then
        return 0
    fi

    local reviewer="${REVIEWER_AGENT:-reviewer}"
    local reviewer_model_flag=""
    if [ -n "${REVIEWER_MODEL:-}" ]; then
        reviewer_model_flag="--model ${REVIEWER_MODEL}"
    fi

    local task_desc
    task_desc=$(get_task_description "$task_file" "$task_id" 2>/dev/null || echo "unknown")

    local steering_hint=""
    if [ -d ".kiro/steering" ] && [ -n "$(ls -A .kiro/steering 2>/dev/null)" ]; then
        steering_hint="You have project context in .kiro/steering/ — read those files first."
    fi

    local prompt="TASK REVIEW: ${task_id} — ${task_desc}

${steering_hint}

Read ${spec_dir}/design.md and ${spec_dir}/requirements.md for context.
Read ${task_file} to see the full task list.

Audit the implementation of task ${task_id}. Check:
1. Code correctness and completeness
2. Type safety and error handling
3. Tests pass (run them if they exist)
4. Task is properly marked [x] in tasks.md

Output 'AUDIT_PASSED' or 'REJECTED: [specific issues]'"

    local response
    response=$(kiro-cli chat --no-interactive --agent "$reviewer" $reviewer_model_flag --trust-all-tools \
        "$prompt" 2>&1) || true

    if echo "$response" | awk '/AUDIT_PASSED/ { found=1 } END { exit !found }' 2>/dev/null; then
        return 0
    fi
    return 1
}
