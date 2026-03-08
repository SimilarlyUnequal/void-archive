#!/bin/bash
set -euo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

# ── Required variables (fail immediately if any missing) ─────
: "${REMOTE_TOKEN:?❌  REMOTE_TOKEN is not set}"
: "${REMOTE_URL:?❌  REMOTE_URL is not set}"
: "${PARENT_FOLDER:?❌  PARENT_FOLDER is not set}"
: "${REPOS_FILE:?❌  REPOS_FILE is not set}"

# ── Internal config ───────────────────────────────────────────
WORK_DIR="/tmp/void-work"
LOG_FILE="/tmp/sync.log"

# ── Counters ──────────────────────────────────────────────────
SUCCESS=0
FAILED=0
FAILED_REPOS=()

# ── Helpers ───────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
hr()  { log "─────────────────────────────────────────────"; }

# Sanitize any error output
safe_err() {
  sed 's|https\?://[^ ]*||g; s|oauth2:[^ ]*||g; s|'"$REMOTE_TOKEN"'|***|g' 2>/dev/null || true
}


ensure_remote_repo() {
  local repo_name="$1"
  local encoded_path
  encoded_path=$(python3 -c \
    "import urllib.parse; print(urllib.parse.quote('${PARENT_FOLDER}/${repo_name}', safe=''))")

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    "$REMOTE_URL/api/v4/projects/$encoded_path")

  if [ "$status" == "200" ]; then
    return 0  # already exists
  fi

  local group_id
  group_id=$(curl -s \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    "$REMOTE_URL/api/v4/groups?search=$PARENT_FOLDER" \
    | python3 -c "
import sys, json
groups = json.load(sys.stdin)
match = next((g['id'] for g in groups if g['path'] == '$PARENT_FOLDER'), '')
print(match)
")

  if [ -z "$group_id" ]; then
    log "   Could not find destination group"
    return 1
  fi

  # Create the repo
  local result
  result=$(curl -s -o /dev/null -w "%{http_code}" \
    --request POST \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"$repo_name\",\"path\":\"$repo_name\",\"namespace_id\":$group_id,\"visibility\":\"private\"}" \
    "$REMOTE_URL/api/v4/projects")

  if [ "$result" != "201" ]; then
    log "   Failed to create destination repo (HTTP $result)"
    return 1
  fi
}

# ── Sync a single repo ────────────────────────────────────────
sync_repo() {
  local source_url="$1"
  local repo_name
  repo_name=$(basename "$source_url" .git)
  local work_dir="$WORK_DIR/$repo_name"

  local dest_url
  dest_url="${REMOTE_URL/https:\/\//https://oauth2:${REMOTE_TOKEN}@}/${PARENT_FOLDER}/${repo_name}.git"

  log "⏳ $repo_name"

  if ! ensure_remote_repo "$repo_name" 2>&1 | safe_err; then
    log "$repo_name — could not prepare destination"
    return 1
  fi

  mkdir -p "$WORK_DIR"
  if ! git clone --mirror "$source_url" "$work_dir" 2>&1 | safe_err; then
    log "$repo_name — source unreachable"
    rm -rf "$work_dir"
    return 1
  fi

  cd "$work_dir"
  if ! git push --mirror "$dest_url" 2>&1 | safe_err; then
    log "$repo_name — push failed"
    cd /
    rm -rf "$work_dir"
    return 1
  fi

  cd /
  rm -rf "$work_dir"
  log "✅ $repo_name"
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

  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue

    url="${line%% *}"

    if sync_repo "$url"; then
      SUCCESS=$((SUCCESS + 1))
    else
      FAILED_REPOS+=("$(basename "$url" .git)")
      FAILED=$((FAILED + 1))
    fi

  done < "$REPOS_FILE"

  # ── Summary ──────────────────────────────────────────────────
  hr
  log "📊 Done — ✅ $SUCCESS succeeded  ❌ $FAILED failed"

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