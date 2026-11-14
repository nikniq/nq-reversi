#!/bin/bash
# Stop hook: commit any changes and push to origin after each Claude turn.
cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || cd "$(dirname "$0")/../.."
git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "Auto-commit: $(date '+%Y-%m-%d %H:%M:%S')" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
fi
branch=$(git rev-parse --abbrev-ref HEAD)
if git push -q -u origin "$branch" 2>/tmp/claude-autopush.err; then
  echo '{"systemMessage":"Auto-pushed to GitHub"}'
else
  msg=$(tr '\n"' ' ' </tmp/claude-autopush.err | cut -c1-200)
  echo "{\"systemMessage\":\"Auto-push failed: $msg\"}"
fi
