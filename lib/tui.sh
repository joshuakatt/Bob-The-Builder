#!/bin/bash
# lib/tui.sh - Full-screen terminal UI for Bob the Builder
# Pure ANSI escape codes. No dependencies. Lightweight.
#
# Features:
#   - DAG tree visualization with auto-scroll
#   - Interactive worker selection (↑/↓ arrows)
#   - Live worker output panel (tails log file)
#   - Activity log ring buffer
#   - Progress bar
#
# Uses alternate screen buffer so the user's terminal is clean on exit.
#
# SAFETY: The TUI is purely cosmetic — it must NEVER crash the orchestrator.
# All public TUI functions use set +eu internally to catch any error
# (including unbound variables, arithmetic failures, printf errors, etc.)
# and silently continue. The orchestrator's execution logic is completely
# isolated from TUI failures. Additionally, btb.sh guards TUI calls with
# || true as a belt-and-suspenders measure.

# ─── Fault Isolation Wrapper ─────────────────────────────────
# Runs a function body with set +eu (disable exit-on-error and unbound-var
# checks) so that TUI bugs cannot kill the orchestrator. Errors are logged
# to the debug log if available, but never propagated.
#
# We can't use a subshell because TUI functions modify global arrays.
# Instead, we save/restore shell options around the call.
_tui_safe() {
    local fn="$1"; shift
    local _prev_opts
    _prev_opts=$(set +o)  # capture current options
    set +eu                # disable strict mode for TUI
    "$fn" "$@" 2>/dev/null
    local _rc=$?
    eval "$_prev_opts"     # restore original options
    if [ "$_rc" -ne 0 ] && declare -F dbg &>/dev/null; then
        dbg "TUI: ${fn} returned ${_rc} (suppressed)" 2>/dev/null || true
    fi
    return 0               # NEVER propagate TUI errors
}

# ─── Terminal Control ────────────────────────────────────────
TUI_ACTIVE=false
TUI_LOG_LINES=()
TUI_MAX_LOG=12
TUI_FRAME=0
TUI_LAST_RENDER=0

# Palette
_RST='\033[0m'
_BOLD='\033[1m'
_DIM='\033[2m'
_WHITE='\033[97m'
_GRAY='\033[90m'
_LGRAY='\033[37m'
_CYAN='\033[96m'
_BLUE='\033[94m'
_YELLOW='\033[93m'
_RED='\033[91m'
_MAGENTA='\033[95m'
_REVERSE='\033[7m'

# ─── Screen Management ───────────────────────────────────────

tui_init() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    TUI_ACTIVE=true
    printf '\033[?1049h\033[?25l'
    tui_update_size
    tui_enable_raw_input
    trap 'tui_update_size 2>/dev/null || true; tui_render 2>/dev/null || true' WINCH
    eval "$_prev_opts" 2>/dev/null
}

tui_cleanup() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    if [ "$TUI_ACTIVE" = true ]; then
        TUI_ACTIVE=false
        tui_restore_input
        printf '\033[?25h\033[?1049l'
    fi
    eval "$_prev_opts" 2>/dev/null
}

tui_update_size() {
    # Use multiple methods to get accurate terminal dimensions.
    # COLUMNS/LINES are set by the shell on resize but may not be exported.
    # stty size reads from the tty directly. tput queries terminfo.
    local _cols="" _rows=""

    # Method 1: stty (most reliable in subshells/alternate screen)
    if _dims=$(stty size </dev/tty 2>/dev/null); then
        _rows="${_dims%% *}"
        _cols="${_dims##* }"
    fi

    # Method 2: tput fallback
    [ -z "$_cols" ] || [ "$_cols" -eq 0 ] 2>/dev/null && _cols=$(tput cols 2>/dev/null)
    [ -z "$_rows" ] || [ "$_rows" -eq 0 ] 2>/dev/null && _rows=$(tput lines 2>/dev/null)

    # Method 3: COLUMNS/LINES env vars
    [ -z "$_cols" ] || [ "$_cols" -eq 0 ] 2>/dev/null && _cols="${COLUMNS:-}"
    [ -z "$_rows" ] || [ "$_rows" -eq 0 ] 2>/dev/null && _rows="${LINES:-}"

    TERM_ROWS="${_rows:-40}"
    TERM_COLS="${_cols:-120}"
}

tui_goto() { printf '\033[%d;%dH' "$1" "$2"; }
tui_clreol() { printf '\033[K'; }

tui_line() {
    local content="$1" row="$2"
    tui_goto "$row" 1
    printf '%b' "$content"
    tui_clreol
}

tui_hr() {
    local row="$1" char="${2:-─}" style="${3:-$_DIM$_GRAY}"
    tui_goto "$row" 1
    printf '%b' "$style"
    printf '%*s' "$TERM_COLS" '' | tr ' ' "$char"
    printf '%b' "$_RST"
}

# ─── Activity Log (Ring Buffer) ──────────────────────────────

tui_log() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    local ts
    ts=$(date +%H:%M:%S)
    TUI_LOG_LINES+=("${ts} $1")
    local count=${#TUI_LOG_LINES[@]}
    if [ "$count" -gt "$TUI_MAX_LOG" ]; then
        TUI_LOG_LINES=("${TUI_LOG_LINES[@]:$((count - TUI_MAX_LOG))}")
    fi
    eval "$_prev_opts" 2>/dev/null
}

# ─── State Arrays ────────────────────────────────────────────

declare -a TUI_WAVE_IDS=()
declare -a TUI_WAVE_TASKS=()
declare -a TUI_TASK_IDS=()
declare -a TUI_TASK_DESCS=()
declare -a TUI_TASK_STATES=()
declare -a TUI_TASK_WAVES=()
declare -a TUI_TASK_DEPS=()
declare -a TUI_TASK_LOGS=()       # log file path per task
declare -a TUI_TASK_MODELS=()     # planner-assigned model per task

TUI_SPEC_NAME=""
TUI_CURRENT_WAVE=-1
TUI_TOTAL_WAVES=0
TUI_TOTAL_TASKS=0
TUI_COMPLETED=0
TUI_FAILED=0
TUI_RUNNING=0
TUI_ELAPSED=0
TUI_MODE="concurrent"
TUI_MAX_PARALLEL=4
TUI_WORKER_SLOTS=3
TUI_REVIEW_RESERVED=1
TUI_RETURN_ROW=0
TUI_PHASE=""

# ─── Worker Selection ────────────────────────────────────────
TUI_SELECTED_WORKER=-1            # index into running workers list
TUI_SELECTED_TASK=""              # task ID of selected worker

# Build list of currently running task IDs for selection
tui_get_running_tasks() {
    TUI_RUNNING_LIST=()
    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        if [ "${TUI_TASK_STATES[$i]}" = "running" ]; then
            TUI_RUNNING_LIST+=("${TUI_TASK_IDS[$i]}")
        fi
    done
}

# Move selection up/down. Wraps around.
tui_select_prev() {
    tui_get_running_tasks
    local count=${#TUI_RUNNING_LIST[@]}
    [ "$count" -eq 0 ] && return
    TUI_SELECTED_WORKER=$(( (TUI_SELECTED_WORKER - 1 + count) % count ))
    TUI_SELECTED_TASK="${TUI_RUNNING_LIST[$TUI_SELECTED_WORKER]}"
    TUI_LAST_RENDER=0  # force re-render
}

tui_select_next() {
    tui_get_running_tasks
    local count=${#TUI_RUNNING_LIST[@]}
    [ "$count" -eq 0 ] && return
    TUI_SELECTED_WORKER=$(( (TUI_SELECTED_WORKER + 1) % count ))
    TUI_SELECTED_TASK="${TUI_RUNNING_LIST[$TUI_SELECTED_WORKER]}"
    TUI_LAST_RENDER=0  # force re-render
}

# Auto-select: if only 1 worker, select it. If selected worker finished, move to next.
tui_auto_select() {
    tui_get_running_tasks
    local count=${#TUI_RUNNING_LIST[@]}
    if [ "$count" -eq 0 ]; then
        TUI_SELECTED_WORKER=-1
        TUI_SELECTED_TASK=""
        return
    fi
    if [ "$count" -eq 1 ]; then
        TUI_SELECTED_WORKER=0
        TUI_SELECTED_TASK="${TUI_RUNNING_LIST[0]}"
        return
    fi
    # Check if current selection is still valid
    local found=false
    for ((i=0; i<count; i++)); do
        if [ "${TUI_RUNNING_LIST[$i]}" = "$TUI_SELECTED_TASK" ]; then
            TUI_SELECTED_WORKER=$i
            found=true
            break
        fi
    done
    if [ "$found" = false ]; then
        [ "$TUI_SELECTED_WORKER" -ge "$count" ] && TUI_SELECTED_WORKER=$((count - 1))
        [ "$TUI_SELECTED_WORKER" -lt 0 ] && TUI_SELECTED_WORKER=0
        TUI_SELECTED_TASK="${TUI_RUNNING_LIST[$TUI_SELECTED_WORKER]}"
    fi
}

# ─── Input Handling ──────────────────────────────────────────
# Uses perl IO::Select for non-blocking read from /dev/tty.
# macOS bash 3.2 doesn't support fractional `read -t` timeouts.

tui_handle_input() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    # Use perl for non-blocking read — macOS bash 3.2 doesn't support
    # fractional seconds in `read -t 0.1` and escape sequences get mangled.
    local input=""
    input=$(perl -e '
        use IO::Select;
        open(my $tty, "<", "/dev/tty") or exit 1;
        my $sel = IO::Select->new($tty);
        if ($sel->can_read(0.1)) {
            my $buf = "";
            sysread($tty, $buf, 8);
            print $buf;
        }
        close($tty);
    ' 2>/dev/null) || { eval "$_prev_opts" 2>/dev/null; return 1; }
    [ -z "$input" ] && { eval "$_prev_opts" 2>/dev/null; return 1; }

    case "$input" in
        $'\033[A'*) tui_select_prev; eval "$_prev_opts" 2>/dev/null; return 0 ;;
        $'\033[B'*) tui_select_next; eval "$_prev_opts" 2>/dev/null; return 0 ;;
    esac
    eval "$_prev_opts" 2>/dev/null
    return 1
}

# Terminal raw mode for non-blocking single-char input
TUI_ORIG_STTY=""

tui_enable_raw_input() {
    TUI_ORIG_STTY=$(stty -g </dev/tty 2>/dev/null) || true
    # min 0 time 0 = non-blocking, -echo = don't echo, -icanon = char-at-a-time
    stty -echo -icanon min 0 time 0 </dev/tty 2>/dev/null || true
}

tui_restore_input() {
    if [ -n "$TUI_ORIG_STTY" ]; then
        stty "$TUI_ORIG_STTY" </dev/tty 2>/dev/null || true
        TUI_ORIG_STTY=""
    fi
}

# ─── Set log file path for a task ────────────────────────────

tui_set_task_log() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    local tid="$1" logpath="$2"
    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        if [ "${TUI_TASK_IDS[$i]}" = "$tid" ]; then
            TUI_TASK_LOGS[$i]="$logpath"
            eval "$_prev_opts" 2>/dev/null; return
        fi
    done
    eval "$_prev_opts" 2>/dev/null
}

# Get log file for a task
tui_get_task_log() {
    local tid="$1"
    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        if [ "${TUI_TASK_IDS[$i]}" = "$tid" ]; then
            echo "${TUI_TASK_LOGS[$i]:-}"
            return
        fi
    done
}

# ─── Worker Output Panel ─────────────────────────────────────
# Shows last N lines from the selected worker's log file.
# Filters out noise (ANSI codes, JSON blobs, blank lines).

tui_render_worker_output() {
    local start_row="$1"
    local max_rows="${2:-6}"
    local row="$start_row"

    if [ -n "$TUI_SELECTED_TASK" ]; then
        tui_line "  ${_BOLD}${_WHITE}WORKER OUTPUT${_RST}  ${_DIM}${_GRAY}[${TUI_SELECTED_TASK}]  ↑↓ to switch${_RST}" "$row"
    else
        tui_line "  ${_BOLD}${_WHITE}WORKER OUTPUT${_RST}  ${_DIM}${_GRAY}↑↓ to switch${_RST}" "$row"
    fi
    row=$((row + 1))

    local content_rows=$((max_rows - 1))

    if [ -z "$TUI_SELECTED_TASK" ]; then
        # No worker selected — show phase
        local phase_msg=""
        case "$TUI_PHASE" in
            syncing)    phase_msg="syncing results to main branch..." ;;
            merging)    phase_msg="merging wave results..." ;;
            reviewing)  phase_msg="quality review in progress..." ;;
            waiting)    phase_msg="preparing next wave..." ;;
            done)       phase_msg="all workers finished" ;;
            *)          phase_msg="no active workers" ;;
        esac
        tui_line "    ${_LGRAY}${phase_msg}${_RST}" "$row"
        row=$((row + 1))
    else
        local logpath
        logpath=$(tui_get_task_log "$TUI_SELECTED_TASK")
        if [ -n "$logpath" ] && [ -f "$logpath" ]; then
            # Tail the log, strip ANSI codes, skip internal timestamps and blank lines
            local -a lines=()
            while IFS= read -r line; do
                lines+=("$line")
            done < <(tail -n 80 "$logpath" 2>/dev/null \
                | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
                | sed 's/\r//g' \
                | awk 'NF && !/^[[:space:]]*$/ && !/^[0-9T:-]+ (STARTED|ITERATION|RESPONSE_START|RESPONSE_END)/' \
                | tail -n "$content_rows")

            local lcount=${#lines[@]}
            for ((li=0; li<lcount && li<content_rows; li++)); do
                local ln="${lines[$li]}"
                ln="${ln:0:$((TERM_COLS - 8))}"
                tui_line "    ${_LGRAY}${ln}${_RST}" "$row"
                row=$((row + 1))
            done
        else
            tui_line "    ${_LGRAY}waiting for output...${_RST}" "$row"
            row=$((row + 1))
        fi
    fi

    # Clear remaining
    while [ "$row" -lt $((start_row + max_rows)) ]; do
        tui_line "" "$row"
        row=$((row + 1))
    done

    TUI_RETURN_ROW=$row
}

# ─── DAG Tree Renderer ───────────────────────────────────────

tui_render_dag() {
    local start_row="$1"
    local max_rows="${2:-20}"
    local row="$start_row"

    local -a wave_heights=()
    local total_lines=0
    for ((w=0; w<TUI_TOTAL_WAVES; w++)); do
        local wt="${TUI_WAVE_TASKS[$w]}"
        IFS=',' read -ra _tasks <<< "$wt"
        local tc=${#_tasks[@]}
        local h=1
        [ "$tc" -gt 1 ] && h=$((tc + 2))
        wave_heights+=("$h")
        total_lines=$((total_lines + h))
    done

    # Scroll to keep current wave visible
    local scroll_start=0
    if [ "$TUI_CURRENT_WAVE" -ge 0 ]; then
        local cur_offset=0
        for ((w=0; w<TUI_CURRENT_WAVE && w<TUI_TOTAL_WAVES; w++)); do
            cur_offset=$((cur_offset + wave_heights[w]))
        done
        local cur_h=${wave_heights[$TUI_CURRENT_WAVE]:-1}
        if [ $((cur_offset + cur_h)) -gt "$max_rows" ]; then
            scroll_start=$((cur_offset - max_rows / 3))
            [ "$scroll_start" -lt 0 ] && scroll_start=0
        fi
    fi

    local line_idx=0
    for ((w=0; w<TUI_TOTAL_WAVES; w++)); do
        local wave_tasks="${TUI_WAVE_TASKS[$w]}"
        IFS=',' read -ra tasks <<< "$wave_tasks"
        local task_count=${#tasks[@]}
        local is_parallel=$( [ "$task_count" -gt 1 ] && echo true || echo false )

        local wmark="${_DIM}${_GRAY}"
        [ "$w" -eq "$TUI_CURRENT_WAVE" ] && wmark="${_BOLD}${_CYAN}"
        local wlabel="w${w}"
        local wpad=""
        [ ${#wlabel} -lt 3 ] && wpad=" "
        [ ${#wlabel} -lt 2 ] && wpad="  "

        if [ "$is_parallel" = true ]; then
            if [ "$line_idx" -ge "$scroll_start" ] && [ "$row" -lt $((start_row + max_rows)) ]; then
                tui_line "  ${wmark}${wlabel}${wpad}${_RST} ${_DIM}${_GRAY}┬ fork(${task_count})${_RST}" "$row"
                row=$((row + 1))
            fi
            line_idx=$((line_idx + 1))

            for ((t=0; t<task_count; t++)); do
                if [ "$line_idx" -ge "$scroll_start" ] && [ "$row" -lt $((start_row + max_rows)) ]; then
                    local tid="${tasks[$t]}"
                    local tstate
                    tstate=$(tui_get_task_state "$tid")
                    local sym
                    sym=$(tui_state_symbol "$tstate")
                    local sym_color
                    sym_color=$(tui_state_color "$tstate")
                    local desc
                    desc=$(tui_get_task_desc "$tid")
                    local tmodel
                    tmodel=$(tui_get_task_model "$tid")
                    local mbadge=""
                    [ -n "$tmodel" ] && mbadge=" $(tui_model_badge "$tmodel")"
                    desc="${desc:0:$((TERM_COLS - 32))}"
                    local conn="${_DIM}${_GRAY}├${_RST}"
                    [ "$t" -eq $((task_count - 1)) ] && conn="${_DIM}${_GRAY}└${_RST}"
                    tui_line "      ${conn}─${sym_color}${sym}${_RST} ${_BOLD}${tid}${_RST}${mbadge} ${_DIM}${desc}${_RST}" "$row"
                    row=$((row + 1))
                fi
                line_idx=$((line_idx + 1))
            done

            if [ "$line_idx" -ge "$scroll_start" ] && [ "$row" -lt $((start_row + max_rows)) ]; then
                tui_line "      ${_DIM}${_GRAY}┴ merge${_RST}" "$row"
                row=$((row + 1))
            fi
            line_idx=$((line_idx + 1))
        else
            if [ "$line_idx" -ge "$scroll_start" ] && [ "$row" -lt $((start_row + max_rows)) ]; then
                local tid="${tasks[0]}"
                local tstate
                tstate=$(tui_get_task_state "$tid")
                local sym
                sym=$(tui_state_symbol "$tstate")
                local sym_color
                sym_color=$(tui_state_color "$tstate")
                local desc
                desc=$(tui_get_task_desc "$tid")
                local tmodel
                tmodel=$(tui_get_task_model "$tid")
                local mbadge=""
                [ -n "$tmodel" ] && mbadge=" $(tui_model_badge "$tmodel")"
                desc="${desc:0:$((TERM_COLS - 32))}"
                tui_line "  ${wmark}${wlabel}${wpad}${_RST} ${_DIM}${_GRAY}│${_RST} ${sym_color}${sym}${_RST} ${_BOLD}${tid}${_RST}${mbadge} ${_DIM}${desc}${_RST}" "$row"
                row=$((row + 1))
            fi
            line_idx=$((line_idx + 1))
        fi
    done

    while [ "$row" -lt $((start_row + max_rows)) ]; do
        tui_line "" "$row"
        row=$((row + 1))
    done
    TUI_RETURN_ROW=$row
}

# ─── Helpers ─────────────────────────────────────────────────

tui_get_task_state() {
    local tid="$1"
    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        [ "${TUI_TASK_IDS[$i]}" = "$tid" ] && { echo "${TUI_TASK_STATES[$i]}"; return; }
    done
    echo "pending"
}

tui_get_task_desc() {
    local tid="$1"
    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        [ "${TUI_TASK_IDS[$i]}" = "$tid" ] && { echo "${TUI_TASK_DESCS[$i]}"; return; }
    done
}

tui_state_symbol() {
    case "$1" in
        completed) echo "✓" ;; running) echo "●" ;;
        failed) echo "✗" ;; *) echo "○" ;;
    esac
}

tui_state_color() {
    case "$1" in
        completed) echo "${_DIM}${_LGRAY}" ;; running) echo "${_BOLD}${_CYAN}" ;;
        failed) echo "${_BOLD}${_RED}" ;; *) echo "${_DIM}${_GRAY}" ;;
    esac
}

# Short model label for TUI display (e.g. "haiku" "sonnet" "opus")
tui_model_badge() {
    case "$1" in
        claude-sonnet-4.5)  echo "${_BOLD}${_CYAN}sonnet${_RST}" ;;
        claude-opus-4.6)    echo "${_BOLD}${_YELLOW}opus${_RST}" ;;
        *)                  echo "${_DIM}${_GRAY}${1}${_RST}" ;;
    esac
}

tui_get_task_model() {
    local tid="$1"
    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        [ "${TUI_TASK_IDS[$i]}" = "$tid" ] && { echo "${TUI_TASK_MODELS[$i]:-}"; return; }
    done
}

# ─── Progress Bar ─────────────────────────────────────────────

tui_render_progress() {
    local row="$1"
    local completed="$TUI_COMPLETED" total="$TUI_TOTAL_TASKS"
    local width=$((TERM_COLS - 30))
    [ "$width" -lt 20 ] && width=20
    local pct=0
    [ "$total" -gt 0 ] && pct=$((completed * 100 / total))
    local filled=$((completed * width / (total > 0 ? total : 1)))
    local empty=$((width - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    local elapsed_str
    elapsed_str=$(tui_format_time "$TUI_ELAPSED")
    tui_line "  ${_BOLD}${_WHITE}${bar}${_RST} ${_LGRAY}${completed}/${total}${_RST} ${_LGRAY}(${pct}%)${_RST}  ${_DIM}${_LGRAY}elapsed ${elapsed_str}${_RST}" "$row"
}

tui_format_time() {
    local secs="$1" m=$((${1} / 60)) s=$((${1} % 60))
    [ "$m" -gt 0 ] && printf '%dm %02ds' "$m" "$s" || printf '%ds' "$s"
}

# ─── Task Map (Node Graph) ────────────────────────────────────
# Task-centric DAG: columns are parent tasks (1, 2, 3…), subtasks
# stacked vertically. Each parent has a return lane column to its
# right where subtask connections flow vertically back up to the
# spine before continuing to the next parent.
#
# Return lane uses ┬ at spine, ┤ for intermediate subs, ╯ for last.
# Nodes are large (padded symbol, no brackets).
# Colors match TUI palette: lgray=done, cyan=active, gray=pending, red=failed.
# Active nodes pulsate (symbol + intensity alternate each frame).
# Node/connector sizing adapts: shrinks node_w and spine_gap for large task counts.

tui_render_task_map() {
    local start_row="$1"
    local max_rows="${2:-8}"
    local row="$start_row"

    local total=${#TUI_TASK_IDS[@]}
    if [ "$total" -eq 0 ]; then
        while [ "$row" -lt $((start_row + max_rows)) ]; do
            tui_line "" "$row"; row=$((row + 1))
        done
        TUI_RETURN_ROW=$row; return
    fi

    # ── Group subtasks by parent ──
    local -a _tm_parents=()
    local -a _tm_parent_subs=()
    local _tm_pcount=0 _tm_max_subs=0

    for ((i=0; i<total; i++)); do
        local tid="${TUI_TASK_IDS[$i]}"
        local parent="${tid%%.*}"
        local found=false
        for ((pp=0; pp<_tm_pcount; pp++)); do
            if [ "${_tm_parents[$pp]}" = "$parent" ]; then
                _tm_parent_subs[$pp]="${_tm_parent_subs[$pp]},${tid}"
                found=true; break
            fi
        done
        if [ "$found" = false ]; then
            _tm_parents+=("$parent")
            _tm_parent_subs+=("$tid")
            _tm_pcount=$((_tm_pcount + 1))
        fi
    done
    for ((pp=0; pp<_tm_pcount; pp++)); do
        IFS=',' read -ra _s <<< "${_tm_parent_subs[$pp]}"
        [ ${#_s[@]} -gt "$_tm_max_subs" ] && _tm_max_subs=${#_s[@]}
    done

    # Count states
    local done_c=0 run_c=0 pend_c=0 fail_c=0
    for ((i=0; i<total; i++)); do
        case "${TUI_TASK_STATES[$i]}" in
            completed) done_c=$((done_c + 1)) ;;
            running)   run_c=$((run_c + 1)) ;;
            failed)    fail_c=$((fail_c + 1)) ;;
            *)         pend_c=$((pend_c + 1)) ;;
        esac
    done

    # Header
    local hdr="  ${_BOLD}${_WHITE}TASK MAP${_RST}  "
    hdr+="${_BOLD}${_WHITE}${done_c}${_RST}${_DIM}${_GRAY} done  ${_RST}"
    hdr+="${_BOLD}${_CYAN}${run_c}${_RST}${_DIM}${_GRAY} active  ${_RST}"
    hdr+="${_DIM}${_GRAY}${pend_c} pending${_RST}"
    [ "$fail_c" -gt 0 ] && hdr+="  ${_BOLD}${_RED}${fail_c}${_RST}${_DIM}${_GRAY} failed${_RST}"
    tui_line "$hdr" "$row"; row=$((row + 1))

    # Adaptive layout: shrink node_w and spine_gap to fit any parent count
    local node_w=3 conn_w=1 ret_w=1
    local draw_w=$((TERM_COLS - 4))

    if [ "$_tm_pcount" -gt 1 ]; then
        # Try node_w=5 first, then 3, then 1 — pick largest that fits
        local _fit=false
        for _try_nw in 3 1; do
            local _min_total=$(( _tm_pcount * _try_nw + (_tm_pcount - 1) * (conn_w + ret_w + 1) ))
            if [ "$_min_total" -le "$draw_w" ]; then
                node_w=$_try_nw
                _fit=true
                break
            fi
        done
        if [ "$_fit" = false ]; then
            node_w=1
        fi
    fi

    local spine_gap=3
    if [ "$_tm_pcount" -gt 1 ]; then
        spine_gap=$(( (draw_w - _tm_pcount * node_w - (_tm_pcount - 1) * (conn_w + ret_w)) / (_tm_pcount - 1) ))
        [ "$spine_gap" -gt 10 ] && spine_gap=10
        [ "$spine_gap" -lt 1 ] && spine_gap=1
    fi

    # Color helpers
    # completed=bold white, running=model color (pulsates), failed=bold red, pending=dim gray
    # _tm_nc takes state + optional model for running color
    _tm_model_color() {
        case "$1" in
            claude-opus-4.6)    echo "${_YELLOW}" ;;
            claude-sonnet-4.5)  echo "${_CYAN}" ;;
            *)                  echo "${_CYAN}" ;;
        esac
    }
    _tm_nc() {
        local st="$1" model="${2:-}"
        case "$st" in
            completed) echo "${_BOLD}${_WHITE}" ;;
            running)
                local mc; mc=$(_tm_model_color "$model")
                if [ $((TUI_FRAME%2)) -eq 0 ]; then echo "${_BOLD}${mc}"; else echo "${_DIM}${mc}"; fi ;;
            failed) echo "${_BOLD}${_RED}" ;;
            *) echo "${_DIM}${_GRAY}" ;;
        esac
    }
    _tm_dc() {
        local st="$1" model="${2:-}"
        case "$st" in
            completed) echo "${_BOLD}${_WHITE}" ;;
            running) local mc; mc=$(_tm_model_color "$model"); echo "${_DIM}${mc}" ;;
            failed) echo "${_DIM}${_RED}" ;;
            *) echo "${_DIM}${_GRAY}" ;;
        esac
    }
    _tm_sym() { case "$1" in completed) echo "●";; running) if [ $((TUI_FRAME%2)) -eq 0 ]; then echo "◉"; else echo "●"; fi;; failed) echo "✗";; *) echo "○";; esac; }

    _tm_parent_state() {
        local pp="$1"
        IFS=',' read -ra _s <<< "${_tm_parent_subs[$pp]}"
        local worst="completed"
        for _sid in "${_s[@]}"; do
            local _st; _st=$(tui_get_task_state "$_sid")
            case "$_st" in
                failed) worst="failed"; break ;;
                pending) [ "$worst" != "failed" ] && worst="pending" ;;
                running) [ "$worst" = "completed" ] && worst="running" ;;
            esac
        done
        echo "$worst"
    }

    _tm_render_node() {
        local st="$1" model="${2:-}"
        local nc; nc=$(_tm_nc "$st" "$model")
        local sym; sym=$(_tm_sym "$st")
        local lpad=$(( (node_w - 1) / 2 ))
        local rpad=$((node_w - 1 - lpad))
        local ls=""; for ((z=0; z<lpad; z++)); do ls+=" "; done
        local rs=""; for ((z=0; z<rpad; z++)); do rs+=" "; done
        echo "${ls}${nc}${sym}\033[0m${rs}"
    }

    _tm_render_empty() {
        local pad=""; for ((z=0; z<node_w; z++)); do pad+=" "; done
        echo "$pad"
    }

    _tm_render_vert() {
        local color="$1"
        local lpad=$(( (node_w - 1) / 2 ))
        local rpad=$((node_w - 1 - lpad))
        local ls=""; for ((z=0; z<lpad; z++)); do ls+=" "; done
        local rs=""; for ((z=0; z<rpad; z++)); do rs+=" "; done
        echo "${ls}${color}│\033[0m${rs}"
    }

    # Parent labels row
    local lbl_line="  "
    for ((pp=0; pp<_tm_pcount; pp++)); do
        local p="${_tm_parents[$pp]}"
        local pst; pst=$(_tm_parent_state "$pp")
        local lc; lc=$(_tm_nc "$pst")
        local lpad=$(( (node_w - ${#p}) / 2 ))
        local rpad=$((node_w - ${#p} - lpad))
        local ls=""; for ((z=0; z<lpad; z++)); do ls+=" "; done
        local rs=""; for ((z=0; z<rpad; z++)); do rs+=" "; done
        lbl_line+="${ls}${lc}${p}\033[0m${rs}"
        if [ "$pp" -lt $((_tm_pcount - 1)) ]; then
            local pad_total=$((conn_w + ret_w + spine_gap))
            local pad=""; for ((z=0; z<pad_total; z++)); do pad+=" "; done
            lbl_line+="${pad}"
        fi
    done
    tui_line "$lbl_line" "$row"; row=$((row + 1))

    # ── SPINE ROW (first subtask of each parent) ──
    local line="  "
    for ((pp=0; pp<_tm_pcount; pp++)); do
        IFS=',' read -ra _s <<< "${_tm_parent_subs[$pp]}"
        local sc=${#_s[@]}
        local tid="${_s[0]}"
        local st; st=$(tui_get_task_state "$tid")
        local tmodel; tmodel=$(tui_get_task_model "$tid")
        line+=$(_tm_render_node "$st" "$tmodel")

        if [ "$pp" -lt $((_tm_pcount - 1)) ]; then
            local pst; pst=$(_tm_parent_state "$pp")
            local pdc; pdc=$(_tm_dc "$pst")
            local fch="─"
            [ "$pst" != "completed" ] && [ "$pst" != "running" ] && [ "$pst" != "failed" ] && fch="·"

            local conn=""; for ((z=0; z<conn_w; z++)); do conn+="${fch}"; done
            line+="${pdc}${conn}\033[0m"

            if [ "$sc" -gt 1 ]; then
                line+="${pdc}┬\033[0m"
            else
                line+="${pdc}${fch}\033[0m"
            fi

            local sgap=""; for ((z=0; z<spine_gap; z++)); do sgap+="${fch}"; done
            line+="${pdc}${sgap}\033[0m"
        fi
    done
    tui_line "$line" "$row"; row=$((row + 1))

    # ── SUBTASK ROWS (2 rows per subtask: vertical connector + node) ──
    local avail_sub_rows=$(( (max_rows - 4) / 2 ))  # header + labels + spine + legend; 2 rows per sub
    [ "$avail_sub_rows" -lt 1 ] && avail_sub_rows=1
    local render_subs=$_tm_max_subs
    [ "$render_subs" -gt $((avail_sub_rows + 1)) ] && render_subs=$((avail_sub_rows + 1))

    for ((si=1; si<render_subs; si++)); do
        [ "$row" -ge $((start_row + max_rows - 1)) ] && break

        # Row A: vertical connectors between previous node and this node
        local line="  "
        for ((pp=0; pp<_tm_pcount; pp++)); do
            IFS=',' read -ra _s <<< "${_tm_parent_subs[$pp]}"
            local sc=${#_s[@]}

            if [ "$si" -lt "$sc" ]; then
                local prev_tid="${_s[$((si-1))]}"
                local prev_st; prev_st=$(tui_get_task_state "$prev_tid")
                local prev_model; prev_model=$(tui_get_task_model "$prev_tid")
                local dc; dc=$(_tm_dc "$prev_st" "$prev_model")
                line+=$(_tm_render_vert "$dc")
            else
                line+=$(_tm_render_empty)
            fi

            if [ "$pp" -lt $((_tm_pcount - 1)) ]; then
                local cpad=""; for ((z=0; z<conn_w; z++)); do cpad+=" "; done
                line+="${cpad}"

                if [ "$sc" -gt 1 ] && [ "$si" -lt "$sc" ]; then
                    local pst; pst=$(_tm_parent_state "$pp")
                    local pdc; pdc=$(_tm_dc "$pst")
                    line+="${pdc}│\033[0m"
                else
                    line+=" "
                fi

                local spad=""; for ((z=0; z<spine_gap; z++)); do spad+=" "; done
                line+="${spad}"
            fi
        done
        tui_line "$line" "$row"; row=$((row + 1))
        [ "$row" -ge $((start_row + max_rows - 1)) ] && break

        # Row B: nodes + horizontal connection to return lane
        line="  "
        for ((pp=0; pp<_tm_pcount; pp++)); do
            IFS=',' read -ra _s <<< "${_tm_parent_subs[$pp]}"
            local sc=${#_s[@]}

            if [ "$si" -lt "$sc" ]; then
                local tid="${_s[$si]}"
                local st; st=$(tui_get_task_state "$tid")
                local tmodel; tmodel=$(tui_get_task_model "$tid")
                local dc; dc=$(_tm_dc "$st" "$tmodel")
                line+=$(_tm_render_node "$st" "$tmodel")

                if [ "$pp" -lt $((_tm_pcount - 1)) ]; then
                    local fch="─"
                    [ "$st" != "completed" ] && [ "$st" != "running" ] && [ "$st" != "failed" ] && fch="·"

                    local conn=""; for ((z=0; z<conn_w; z++)); do conn+="${fch}"; done
                    line+="${dc}${conn}\033[0m"

                    if [ "$((si + 1))" -lt "$sc" ]; then
                        line+="${dc}┤\033[0m"
                    else
                        line+="${dc}╯\033[0m"
                    fi

                    local spad=""; for ((z=0; z<spine_gap; z++)); do spad+=" "; done
                    line+="${spad}"
                fi
            else
                line+=$(_tm_render_empty)
                if [ "$pp" -lt $((_tm_pcount - 1)) ]; then
                    local cpad=""; for ((z=0; z<conn_w; z++)); do cpad+=" "; done
                    line+="${cpad} "
                    local spad=""; for ((z=0; z<spine_gap; z++)); do spad+=" "; done
                    line+="${spad}"
                fi
            fi
        done
        tui_line "$line" "$row"; row=$((row + 1))
    done

    # Legend
    local legend="  ${_BOLD}${_WHITE}  ●  ${_RST}${_DIM}${_GRAY}done  ${_RST}${_BOLD}${_CYAN}  ◉  ${_RST}${_DIM}${_GRAY}active  ${_RST}${_DIM}${_GRAY}  ○  pending  ${_RST}${_BOLD}${_RED}  ✗  ${_RST}${_DIM}${_GRAY}failed${_RST}"
    tui_line "$legend" "$row"; row=$((row + 1))

    # Clear remaining
    while [ "$row" -lt $((start_row + max_rows)) ]; do
        tui_line "" "$row"; row=$((row + 1))
    done

    TUI_RETURN_ROW=$row
}

# ─── Workers Panel (with selection highlight) ─────────────────

tui_render_workers() {
    local start_row="$1" max_rows="${2:-6}"
    local row="$start_row"

    tui_line "  ${_BOLD}${_WHITE}ACTIVE WORKERS${_RST}  ${_DIM}${_LGRAY}(${TUI_RUNNING}/${TUI_WORKER_SLOTS} worker slots, ${TUI_REVIEW_RESERVED} reserved for review)${_RST}" "$row"
    row=$((row + 1))

    tui_auto_select

    local found=0 widx=0
    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        [ "$row" -ge $((start_row + max_rows)) ] && break
        if [ "${TUI_TASK_STATES[$i]}" = "running" ]; then
            local tid="${TUI_TASK_IDS[$i]}"
            local desc="${TUI_TASK_DESCS[$i]}"
            local wmodel="${TUI_TASK_MODELS[$i]:-}"
            local wmbadge=""
            [ -n "$wmodel" ] && wmbadge=" $(tui_model_badge "$wmodel")"
            desc="${desc:0:$((TERM_COLS - 35))}"
            if [ "$tid" = "$TUI_SELECTED_TASK" ]; then
                tui_line "    ${_CYAN}▸${_RST} ${_BOLD}${_CYAN}${tid}${_RST}${wmbadge} ${_DIM}${desc}${_RST}" "$row"
            else
                tui_line "      ${_BOLD}${tid}${_RST}${wmbadge} ${_DIM}${desc}${_RST}" "$row"
            fi
            row=$((row + 1))
            found=$((found + 1))
            widx=$((widx + 1))
        fi
    done

    if [ "$found" -eq 0 ]; then
        local phase_msg=""
        case "$TUI_PHASE" in
            syncing)    phase_msg="▸ syncing results to main..." ;;
            merging)    phase_msg="▸ merging wave results..." ;;
            reviewing)  phase_msg="▸ 🔍 quality review in progress..." ;;
            waiting)    phase_msg="▸ preparing next wave..." ;;
            done)       phase_msg="  all workers finished" ;;
            *)          phase_msg="  idle" ;;
        esac
        tui_line "    ${_DIM}${_GRAY}${phase_msg}${_RST}" "$row"
        row=$((row + 1))
    fi

    while [ "$row" -lt $((start_row + max_rows)) ]; do
        tui_line "" "$row"; row=$((row + 1))
    done
    TUI_RETURN_ROW=$row
}

# ─── Activity Log Panel ──────────────────────────────────────

tui_render_log() {
    local start_row="$1" max_rows="${2:-$TUI_MAX_LOG}"
    local row="$start_row"

    tui_line "  ${_BOLD}${_WHITE}ACTIVITY${_RST}" "$row"
    row=$((row + 1))

    local count=${#TUI_LOG_LINES[@]} start_idx=0
    [ "$count" -gt "$((max_rows - 1))" ] && start_idx=$((count - max_rows + 1))

    for ((i=start_idx; i<count; i++)); do
        [ "$row" -ge $((start_row + max_rows)) ] && break
        tui_line "    ${_LGRAY}${TUI_LOG_LINES[$i]}${_RST}" "$row"
        row=$((row + 1))
    done

    while [ "$row" -lt $((start_row + max_rows)) ]; do
        tui_line "" "$row"; row=$((row + 1))
    done
    TUI_RETURN_ROW=$row
}

# ─── Main Render ──────────────────────────────────────────────

tui_render() {
    [ "$TUI_ACTIVE" != true ] && return
    local _prev_opts; _prev_opts=$(set +o); set +eu

    # Safety: if a previous render crashed mid-frame, tui_line/tui_hr may
    # still be the buffer overrides (writing to a dead $_buf). Restore the
    # real implementations before doing anything else.
    unset -f tui_line tui_hr 2>/dev/null || true
    tui_line() {
        local content="$1" row="$2"
        tui_goto "$row" 1
        printf '%b' "$content"
        tui_clreol
    }
    tui_hr() {
        local row="$1" char="${2:-─}" style="${3:-$_DIM$_GRAY}"
        tui_goto "$row" 1
        printf '%b' "$style"
        printf '%*s' "$TERM_COLS" '' | tr ' ' "$char"
        printf '%b' "$_RST"
    }

    # Throttle: max 1 render per second to avoid flicker
    local now
    now=$(date +%s)
    if [ $((now - TUI_LAST_RENDER)) -lt 1 ]; then
        eval "$_prev_opts" 2>/dev/null; return
    fi
    TUI_LAST_RENDER=$now

    TUI_FRAME=$((TUI_FRAME + 1))
    tui_update_size

    # Buffer the entire frame to reduce flicker — one big write instead of many small ones
    local _buf=""
    _tui_buf_line() { _buf+="$(printf '\033[%d;1H' "$2")$(printf '%b' "$1")$(printf '\033[K')"; }
    _tui_buf_hr() {
        local r="$1" ch="${2:-─}" st="${3:-$_DIM$_GRAY}"
        _buf+="$(printf '\033[%d;1H' "$r")$(printf '%b' "$st")$(printf '%*s' "$TERM_COLS" '' | tr ' ' "$ch")$(printf '%b' "$_RST")"
    }

    # Temporarily override tui_line and tui_hr to buffer
    local _orig_line_fn=true _orig_hr_fn=true
    tui_line() { _tui_buf_line "$1" "$2"; }
    tui_hr() { _tui_buf_hr "$1" "${2:-─}" "${3:-$_DIM$_GRAY}"; }

    # Layout budget
    local header_rows=4
    local progress_rows=3
    local workers_rows=$((TUI_WORKER_SLOTS + 2))
    [ "$workers_rows" -lt 4 ] && workers_rows=4
    local worker_output_rows=12
    local activity_rows=6
    local sep_count=6  # separators between sections (added 1 for task map)
    local footer_rows=1

    # Task map height: v9 return-lane layout uses 2 rows per subtask
    # (vertical connector + node row) plus spine + labels + header + legend
    local _tm_max_per_parent=1
    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        local _tmp="${TUI_TASK_IDS[$i]%%.*}"
        local _tmc=0
        for ((j=0; j<${#TUI_TASK_IDS[@]}; j++)); do
            [ "${TUI_TASK_IDS[$j]%%.*}" = "$_tmp" ] && _tmc=$((_tmc + 1))
        done
        [ "$_tmc" -gt "$_tm_max_per_parent" ] && _tm_max_per_parent=$_tmc
    done
    # rows = header(1) + labels(1) + spine(1) + (max_subs-1)*2 connector+node rows + legend(1)
    local task_map_rows=$(( 4 + (_tm_max_per_parent - 1) * 2 ))
    [ "$task_map_rows" -lt 5 ] && task_map_rows=5
    [ "$task_map_rows" -gt 16 ] && task_map_rows=16

    local fixed=$((header_rows + progress_rows + task_map_rows + workers_rows + worker_output_rows + activity_rows + sep_count + footer_rows + 2))
    local dag_rows=$((TERM_ROWS - fixed))
    [ "$dag_rows" -lt 5 ] && dag_rows=5

    local row=1

    # Header
    tui_line "" "$row"; row=$((row + 1))
    tui_line "  ${_BOLD}${_WHITE}BOB THE BUILDER${_RST} ${_DIM}concurrent task orchestrator${_RST}" "$row"; row=$((row + 1))
    tui_line "  ${_DIM}${_LGRAY}spec ${_RST}${_WHITE}${TUI_SPEC_NAME}${_RST}${_DIM}${_LGRAY}  mode ${_RST}${_WHITE}${TUI_MODE}${_RST}${_DIM}${_LGRAY}  workers ${_RST}${_WHITE}${TUI_WORKER_SLOTS}${_RST}${_DIM}${_LGRAY}+${_RST}${_WHITE}${TUI_REVIEW_RESERVED}${_RST}${_DIM}${_LGRAY}r  review ${_RST}${_WHITE}${TUI_REVIEW_STATUS:-on}${_RST}" "$row"; row=$((row + 1))

    # Progress
    tui_line "" "$row"; row=$((row + 1))
    tui_render_progress "$row"; row=$((row + 1))
    tui_line "" "$row"; row=$((row + 1))

    tui_hr "$row"; row=$((row + 1))

    # DAG
    tui_line "  ${_BOLD}${_WHITE}EXECUTION GRAPH${_RST}  ${_DIM}${_GRAY}wave ${TUI_CURRENT_WAVE}/${TUI_TOTAL_WAVES}${_RST}" "$row"; row=$((row + 1))
    tui_render_dag "$row" "$dag_rows"; row=$TUI_RETURN_ROW

    tui_hr "$row"; row=$((row + 1))

    # Task Map
    tui_render_task_map "$row" "$task_map_rows"; row=$TUI_RETURN_ROW

    tui_hr "$row"; row=$((row + 1))

    # Workers
    tui_render_workers "$row" "$workers_rows"; row=$TUI_RETURN_ROW

    tui_hr "$row"; row=$((row + 1))

    # Worker Output
    tui_render_worker_output "$row" "$worker_output_rows"; row=$TUI_RETURN_ROW

    tui_hr "$row"; row=$((row + 1))

    # Activity
    tui_render_log "$row" "$activity_rows"; row=$TUI_RETURN_ROW

    # Clear leftover
    while [ "$row" -lt "$TERM_ROWS" ]; do
        tui_line "" "$row"; row=$((row + 1))
    done

    # Footer
    _buf+="$(printf '\033[%d;1H' "$TERM_ROWS")$(printf '%b' "  ${_DIM}${_GRAY}↑↓ select worker  ctrl-c abort${_RST}")$(printf '\033[K')"

    # Restore real tui_line / tui_hr — unset removes the override AND the original,
    # so we must redefine them explicitly.
    unset -f tui_line tui_hr 2>/dev/null || true
    tui_line() {
        local content="$1" row="$2"
        tui_goto "$row" 1
        printf '%b' "$content"
        tui_clreol
    }
    tui_hr() {
        local row="$1" char="${2:-─}" style="${3:-$_DIM$_GRAY}"
        tui_goto "$row" 1
        printf '%b' "$style"
        printf '%*s' "$TERM_COLS" '' | tr ' ' "$char"
        printf '%b' "$_RST"
    }

    # Flush entire frame in one write
    printf '%s' "$_buf"
    eval "$_prev_opts" 2>/dev/null
}

# ─── Load DAG ────────────────────────────────────────────────

tui_load_dag() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    local dag_json="$1" task_file="$2"

    TUI_WAVE_IDS=(); TUI_WAVE_TASKS=()
    TUI_TASK_IDS=(); TUI_TASK_DESCS=(); TUI_TASK_STATES=()
    TUI_TASK_WAVES=(); TUI_TASK_DEPS=(); TUI_TASK_LOGS=()
    TUI_TASK_MODELS=()

    eval "$(echo "$dag_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
waves = data.get('waves', [])
wave_ids, wave_tasks, task_ids, task_descs, task_waves, task_deps, task_models = [], [], [], [], [], [], []
for wave in waves:
    wid = wave['id']
    wave_ids.append(str(wid))
    tids = []
    for task in wave['tasks']:
        tid = task['id']
        tids.append(tid)
        task_ids.append(tid)
        desc = task.get('description', '').replace(\"'\", \"'\\\\''\")
        task_descs.append(desc)
        task_waves.append(str(wid))
        task_deps.append(','.join(task.get('dependencies', [])))
        task_models.append(task.get('model', 'claude-sonnet-4.5'))
    wave_tasks.append(','.join(tids))
print('TUI_WAVE_IDS=(' + ' '.join(f'\"{x}\"' for x in wave_ids) + ')')
print('TUI_WAVE_TASKS=(' + ' '.join(f'\"{x}\"' for x in wave_tasks) + ')')
print('TUI_TASK_IDS=(' + ' '.join(f'\"{x}\"' for x in task_ids) + ')')
print('TUI_TASK_DESCS=(' + ' '.join(f\"'{x}'\" for x in task_descs) + ')')
print('TUI_TASK_WAVES=(' + ' '.join(f'\"{x}\"' for x in task_waves) + ')')
print('TUI_TASK_DEPS=(' + ' '.join(f'\"{x}\"' for x in task_deps) + ')')
print('TUI_TASK_MODELS=(' + ' '.join(f'\"{x}\"' for x in task_models) + ')')
print(f'TUI_TOTAL_WAVES={len(waves)}')
print(f'TUI_TOTAL_TASKS={len(task_ids)}')
" 2>&1)" || true

    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        TUI_TASK_LOGS+=("")
    done

    # Batch-check completion for ALL tasks in a single python3 call
    # instead of spawning one python3 per task (which is 100x slower)
    local _completed_set=""
    if [ "${#TUI_TASK_IDS[@]}" -gt 0 ]; then
        _completed_set=$(python3 - "$task_file" "${TUI_TASK_IDS[@]}" <<'PYEOF'
import re, sys

task_file = sys.argv[1]
task_ids = sys.argv[2:]

with open(task_file) as f:
    lines = f.readlines()

completed = set()
for tid in task_ids:
    pattern = re.compile(r'\[x\]\s+' + re.escape(tid) + r'(?:\.?\s)')
    for line in lines:
        m = pattern.search(line)
        if m:
            prefix = line[:m.start()]
            stripped = prefix.rstrip()
            if stripped and stripped[-1].isdigit():
                continue
            completed.add(tid)
            break

for tid in task_ids:
    print("completed" if tid in completed else "pending")
PYEOF
) || true
    fi

    # Parse the batch result into TUI_TASK_STATES
    local _idx=0
    while IFS= read -r _state; do
        TUI_TASK_STATES+=("$_state")
        _idx=$((_idx + 1))
    done <<< "$_completed_set"

    # Fill any missing states (if python failed)
    while [ "${#TUI_TASK_STATES[@]}" -lt "${#TUI_TASK_IDS[@]}" ]; do
        TUI_TASK_STATES+=("pending")
    done

    eval "$_prev_opts" 2>/dev/null
}

# ─── State Helpers ────────────────────────────────────────────

tui_set_task_state() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    local tid="$1" new_state="$2"
    for ((i=0; i<${#TUI_TASK_IDS[@]}; i++)); do
        [ "${TUI_TASK_IDS[$i]}" = "$tid" ] && { TUI_TASK_STATES[$i]="$new_state"; eval "$_prev_opts" 2>/dev/null; return; }
    done
    eval "$_prev_opts" 2>/dev/null
}

tui_update_counts() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    TUI_RUNNING=0; TUI_COMPLETED=0; TUI_FAILED=0
    for ((i=0; i<${#TUI_TASK_STATES[@]}; i++)); do
        case "${TUI_TASK_STATES[$i]}" in
            running) TUI_RUNNING=$((TUI_RUNNING + 1)) ;;
            completed) TUI_COMPLETED=$((TUI_COMPLETED + 1)) ;;
            failed) TUI_FAILED=$((TUI_FAILED + 1)) ;;
        esac
    done
    eval "$_prev_opts" 2>/dev/null
}

tui_event() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    tui_log "$1"
    tui_update_counts
    tui_render
    eval "$_prev_opts" 2>/dev/null
}

# ─── Summary ─────────────────────────────────────────────────

tui_print_summary() {
    local _prev_opts; _prev_opts=$(set +o); set +eu
    local completed="$TUI_COMPLETED" total="$TUI_TOTAL_TASKS" failed="$TUI_FAILED"
    local elapsed_str
    elapsed_str=$(tui_format_time "$TUI_ELAPSED")
    echo ""
    echo -e "  ${_BOLD}${_WHITE}BOB THE BUILDER${_RST} ${_DIM}run complete${_RST}"
    echo ""
    echo -e "  ${_DIM}tasks${_RST}  ${completed}/${total} completed"
    [ "$failed" -gt 0 ] && echo -e "  ${_DIM}failed${_RST} ${_RED}${failed}${_RST}"
    [ "${TUI_SKIPPED:-0}" -gt 0 ] && echo -e "  ${_DIM}skipped${_RST} ${_YELLOW}${TUI_SKIPPED}${_RST}"
    echo -e "  ${_DIM}waves${_RST}  ${TUI_TOTAL_WAVES}"
    echo -e "  ${_DIM}time${_RST}   ${elapsed_str}"
    echo -e "  ${_DIM}review${_RST} ${TUI_REVIEW_PASSES:-0} passed, ${TUI_REVIEW_FIXES:-0} fix cycles"
    echo -e "  ${_DIM}logs${_RST}   ${LOG_DIR:-".ralph-logs"}/"
    echo ""
    if [ "$completed" -eq "$total" ] && [ "$failed" -eq 0 ]; then
        echo -e "  ${_BOLD}${_WHITE}all tasks completed${_RST}"
    elif [ "$failed" -gt 0 ]; then
        echo -e "  ${_RED}some tasks failed${_RST}"
    else
        echo -e "  ${_YELLOW}incomplete${_RST}"
    fi
    echo ""
    eval "$_prev_opts" 2>/dev/null
}
