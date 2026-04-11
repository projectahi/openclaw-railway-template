#!/usr/bin/env bash
# workspace-sync.sh - bidirectional git sync for /data/workspace
#
# Called from HEARTBEAT.md every ~45 min, or manually during debugging.
# Commits any local agent-evolved changes (memory/, tasks/*.md), then pulls
# --ff-only with rebase fallback, then pushes.
#
# Design source: best-practices/13-git-backed-workspace-sync.md §5.
#
# Exit codes:
#   0   OK (possibly a no-op)
#   2   rebase conflict — human intervention needed
#   3   retry pull after push race failed
#   4   retry push after pull failed
#  10   workspace dir is not a git repo
#
# Stdout contract (parsed by HEARTBEAT.md):
#   WORKSPACE_SYNC_EXIT=<code>
#   CHANGED_FILES=<space-separated list>   (only if non-empty)
#
# All detailed logs go to $STATE_DIR/scripts/workspace-sync.log.

set -euo pipefail

WORKSPACE="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
SCRIPTS_DIR="${STATE_DIR}/scripts"
LOG="${SCRIPTS_DIR}/workspace-sync.log"
LOCK="${SCRIPTS_DIR}/workspace-sync.lock"

mkdir -p "$SCRIPTS_DIR"

# Fail fast if the workspace isn't a git repo yet (first boot race).
if [ ! -d "$WORKSPACE/.git" ]; then
  echo "WORKSPACE_SYNC_EXIT=10"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: $WORKSPACE is not a git repo" >> "$LOG"
  exit 10
fi

# Prevent overlapping runs (heartbeat and manual invocation can collide).
exec 200>"$LOCK"
if ! flock -n 200; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) another sync in progress, skipping" >> "$LOG"
  echo "WORKSPACE_SYNC_EXIT=0"
  exit 0
fi

cd "$WORKSPACE"

# Railway volume UID rarely matches the container user — dodge the
# "dubious ownership" error that would otherwise hang every git command.
git config --global --add safe.directory "$WORKSPACE" 2>/dev/null || true

# Agent commit identity. Uses @users.noreply.github.com so GitHub doesn't
# auto-link commits to a real person's account.
git config user.name  "ahi-pm-agent"
git config user.email "ahi-pm-agent@users.noreply.github.com"

# Inject auth token into remote URL if it isn't already there. The entrypoint
# does this on first boot, but the URL can be reset by git on some operations.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  CURRENT_URL=$(git remote get-url origin)
  if ! echo "$CURRENT_URL" | grep -q '@github.com'; then
    AUTH_URL=$(echo "$CURRENT_URL" | sed "s#https://github.com#https://x-access-token:${GITHUB_TOKEN}@github.com#")
    git remote set-url origin "$AUTH_URL"
  fi
fi

EXIT_CODE=0
CHANGED_FILES=""

{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  # Capture pre-sync HEAD so we can diff what the pull brought in.
  PRE_SYNC_HEAD=$(git rev-parse HEAD)

  # 1. Commit local agent-evolved changes first. Doing this before pull means
  # the pull has something concrete to fast-forward against — no silent
  # auto-stash, no lossy merge paths.
  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    git add -A
    if ! git diff --cached --quiet; then
      git commit -m "agent: heartbeat snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "committed local changes"
    fi
  fi

  # 2. Fetch, then try fast-forward pull. If the remote has diverged AND
  # we have local commits, ff-only fails loudly — we then try a plain
  # rebase (safe because agent writes are append-only to dated memory files).
  git fetch --depth 1 origin main
  if git pull --ff-only origin main; then
    echo "pull --ff-only OK"
  else
    echo "ff-only failed, trying rebase"
    if git pull --rebase origin main; then
      echo "rebase OK"
    else
      git rebase --abort || true
      echo "REBASE CONFLICT - human intervention needed"
      EXIT_CODE=2
    fi
  fi

  # 3. Push, with one retry on push-race (origin advanced during our window).
  if [ "$EXIT_CODE" = "0" ]; then
    if ! git push origin main; then
      echo "push failed, pulling and retrying once"
      if ! git pull --rebase origin main; then
        echo "retry pull failed"
        EXIT_CODE=3
      elif ! git push origin main; then
        echo "retry push failed"
        EXIT_CODE=4
      fi
    fi
  fi

  # 4. Compute what changed in this sync (for the agent to react to).
  POST_SYNC_HEAD=$(git rev-parse HEAD)
  if [ "$PRE_SYNC_HEAD" != "$POST_SYNC_HEAD" ]; then
    CHANGED_FILES=$(git diff --name-only "$PRE_SYNC_HEAD" "$POST_SYNC_HEAD" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    echo "changed since last sync: $CHANGED_FILES"
  else
    echo "no changes since last sync"
  fi

  echo "=== done (exit=$EXIT_CODE) ==="
} >> "$LOG" 2>&1

# Structured stdout for HEARTBEAT.md's step 1 to parse.
echo "WORKSPACE_SYNC_EXIT=$EXIT_CODE"
if [ -n "$CHANGED_FILES" ]; then
  echo "CHANGED_FILES=$CHANGED_FILES"
fi

exit $EXIT_CODE
