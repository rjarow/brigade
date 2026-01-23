# Smart Retries

Brigade learns from failures instead of repeating them. When tasks fail, errors are classified, approaches are tracked, and retry prompts include what was already tried.

## Error Classification

Failures are automatically categorized:

| Category | Examples |
|----------|----------|
| **syntax** | Parse errors, compilation failures, unexpected tokens |
| **integration** | Network errors, API failures, timeouts, connection refused |
| **environment** | Missing files, permission denied, command not found |
| **logic** | Test failures, assertion errors, wrong output |

Classification appears in walkaway decisions and retry prompts.

## Approach Tracking

Workers declare their strategy using the `<approach>` signal:

```xml
<approach>Direct API integration with retry logic</approach>
```

On retry, previous approaches appear in a "PREVIOUS APPROACHES" section:

```
PREVIOUS APPROACHES (avoid repeating these):
- Direct API integration → integration: Connection refused
- Raw HTTP requests → integration: timeout

Try a DIFFERENT approach.
```

This prevents workers from repeatedly attempting failed strategies.

## Strategy Suggestions

Based on error category, workers receive tailored suggestions:

| Category | Suggestions |
|----------|-------------|
| **integration** | Try: Mock the service, use test doubles, verify service is running |
| **environment** | Try: Check file paths, verify permissions, ensure dependencies installed |
| **syntax** | Try: Check language version, verify imports, review compiler output |
| **logic** | Try: Re-read acceptance criteria, check edge cases, verify test setup |

## Escalation Context

When escalating to a higher tier, the new worker sees what was already tried:

```
=== ESCALATION CONTEXT ===
Escalated from Line Cook after multiple failures.

Attempted approaches:
- line: Direct API call → integration
- line: Retry with timeout → integration

Do NOT repeat these approaches.
===========================
```

This gives Sous Chef or Executive Chef full context to try a different strategy.

## Cross-Task Learning

Session failures are tracked across tasks. If Task A fails on a pattern, Task B sees a warning:

```
SESSION FAILURES (issues encountered in other tasks this session):
- integration: Connection refused on port 8080
- environment: Missing config file

Be aware of these patterns that have caused problems.
```

## Configuration

```bash
# Enable all smart retry features (default: true)
SMART_RETRY_ENABLED=true

# Custom error patterns for your codebase
# Format: comma-separated "pattern:category" pairs
SMART_RETRY_CUSTOM_PATTERNS="MyCustomError:logic,ServiceUnavailable:integration"

# Custom strategy suggestions (JSON file)
# Format: {"syntax": "Try: ...", "integration": "Try: ...", ...}
SMART_RETRY_STRATEGIES_FILE=""

# Max approaches shown in retry prompt (prevents bloat)
SMART_RETRY_APPROACH_HISTORY_MAX=3

# Max session failures tracked for cross-task learning
SMART_RETRY_SESSION_FAILURES_MAX=5

# Auto-add to learnings after N same-category failures
# Set to 0 to disable auto-learning
SMART_RETRY_AUTO_LEARNING_THRESHOLD=3
```

## How It Works

1. **Worker attempts task** and fails
2. **Error output is classified** into category (syntax/integration/environment/logic)
3. **Approach is recorded** if worker used `<approach>` signal
4. **On retry**, worker sees:
   - Previous approaches and their outcomes
   - Strategy suggestions for the error category
   - Session-wide failures from other tasks
5. **On escalation**, next-tier worker sees full context of what was tried

## Best Practices

### For Workers

Use the `<approach>` signal when trying a specific strategy:

```xml
<approach>Using mocked API responses for testing</approach>
```

This helps future attempts (and escalations) understand what was tried.

### For PRD Authors

Add custom error patterns for domain-specific errors:

```bash
SMART_RETRY_CUSTOM_PATTERNS="RateLimitError:integration,ValidationFailed:logic"
```

### For Debugging

Enable debug mode to see classification in action:

```bash
BRIGADE_DEBUG=true ./brigade.sh service prd.json
```

Output includes error classification decisions and approach tracking.
