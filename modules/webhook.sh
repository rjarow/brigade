#!/bin/bash
# Webhook notifications for Brigade
# Supports Slack, Discord, and custom JSON webhooks
# Config: MODULE_WEBHOOK_URL, MODULE_WEBHOOK_FORMAT (slack|discord|json)

module_webhook_events() {
  echo "attention escalation task_slow service_complete"
}

module_webhook_init() {
  if [ -z "$MODULE_WEBHOOK_URL" ]; then
    echo "[webhook] MODULE_WEBHOOK_URL required" >&2
    return 1
  fi
  # Default format to json if not set
  : "${MODULE_WEBHOOK_FORMAT:=json}"
  return 0
}

_webhook_send() {
  local event="$1"
  local title="$2"
  local message="$3"
  local color="$4"  # For Discord embeds

  local payload=""

  case "$MODULE_WEBHOOK_FORMAT" in
    slack)
      # Slack format with emoji based on event type
      local emoji=""
      case "$event" in
        attention) emoji=":rotating_light:" ;;
        escalation) emoji=":arrow_up:" ;;
        task_slow) emoji=":hourglass:" ;;
        service_complete) emoji=":checkered_flag:" ;;
        *) emoji=":robot_face:" ;;
      esac
      payload=$(cat <<EOF
{"text": "$emoji *$title*\n$message"}
EOF
)
      ;;
    discord)
      # Discord format with colored embed
      # Color is decimal: red=16711680, yellow=16776960, green=65280, cyan=65535
      local dec_color="0"
      case "$color" in
        red) dec_color="16711680" ;;
        yellow) dec_color="16776960" ;;
        green) dec_color="65280" ;;
        cyan) dec_color="65535" ;;
      esac
      payload=$(cat <<EOF
{"embeds": [{"title": "$title", "description": "$message", "color": $dec_color}]}
EOF
)
      ;;
    json|*)
      # Raw JSON format
      payload=$(cat <<EOF
{"event": "$event", "title": "$title", "message": "$message", "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
)
      ;;
  esac

  # Async curl, non-blocking
  curl -s -X POST "$MODULE_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" > /dev/null 2>&1 &
}

module_webhook_on_attention() {
  local task_id="$1" reason="$2"
  _webhook_send "attention" "Attention Needed" "Task $task_id: $reason" "red"
}

module_webhook_on_escalation() {
  local task_id="$1" from="$2" to="$3"
  _webhook_send "escalation" "Escalation" "Task $task_id escalated: $from -> $to" "yellow"
}

module_webhook_on_task_slow() {
  local task_id="$1" worker="$2" elapsed="$3" threshold="$4"
  _webhook_send "task_slow" "Task Running Long" "Task $task_id running ${elapsed}m (expected ~${threshold}m for $worker)" "yellow"
}

module_webhook_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  local mins=$((duration / 60))
  local color="green"
  local title="Service Complete"
  local message="$completed tasks completed in ${mins}m"
  if [ "$failed" -gt 0 ]; then
    color="cyan"
    message="$completed done, $failed failed (${mins}m)"
  fi
  _webhook_send "service_complete" "$title" "$message" "$color"
}
