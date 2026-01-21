#!/bin/bash
# Telegram notifications for Brigade
# Config: MODULE_TELEGRAM_BOT_TOKEN, MODULE_TELEGRAM_CHAT_ID

module_telegram_events() {
  echo "task_complete escalation attention task_slow service_complete"
}

module_telegram_init() {
  if [ -z "$MODULE_TELEGRAM_BOT_TOKEN" ] || [ -z "$MODULE_TELEGRAM_CHAT_ID" ]; then
    echo "[telegram] MODULE_TELEGRAM_BOT_TOKEN and MODULE_TELEGRAM_CHAT_ID required" >&2
    return 1
  fi
  return 0
}

_telegram_send() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${MODULE_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${MODULE_TELEGRAM_CHAT_ID}" \
    -d "text=${message}" \
    -d "parse_mode=Markdown" > /dev/null 2>&1 &
}

module_telegram_on_task_complete() {
  local task_id="$1" worker="$2" duration="$3"
  _telegram_send "Task *$task_id* completed by $worker (${duration}s)"
}

module_telegram_on_escalation() {
  local task_id="$1" from="$2" to="$3"
  _telegram_send "Task *$task_id* escalated: $from -> $to"
}

module_telegram_on_attention() {
  local task_id="$1" reason="$2"
  _telegram_send "Task *$task_id* needs attention: $reason"
}

module_telegram_on_task_slow() {
  local task_id="$1" worker="$2" elapsed="$3" threshold="$4"
  _telegram_send "⏱️ Task *$task_id* running ${elapsed}m (expected ~${threshold}m for $worker)"
}

module_telegram_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  local mins=$((duration / 60))
  _telegram_send "Service complete: $completed tasks, $failed failed (${mins}m)"
}
