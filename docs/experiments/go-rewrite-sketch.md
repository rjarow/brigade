# Brigade Go Rewrite Sketch

## Why Go Over Rust

| Factor | Go | Rust |
|--------|-----|------|
| Learning curve | Days | Weeks-months |
| CLI tooling | Excellent (cobra, viper) | Good (clap) |
| Concurrency | Goroutines - trivial | async/await - more complex |
| JSON handling | Native, easy | serde - powerful but verbose |
| Build | `go build` → single binary | `cargo build` → single binary |
| AI assistance | Very good | Good but ownership trips it up |

For an orchestrator that shells out to external tools, Go is the pragmatic choice.

## Project Structure

```
brigade/
├── cmd/
│   └── brigade/
│       └── main.go           # CLI entry point
├── internal/
│   ├── config/
│   │   └── config.go         # Configuration loading
│   ├── prd/
│   │   ├── prd.go            # PRD types and parsing
│   │   └── validate.go       # PRD validation
│   ├── state/
│   │   ├── state.go          # State management
│   │   └── store.go          # File-based state persistence
│   ├── task/
│   │   ├── task.go           # Task types
│   │   ├── router.go         # Complexity-based routing
│   │   └── graph.go          # Dependency graph
│   ├── worker/
│   │   ├── worker.go         # Worker interface
│   │   ├── claude.go         # Claude Code implementation
│   │   ├── opencode.go       # OpenCode implementation
│   │   └── output.go         # Parse worker output (promises, learnings)
│   ├── orchestrator/
│   │   ├── orchestrator.go   # Main service loop
│   │   ├── escalation.go     # Escalation logic
│   │   └── review.go         # Executive review
│   ├── module/
│   │   ├── module.go         # Module interface
│   │   ├── loader.go         # Dynamic module loading
│   │   └── builtin/          # Built-in modules
│   │       ├── telegram.go
│   │       └── cost.go
│   └── supervisor/
│       ├── status.go         # Status file generation
│       └── events.go         # Event stream
├── chef/                     # Worker prompts (unchanged)
│   ├── executive.md
│   ├── sous.md
│   └── line.md
├── go.mod
└── go.sum
```

## Core Types

```go
// prd/prd.go
package prd

type PRD struct {
    FeatureName string  `json:"featureName"`
    BranchName  string  `json:"branchName"`
    Walkaway    bool    `json:"walkaway"`
    Tasks       []Task  `json:"tasks"`
    Constraints []string `json:"constraints,omitempty"`
}

type Task struct {
    ID                 string         `json:"id"`
    Title              string         `json:"title"`
    AcceptanceCriteria []string       `json:"acceptanceCriteria"`
    Verification       []Verification `json:"verification,omitempty"`
    DependsOn          []string       `json:"dependsOn"`
    Complexity         Complexity     `json:"complexity"`
    Passes             bool           `json:"passes"`
}

type Verification struct {
    Type string `json:"type"` // pattern, unit, integration, smoke
    Cmd  string `json:"cmd"`
}

type Complexity string

const (
    Junior Complexity = "junior"
    Senior Complexity = "senior"
    Auto   Complexity = "auto"
)
```

```go
// state/state.go
package state

import "time"

type State struct {
    SessionID     string                 `json:"sessionId"`
    StartedAt     time.Time              `json:"startedAt"`
    LastStartTime time.Time              `json:"lastStartTime"`
    CurrentTask   string                 `json:"currentTask,omitempty"`
    TaskHistory   map[string]TaskHistory `json:"taskHistory"`
    Escalations   []Escalation           `json:"escalations"`
    Reviews       []Review               `json:"reviews"`
}

type TaskHistory struct {
    Worker    string        `json:"worker"`
    Status    string        `json:"status"`
    Attempts  int           `json:"attempts"`
    Durations []Duration    `json:"durations"`
    Approaches []Approach   `json:"approaches,omitempty"`
}

type Approach struct {
    Strategy string `json:"strategy"`
    Error    string `json:"error,omitempty"`
    Category string `json:"category,omitempty"` // syntax, integration, environment, logic
}
```

```go
// worker/worker.go
package worker

import "context"

type Worker interface {
    Execute(ctx context.Context, prompt string) (*Result, error)
    Name() string
}

type Result struct {
    Output     string
    Promise    Promise       // COMPLETE, BLOCKED, ALREADY_DONE, ABSORBED_BY
    AbsorbedBy string        // Task ID if ABSORBED_BY
    Learnings  []string      // Extracted <learning> tags
    Backlog    []string      // Extracted <backlog> tags
    Approach   string        // Extracted <approach> tag
    ExitCode   int
}

type Promise int

const (
    Complete Promise = iota
    Blocked
    AlreadyDone
    AbsorbedBy
    NeedsIteration
)
```

## Main Orchestration Loop

```go
// orchestrator/orchestrator.go
package orchestrator

func (o *Orchestrator) Run(ctx context.Context, prdPath string) error {
    prd, err := prd.Load(prdPath)
    if err != nil {
        return fmt.Errorf("load PRD: %w", err)
    }

    state := o.state.LoadOrCreate(prdPath)
    graph := task.NewGraph(prd.Tasks)

    for {
        // Find ready tasks (dependencies met, not completed)
        ready := graph.ReadyTasks(state)
        if len(ready) == 0 {
            if graph.AllComplete(state) {
                return o.finalize(ctx, prd, state)
            }
            return fmt.Errorf("no ready tasks but not complete - dependency cycle?")
        }

        // Execute tasks (parallel if configured)
        results := o.executeTasks(ctx, ready, state)

        for _, r := range results {
            switch r.Promise {
            case worker.Complete:
                if err := o.review(ctx, r.Task, state); err != nil {
                    // Review failed - task needs iteration
                    state.RecordIteration(r.Task.ID, err.Error())
                    continue
                }
                state.MarkComplete(r.Task.ID)
                o.events.Emit(EventTaskComplete, r.Task)

            case worker.Blocked:
                if state.ShouldEscalate(r.Task.ID) {
                    o.escalate(ctx, r.Task, state)
                } else {
                    state.RecordAttempt(r.Task.ID, r.Approach, r.Error)
                }

            case worker.AlreadyDone, worker.AbsorbedBy:
                state.MarkComplete(r.Task.ID)
                // Skip review - no new code written
            }
        }

        state.Save()
    }
}
```

## Comparison: Bash vs Go

### JSON Parsing

**Bash (current):**
```bash
get_task_by_id() {
  local prd_path="$1" task_id="$2"
  jq -r --arg id "$task_id" '.tasks[] | select(.id == $id)' "$prd_path"
}

get_task_dependencies() {
  local prd_path="$1" task_id="$2"
  jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .dependsOn // [] | .[]' "$prd_path"
}
```

**Go:**
```go
func (p *PRD) TaskByID(id string) (*Task, bool) {
    for i := range p.Tasks {
        if p.Tasks[i].ID == id {
            return &p.Tasks[i], true
        }
    }
    return nil, false
}

func (t *Task) Dependencies() []string {
    return t.DependsOn // It's just a field
}
```

### Parallel Execution

**Bash (current):**
```bash
# ~100 lines of background jobs, lock files, PID tracking, trap handlers
```

**Go:**
```go
func (o *Orchestrator) executeTasks(ctx context.Context, tasks []Task, state *State) []Result {
    var wg sync.WaitGroup
    results := make(chan Result, len(tasks))

    for _, t := range tasks {
        wg.Add(1)
        go func(task Task) {
            defer wg.Done()
            worker := o.router.WorkerFor(task)
            result, _ := worker.Execute(ctx, o.buildPrompt(task, state))
            result.Task = task
            results <- result
        }(t)
    }

    wg.Wait()
    close(results)

    var out []Result
    for r := range results {
        out = append(out, r)
    }
    return out
}
```

### Error Classification

**Bash (current):**
```bash
classify_error() {
  local output="$1"
  if echo "$output" | grep -qiE "(syntax error|unexpected token|parse error)"; then
    echo "syntax"
  elif echo "$output" | grep -qiE "(connection refused|timeout|ECONNRESET)"; then
    echo "integration"
  # ... 50 more lines
}
```

**Go:**
```go
var errorPatterns = map[ErrorCategory][]string{
    Syntax:      {"syntax error", "unexpected token", "parse error"},
    Integration: {"connection refused", "timeout", "ECONNRESET"},
    Environment: {"file not found", "permission denied", "command not found"},
    Logic:       {"assertion failed", "expected .* got", "test failed"},
}

func ClassifyError(output string) ErrorCategory {
    lower := strings.ToLower(output)
    for category, patterns := range errorPatterns {
        for _, p := range patterns {
            if strings.Contains(lower, p) {
                return category
            }
        }
    }
    return Unknown
}
```

## Migration Path

### Phase 1: Core Loop (1-2 weeks)
- PRD parsing and validation
- State management
- Basic task execution (sequential)
- Worker output parsing

### Phase 2: Feature Parity (2-3 weeks)
- Parallel execution
- Escalation logic
- Executive review
- Smart retry (approach tracking)

### Phase 3: Advanced Features (1-2 weeks)
- Module system
- Supervisor integration
- Walkaway mode
- Partial execution filters

### Phase 4: Polish (1 week)
- CLI flags matching current interface
- Status/summary commands
- Error messages and logging

## What Stays The Same

- `chef/*.md` - Worker prompts unchanged
- `brigade/tasks/` - PRD format unchanged
- CLI interface - Same commands, same flags
- Config format - Can keep `brigade.config` or move to YAML

## What Gets Better

1. **Testing** - Proper unit tests for routing, escalation, state transitions
2. **Type safety** - Can't accidentally pass task ID where PRD path expected
3. **Concurrency** - No more lock files and PID tracking
4. **Error messages** - Stack traces, structured logging
5. **Distribution** - Single binary, no bash/jq dependencies
6. **IDE support** - Autocomplete, refactoring, go to definition

## Language-Agnostic Module System

The current bash modules require bash. A better design: **modules are executables** that follow a simple protocol.

### Module Contract

A module is any executable that:

1. **Declares events** when called with `--events` flag
2. **Receives events** via JSON on stdin
3. **Returns status** via exit code (0 = success)

### Example: Python Module

```python
#!/usr/bin/env python3
# modules/slack.py
import sys
import json
import os
import requests

EVENTS = ["task_complete", "service_complete", "attention"]

def main():
    if "--events" in sys.argv:
        print(" ".join(EVENTS))
        return

    event = json.load(sys.stdin)
    webhook = os.environ.get("MODULE_SLACK_WEBHOOK")

    if event["type"] == "task_complete":
        requests.post(webhook, json={
            "text": f"✓ {event['task_id']} completed by {event['worker']}"
        })
    elif event["type"] == "attention":
        requests.post(webhook, json={
            "text": f"⚠️ Brigade needs attention: {event['reason']}"
        })

if __name__ == "__main__":
    main()
```

### Example: Bash Module (backwards compatible)

```bash
#!/bin/bash
# modules/notify.sh

if [[ "$1" == "--events" ]]; then
    echo "task_complete attention"
    exit 0
fi

# Read JSON event from stdin
event=$(cat)
type=$(echo "$event" | jq -r '.type')
task_id=$(echo "$event" | jq -r '.task_id // empty')

case "$type" in
    task_complete)
        notify-send "Brigade" "Task $task_id complete"
        ;;
    attention)
        notify-send -u critical "Brigade" "$(echo "$event" | jq -r '.reason')"
        ;;
esac
```

### Example: Go Module (compiled binary)

```go
// modules/pagerduty/main.go
package main

import (
    "encoding/json"
    "fmt"
    "os"
)

var events = []string{"attention", "service_complete"}

type Event struct {
    Type   string `json:"type"`
    Reason string `json:"reason,omitempty"`
    TaskID string `json:"task_id,omitempty"`
}

func main() {
    if len(os.Args) > 1 && os.Args[1] == "--events" {
        fmt.Println("attention service_complete")
        return
    }

    var event Event
    json.NewDecoder(os.Stdin).Decode(&event)

    if event.Type == "attention" {
        // Call PagerDuty API
        triggerPagerDuty(event.Reason)
    }
}
```

### Event JSON Schema

```json
{
  "type": "task_complete",
  "timestamp": "2025-01-23T10:30:00Z",
  "prd": "prd-auth.json",
  "session_id": "abc123",

  // Event-specific fields
  "task_id": "US-003",
  "worker": "sous",
  "duration": 145,
  "approach": "Using dependency injection"
}
```

### Core Module Loader (Go)

```go
// internal/module/loader.go
package module

type Module struct {
    Name   string
    Path   string   // Path to executable
    Events []string // Events it handles
}

func (m *Module) Load() error {
    // Call module with --events to discover what it handles
    out, err := exec.Command(m.Path, "--events").Output()
    if err != nil {
        return fmt.Errorf("module %s failed --events: %w", m.Name, err)
    }
    m.Events = strings.Fields(string(out))
    return nil
}

func (m *Module) Dispatch(event Event) error {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    cmd := exec.CommandContext(ctx, m.Path)
    cmd.Stdin = strings.NewReader(event.JSON())
    cmd.Env = append(os.Environ(), m.envVars()...)

    return cmd.Run()
}
```

### Module Discovery

```
modules/
├── slack.py          # Python
├── notify.sh         # Bash
├── pagerduty         # Compiled Go binary
└── discord.js        # Node.js (with shebang)
```

Core scans `modules/` directory, finds executables, calls `--events` on each to build the dispatch table.

### Migration

Existing bash modules can be wrapped:

```bash
#!/bin/bash
# modules/telegram-wrapper.sh
# Wraps the old bash module in the new protocol

if [[ "$1" == "--events" ]]; then
    echo "task_complete escalation attention service_complete"
    exit 0
fi

# Source old module and call handler based on event type
source "$(dirname "$0")/../legacy/telegram.sh"
event=$(cat)
type=$(echo "$event" | jq -r '.type')

case "$type" in
    task_complete)
        module_telegram_on_task_complete \
            "$(echo "$event" | jq -r '.task_id')" \
            "$(echo "$event" | jq -r '.worker')" \
            "$(echo "$event" | jq -r '.duration')"
        ;;
    # ... etc
esac
```

Or just rewrite them - they're typically < 50 lines.

## Risks

1. **Two codebases during migration** - Could be confusing
2. **Feature drift** - Go version might diverge from bash
3. **Learning curve** - Even with AI help, debugging requires understanding

## Recommendation

Start with Phase 1 as an experiment in a `cmd/brigade-go/` directory. Keep bash as primary until Go version reaches feature parity. The PRD format and worker prompts don't change, so switching is low-risk.
