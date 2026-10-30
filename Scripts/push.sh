#!/bin/bash
# Commit every change in the project and push it to GitHub.
#   bash Scripts/push.sh                  # commit message defaults to a timestamp
#   bash Scripts/push.sh "修复侧栏缝隙"    # custom commit message
# QISHI_REMOTE overrides the repository URL used when origin is not set yet.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${QISHI_REMOTE:-https://github.com/SlxBYR/qishi-claude.git}"
cd "$ROOT"
command -v git >/dev/null || { printf '%s\n' 'FAIL: git is required.' >&2; exit 1; }
[ -d .git ] || git init -b main
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REMOTE"
BRANCH="$(git symbolic-ref --short HEAD)"
git add -A
if git diff --cached --quiet; then
  printf '%s\n' 'No changes to commit.'
else
  git commit -m "${1:-Update $(date '+%Y-%m-%d %H:%M')}"
fi
git push -u origin "$BRANCH"
printf 'Pushed %s to %s\n' "$BRANCH" "$(git remote get-url origin)"
