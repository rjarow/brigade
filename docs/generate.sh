#!/bin/bash
#
# Generate individual doc files from REFERENCE.md
#
# Usage: ./docs/generate.sh
#
# This script parses REFERENCE.md and splits it into individual markdown files
# based on <!-- section: filename --> markers.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFERENCE="$SCRIPT_DIR/REFERENCE.md"

if [ ! -f "$REFERENCE" ]; then
  echo "Error: REFERENCE.md not found at $REFERENCE"
  exit 1
fi

echo "Generating docs from REFERENCE.md..."

# Track current section and content
current_section=""
current_content=""
sections_generated=0

# Process line by line
while IFS= read -r line || [ -n "$line" ]; do
  # Check for section marker
  if [[ "$line" =~ \<!--\ section:\ ([a-zA-Z0-9/_-]+)\ --\> ]]; then
    # Save previous section if exists
    if [ -n "$current_section" ] && [ -n "$current_content" ]; then
      output_file="$SCRIPT_DIR/${current_section}.md"
      mkdir -p "$(dirname "$output_file")"
      echo "$current_content" > "$output_file"
      echo "  ✓ ${current_section}.md"
      ((sections_generated++))
    fi

    # Start new section
    current_section="${BASH_REMATCH[1]}"
    current_content=""
  else
    # Skip the source-of-truth header (first few lines before any section)
    if [ -n "$current_section" ]; then
      if [ -n "$current_content" ]; then
        current_content="$current_content"$'\n'"$line"
      else
        current_content="$line"
      fi
    fi
  fi
done < "$REFERENCE"

# Save final section
if [ -n "$current_section" ] && [ -n "$current_content" ]; then
  output_file="$SCRIPT_DIR/${current_section}.md"
  mkdir -p "$(dirname "$output_file")"
  echo "$current_content" > "$output_file"
  echo "  ✓ ${current_section}.md"
  ((sections_generated++))
fi

echo ""
echo "Generated $sections_generated files from REFERENCE.md"
echo ""
echo "Section markers in REFERENCE.md:"
grep -o '<!-- section: [^>]*-->' "$REFERENCE" | sed 's/<!-- section: /  - /g' | sed 's/ -->//g'
