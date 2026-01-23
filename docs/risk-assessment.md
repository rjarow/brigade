# Risk Assessment Guide

The risk assessment feature helps you understand the complexity and potential challenges of a PRD before execution.

## Usage

```bash
# Analyze risk for a PRD
./brigade.sh risk brigade/tasks/prd.json

# Include historical escalation patterns
./brigade.sh risk --history brigade/tasks/prd.json
```

## Risk Scoring

Tasks are scored based on multiple factors:

### High-Risk Indicators (3 points each)
- **Authentication**: Tasks involving auth, JWT, OAuth, sessions
- **Payment Processing**: Billing, payments, transactions, checkout
- **Database Migrations**: Schema changes, migrations
- **Security**: Encryption, security, vulnerabilities
- **External APIs**: Third-party integrations

### Medium-Risk Indicators (2 points each)
- **No Verification**: Tasks without test verification commands
- **Multiple Dependencies**: Tasks with 3+ dependencies

### Low-Risk Indicators (1 point each)
- **Senior Complexity**: Tasks marked as "senior" complexity

## Risk Levels

- **Low Risk (0-3)**: Straightforward tasks, well-defined scope
- **Medium Risk (4-6)**: Moderate complexity, some unknowns
- **High Risk (7-10)**: Complex tasks with multiple risk factors
- **Very High Risk (11+)**: Substantial complexity, high chance of escalation

## Configuration

In `brigade.config`:

```bash
# Enable risk report before service execution
RISK_REPORT_ENABLED=true

# Warn if aggregate risk exceeds threshold
RISK_WARN_THRESHOLD=15
```

## Interpreting Results

The risk report shows:
- Individual task scores
- Aggregate PRD complexity
- Estimated escalation likelihood
- Flagged sensitive areas

Use this to:
- Adjust task complexity assignments
- Add verification commands to high-risk tasks
- Break down complex tasks into smaller chunks
- Plan for additional review cycles
