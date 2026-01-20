# Brigade Development Handoff

**Date:** 2026-01-20
**Last commit:** `20bde68` - PRD Templates (P10)

---

## Session Summary

Completed this session:
1. **P6: Partial Execution** - `--only`, `--skip`, `--from`, `--until` flags
2. **P7: Iteration Mode** - `./brigade.sh iterate "tweak"`
3. **P10: PRD Templates** - `./brigade.sh template api users`

All pushed to master.

---

## Current Roadmap Status

| Priority | Feature | Status |
|----------|---------|--------|
| 1 | Quick Tasks | ✓ Complete |
| 2 | PR Workflow | ✓ Complete |
| 3 | Cost Visibility | ✓ Complete |
| 4 | Explore Mode | ✓ Complete |
| 5 | Context Persistence | Pending (Hard) |
| 6 | Partial Execution | ✓ Complete |
| 7 | Iteration Mode | ✓ Complete |
| **8** | **Proactive Updates** | **Ready to implement** |
| 9 | Confidence Indicators | Pending |
| 10 | PRD Templates | ✓ Complete |
| 11 | Learning from History | Pending (Hard) |
| 12 | Multi-Project | Pending (Hard) |

---

## Next Up: P8 Proactive Updates

### Overview

Push notifications instead of polling. When something needs attention, Brigade tells you.

### What Already Exists

- Event system (`emit_supervisor_event`, `dispatch_to_modules`) - fully functional
- Telegram module (`modules/telegram.sh`) - sends to phone
- Activity log heartbeat - writes to file
- Task timeout warnings - logged but not pushed as alerts

### Implementation Plan (~200 lines total)

#### 1. Desktop Notification Module (`modules/desktop.sh`, ~60 lines)

```bash
#!/bin/bash
# Desktop notifications for Brigade (macOS/Linux)
# Gracefully fails if no display available

module_desktop_events() {
  echo "attention escalation task_slow service_complete"
}

module_desktop_init() {
  # Detect notification command
  if command -v osascript &>/dev/null; then
    DESKTOP_NOTIFY_CMD="osascript"
  elif command -v notify-send &>/dev/null; then
    DESKTOP_NOTIFY_CMD="notify-send"
  else
    echo "[desktop] No notification command found" >&2
    return 1
  fi

  # Check if display available (for Linux)
  if [ "$DESKTOP_NOTIFY_CMD" == "notify-send" ] && [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
    echo "[desktop] No display available (SSH session?)" >&2
    return 1
  fi

  return 0
}

_desktop_notify() {
  local title="$1" message="$2"
  case "$DESKTOP_NOTIFY_CMD" in
    osascript)
      osascript -e "display notification \"$message\" with title \"$title\" sound name \"default\"" 2>/dev/null &
      ;;
    notify-send)
      notify-send -a "Brigade" "$title" "$message" 2>/dev/null &
      ;;
  esac
}

module_desktop_on_attention() {
  local task_id="$1" reason="$2"
  _desktop_notify "Brigade: Attention" "$task_id needs attention: $reason"
}

module_desktop_on_escalation() {
  local task_id="$1" from="$2" to="$3"
  _desktop_notify "Brigade: Escalation" "$task_id: $from → $to"
}

module_desktop_on_task_slow() {
  local task_id="$1" worker="$2" elapsed="$3" expected="$4"
  _desktop_notify "Brigade: Slow Task" "$task_id running ${elapsed}m (expected ~${expected}m)"
}

module_desktop_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  local mins=$((duration / 60))
  if [ "$failed" -gt 0 ]; then
    _desktop_notify "Brigade: Complete" "$completed tasks, $failed failed (${mins}m)"
  else
    _desktop_notify "Brigade: Complete!" "$completed tasks done (${mins}m)"
  fi
}
```

#### 2. Terminal Alert Module (`modules/terminal.sh`, ~50 lines)

```bash
#!/bin/bash
# Terminal alerts with bell and banner
# Works over SSH if terminal supports bell notifications

module_terminal_events() {
  echo "attention escalation task_slow service_complete"
}

module_terminal_init() {
  # Always succeeds - terminal is always available
  return 0
}

_terminal_bell() {
  [ "${MODULE_TERMINAL_BELL:-true}" == "true" ] && printf '\a'
}

_terminal_banner() {
  local message="$1" level="${2:-info}"
  local color
  case "$level" in
    error)   color="\033[0;31m" ;;  # Red
    warning) color="\033[1;33m" ;;  # Yellow
    success) color="\033[0;32m" ;;  # Green
    *)       color="\033[0;36m" ;;  # Cyan
  esac
  echo ""
  echo -e "${color}╔══════════════════════════════════════════════════════╗\033[0m"
  echo -e "${color}║\033[0m  $message"
  echo -e "${color}╚══════════════════════════════════════════════════════╝\033[0m"
}

module_terminal_on_attention() {
  local task_id="$1" reason="$2"
  _terminal_bell
  _terminal_banner "⚠️  $task_id needs attention: $reason" "warning"
}

module_terminal_on_escalation() {
  local task_id="$1" from="$2" to="$3"
  _terminal_bell
  _terminal_banner "↑ $task_id escalated: $from → $to" "warning"
}

module_terminal_on_task_slow() {
  local task_id="$1" worker="$2" elapsed="$3" expected="$4"
  _terminal_bell
  _terminal_banner "⏱️  $task_id running ${elapsed}m (expected ~${expected}m)" "warning"
}

module_terminal_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  local mins=$((duration / 60))
  if [ "$failed" -gt 0 ]; then
    _terminal_bell
    _terminal_banner "✓ Complete: $completed tasks, $failed failed (${mins}m)" "warning"
  else
    _terminal_bell
    _terminal_banner "✓ Complete: $completed tasks (${mins}m)" "success"
  fi
}
```

#### 3. Webhook Module (`modules/webhook.sh`, ~70 lines)

```bash
#!/bin/bash
# Webhook notifications (Slack, Discord, custom)
# Config: MODULE_WEBHOOK_URL, MODULE_WEBHOOK_FORMAT (slack|discord|json)

module_webhook_events() {
  echo "attention escalation task_slow service_complete"
}

module_webhook_init() {
  if [ -z "$MODULE_WEBHOOK_URL" ]; then
    echo "[webhook] MODULE_WEBHOOK_URL required" >&2
    return 1
  fi
  MODULE_WEBHOOK_FORMAT="${MODULE_WEBHOOK_FORMAT:-json}"
  return 0
}

_webhook_send() {
  local title="$1" message="$2" level="${3:-info}"
  local payload

  case "$MODULE_WEBHOOK_FORMAT" in
    slack)
      local emoji="ℹ️"
      [ "$level" == "warning" ] && emoji="⚠️"
      [ "$level" == "error" ] && emoji="❌"
      [ "$level" == "success" ] && emoji="✅"
      payload=$(jq -n --arg text "$emoji *$title*: $message" '{text: $text}')
      ;;
    discord)
      local color=5814783  # Blue
      [ "$level" == "warning" ] && color=16776960  # Yellow
      [ "$level" == "error" ] && color=16711680    # Red
      [ "$level" == "success" ] && color=65280     # Green
      payload=$(jq -n --arg title "$title" --arg desc "$message" --argjson color "$color" \
        '{embeds: [{title: $title, description: $desc, color: $color}]}')
      ;;
    *)  # json
      payload=$(jq -n --arg title "$title" --arg message "$message" --arg level "$level" \
        '{title: $title, message: $message, level: $level, source: "brigade"}')
      ;;
  esac

  curl -s -X POST "$MODULE_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" > /dev/null 2>&1 &
}

module_webhook_on_attention() {
  local task_id="$1" reason="$2"
  _webhook_send "Attention Needed" "$task_id: $reason" "warning"
}

module_webhook_on_escalation() {
  local task_id="$1" from="$2" to="$3"
  _webhook_send "Task Escalated" "$task_id: $from → $to" "warning"
}

module_webhook_on_task_slow() {
  local task_id="$1" worker="$2" elapsed="$3" expected="$4"
  _webhook_send "Slow Task" "$task_id running ${elapsed}m (expected ~${expected}m)" "warning"
}

module_webhook_on_service_complete() {
  local completed="$1" failed="$2" duration="$3"
  local mins=$((duration / 60))
  if [ "$failed" -gt 0 ]; then
    _webhook_send "Service Complete" "$completed tasks, $failed failed (${mins}m)" "warning"
  else
    _webhook_send "Service Complete" "$completed tasks done (${mins}m)" "success"
  fi
}
```

#### 4. Add `task_slow` Event to brigade.sh (~15 lines)

Find `check_task_timeout_warning()` function and add event emission:

```bash
# After the existing warning log, add:
emit_supervisor_event "task_slow" "$task_id" "$worker" "$elapsed_mins" "$warning_threshold"
```

Also update `module_telegram_events()` in `modules/telegram.sh` to include `task_slow`.

#### 5. Configuration (`brigade.config.example`)

Add:
```bash
# Proactive Updates (P8)
# Enable modules: MODULES="desktop,terminal,telegram,webhook"

# Desktop notifications (macOS/Linux with display)
# No additional config needed - auto-detects osascript/notify-send

# Terminal alerts
MODULE_TERMINAL_BELL=true        # Audible bell on alerts

# Webhook (Slack/Discord/custom)
MODULE_WEBHOOK_URL=""            # Webhook URL
MODULE_WEBHOOK_FORMAT="slack"    # slack, discord, or json
```

### Files to Create/Modify

| File | Action |
|------|--------|
| `modules/desktop.sh` | Create (~60 lines) |
| `modules/terminal.sh` | Create (~50 lines) |
| `modules/webhook.sh` | Create (~70 lines) |
| `modules/telegram.sh` | Add `task_slow` event |
| `brigade.sh` | Emit `task_slow` event (~15 lines) |
| `brigade.config.example` | Add webhook/terminal config |
| `docs/modules.md` | Document new modules |
| `ROADMAP.md` | Mark P8 complete |

### Verification

```bash
# Test desktop (local only)
MODULES="desktop" ./brigade.sh service prd.json

# Test terminal (works over SSH)
MODULES="terminal" ./brigade.sh service prd.json

# Test webhook (Slack)
MODULE_WEBHOOK_URL="https://hooks.slack.com/..." \
MODULE_WEBHOOK_FORMAT="slack" \
MODULES="webhook" ./brigade.sh service prd.json

# Test all
MODULES="desktop,terminal,webhook" ./brigade.sh service prd.json
```

---

## After P8

**P9: Confidence Indicators** - Risk scoring before execution
- Keyword-based risk detection (auth, payment, security)
- Historical escalation patterns
- Pre-flight report

**Then consider:**
- P5: Context Persistence (Hard)
- P11: Learning from History (Hard)

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `brigade.sh` | Main orchestrator (~7500 lines) |
| `chef/*.md` | Worker prompts |
| `modules/*.sh` | Optional notification modules |
| `templates/*.json` | PRD templates |
| `commands/brigade.md` | Claude Code skill |
| `ROADMAP.md` | Feature tracking |
| `CLAUDE.md` | AI guidance (gitignored) |

---

## Commands Quick Reference

```bash
./brigade.sh plan "feature"           # Generate PRD
./brigade.sh service prd.json         # Execute PRD
./brigade.sh template api users       # PRD from template
./brigade.sh iterate "tweak"          # Quick fix
./brigade.sh --only US-001 service    # Partial execution
./brigade.sh status --watch           # Monitor progress
./brigade.sh cost prd.json            # Cost estimate
```
