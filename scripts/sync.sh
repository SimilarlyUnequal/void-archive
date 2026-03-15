#!/bin/bash

set -euo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

# ── Required variables ────────────────────────────────────────
: "${REMOTE_TOKEN:?❌  REMOTE_TOKEN is not set}"
: "${REMOTE_URL:?❌  REMOTE_URL is not set}"
: "${PARENT_FOLDER:?❌  PARENT_FOLDER is not set}"
: "${REPOS_FILE:?❌  REPOS_FILE is not set}"
: "${GITHUB_TOKEN:?❌  GITHUB_TOKEN is not set}"

# ── Optional ──────────────────────────────────────────────────
FORCE_FULL="${FORCE_FULL:-false}"

# ── Internal config ───────────────────────────────────────────
WORK_DIR="/tmp/void-work"
LOG_FILE="/tmp/sync.log"
RESULTS_FILE="/tmp/sync-results.json"
PREV_STATE="/tmp/prev-state.json"
LFS_FILE="lfs-repos.txt"
MAX_RETRIES=3
RETRY_DELAY=10
API_COOLDOWN=0.5

# ── Counters ──────────────────────────────────────────────────
SUCCESS=0
FAILED=0
SKIPPED=0
LFS_MOVED=0
FAILED_REPOS=()

# ── In-memory results dict (written to JSON at end via Python) ─
RESULTS_DATA="{}"

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

# ── GitHub API helper ─────────────────────────────────────────
github_api() {
  local endpoint="$1"
  sleep $API_COOLDOWN
  curl -sf \
    --max-time 10 \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com${endpoint}" 2>/dev/null || echo ""
}

# ── Detect LFS via GitHub API ─────────────────────────────────
# Checks .gitattributes for lfs filter — no cloning needed
has_lfs() {
  local owner="$1"
  local repo="$2"

  local response
  response=$(github_api "/repos/${owner}/${repo}/contents/.gitattributes")

  [ -z "$response" ] && return 1

  # Decode base64 content and check for lfs
  echo "$response" | python3 -c "
import sys, json, base64
try:
    data = json.load(sys.stdin)
    content = base64.b64decode(data.get('content', '')).decode('utf-8', errors='ignore')
    if 'lfs' in content.lower():
        sys.exit(0)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# ── Get latest commit SHA ─────────────────────────────────────
get_latest_sha() {
  local owner="$1"
  local repo="$2"

  local response
  response=$(github_api "/repos/${owner}/${repo}/commits?per_page=1")

  [ -z "$response" ] && echo "" && return 0

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

# ── Get last known SHA from previous state ────────────────────
get_last_sha() {
  local url="$1"
  [ ! -f "$PREV_STATE" ] && echo "" && return 0
  python3 -c "
import json
try:
    with open('$PREV_STATE') as f:
        state = json.load(f)
    print(state.get('$url', {}).get('last_commit_sha', ''))
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# ── Move repo from repos.txt to lfs-repos.txt ─────────────────
move_to_lfs_file() {
  local url="$1"

  # Remove from repos.txt
  local tmp
  tmp=$(mktemp)
  grep -vF "$url" "$REPOS_FILE" > "$tmp" || true
  mv "$tmp" "$REPOS_FILE"

  # Append to lfs-repos.txt if not already there
  touch "$LFS_FILE"
  if ! grep -qF "$url" "$LFS_FILE"; then
    echo "$url" >> "$LFS_FILE"
  fi
}

# ── Add result entry to in-memory dict ───────────────────────
add_result() {
  local url="$1"
  local status="$2"
  local clone_time="${3:-0}"
  local push_time="${4:-0}"
  local total_time="${5:-0}"
  local repo_size="${6:-—}"
  local branches="${7:-0}"
  local tags="${8:-0}"
  local retries="${9:-0}"
  local commit_sha="${10:-}"

  RESULTS_DATA=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
data[sys.argv[2]] = {
    'status':          sys.argv[3],
    'clone_time':      int(sys.argv[4]),
    'push_time':       int(sys.argv[5]),
    'total_time':      int(sys.argv[6]),
    'size':            sys.argv[7],
    'branches':        int(sys.argv[8]) if sys.argv[8].isdigit() else 0,
    'tags':            int(sys.argv[9]) if sys.argv[9].isdigit() else 0,
    'retries':         int(sys.argv[10]),
    'last_commit_sha': sys.argv[11],
}
print(json.dumps(data))
" "$RESULTS_DATA" "$url" "$status" \
    "$clone_time" "$push_time" "$total_time" \
    "$repo_size" "$branches" "$tags" \
    "$retries" "$commit_sha" 2>/dev/null) || true
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
  local repo_name
  repo_name=$(basename "$source_url" .git)
  local owner
  owner=$(echo "$source_url" | sed 's|https://github.com/||' | cut -d/ -f1)
  local work_dir="$WORK_DIR/$repo_name"
  local dest_url
  dest_url="${REMOTE_URL/https:\/\//https://oauth2:${REMOTE_TOKEN}@}/${PARENT_FOLDER}/${repo_name}.git"

  log "⏳ $repo_name"

  # ── LFS check ─────────────────────────────────────────────────
  # Skip if already in lfs-repos.txt
  touch "$LFS_FILE"
  if grep -qF "$source_url" "$LFS_FILE"; then
    log "⏭️  $repo_name — already in LFS exclusion list"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  # Check for LFS via API
  if has_lfs "$owner" "$repo_name"; then
    log "🗂️  $repo_name — LFS detected, moving to exclusion list"
    move_to_lfs_file "$source_url"
    LFS_MOVED=$((LFS_MOVED + 1))
    return 0
  fi

  # ── SHA check ─────────────────────────────────────────────────
  local current_sha=""
  local last_sha=""

  if [ "$FORCE_FULL" = "true" ]; then
    log "   🔁 Force full sync — skipping SHA check"
  else
    current_sha=$(get_latest_sha "$owner" "$repo_name")
    last_sha=$(get_last_sha "$source_url")

    if [ -n "$current_sha" ] && [ -n "$last_sha" ] && [ "$current_sha" = "$last_sha" ]; then
      log "⏭️  $repo_name — no changes since last sync"
      add_result "$source_url" "skipped" 0 0 0 "—" 0 0 0 "$current_sha"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi

    [ -z "$current_sha" ] && log "   ⚠️  Could not fetch SHA — proceeding anyway"
  fi

  # ── Ensure destination repo exists ───────────────────────────
  if ! ensure_remote_repo "$repo_name"; then
    log "❌ $repo_name — could not prepare destination"
    add_result "$source_url" "failed" 0 0 0 "—" 0 0 0 "$current_sha"
    return 1
  fi

  mkdir -p "$work_dir"

  # ── Fetch only branches + tags ────────────────────────────────
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
    add_result "$source_url" "failed" 0 0 0 "—" 0 0 0 "$current_sha"
    return 1
  fi

  clone_end=$(date +%s)
  clone_time=$((clone_end - clone_start))

  # ── Repo metrics ──────────────────────────────────────────────
  local repo_size repo_size_bytes branch_count tag_count
  repo_size_bytes=$(du -sb "$work_dir" 2>/dev/null | cut -f1 || echo 0)
  repo_size=$(python3 -c "
s = $repo_size_bytes
if s < 1024: print(f'{s} B')
elif s < 1048576: print(f'{s/1024:.1f} KB')
elif s < 1073741824: print(f'{s/1048576:.1f} MB')
else: print(f'{s/1073741824:.2f} GB')
")
  cd "$work_dir"
  branch_count=$(git branch | wc -l | tr -d ' ')
  tag_count=$(git tag | wc -l | tr -d ' ')

  # ── Push: branches + tags only ────────────────────────────────
  local push_start push_end push_time retries=0
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
  local total_time=$((clone_time + push_time))

  cd /
  rm -rf "$work_dir"

  if [ "$push_ok" = false ]; then
    log "❌ $repo_name — push failed"
    add_result "$source_url" "failed" \
      "$clone_time" "$push_time" "$total_time" \
      "$repo_size" "$branch_count" "$tag_count" "$retries" "$current_sha"
    return 1
  fi

  log "✅ $repo_name (clone: ${clone_time}s push: ${push_time}s total: ${total_time}s size: $repo_size)"
  add_result "$source_url" "success" \
    "$clone_time" "$push_time" "$total_time" \
    "$repo_size" "$branch_count" "$tag_count" "$retries" "$current_sha"
  SUCCESS=$((SUCCESS + 1))
}

# ── Main ──────────────────────────────────────────────────────
main() {
  hr
  log "🚀 void-archive sync started (force_full: $FORCE_FULL)"
  hr

  if [ ! -f "$REPOS_FILE" ]; then
    log "❌ Repos file not found: $REPOS_FILE"
    exit 1
  fi

  mkdir -p "$WORK_DIR"
  touch "$LFS_FILE"

  TOTAL_START=$(date +%s)

  # Read repos into array first — repos.txt may change during loop (LFS removal)
  mapfile -t REPO_URLS < <(grep -v '^\s*#' "$REPOS_FILE" | grep -v '^\s*$' | grep '^http' || true)

  for url in "${REPO_URLS[@]}"; do
    sync_repo "$url" || FAILED_REPOS+=("$(basename "$url" .git)")
  done

  TOTAL_END=$(date +%s)
  TOTAL_RUN=$((TOTAL_END - TOTAL_START))

  # ── Write results JSON via Python (safe escaping) ─────────────
  echo "$RESULTS_DATA" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    with open('$RESULTS_FILE', 'w') as f:
        json.dump(data, f, indent=2)
    print('✅ Results written')
except Exception as e:
    print(f'❌ Results write error: {e}', file=sys.stderr)
    sys.exit(1)
"

  hr
  log "📊 Done — ✅ $SUCCESS synced  ⏭️  $SKIPPED skipped  🗂️  $LFS_MOVED moved to LFS list  ❌ ${#FAILED_REPOS[@]} failed  ⏱️  ${TOTAL_RUN}s"

  if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
    log "🔴 Failed:"
    for r in "${FAILED_REPOS[@]}"; do
      log "   - $r"
    done
  fi

  if [ "$LFS_MOVED" -gt 0 ]; then
    log "🗂️  Moved to LFS exclusion list — will be committed by workflow"
  fi
  hr

  if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then exit 1; else exit 0; fi
}

main