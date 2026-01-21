#!/bin/bash
# Desktop notifications for Brigade
# Uses osascript on macOS (with sound) or notify-send on Linux
# Gracefully disables if no display (SSH sessions)

# Detect notification command at init
DESKTOP_NOTIFY_CMD=""

module_desktop_events() {
  echo "attention escalation task_slow service_complete"
}

module_desktop_init() {
  # Check for macOS osascript
  if command -v osascript &>/dev/null; then
    DESKTOP_NOTIFY_CMD="osascript"
    return 0
  fi

  # Check for Linux notify-send
  if command -v notify-send &>/dev/null; then
    # Check if we have a display (not SSH without X forwarding)
    if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
      DESKTOP_NOTIFY_CMD="notify-send"
      return 0
    fi
  fi

  # No notification method available
  echo "[desktop] No notification method available (need osascript or notify-send with display)" >&2
  return 1
}

_desktop_notify() {
  local title="$1"
  local message="$2"
  local sound="${3:-true}"  # Sound by default

  if [ "$DESKTOP_NOTIFY_CMD" = "osascript" ]; then
    # macOS notification with optional sound
    if [ "$sound" = "true" ]; then
      osascript -e "display notification \"$message\" with title \"$title\" sound name \"Submarine\""
    else
      osascript -e "display notification \"$message\" with title \"$title\""
    fi
  elif [ "$DESKTOP_NOTIFY_CMD" = "notify-send" ]; then
    # Linux notification (no sound support built-in)
    notify-send -a "Brigade" "$title" "$message"
  fi
}

module_desktop_on_attention() {
  local task_id="$1" reason="$2"
  _desktop_notify "Brigade: Attention Needed" "Task $task_id: $reason" "true"
}

module_desktop_on_escalation() {
  local task_id="$1" from="$2" to="$3"
  _desktop_notify "Brigade: Escalation" "Task $task_id escalated from $from to $to" "false"
}

module_desktop_on_task_slow() {
  local task_id="$1" worker="$2" elapsed="$3" threshold="$4"
  _desktop_notify "Brigade: Task Running Long" "Task $task_id running ${elapsed}m (expected ~${threshold}m)" "true"
}

module_desktop_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  local mins=$((duration / 60))
  if [ "$failed" -eq 0 ]; then
    _desktop_notify "Brigade: Complete" "$completed tasks done in ${mins}m" "true"
  else
    _desktop_notify "Brigade: Complete with Issues" "$completed done, $failed failed (${mins}m)" "true"
  fi
}
