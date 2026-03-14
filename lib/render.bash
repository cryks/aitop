#!/usr/bin/env bash
# lib/render.bash — shared rendering for usage dashboards
# Sourced by provider scripts. Do not run directly.

BAR_WIDTH=30

# ── Colors ──────────────────────────────────────

setup_colors() {
  if [[ -t 1 ]] || [[ "${CLICOLOR_FORCE:-}" == "1" ]]; then
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_RED='\033[31m'
    C_CYAN='\033[36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
    USE_COLOR=1
  else
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_CYAN=''
    C_BOLD=''
    C_DIM=''
    C_RESET=''
    USE_COLOR=0
  fi
}

# ── Primitives ──────────────────────────────────

repeat_char() {
  local char="$1" count="$2" i
  for (( i = 0; i < count; i++ )); do
    printf '%s' "$char"
  done
}

# Truecolor gradient usage bar (no brackets).
# Color flows across bar positions: teal-green -> yellow -> red.
render_bar() {
  local percent_raw="$1"
  local int_percent="${percent_raw%%.*}"
  if [[ ! "${int_percent:-}" =~ ^[0-9]+$ ]]; then
    int_percent=0
  fi
  if (( int_percent > 100 )); then
    int_percent=100
  fi

  local filled=$(( int_percent * BAR_WIDTH / 100 ))
  local empty=$(( BAR_WIDTH - filled ))

  if [[ "${USE_COLOR:-0}" == "1" ]]; then
    local i
    for (( i = 0; i < filled; i++ )); do
      local pos=$(( i * 100 / BAR_WIDTH ))
      local r g b
      if (( pos < 50 )); then
        # Teal (#00c896) -> Yellow (#ffd600)
        r=$(( 0 + 255 * pos / 50 ))
        g=$(( 200 + 14 * pos / 50 ))
        b=$(( 150 - 150 * pos / 50 ))
      else
        # Yellow (#ffd600) -> Red (#ff4545)
        local t=$(( pos - 50 ))
        r=255
        g=$(( 214 - 145 * t / 50 ))
        b=$(( 0 + 69 * t / 50 ))
      fi
      printf '\033[38;2;%d;%d;%dm\xe2\x96\x88' "$r" "$g" "$b"
    done
    printf '\033[0m'
  else
    repeat_char '█' "$filled"
  fi

  if (( empty > 0 )); then
    printf '%b' "${C_DIM}"
    repeat_char '░' "$empty"
    printf '%b' "${C_RESET}"
  fi
}

# Time elapsed bar — cyan track (no brackets).
render_time_bar() {
  local percent="$1"
  if (( percent > 100 )); then
    percent=100
  fi

  local filled=$(( percent * BAR_WIDTH / 100 ))
  local empty=$(( BAR_WIDTH - filled ))

  if (( filled > 0 && empty > 0 )); then
    printf '%b' "$C_CYAN"
    repeat_char '━' "$filled"
    printf '%b' "$C_RESET"
    printf '◆%b' "$C_RESET"
    printf '%b' "$C_DIM"
    repeat_char '─' $(( empty - 1 ))
    printf '%b' "$C_RESET"
  elif (( filled > 0 )); then
    printf '%b' "$C_CYAN"
    repeat_char '━' "$filled"
    printf '%b' "$C_RESET"
  else
    printf '%b' "$C_DIM"
    repeat_char '─' "$empty"
    printf '%b' "$C_RESET"
  fi
}

# ── Formatting ──────────────────────────────────

format_duration_seconds() {
  local total="$1"
  if [[ -z "$total" || ! "$total" =~ ^[0-9]+$ ]]; then
    printf '%s' "$total"
    return
  fi

  local days hours minutes seconds
  local parts=()
  days=$(( total / 86400 ))
  hours=$(( (total % 86400) / 3600 ))
  minutes=$(( (total % 3600) / 60 ))
  seconds=$(( total % 60 ))

  if (( days > 0 )); then
    parts+=("${days}d")
  fi
  if (( hours > 0 )); then
    parts+=("${hours}h")
  fi
  if (( minutes > 0 )); then
    parts+=("${minutes}m")
  fi
  if (( seconds > 0 || ${#parts[@]} == 0 )); then
    parts+=("${seconds}s")
  fi

  printf '%s' "${parts[*]}"
}

format_reset_duration_seconds() {
  local total="$1"
  if [[ -z "$total" || ! "$total" =~ ^[0-9]+$ ]]; then
    printf '%15s' "$total"
    return
  fi

  local days hours minutes seconds
  local parts=()
  days=$(( total / 86400 ))
  hours=$(( (total % 86400) / 3600 ))
  minutes=$(( (total % 3600) / 60 ))
  seconds=$(( total % 60 ))

  if (( days > 0 )); then
    parts+=("${days}d")
    parts+=("$(printf '%2dh' "$hours")")
    parts+=("$(printf '%2dm' "$minutes")")
    parts+=("$(printf '%2ds' "$seconds")")
  elif (( hours > 0 )); then
    parts+=("$(printf '%2dh' "$hours")")
    parts+=("$(printf '%2dm' "$minutes")")
    parts+=("$(printf '%2ds' "$seconds")")
  elif (( minutes > 0 )); then
    parts+=("$(printf '%2dm' "$minutes")")
    parts+=("$(printf '%2ds' "$seconds")")
  else
    parts+=("$(printf '%2ds' "$seconds")")
  fi

  printf '%15s' "${parts[*]}"
}

normalize_percent_display() {
  local percent_raw="$1"
  local int_part="0"
  local frac_part=""

  if [[ "$percent_raw" =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
    int_part="${BASH_REMATCH[1]}"
    frac_part="${BASH_REMATCH[3]:-}"
  else
    int_part="${percent_raw%%.*}"
    if [[ ! "$int_part" =~ ^[0-9]+$ ]]; then
      int_part=0
    fi
  fi

  if [[ -n "$frac_part" && "$frac_part" =~ [1-9] ]]; then
    int_part=$(( int_part + 1 ))
  fi

  if (( int_part > 100 )); then
    int_part=100
  fi

  printf '%d' "$int_part"
}

format_percent_label() {
  local normalized
  normalized="$(normalize_percent_display "$1")"
  printf '%2d' "$normalized"
}

# ── Pace indicator ──────────────────────────────

# Compare usage% vs elapsed% to show pacing status.
pace_indicator() {
  local usage="$1" elapsed="$2"
  local u e
  u="$(normalize_percent_display "$usage")"
  e="$(normalize_percent_display "$elapsed")"

  if (( u >= 100 )); then
    printf '%b■ full%b' "$C_RED" "$C_RESET"
  elif (( u > e )); then
    printf '%b⚠ ahead%b' "$C_YELLOW" "$C_RESET"
  else
    printf '%b✓%b' "$C_GREEN" "$C_RESET"
  fi
}

# ── Provider header ─────────────────────────────

# Section header with colored accent dot and optional subtitle.
# Args: name r g b [subtitle]
render_provider_header() {
  local name="$1"
  local r="${2:-255}" g="${3:-255}" b="${4:-255}"
  local subtitle="${5:-}"

  printf '\n'
  if [[ "${USE_COLOR:-0}" == "1" ]]; then
    printf '  \033[38;2;%d;%d;%dm\xe2\x97\x86\033[0m %b%s%b' \
      "$r" "$g" "$b" "$C_BOLD" "$name" "$C_RESET"
    if [[ -n "$subtitle" ]]; then
      printf ' %b· %s%b' "$C_DIM" "$subtitle" "$C_RESET"
    fi
    printf '\n'
  else
    if [[ -n "$subtitle" ]]; then
      printf '  * %s · %s\n' "$name" "$subtitle"
    else
      printf '  * %s\n' "$name"
    fi
  fi
}

# ── Window rendering ────────────────────────────

# Render a single usage window (2-3 lines).
#
# Line 1: usage bar + percentage + pace indicator
# Line 2: time bar + elapsed% + window/reset info  (when elapsed data exists)
# Line 2 (fallback): window/reset info only        (when no elapsed data)
#
# Args: label usage_pct elapsed_pct reset_remaining_seconds window_seconds
#   elapsed_pct, reset_remaining, window_seconds can be empty.
render_window() {
  local label="$1"
  local usage_pct="$2"
  local elapsed_pct="$3"
  local reset_remaining="$4"
  local window_seconds="$5"
  local usage_label elapsed_label window_label=""

  [[ -n "$usage_pct" ]] || return 0

  usage_label="$(format_percent_label "$usage_pct")"

  # ── Line 1: usage bar ──
  printf '    %-11s' "$label"
  render_bar "$usage_pct"
  printf ' %s%% used' "$usage_label"
  if [[ -n "$elapsed_pct" ]]; then
    printf '  '
    pace_indicator "$usage_pct" "$elapsed_pct"
  fi
  printf '\n'

  # ── Line 2: time bar + details  OR  fallback details ──
  if [[ -n "$elapsed_pct" ]]; then
    elapsed_label="$(format_percent_label "$elapsed_pct")"
    if [[ -n "$window_seconds" && "$window_seconds" =~ ^[0-9]+$ ]] && (( window_seconds > 0 )); then
      window_label="$(format_duration_seconds "$window_seconds")"
    fi

    # Time bar line
    printf '    %b%10s %b' "$C_DIM" "$window_label" "$C_RESET"
    render_time_bar "$elapsed_pct"
    printf ' %s%% elapsed' "$elapsed_label"
    if [[ -n "$reset_remaining" && "$reset_remaining" =~ ^[0-9]+$ ]] && (( reset_remaining > 0 )); then
      printf '%b · resets in %s%b' "$C_DIM" "$(format_reset_duration_seconds "$reset_remaining")" "$C_RESET"
    fi
    printf '\n'
  else
    # No elapsed data — show available details on a dim line
    local has_detail=""
    if [[ -n "$window_seconds" && "$window_seconds" =~ ^[0-9]+$ ]] && (( window_seconds > 0 )); then
      if [[ -z "$has_detail" ]]; then
        printf '               %b' "$C_DIM"
      fi
      printf '%s window' "$(format_duration_seconds "$window_seconds")"
      has_detail=1
    fi
    if [[ -n "$reset_remaining" && "$reset_remaining" =~ ^[0-9]+$ ]] && (( reset_remaining > 0 )); then
      if [[ -z "$has_detail" ]]; then
        printf '               %b' "$C_DIM"
      else
        printf ' · '
      fi
      printf 'resets in %s' "$(format_reset_duration_seconds "$reset_remaining")"
      has_detail=1
    fi
    if [[ -n "$has_detail" ]]; then
      printf '%b\n' "$C_RESET"
    fi
  fi
}

# ── Dashboard chrome (used by aitop) ────────────

render_dashboard_header() {
  printf '\n'
  printf '%b━━━ Usage Dashboard ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$C_BOLD" "$C_RESET"
}

render_dashboard_footer() {
  printf '\n'
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$C_DIM" "$C_RESET"
}
