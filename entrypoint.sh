#!/bin/bash
set -e

if [ -z "$OPENCLAW_VERSION" ]; then
  echo "ERROR: OPENCLAW_VERSION env var is required but not set."
  exit 1
fi

INSTALLED=$(node -e "try{console.log(require('/usr/local/lib/node_modules/openclaw/package.json').version)}catch(e){console.log('')}" 2>/dev/null)
if [ "$INSTALLED" != "$OPENCLAW_VERSION" ]; then
  echo "Installing openclaw@${OPENCLAW_VERSION} (currently: ${INSTALLED:-none})..."
  npm install -g openclaw@${OPENCLAW_VERSION}
else
  echo "openclaw@${OPENCLAW_VERSION} already installed, skipping."
fi

chown -R openclaw:openclaw /data
chmod 700 /data

if [ ! -d /data/.linuxbrew ]; then
  cp -a /home/linuxbrew/.linuxbrew /data/.linuxbrew
fi

rm -rf /home/linuxbrew/.linuxbrew
ln -sfn /data/.linuxbrew /home/linuxbrew/.linuxbrew

# -----------------------------------------------------------------------------
# AHI: workspace bootstrap / auto-sync
# -----------------------------------------------------------------------------
# On first boot, clone $AHI_WORKSPACE_REPO (e.g. "projectahi/ahi-pm-workspace")
# into $OPENCLAW_WORKSPACE_DIR. On subsequent boots, fast-forward pull to pick
# up any git-committed workspace changes.
#
# Requires Railway env vars:
#   GITHUB_TOKEN         - PAT with repo:read on the workspace repo
#   AHI_WORKSPACE_REPO   - "owner/repo" form, e.g. "projectahi/ahi-pm-workspace"
#
# If either is unset, this block is a no-op and OpenClaw uses whatever files
# are already on /data/workspace (or its internal defaults).
# -----------------------------------------------------------------------------
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
if [ -n "${AHI_WORKSPACE_REPO:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  CLONE_URL="https://${GITHUB_TOKEN}@github.com/${AHI_WORKSPACE_REPO}.git"
  if [ -d "${WORKSPACE_DIR}/.git" ] && git -C "${WORKSPACE_DIR}" remote get-url origin >/dev/null 2>&1; then
    # Existing git repo, pull latest
    echo "[bootstrap] Updating workspace from ${AHI_WORKSPACE_REPO}"
    (
      cd "${WORKSPACE_DIR}" && \
      git remote set-url origin "${CLONE_URL}" && \
      git fetch --depth 1 origin main && \
      git reset --hard origin/main
    ) || echo "[bootstrap] WARN: workspace update failed, continuing with existing files"
  else
    # Fresh boot, empty volume, or non-git workspace — clone into temp and merge
    echo "[bootstrap] Cloning workspace from ${AHI_WORKSPACE_REPO} (first boot)"
    TMP_CLONE=$(mktemp -d /tmp/workspace-clone.XXXXXX)
    if git clone --depth 1 "${CLONE_URL}" "${TMP_CLONE}"; then
      # Preserve any OpenClaw-created runtime state that the clone doesn't ship
      [ -d "${WORKSPACE_DIR}/.openclaw" ] && cp -a "${WORKSPACE_DIR}/.openclaw" "${TMP_CLONE}/" 2>/dev/null || true
      [ -d "${WORKSPACE_DIR}/state" ]     && cp -a "${WORKSPACE_DIR}/state"     "${TMP_CLONE}/" 2>/dev/null || true
      if [ -d "${WORKSPACE_DIR}/memory" ]; then
        mkdir -p "${TMP_CLONE}/memory"
        cp -a "${WORKSPACE_DIR}/memory/." "${TMP_CLONE}/memory/" 2>/dev/null || true
      fi
      rm -rf "${WORKSPACE_DIR}"
      mv "${TMP_CLONE}" "${WORKSPACE_DIR}"
      echo "[bootstrap] Workspace ready at ${WORKSPACE_DIR}"
    else
      echo "[bootstrap] WARN: git clone failed, falling back to existing workspace"
      rm -rf "${TMP_CLONE}"
    fi
  fi
  chown -R openclaw:openclaw "${WORKSPACE_DIR}" 2>/dev/null || true
else
  echo "[bootstrap] SKIP workspace sync: AHI_WORKSPACE_REPO or GITHUB_TOKEN not set"
fi

# -----------------------------------------------------------------------------
# AHI: clone code repos to /data/repos/<name>/
# -----------------------------------------------------------------------------
# Clones (or updates) each repo listed in $AHI_CODE_REPOS. These are reference
# clones for the PM agent to browse code and for coding workers to create
# worktrees from. Separate from /data/workspace to avoid polluting workspace sync.
# -----------------------------------------------------------------------------
if [ -n "${AHI_CODE_REPOS:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  mkdir -p /data/repos
  for REPO in ${AHI_CODE_REPOS}; do
    REPO_NAME=$(basename "$REPO")
    REPO_DIR="/data/repos/${REPO_NAME}"
    CLONE_URL="https://${GITHUB_TOKEN}@github.com/${REPO}.git"
    if [ -d "${REPO_DIR}/.git" ]; then
      echo "[bootstrap] Updating code repo ${REPO}"
      git -C "${REPO_DIR}" remote set-url origin "${CLONE_URL}" 2>/dev/null
      git -C "${REPO_DIR}" fetch --depth 1 origin main 2>/dev/null && \
        git -C "${REPO_DIR}" reset --hard origin/main 2>/dev/null || \
        echo "[bootstrap] WARN: update failed for ${REPO}, continuing"
    else
      echo "[bootstrap] Cloning code repo ${REPO}"
      git clone --depth 1 "${CLONE_URL}" "${REPO_DIR}" || \
        echo "[bootstrap] WARN: clone failed for ${REPO}, skipping"
    fi
  done
  chown -R openclaw:openclaw /data/repos 2>/dev/null || true
else
  echo "[bootstrap] SKIP code repo clone: AHI_CODE_REPOS or GITHUB_TOKEN not set"
fi

# Worktree directory for coding workers (outside workspace and repos)
mkdir -p /data/worktrees
chown openclaw:openclaw /data/worktrees 2>/dev/null || true

# -----------------------------------------------------------------------------
# AHI: install workspace-sync.sh into /data/.openclaw/scripts/
# -----------------------------------------------------------------------------
# HEARTBEAT.md calls this script every heartbeat for bidirectional git sync.
# It lives in the image at /app/scripts/ and is copied into the volume path
# /data/.openclaw/scripts/ so the agent can invoke it at a stable location.
# -----------------------------------------------------------------------------
STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
mkdir -p "${STATE_DIR}/scripts"
if [ -f /app/scripts/workspace-sync.sh ]; then
  cp /app/scripts/workspace-sync.sh "${STATE_DIR}/scripts/workspace-sync.sh"
  chmod +x "${STATE_DIR}/scripts/workspace-sync.sh"
  echo "[bootstrap] Installed workspace-sync.sh to ${STATE_DIR}/scripts/"
fi
chown -R openclaw:openclaw "${STATE_DIR}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# AHI: authenticate gh CLI so the agent can check PRs, CI, and create PRs
# -----------------------------------------------------------------------------
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "${GITHUB_TOKEN}" | gosu openclaw gh auth login --with-token 2>/dev/null || \
    echo "[bootstrap] WARN: gh auth login failed"
fi

exec gosu openclaw node src/server.js
