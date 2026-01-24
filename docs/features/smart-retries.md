# Smart Retries

Brigade learns from failures instead of repeating them.

## Error Classification

Failures are categorized automatically:

| Category | Examples |
|----------|----------|
| **syntax** | Parse errors, compilation failures |
| **integration** | Network errors, API failures, timeouts |
| **environment** | Missing files, permission denied |
| **logic** | Test failures, assertion errors |

## Approach Tracking

Workers declare strategy using `<approach>`:

```xml
<approach>Direct API integration with retry logic</approach>
```

On retry, previous approaches appear:

```
PREVIOUS APPROACHES (avoid repeating these):
- Direct API integration → integration: Connection refused
- Raw HTTP requests → integration: timeout

Try a DIFFERENT approach.
```

## Strategy Suggestions

Based on error category, workers receive suggestions:

| Category | Suggestions |
|----------|-------------|
| **integration** | Mock the service, use test doubles |
| **environment** | Check file paths, verify permissions |
| **syntax** | Check language version, verify imports |
| **logic** | Re-read acceptance criteria, check edge cases |

## Escalation Context

When escalating, the new worker sees what was tried:

```
=== ESCALATION CONTEXT ===
Escalated from Line Cook after multiple failures.

Attempted approaches:
- line: Direct API call → integration
- line: Retry with timeout → integration

Do NOT repeat these approaches.
===========================
```

## Configuration

```bash
SMART_RETRY_ENABLED=true
SMART_RETRY_CUSTOM_PATTERNS="MyError:logic,ServiceDown:integration"
SMART_RETRY_APPROACH_HISTORY_MAX=3
```

