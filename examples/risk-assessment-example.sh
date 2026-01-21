#!/bin/bash
# Example: Using Brigade's Risk Assessment Feature
# This example demonstrates how to analyze PRD risk before execution

set -e

echo "=== Brigade Risk Assessment Example ==="
echo

# Example 1: Basic risk assessment
echo "1. Basic risk assessment of a PRD:"
echo "   ./brigade.sh risk brigade/tasks/prd-example.json"
echo

# Example 2: Risk assessment with historical data
echo "2. Risk assessment including historical patterns:"
echo "   ./brigade.sh risk --history brigade/tasks/prd-example.json"
echo

# Example 3: Interpreting risk scores
echo "3. Understanding risk scores:"
echo "   - Overall Risk: Combined score from all factors"
echo "   - Complexity: Based on task complexity distribution"
echo "   - Dependencies: Based on dependency chain depth"
echo "   - Verification: Based on test coverage quality"
echo "   - Size: Based on number of tasks"
echo

# Example 4: Using risk assessment in CI/CD
echo "4. CI/CD integration example:"
cat << 'EOF'
   # In your CI pipeline:
   RISK_SCORE=$(./brigade.sh risk prd.json | grep "Overall Risk:" | awk '{print $3}')
   if [ "$RISK_SCORE" = "HIGH" ]; then
     echo "High risk detected - requiring manual approval"
     exit 1
   fi
EOF
echo

echo "For more details, see: docs/risk-assessment.md"
