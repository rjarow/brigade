#!/bin/bash
# Install Brigade commands to ~/.claude/commands/
# This makes /brigade-generate-prd and /brigade-convert-prd-to-json available globally

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_DIR="$HOME/.claude/commands"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}Installing Brigade commands...${NC}"
echo ""

# Create commands directory if it doesn't exist
mkdir -p "$COMMANDS_DIR"

# Find commands directory
if [ -d "$SCRIPT_DIR/commands" ]; then
    BRIGADE_COMMANDS_DIR="$SCRIPT_DIR/commands"
else
    echo "Error: Could not find commands directory at $SCRIPT_DIR/commands"
    exit 1
fi

# Create symlinks to command files (so updates propagate automatically)
for cmd in "$BRIGADE_COMMANDS_DIR"/*.md; do
    if [ -f "$cmd" ]; then
        filename=$(basename "$cmd")
        ln -sf "$cmd" "$COMMANDS_DIR/$filename"
        echo -e "  ${GREEN}→${NC} Linked: $filename"
    fi
done

echo ""
echo -e "${GREEN}Done!${NC} Commands symlinked to $COMMANDS_DIR"
echo ""
echo "Available commands in Claude Code:"
echo "  /brigade-generate-prd       - Create a new PRD through interactive interview"
echo "  /brigade-convert-prd-to-json - Convert markdown PRD to JSON for Brigade"
echo ""
echo "To update commands later, just: cd brigade && git pull"
echo "(Symlinks auto-update, no reinstall needed)"
echo ""
