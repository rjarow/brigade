#!/usr/bin/env bash
# Run all brigade tests
# Requires: bats-core (brew install bats-core)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for bats
if ! command -v bats &> /dev/null; then
  echo "Error: bats-core not found"
  echo ""
  echo "Install with:"
  echo "  brew install bats-core    # macOS"
  echo "  apt install bats          # Debian/Ubuntu"
  echo "  npm install -g bats       # npm"
  exit 1
fi

echo "Running Brigade tests..."
echo ""

# Run all .bats files in the tests directory
bats "$SCRIPT_DIR"/*.bats "$@"
