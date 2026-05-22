#!/bin/bash
INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# Only intercept prod_info.md
if [[ "$FILE" != *"prod_info.md"* ]]; then
  exit 0
fi

RESULT=$(osascript 2>/dev/null <<'APPLESCRIPT'
display dialog "Allow modification to prod_info.md?" & return & "(Auto-denies in 5 minutes if no response.)" buttons {"Deny", "Allow"} default button "Deny" giving up after 300
APPLESCRIPT
)

if [[ "$RESULT" == *"button returned:Allow"* ]]; then
  exit 0
fi

# Timed out or denied
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"prod_info.md modification denied — no confirmation received within 5 minutes or explicitly denied. Continuing without this change."}}'
