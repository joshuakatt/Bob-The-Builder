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
    changed_source=$(echo "$changed_files" | awk '/\.(ts|js|py|tsx|jsx|json|md|sh|bash|rs|toml|yaml|yml|css|html|vue|svelte|go|rb|java|kt|swift|c|cpp|h)$/' | head -40)

    # Track review/fix history across attempts so the reviewer has full context
    # on re-reviews after fixes. Each entry: "ATTEMPT N: REJECTED: ... → FIX: ..."
    local review_fix_history=""

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        tui_event "🔍 reviewing wave ${wave_label} (attempt ${attempt}/${max_retries})"

        # Build steering context hint
        local steering_hint=""
        if [ -d ".kiro/steering" ] && [ -n "$(ls -A .kiro/steering 2>/dev/null)" ]; then
            steering_hint="You have project context in .kiro/steering/ — read those files first for architecture, conventions, and spec summary."
        fi

        # Build history context for re-review attempts
        local history_section=""
        if [ -n "$review_fix_history" ]; then
            history_section="
PREVIOUS REVIEW/FIX HISTORY:
This is re-review attempt ${attempt}. Here is what happened in previous rounds:
${review_fix_history}
IMPORTANT: Focus on whether the previously identified issues have been ACTUALLY FIXED.
If they have, and no new issues are found, output AUDIT_PASSED.
Do NOT re-raise issues that have already been addressed."
        fi

        local review_prompt
        review_prompt="WAVE ${wave_label} QUALITY REVIEW

You are auditing work that was just completed. Review it against the spec.

${steering_hint}
${history_section}

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
5. If test files were created, run them — but use NON-INTERACTIVE commands:
   - vitest: always use 'vitest --run' (NEVER bare 'vitest' which enters watch mode)
   - jest: use 'jest --forceExit'
   - pnpm/npm scripts: if the script runs vitest, use 'pnpm run test -- --run' or set CI=true
   - cargo: 'cargo test' is fine (non-interactive by default)
   - NEVER run commands that wait for user input or enter watch/interactive mode
6. Verify tasks.md was updated — completed tasks should be marked [x]
7. Check for obvious bugs, missing error handling, or security issues
8. If you need to understand how changed code integrates with the rest of the codebase, explore related files freely — you have full access to the entire repository

OUTPUT FORMAT:
- If everything passes: output exactly 'AUDIT_PASSED'
- If issues found: output 'REJECTED: ' followed by a numbered list of specific issues

Be thorough but pragmatic. Flag real problems, not style preferences."

        echo "$(date +%Y-%m-%dT%H:%M:%S) REVIEW_START wave=${wave_label} attempt=${attempt}" >> "$review_log"

        local review_timeout="${REVIEW_TIMEOUT:-1800}"
        local review_response
        review_response=$(timeout "$review_timeout" kiro-cli chat --no-interactive --agent "$reviewer" $reviewer_model_flag --trust-all-tools \
            "$review_prompt" 2>&1 | tee -a "$review_log") || {
            local _rc=$?
            if [ "$_rc" -eq 124 ]; then
                echo "$(date +%Y-%m-%dT%H:%M:%S) REVIEW_TIMEOUT wave=${wave_label} attempt=${attempt} after ${review_timeout}s" >> "$review_log"
                tui_event "⚠ review timed out after ${review_timeout}s (attempt ${attempt})"
                review_response="REJECTED: Review timed out after ${review_timeout} seconds — likely a hung build/test command"
            fi
        }

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

            # Include history so the fixer knows what was already tried
            local fixer_history_section=""
            if [ -n "$review_fix_history" ]; then
                fixer_history_section="
PREVIOUS FIX ATTEMPTS:
${review_fix_history}
Do NOT repeat fixes that already failed. Try a different approach if the same issue persists."
            fi

            local fix_prompt
            fix_prompt="CODE REVIEW FIX REQUEST

The reviewer found issues with the recent implementation. Fix them.

${steering_hint}
${fixer_history_section}

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
3. If tests need to be fixed or run, use NON-INTERACTIVE commands:
   - vitest: always use 'vitest --run' (NEVER bare 'vitest' which enters watch mode)
   - jest: use 'jest --forceExit'
   - pnpm/npm scripts: if the script runs vitest, use 'pnpm run test -- --run' or set CI=true
   - cargo: 'cargo test' is fine (non-interactive by default)
   - NEVER run commands that wait for user input or enter watch/interactive mode
4. Verify your fixes resolve ALL the listed issues
5. Do NOT modify tasks.md unless the reviewer specifically flagged it
6. Output 'FIXES_APPLIED' when done"

            local fix_log="${log_dir}/fix_wave${wave_label}_attempt${attempt}_${timestamp}.log"
            echo "$(date +%Y-%m-%dT%H:%M:%S) FIX_START wave=${wave_label} attempt=${attempt}" >> "$fix_log"

            local fix_response
            fix_response=$(timeout "$review_timeout" kiro-cli chat --no-interactive --agent "$fixer" --trust-all-tools \
                "$fix_prompt" 2>&1 | tee -a "$fix_log") || {
                local _rc=$?
                if [ "$_rc" -eq 124 ]; then
                    echo "$(date +%Y-%m-%dT%H:%M:%S) FIX_TIMEOUT wave=${wave_label} attempt=${attempt} after ${review_timeout}s" >> "$fix_log"
                    tui_event "⚠ fix attempt timed out after ${review_timeout}s"
                    fix_response="(fix timed out after ${review_timeout} seconds — likely a hung build/test command)"
                fi
            }

            echo "$(date +%Y-%m-%dT%H:%M:%S) FIX_END" >> "$fix_log"

            # Commit the fixes
            git add --all -- ':!.ralph-logs' >/dev/null 2>&1 || true
            git commit -m "Wave ${wave_label} review fix (attempt ${attempt})" --allow-empty >/dev/null 2>&1 || true

            # Extract what the fixer claimed to do (first 20 lines after FIXES_APPLIED or last 20 lines)
            local fix_summary=""
            fix_summary=$(echo "$fix_response" | awk '/FIXES_APPLIED/ { found=1; next } found { print }' | head -20)
            if [ -z "$fix_summary" ]; then
                # Fixer didn't output FIXES_APPLIED — grab the tail as summary
                fix_summary=$(echo "$fix_response" | tail -20 | head -20)
            fi

            if echo "$fix_response" | awk '/FIXES_APPLIED/ { found=1 } END { exit !found }' 2>/dev/null; then
                tui_event "✓ fixes applied for wave ${wave_label}, re-reviewing..."
            else
                tui_event "⚠ fixer did not confirm fixes, re-reviewing anyway..."
                fix_summary="(fixer did not confirm completion) ${fix_summary}"
            fi

            # Append to history for the next review/fix iteration
            # Truncate to avoid unbounded prompt growth
            local history_entry=""
            history_entry="--- ROUND ${attempt} ---
REJECTED: $(echo "$rejection_reason" | head -15)
FIX ATTEMPTED: $(echo "$fix_summary" | head -15)
"
            review_fix_history="${review_fix_history}${history_entry}"

            # Update changed_files for the next review iteration
            changed_files=$(git diff --name-only "$diff_ref" HEAD 2>/dev/null || echo "")
            changed_source=$(echo "$changed_files" | awk '/\.(ts|js|py|tsx|jsx|json|md|sh|bash|rs|toml|yaml|yml|css|html|vue|svelte|go|rb|java|kt|swift|c|cpp|h)$/' | head -40)
        else
            # Last attempt rejected, no more fixes — append rejection to history for logging
            review_fix_history="${review_fix_history}--- ROUND ${attempt} (FINAL) ---
REJECTED: $(echo "$rejection_reason" | head -15)
(no more fix attempts)
"
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
