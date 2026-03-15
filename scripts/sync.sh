#!/bin/bash
# =============================================================
#  void-archive — sync.sh
#  Syncs selected OSS repos to a remote git host
#  - Checks latest commit SHA via API before cloning
#  - Skips repos with no new commits since last sync
#  - Fetches only branches + tags (no PR/issue refs)
#  - Retries on network failure with 0.5s API cooldown
#  - Suppresses verbose git output
# =============================================================

set -euo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

# ── Required variables ────────────────────────────────────────
: "${REMOTE_TOKEN:?❌  REMOTE_TOKEN is not set}"
: "${REMOTE_URL:?❌  REMOTE_URL is not set}"
: "${PARENT_FOLDER:?❌  PARENT_FOLDER is not set}"
: "${REPOS_FILE:?❌  REPOS_FILE is not set}"
: "${GITHUB_TOKEN:?❌  GITHUB_TOKEN is not set}"

# ── Internal config ───────────────────────────────────────────
WORK_DIR="/tmp/void-work"
LOG_FILE="/tmp/sync.log"
RESULTS_FILE="/tmp/sync-results.json"
MAX_RETRIES=3
RETRY_DELAY=10
API_COOLDOWN=0.5

# ── Counters ──────────────────────────────────────────────────
SUCCESS=0
FAILED=0
SKIPPED=0
FAILED_REPOS=()

# ── Helpers ───────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
hr()  { log "─────────────────────────────────────────────"; }

silent() {
  local out
  out=$("$@" 2>&1) || {
    echo "$out" \
      | sed 's|https\?://[^ ]*||g' \
      | sed "s|$REMOTE_TOKEN|***|g" \
      | sed "s|$GITHUB_TOKEN|***|g" \
      | grep -v '^\s*$' \
      | head -5 \
      | while IFS= read -r line; do log "   $line"; done
    return 1
  }
}

with_retry() {
  local attempt=1
  while [ $attempt -le $MAX_RETRIES ]; do
    if silent "$@"; then
      return 0
    fi
    if [ $attempt -lt $MAX_RETRIES ]; then
      log "   ⚠️  Attempt $attempt failed — retrying in ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# ── Check latest commit SHA via GitHub API ────────────────────
# Returns SHA or empty string on failure
# Cooldown applied to avoid rate limiting
get_latest_sha() {
  local owner="$1"
  local repo="$2"

  sleep $API_COOLDOWN

  local response
  response=$(curl -sf \
    --max-time 10 \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${owner}/${repo}/commits?per_page=1" 2>/dev/null) || {
    echo ""
    return 0
  }

  echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if isinstance(data, list) and len(data) > 0:
        print(data[0].get('sha', ''))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# ── Remote API: ensure destination repo exists ────────────────
ensure_remote_repo() {
  local repo_name="$1"
  local encoded_path
  encoded_path=$(python3 -c \
    "import urllib.parse; print(urllib.parse.quote('${PARENT_FOLDER}/${repo_name}', safe=''))")

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    "$REMOTE_URL/api/v4/projects/$encoded_path")

  [ "$status" == "200" ] && return 0

  local group_id
  group_id=$(curl -s \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    "$REMOTE_URL/api/v4/groups?search=$PARENT_FOLDER" \
    | python3 -c "
import sys, json
try:
    groups = json.load(sys.stdin)
    print(next((g['id'] for g in groups if g['path'] == '$PARENT_FOLDER'), ''))
except Exception:
    print('')
")

  if [ -z "$group_id" ]; then
    log "   ❌ Could not find destination group"
    return 1
  fi

  local result
  result=$(curl -s -o /dev/null -w "%{http_code}" \
    --request POST \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"$repo_name\",\"path\":\"$repo_name\",\"namespace_id\":$group_id,\"visibility\":\"private\"}" \
    "$REMOTE_URL/api/v4/projects")

  if [ "$result" != "201" ]; then
    log "   ❌ Failed to create destination repo (HTTP $result)"
    return 1
  fi
}

# ── Sync a single repo ────────────────────────────────────────
sync_repo() {
  local source_url="$1"
  local last_sha="${2:-}"   # SHA from state.json, empty if first time

  local repo_name
  repo_name=$(basename "$source_url" .git)

  # Extract owner/repo from URL
  local owner
  owner=$(echo "$source_url" | sed 's|https://github.com/||' | cut -d/ -f1)

  local work_dir="$WORK_DIR/$repo_name"
  local dest_url
  dest_url="${REMOTE_URL/https:\/\//https://oauth2:${REMOTE_TOKEN}@}/${PARENT_FOLDER}/${repo_name}.git"

  log "⏳ $repo_name"

  # ── Check latest SHA before cloning ──────────────────────────
  local current_sha
  current_sha=$(get_latest_sha "$owner" "$repo_name")

  if [ -n "$current_sha" ] && [ -n "$last_sha" ] && [ "$current_sha" = "$last_sha" ]; then
    log "⏭️  $repo_name — no changes since last sync"
    echo "skipped:0:0:0:—:0:0:0:${current_sha}"
    return 0
  fi

  if [ -z "$current_sha" ]; then
    log "   ⚠️  Could not fetch SHA — proceeding with sync"
  fi

  # ── Ensure destination repo exists ───────────────────────────
  if ! ensure_remote_repo "$repo_name"; then
    log "❌ $repo_name — could not prepare destination"
    echo "failed:0:0:0:—:0:0:0:${current_sha}"
    return 1
  fi

  mkdir -p "$work_dir"

  # ── Fetch only branches + tags (no PR/issue refs) ─────────
  local clone_start clone_end clone_time
  clone_start=$(date +%s)

  if ! (
    silent git init --bare "$work_dir" && \
    cd "$work_dir" && \
    silent git remote add origin "$source_url" && \
    with_retry git fetch --prune origin \
      '+refs/heads/*:refs/heads/*' \
      '+refs/tags/*:refs/tags/*'
  ); then
    log "❌ $repo_name — fetch failed"
    rm -rf "$work_dir"
    echo "failed:0:0:0:—:0:0:0:${current_sha}"
    return 1
  fi

  clone_end=$(date +%s)
  clone_time=$((clone_end - clone_start))

  # ── Measure repo size ─────────────────────────────────────────
  local repo_size
  local repo_size_bytes
  repo_size_bytes=$(du -sb "$work_dir" 2>/dev/null | cut -f1 || echo 0)
  repo_size=$(python3 -c "
s = $repo_size_bytes
if s < 1024: print(f'{s} B')
elif s < 1048576: print(f'{s/1024:.1f} KB')
elif s < 1073741824: print(f'{s/1048576:.1f} MB')
else: print(f'{s/1073741824:.2f} GB')
")

  # ── Count branches and tags ───────────────────────────────────
  local branch_count tag_count
  cd "$work_dir"
  branch_count=$(git branch | wc -l | tr -d ' ')
  tag_count=$(git tag | wc -l | tr -d ' ')

  # ── Push: branches and tags only ─────────────────────────────
  local push_start push_end push_time
  local retries=0
  push_start=$(date +%s)

  local push_attempt=1
  local push_ok=false
  while [ $push_attempt -le $MAX_RETRIES ]; do
    if silent git push --prune "$dest_url" \
        '+refs/heads/*:refs/heads/*' \
        '+refs/tags/*:refs/tags/*'; then
      push_ok=true
      break
    fi
    if [ $push_attempt -lt $MAX_RETRIES ]; then
      retries=$((retries + 1))
      log "   ⚠️  Push attempt $push_attempt failed — retrying in ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
    fi
    push_attempt=$((push_attempt + 1))
  done

  push_end=$(date +%s)
  push_time=$((push_end - push_start))

  cd /
  rm -rf "$work_dir"

  if [ "$push_ok" = false ]; then
    log "❌ $repo_name — push failed"
    echo "failed:${clone_time}:${push_time}:$((clone_time+push_time)):${repo_size}:${branch_count}:${tag_count}:${retries}:${current_sha}"
    return 1
  fi

  local total_time=$((clone_time + push_time))
  log "✅ $repo_name (clone: ${clone_time}s push: ${push_time}s total: ${total_time}s size: $repo_size)"
  echo "success:${clone_time}:${push_time}:${total_time}:${repo_size}:${branch_count}:${tag_count}:${retries}:${current_sha}"
}

# ── Load last SHA from state.json ─────────────────────────────
get_last_sha() {
  local url="$1"
  local state_file="/tmp/prev-state.json"

  [ ! -f "$state_file" ] && echo "" && return 0

  python3 -c "
import json, sys
try:
    with open('$state_file') as f:
        state = json.load(f)
    print(state.get('$url', {}).get('last_commit_sha', ''))
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# ── Main ──────────────────────────────────────────────────────
main() {
  hr
  log "🚀 void-archive sync started"
  hr

  if [ ! -f "$REPOS_FILE" ]; then
    log "❌ Repos file not found: $REPOS_FILE"
    exit 1
  fi

  mkdir -p "$WORK_DIR"

  echo "{" > "$RESULTS_FILE"
  FIRST_ENTRY=true
  TOTAL_START=$(date +%s)

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue

    url="${line%% *}"

    # Get last known SHA from previous state
    last_sha=$(get_last_sha "$url")

    result=$(sync_repo "$url" "$last_sha")
    STATUS=$(echo "$result"     | cut -d: -f1)
    CLONE_TIME=$(echo "$result" | cut -d: -f2)
    PUSH_TIME=$(echo "$result"  | cut -d: -f3)
    TOTAL_TIME=$(echo "$result" | cut -d: -f4)
    REPO_SIZE=$(echo "$result"  | cut -d: -f5)
    BRANCHES=$(echo "$result"   | cut -d: -f6)
    TAGS=$(echo "$result"       | cut -d: -f7)
    RETRIES=$(echo "$result"    | cut -d: -f8)
    COMMIT_SHA=$(echo "$result" | cut -d: -f9)

    case "$STATUS" in
      success) SUCCESS=$((SUCCESS + 1)) ;;
      skipped) SKIPPED=$((SKIPPED + 1)) ;;
      failed)
        FAILED=$((FAILED + 1))
        FAILED_REPOS+=("$(basename "$url" .git)")
        ;;
    esac

    [ "$FIRST_ENTRY" = "true" ] && FIRST_ENTRY=false || echo "," >> "$RESULTS_FILE"
    cat >> "$RESULTS_FILE" << JSON
  "$url": {
    "status": "$STATUS",
    "clone_time": $CLONE_TIME,
    "push_time": $PUSH_TIME,
    "total_time": $TOTAL_TIME,
    "size": "$REPO_SIZE",
    "branches": $BRANCHES,
    "tags": $TAGS,
    "retries": $RETRIES,
    "last_commit_sha": "$COMMIT_SHA"
  }
JSON

  done < "$REPOS_FILE"

  TOTAL_END=$(date +%s)
  TOTAL_RUN=$((TOTAL_END - TOTAL_START))

  echo "" >> "$RESULTS_FILE"
  echo "}" >> "$RESULTS_FILE"

  hr
  log "📊 Done — ✅ $SUCCESS synced  ⏭️  $SKIPPED skipped  ❌ $FAILED failed  ⏱️  ${TOTAL_RUN}s"

  if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
    log "🔴 Failed:"
    for r in "${FAILED_REPOS[@]}"; do
      log "   - $r"
    done
  fi
  hr

  if [ "$FAILED" -gt 0 ]; then exit 1; else exit 0; fi
}

main