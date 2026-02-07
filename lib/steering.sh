#!/bin/bash
# lib/steering.sh - Steering document generation and management
#
# Before any task execution, the orchestrator checks if the target repo has
# .kiro/steering/ docs. If not, it runs a special agent prompt to
# generate them from the spec files and existing codebase.
#
# This gives every subsequent agent invocation persistent project
# context without hardcoding spec paths into every prompt.

set -euo pipefail

# Guard against double-sourcing
if declare -F ensure_steering_docs &>/dev/null; then
    return 0 2>/dev/null || true
fi

# utils.sh is already sourced by the caller
if ! declare -F log_info &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
fi

# ─── Configuration ───────────────────────────────────────────
STEERING_DIR=".kiro/steering"
STEERING_AGENT="${STEERING_AGENT:-planner}"  # Reuse planner (opus) for quality
STEERING_MODEL="${STEERING_MODEL:-claude-opus-4.6}"

# ─── Check if steering docs exist ────────────────────────────
has_steering_docs() {
    [ -d "$STEERING_DIR" ] && [ -n "$(ls -A "$STEERING_DIR" 2>/dev/null)" ]
}

# ─── Count existing steering files ───────────────────────────
count_steering_files() {
    if [ -d "$STEERING_DIR" ]; then
        find "$STEERING_DIR" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

# ─── Generate steering docs from spec + codebase ─────────────
# Runs a one-shot agent prompt that reads the spec files and existing
# code, then produces steering markdown files in .kiro/steering/.
#
# Arguments:
#   $1 - spec directory path (e.g. .kiro/specs/my-feature)
#
# The agent creates:
#   - project.md    — project overview, tech stack, architecture
#   - conventions.md — coding standards, naming, patterns
#   - spec-context.md — spec summary with pointers to spec files

generate_steering_docs() {
    local spec_dir="$1"
    local task_file="${spec_dir}/tasks.md"
    local design_file="${spec_dir}/design.md"
    local requirements_file="${spec_dir}/requirements.md"

    log_info "generating steering docs from spec and codebase..."

    mkdir -p "$STEERING_DIR"

    # Build a list of spec files that exist
    local spec_files_list=""
    [ -f "$task_file" ] && spec_files_list="${spec_files_list}\n- ${task_file}"
    [ -f "$design_file" ] && spec_files_list="${spec_files_list}\n- ${design_file}"
    [ -f "$requirements_file" ] && spec_files_list="${spec_files_list}\n- ${requirements_file}"

    # Detect existing codebase structure for context
    local tree_snapshot=""
    if command -v find &>/dev/null; then
        tree_snapshot=$(find . -maxdepth 3 -type f \
            \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
               -o -name '*.py' -o -name '*.go' -o -name '*.rs' -o -name '*.java' \
               -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' \
               -o -name '*.toml' -o -name '*.cfg' -o -name 'Makefile' \
               -o -name 'Dockerfile' -o -name '*.sh' \) \
            ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.ralph-*' \
            2>/dev/null | head -50 || echo "")
    fi

    local prompt
    prompt="You are setting up project context for an AI-assisted development workflow.

READ THESE SPEC FILES:
$(echo -e "$spec_files_list")

EXISTING CODEBASE FILES (if any):
${tree_snapshot:-No existing source files found — this may be a new project.}

YOUR JOB: Create steering documents in ${STEERING_DIR}/ that give future AI agents
persistent context about this project. These files are automatically included in
every agent conversation, so they must be concise and actionable.

CREATE EXACTLY THESE 3 FILES:

1. ${STEERING_DIR}/project.md
   - Project name and one-line description
   - Tech stack (languages, frameworks, key libraries)
   - Architecture overview (patterns, directory structure)
   - Build/test/run commands
   - Keep it under 80 lines. Be specific, not generic.

2. ${STEERING_DIR}/conventions.md
   - Naming conventions (files, variables, functions, classes)
   - Code style (formatting, imports, error handling patterns)
   - Testing approach (framework, file naming, patterns)
   - Any patterns visible in existing code
   - Keep it under 60 lines. Be opinionated based on what you see.

3. ${STEERING_DIR}/spec-context.md
   - One-paragraph summary of what the spec is building
   - Key architectural decisions from design.md
   - Critical requirements/constraints from requirements.md
   - Reference the spec files by path so agents can read them for details:
     'For full task list, read ${task_file}'
     'For architecture details, read ${design_file}'
     'For acceptance criteria, read ${requirements_file}'
   - Keep it under 60 lines.

RULES:
- Write ALL 3 files using your file writing tools
- Be concise — these consume tokens on every agent request
- Be specific to THIS project, not generic boilerplate
- If the codebase already has patterns, document them
- If it's a new project, infer conventions from the spec
- Output 'STEERING_COMPLETE' when all 3 files are written"

    local steering_log="${LOG_DIR:-".ralph-logs"}/steering_${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}.log"
    mkdir -p "$(dirname "$steering_log")"

    local response
    response=$(kiro-cli chat --no-interactive --agent "$STEERING_AGENT" \
        --model "$STEERING_MODEL" --trust-all-tools \
        "$prompt" 2>&1 | tee -a "$steering_log") || true

    # Verify files were created
    local created=0
    for f in project.md conventions.md spec-context.md; do
        [ -f "${STEERING_DIR}/${f}" ] && created=$((created + 1))
    done

    if [ "$created" -ge 2 ]; then
        log_success "steering docs generated (${created}/3 files in ${STEERING_DIR}/)"
        # Commit the steering docs
        git add "${STEERING_DIR}/" >/dev/null 2>&1 || true
        git commit -m "Add steering docs (generated from spec)" --allow-empty >/dev/null 2>&1 || true
        return 0
    else
        log_warn "steering generation incomplete (${created}/3 files) — agents will use inline spec references"
        return 1
    fi
}

# ─── Main entry point ────────────────────────────────────────
# Called from btb.sh before any task execution.
# Checks for existing steering, generates if missing.
#
# Arguments:
#   $1 - spec directory path

ensure_steering_docs() {
    local spec_dir="$1"

    if has_steering_docs; then
        local count
        count=$(count_steering_files)
        log_info "steering docs found (${count} files in ${STEERING_DIR}/)"
        return 0
    fi

    log_info "no steering docs found — generating from spec..."
    generate_steering_docs "$spec_dir"
}
