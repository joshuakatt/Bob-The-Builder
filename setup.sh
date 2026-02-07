#!/bin/bash
# setup.sh - Bootstrap Bob the Builder into any repository
#
# Drop the btb directory anywhere, cd into your target repo, and run:
#   /path/to/btb/setup.sh
#
# This installs the agent configs into your repo's .kiro/agents/ and
# validates everything is ready to go. Non-destructive — won't overwrite
# existing agent configs.
#
# After setup, run:
#   /path/to/btb/btb.sh <spec_name_or_path>
#   /path/to/btb/btb.sh --spec-dir .kiro/specs/my-feature

set -euo pipefail

BTB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "  \033[1m\033[97mBOB THE BUILDER\033[0m \033[2msetup\033[0m"
echo ""

# ─── Check prerequisites ─────────────────────────────────────
errors=0
warnings=0

if ! command -v kiro-cli &>/dev/null; then
    echo -e "  \033[91m✗\033[0m  kiro-cli not found in PATH"
    errors=$((errors + 1))
else
    echo -e "  \033[37m✓\033[0m  kiro-cli $(kiro-cli --version 2>/dev/null || echo 'found')"
fi

if ! command -v git &>/dev/null; then
    echo -e "  \033[91m✗\033[0m  git not found"
    errors=$((errors + 1))
else
    echo -e "  \033[37m✓\033[0m  git $(git --version 2>/dev/null | head -1)"
fi

if ! command -v python3 &>/dev/null; then
    echo -e "  \033[91m✗\033[0m  python3 not found (needed for DAG analysis)"
    errors=$((errors + 1))
else
    echo -e "  \033[37m✓\033[0m  python3 $(python3 --version 2>/dev/null)"
fi

if ! command -v perl &>/dev/null; then
    echo -e "  \033[93m⚠\033[0m  perl not found (TUI input requires it — use --no-tui to skip)"
    warnings=$((warnings + 1))
else
    echo -e "  \033[37m✓\033[0m  perl $(perl -v 2>/dev/null | awk '/version/ { print; exit }' | sed 's/.*(\(v[0-9.]*\)).*/\1/' || echo 'found')"
fi

if [ "$errors" -gt 0 ]; then
    echo ""
    echo -e "  \033[91m${errors} missing prerequisite(s). Install them and re-run.\033[0m"
    echo ""
    exit 1
fi

# ─── Install agents ──────────────────────────────────────────
agent_src="${BTB_DIR}/.kiro/agents"
agent_dst=".kiro/agents"

if [ ! -d "$agent_src" ]; then
    echo -e "  \033[91m✗\033[0m  Agent configs not found at ${agent_src}"
    exit 1
fi

mkdir -p "$agent_dst"

installed=0
skipped=0
for agent_file in "${agent_src}"/*.json; do
    [ -f "$agent_file" ] || continue
    name=$(basename "$agent_file")
    if [ -f "${agent_dst}/${name}" ]; then
        skipped=$((skipped + 1))
    else
        cp "$agent_file" "${agent_dst}/${name}"
        installed=$((installed + 1))
    fi
done

echo -e "  \033[37m✓\033[0m  agents: ${installed} installed, ${skipped} already present"

# ─── Validate agents ─────────────────────────────────────────
valid=0
invalid=0
for agent_file in "${agent_dst}"/*.json; do
    [ -f "$agent_file" ] || continue
    if kiro-cli agent validate --path "$agent_file" >/dev/null 2>&1; then
        valid=$((valid + 1))
    else
        echo -e "  \033[91m✗\033[0m  invalid: ${agent_file}"
        invalid=$((invalid + 1))
    fi
done

if [ "$invalid" -gt 0 ]; then
    echo -e "  \033[91m✗\033[0m  ${invalid} agent(s) failed validation"
else
    echo -e "  \033[37m✓\033[0m  all ${valid} agents validated"
fi

# ─── Ensure .gitignore covers build artifacts ────────────────
_ensure_gitignore() {
    local pattern="$1"
    if [ -f .gitignore ]; then
        if ! awk -v p="$pattern" '$0 == p { found=1; exit } END { exit !found }' .gitignore 2>/dev/null; then
            echo "$pattern" >> .gitignore
        fi
    else
        echo "$pattern" > .gitignore
    fi
}
_ensure_gitignore ".ralph-logs/"
_ensure_gitignore ".ralph-worktrees/"
echo -e "  \033[37m✓\033[0m  .gitignore updated"

# ─── Detect specs ────────────────────────────────────────────
echo ""
specs_found=0
for spec_dir in .kiro/specs/*/; do
    [ -d "$spec_dir" ] || continue
    if [ -f "${spec_dir}tasks.md" ]; then
        spec_name=$(basename "$spec_dir")
        tasks=$(awk '/^[[:space:]]+-[[:space:]]\[.\][[:space:]][0-9]+\.[0-9]+/ { n++ } END { print n+0 }' "${spec_dir}tasks.md" 2>/dev/null)
        done_count=$(awk '/^[[:space:]]+-[[:space:]]\[x\][[:space:]][0-9]+\.[0-9]+/ { n++ } END { print n+0 }' "${spec_dir}tasks.md" 2>/dev/null)
        echo -e "  \033[37m·\033[0m  spec: \033[1m${spec_name}\033[0m (${done_count}/${tasks} tasks done)"
        specs_found=$((specs_found + 1))
    fi
done

if [ "$specs_found" -eq 0 ]; then
    echo -e "  \033[93m·\033[0m  no specs found in .kiro/specs/ — you can point to any directory with tasks.md"
fi

# ─── Detect steering docs ────────────────────────────────────
if [ -d ".kiro/steering" ] && [ -n "$(ls -A .kiro/steering 2>/dev/null)" ]; then
    steering_count=$(find .kiro/steering -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  \033[37m✓\033[0m  steering: ${steering_count} docs in .kiro/steering/"
else
    echo -e "  \033[93m·\033[0m  no steering docs — they'll be auto-generated on first run"
fi

# ─── Print usage ─────────────────────────────────────────────
echo ""
echo -e "  \033[2mready. usage:\033[0m"
echo ""
echo -e "  \033[37m# by spec name (looks in .kiro/specs/<name>)\033[0m"
echo -e "  ${BTB_DIR}/btb.sh my-feature"
echo ""
echo -e "  \033[37m# by direct path\033[0m"
echo -e "  ${BTB_DIR}/btb.sh --spec-dir path/to/spec"
echo ""
echo -e "  \033[37m# sequential (one task at a time)\033[0m"
echo -e "  ${BTB_DIR}/btb.sh my-feature --sequential"
echo ""
if [ "$warnings" -gt 0 ]; then
    echo -e "  \033[93m${warnings} warning(s) above — non-blocking but worth addressing.\033[0m"
    echo ""
fi
