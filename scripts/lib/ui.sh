#!/bin/bash
# Shared terminal UI, semantic logging, TUI (whiptail/dialog), and GNU screen
# storage/session helpers for ubuntu-vanilla-build.

# Color auto-disables per stream when not a TTY, TERM=dumb, or NO_COLOR is set.
UI_USE_COLOR_OUT=0
UI_USE_COLOR_ERR=0
if [[ "${TERM:-}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    [[ -t 1 ]] && UI_USE_COLOR_OUT=1
    [[ -t 2 ]] && UI_USE_COLOR_ERR=1
fi
UI_USE_COLOR="$UI_USE_COLOR_OUT"

# Unicode symbols with clean ASCII fallbacks for dumb/non-UTF-8 terminals.
UI_SYM_OK="[OK]"
UI_SYM_WARN="[WARN]"
UI_SYM_ERR="[ERROR]"
UI_SYM_INFO="info"
UI_SYM_PTR=">"
UI_RULE_CHAR="-"
UI_BANNER_CHAR="="
if [[ "${TERM:-}" != "dumb" ]] && [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]]; then
    UI_SYM_OK="✓"
    UI_SYM_WARN="!"
    UI_SYM_ERR="✗"
    UI_SYM_INFO="•"
    UI_SYM_PTR="›"
    UI_RULE_CHAR="─"
    UI_BANNER_CHAR="═"
fi

# Prompting policy: interactive prompts run when stdin is a TTY, or when forced
# via --interactive / INTERACTIVE=1. --no-interactive redirects stdin from /dev/null.
FORCE_INTERACTIVE="${FORCE_INTERACTIVE:-0}"
UVB_UI_MODE="${UVB_UI_MODE:-}" # cli | tui
UI_REPLY=""

function ui_disable_color() {
    export NO_COLOR=1
    UI_USE_COLOR=0
    UI_USE_COLOR_OUT=0
    UI_USE_COLOR_ERR=0
}

function prompts_enabled() {
    [[ "${FORCE_INTERACTIVE:-0}" == "1" ]] || [[ -t 0 ]]
}

function _ui_c_out() {
    if [[ "${UI_USE_COLOR_OUT:-0}" -eq 1 ]]; then
        printf '\033[%sm' "$1"
    fi
}

function _ui_r_out() {
    if [[ "${UI_USE_COLOR_OUT:-0}" -eq 1 ]]; then
        printf '\033[0m'
    fi
}

function _ui_c_err() {
    if [[ "${UI_USE_COLOR_ERR:-0}" -eq 1 ]]; then
        printf '\033[%sm' "$1"
    fi
}

function _ui_r_err() {
    if [[ "${UI_USE_COLOR_ERR:-0}" -eq 1 ]]; then
        printf '\033[0m'
    fi
}

function _ui_term_cols() {
    local cols="${COLUMNS:-}"
    if [[ ! "$cols" =~ ^[0-9]+$ ]] && command -v tput >/dev/null 2>&1 && [[ -t 1 || -t 2 ]]; then
        cols="$(tput cols 2>/dev/null || true)"
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    echo "$cols"
}

function _ui_term_lines() {
    local lines="${LINES:-}"
    if [[ ! "$lines" =~ ^[0-9]+$ ]] && command -v tput >/dev/null 2>&1 && [[ -t 1 || -t 2 ]]; then
        lines="$(tput lines 2>/dev/null || true)"
    fi
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
    echo "$lines"
}

function _ui_rule_width() {
    local cols
    cols="$(_ui_term_cols)"
    local w=$(( cols - 2 ))
    (( w > 70 )) && w=70
    (( w < 44 )) && w=44
    echo "$w"
}

function _ui_repeat_char() {
    local ch="$1" count="$2" out=""
    local i
    for (( i=0; i<count; i++ )); do
        out+="$ch"
    done
    printf '%s\n' "$out"
}

function ui_banner() {
    local title="$1"
    local width
    width="$(_ui_rule_width)"
    printf '\n'
    _ui_c_out '1;36'
    _ui_repeat_char "$UI_BANNER_CHAR" "$width"
    _ui_r_out
    _ui_c_out '1'
    printf '  %s\n' "$title"
    _ui_r_out
    _ui_c_out '1;36'
    _ui_repeat_char "$UI_BANNER_CHAR" "$width"
    _ui_r_out
    printf '\n'
}

function ui_heading() {
    local title="$1"
    printf '\n'
    _ui_c_out '1;36'
    printf '%s %s\n' "${UI_RULE_CHAR}${UI_RULE_CHAR}" "$title"
    _ui_r_out
}

function ui_step() {
    local n="$1" total="$2" name="$3"
    printf '\n'
    _ui_c_out '1;36'
    printf '[%d/%d]' "$n" "$total"
    _ui_r_out
    _ui_c_out '1'
    printf ' %s\n' "$name"
    _ui_r_out
}

function ui_ok()   { _ui_c_out '1;32'; printf '  %s  ' "$UI_SYM_OK"; _ui_r_out; printf '%s\n' "$1"; }
# Color escapes and text go to the same stream so stderr redirection never leaks escapes.
function ui_warn() { { _ui_c_err '1;33'; printf '  %s  ' "$UI_SYM_WARN"; _ui_r_err; printf '%s\n' "$1"; } >&2; }
function ui_err()  { { _ui_c_err '1;31'; printf '  %s  ' "$UI_SYM_ERR"; _ui_r_err; printf '%s\n' "$1"; } >&2; }
function ui_info() { _ui_c_out '36'; printf '  %s  ' "$UI_SYM_INFO"; _ui_r_out; printf '%s\n' "$1"; }

function ui_kv() {
    _ui_c_out '2'
    printf '    %-22s ' "$1"
    _ui_r_out
    printf '%s\n' "$2"
}

function tui_tool() {
    if command -v whiptail >/dev/null 2>&1; then
        echo "whiptail"
    elif command -v dialog >/dev/null 2>&1; then
        echo "dialog"
    else
        echo ""
    fi
}

function tui_available() {
    [[ -n "$(tui_tool)" ]] && [[ -t 0 ]] && [[ -t 1 ]]
}

function is_tui_mode() {
    [[ "${UVB_UI_MODE:-cli}" == "tui" ]] && [[ -n "$(tui_tool)" ]]
}

function _tui_box_dims() {
    local desired_h="$1" desired_w="$2"
    local rows cols
    rows="$(_ui_term_lines)"
    cols="$(_ui_term_cols)"
    local max_h=$(( rows - 2 ))
    local max_w=$(( cols - 4 ))
    (( max_h < 10 )) && max_h=10
    (( max_w < 44 )) && max_w=44
    local h="$desired_h" w="$desired_w"
    (( h > max_h )) && h="$max_h"
    (( w > max_w )) && w="$max_w"
    printf '%d %d\n' "$h" "$w"
}

function normalize_ui_mode() {
    local m="${UVB_UI_MODE:-cli}"
    m="${m,,}"
    case "$m" in
        ""|cli|text)
            export UVB_UI_MODE="cli"
            ;;
        tui|whiptail|dialog)
            if [[ -z "$(tui_tool)" ]]; then
                ui_warn "TUI requested (--ui=tui) but neither whiptail nor dialog is installed; falling back to CLI mode."
                export UVB_UI_MODE="cli"
            else
                export UVB_UI_MODE="tui"
            fi
            ;;
        *)
            ui_err "Invalid UI mode '${UVB_UI_MODE:-}'. Use --ui=cli or --ui=tui."
            exit 1
            ;;
    esac
}

function resolve_ui_mode() {
    if [[ -n "${UVB_UI_MODE:-}" ]]; then
        normalize_ui_mode
        return 0
    fi
    if ! prompts_enabled || ! tui_available; then
        export UVB_UI_MODE="cli"
        return 0
    fi

    ui_heading "Interface mode"
    _ui_c_out '1;32'; printf '  %s 1) ' "$UI_SYM_PTR"; _ui_r_out
    printf '%-6s %s ' "CLI" "Clean terminal prompts"
    _ui_c_out '32'; printf '[default]\n'; _ui_r_out
    printf '    2) %-6s %s\n' "TUI" "Interactive $(tui_tool) menu dialogs"

    local choice
    while true; do
        read -r -p "  Interface [1/2, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|c|cli|text)   export UVB_UI_MODE="cli"; break ;;
            2|t|tui|dialog)    export UVB_UI_MODE="tui"; break ;;
            *) ui_warn "Invalid selection '$choice' -- enter 1 (cli) or 2 (tui)." ;;
        esac
    done
    ui_ok "Interface: $UVB_UI_MODE"
}

# ui_confirm "Prompt" [y|n]  -- default is "y" if omitted. Returns 0 for yes, 1 for no.
function ui_confirm() {
    local prompt="${1:-Proceed?}"
    local default="${2:-y}"
    if is_tui_mode; then
        local tool h w
        tool="$(tui_tool)"
        read -r h w < <(_tui_box_dims 10 72)
        local -a args=(--title "Confirmation")
        if [[ "$default" == "n" ]]; then
            args+=(--defaultno)
        fi
        "$tool" "${args[@]}" --yesno "$prompt" "$h" "$w"
        return $?
    fi

    local hint yn
    if [[ "$default" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
    while true; do
        read -r -p "  ${prompt} ${hint}: " yn
        yn="${yn,,}"
        [[ -z "$yn" ]] && yn="$default"
        case "$yn" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     ui_warn "Please answer 'y' or 'n'." ;;
        esac
    done
}

# ui_input TITLE PROMPT [DEFAULT]  -- sets UI_REPLY.
function ui_input() {
    local title="$1" prompt="$2" default="${3:-}"
    if is_tui_mode; then
        local tool val rc=0 h w
        tool="$(tui_tool)"
        read -r h w < <(_tui_box_dims 11 74)
        val="$("$tool" --title "$title" --inputbox "$prompt" "$h" "$w" "$default" 3>&1 1>&2 2>&3)" || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            ui_err "Input cancelled at '${title}'."
            exit 130
        fi
        UI_REPLY="${val:-$default}"
        return 0
    fi

    local val=""
    if [[ -n "$default" ]]; then
        read -r -p "  ${prompt} [${default}]: " val
        UI_REPLY="${val:-$default}"
    else
        read -r -p "  ${prompt}: " val
        UI_REPLY="$val"
    fi
}

# ui_password TITLE PROMPT  -- sets UI_REPLY (non-empty, confirmed).
function ui_password() {
    local title="$1" prompt="$2"
    local p1="" p2="" tool rc h w
    if is_tui_mode; then
        tool="$(tui_tool)"
        read -r h w < <(_tui_box_dims 10 72)
        while true; do
            rc=0
            p1="$("$tool" --title "$title" --passwordbox "$prompt" "$h" "$w" 3>&1 1>&2 2>&3)" || rc=$?
            [[ "$rc" -ne 0 ]] && { ui_err "Password input cancelled."; exit 130; }
            rc=0
            p2="$("$tool" --title "$title" --passwordbox "Confirm ${prompt}" "$h" "$w" 3>&1 1>&2 2>&3)" || rc=$?
            [[ "$rc" -ne 0 ]] && { ui_err "Password confirmation cancelled."; exit 130; }
            if [[ -n "$p1" && "$p1" == "$p2" ]]; then
                UI_REPLY="$p1"
                return 0
            fi
            "$tool" --title "$title" --msgbox "Passwords are empty or do not match. Try again." 8 60
        done
    fi

    while true; do
        read -r -s -p "  ${prompt} (input hidden): " p1; echo
        read -r -s -p "  Confirm ${prompt}: " p2; echo
        if [[ -n "$p1" && "$p1" == "$p2" ]]; then
            UI_REPLY="$p1"
            return 0
        fi
        ui_warn "Passwords are empty or do not match -- try again."
    done
}

# ui_menu TITLE PROMPT DEFAULT_TAG TAG1 DESC1 [TAG2 DESC2 ...]  -- sets UI_REPLY to selected TAG.
function ui_menu() {
    local title="$1" prompt="$2" default_tag="$3"
    shift 3
    if (( $# == 0 || $# % 2 != 0 )); then
        ui_err "Internal error: ui_menu requires tag/description pairs."
        exit 1
    fi

    if is_tui_mode; then
        local tool count max_h height list_height choice rc=0 w
        tool="$(tui_tool)"
        count=$(( $# / 2 ))
        read -r max_h w < <(_tui_box_dims 22 76)
        local max_list=$(( max_h - 9 ))
        (( max_list < 4 )) && max_list=4
        list_height=$(( count > max_list ? max_list : count ))
        height=$(( list_height + 9 ))
        (( height > max_h )) && height="$max_h"
        local -a cmd=("$tool" --title "$title")
        if [[ -n "$default_tag" ]]; then
            cmd+=(--default-item "$default_tag")
        fi
        cmd+=(--menu "$prompt" "$height" "$w" "$list_height" "$@")
        choice="$("${cmd[@]}" 3>&1 1>&2 2>&3)" || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            ui_err "Selection cancelled at '${title}'."
            exit 130
        fi
        UI_REPLY="$choice"
        return 0
    fi

    ui_heading "$title"
    [[ -n "$prompt" ]] && printf '  %s\n' "$prompt"
    local -a tags=() descs=()
    while (( $# > 0 )); do
        tags+=("$1")
        descs+=("$2")
        shift 2
    done

    local i default_idx=""
    for (( i=0; i<${#tags[@]}; i++ )); do
        if [[ -n "$default_tag" && "${tags[$i]}" == "$default_tag" ]]; then
            default_idx=$(( i + 1 ))
            _ui_c_out '1;32'; printf '  %s ' "$UI_SYM_PTR"; _ui_r_out
            printf '%2d) %-16s %s ' "$((i + 1))" "${tags[$i]}" "${descs[$i]}"
            _ui_c_out '32'; printf '[default]\n'; _ui_r_out
        else
            printf '    %2d) %-16s %s\n' "$((i + 1))" "${tags[$i]}" "${descs[$i]}"
        fi
    done

    local ans hint
    if [[ -n "$default_idx" ]]; then
        hint="1-${#tags[@]}, Enter=${default_idx}"
    else
        hint="1-${#tags[@]}"
    fi
    while true; do
        read -r -p "  Choice [${hint}]: " ans
        if [[ -z "$ans" && -n "$default_idx" ]]; then
            UI_REPLY="${tags[$((default_idx - 1))]}"
            return 0
        fi
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#tags[@]} )); then
            UI_REPLY="${tags[$((ans - 1))]}"
            return 0
        fi
        for (( i=0; i<${#tags[@]}; i++ )); do
            if [[ "${ans,,}" == "${tags[$i],,}" ]]; then
                UI_REPLY="${tags[$i]}"
                return 0
            fi
        done
        ui_warn "Invalid selection '$ans' -- enter 1-${#tags[@]} or an option name."
    done
}

# ---------------------------------------------------------------------------
# Storage calculation & GNU screen session helpers
# ---------------------------------------------------------------------------
function uvb_available_gb() {
    local target="${1:-/}"
    local probe="$target"
    while [[ -n "$probe" && "$probe" != "/" && ! -e "$probe" ]]; do
        probe="$(dirname "$probe")"
    done
    [[ -z "$probe" ]] && probe="/"
    local kb
    kb="$(df -Pk "$probe" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
        echo 0
        return 0
    fi
    echo $(( kb / 1048576 ))
}

# Estimate minimum free storage (GB) for one build of OUTPUT_KIND.
function uvb_single_build_req_gb() {
    local kind="${1:-iso}"
    local disk_gb="${2:-16}"
    local vm_formats="${3:-qcow2}"
    case "$kind" in
        iso)
            echo 20
            ;;
        cloud|removable)
            echo $(( 20 + disk_gb ))
            ;;
        vm)
            local extra=0
            [[ "${vm_formats:-qcow2}" != "none" ]] && extra=10
            echo $(( 20 + disk_gb + extra ))
            ;;
        *)
            echo 20
            ;;
    esac
}

function uvb_screen_available() {
    command -v screen >/dev/null 2>&1
}

# Launch CMD... inside a detached GNU screen session, logging to LOG_FILE.
function uvb_launch_screen_session() {
    local session_name="$1"
    local log_file="$2"
    shift 2

    if ! uvb_screen_available; then
        ui_err "GNU screen is not installed. Install 'screen' first or run without --screen."
        return 1
    fi

    local quoted_cmd="" arg
    for arg in "$@"; do
        quoted_cmd+="$(printf '%q ' "$arg")"
    done
    local runner
    runner="${quoted_cmd}; rc=\$?; echo \"\"; echo \"=====> Screen build finished (exit \$rc). Press Enter to close.\"; read -r _ || true; exit \$rc"

    if [[ -n "$log_file" ]]; then
        mkdir -p "$(dirname "$log_file")"
        screen -dmS "$session_name" -L -Logfile "$log_file" bash -c "$runner"
    else
        screen -dmS "$session_name" bash -c "$runner"
    fi
}
