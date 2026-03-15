#!/bin/bash
# =============================================================
#  void-archive — sync.sh
#  Syncs selected OSS repos to a remote git host
#  - Reads repos.yml (grouped + ungrouped)
#  - Creates GitLab subgroups automatically
#  - Detects LFS via API before cloning — moves to lfs-repos.txt
#  - Checks latest commit SHA via API — skips unchanged repos
#  - FORCE_FULL=true bypasses SHA check
#  - Fetches only branches + tags (no PR/issue refs)
#  - Writes sync-results.json via Python (safe JSON escaping)
#  - Retries on network failure
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
: "${GITHUB_WORKSPACE:?❌  GITHUB_WORKSPACE is not set}"

# ── Optional ──────────────────────────────────────────────────
FORCE_FULL="${FORCE_FULL:-false}"

# ── Resolve workspace paths ───────────────────────────────────
REPOS_FILE="$(realpath "$REPOS_FILE")"
LFS_FILE="${GITHUB_WORKSPACE}/lfs-repos.txt"

# ── Internal config ───────────────────────────────────────────
WORK_DIR="/tmp/void-work"
LOG_FILE="/tmp/sync.log"
RESULTS_FILE="/tmp/sync-results.json"
PREV_STATE="/tmp/prev-state.json"
MAX_RETRIES=3
RETRY_DELAY=10
API_COOLDOWN=0.5

# ── Counters ──────────────────────────────────────────────────
SUCCESS=0
FAILED=0
SKIPPED=0
LFS_MOVED=0
FAILED_REPOS=()

# ── In-memory results ─────────────────────────────────────────
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
has_lfs() {
  local owner="$1"
  local repo="$2"
  local response
  response=$(github_api "/repos/${owner}/${repo}/contents/.gitattributes")
  [ -z "$response" ] && return 1
  echo "$response" | python3 -c "
import sys, json, base64
try:
    data = json.load(sys.stdin)
    content = base64.b64decode(data.get('content', '')).decode('utf-8', errors='ignore')
    sys.exit(0 if 'lfs' in content.lower() else 1)
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
    print(data[0].get('sha', '') if isinstance(data, list) and data else '')
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

# ── Move repo to LFS exclusion list ──────────────────────────
move_to_lfs_file() {
  local url="$1"
  local repos_file="$REPOS_FILE"

  # Remove from repos.yml using Python
  python3 - "$repos_file" "$url" << 'PYEOF'
import sys, yaml

repos_file = sys.argv[1]
url        = sys.argv[2]

try:
    with open(repos_file) as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    print(f"[lfs] repos.yml read error: {e}", file=sys.stderr)
    sys.exit(1)

# Remove from groups
for group in (data.get("groups") or {}).values():
    if group and url in group:
        group.remove(url)

# Remove from ungrouped
ungrouped = data.get("ungrouped") or []
if url in ungrouped:
    ungrouped.remove(url)
data["ungrouped"] = ungrouped

try:
    with open(repos_file, "w") as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
    print(f"✅ Removed from repos.yml")
except Exception as e:
    print(f"[lfs] repos.yml write error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

  # Append to lfs-repos.txt
  touch "$LFS_FILE"
  if ! grep -qF "$url" "$LFS_FILE"; then
    echo "$url" >> "$LFS_FILE"
  fi
}

# ── Add result entry ──────────────────────────────────────────
add_result() {
  local url="$1"
  local subgroup="$2"
  local status="$3"
  local clone_time="${4:-0}"
  local push_time="${5:-0}"
  local total_time="${6:-0}"
  local repo_size="${7:-—}"
  local branches="${8:-0}"
  local tags="${9:-0}"
  local retries="${10:-0}"
  local commit_sha="${11:-}"

  RESULTS_DATA=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
data[sys.argv[2]] = {
    'subgroup':        sys.argv[3],
    'status':          sys.argv[4],
    'clone_time':      int(sys.argv[5]),
    'push_time':       int(sys.argv[6]),
    'total_time':      int(sys.argv[7]),
    'size':            sys.argv[8],
    'branches':        int(sys.argv[9])  if sys.argv[9].isdigit()  else 0,
    'tags':            int(sys.argv[10]) if sys.argv[10].isdigit() else 0,
    'retries':         int(sys.argv[11]),
    'last_commit_sha': sys.argv[12],
}
print(json.dumps(data))
" "$RESULTS_DATA" "$url" "$subgroup" "$status" \
    "$clone_time" "$push_time" "$total_time" \
    "$repo_size" "$branches" "$tags" \
    "$retries" "$commit_sha" 2>/dev/null) || true
}

# ── Ensure GitLab namespace (group or subgroup) exists ────────
ensure_namespace() {
  local subgroup="$1"   # empty = use parent group directly

  if [ -z "$subgroup" ]; then
    # No subgroup — get parent group ID
    curl -s \
      --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
      "$REMOTE_URL/api/v4/groups?search=$PARENT_FOLDER" \
      | python3 -c "
import sys, json
try:
    groups = json.load(sys.stdin)
    print(next((g['id'] for g in groups if g['path'] == '$PARENT_FOLDER'), ''))
except Exception:
    print('')
"
    return 0
  fi

  # Check if subgroup already exists
  local full_path="${PARENT_FOLDER}/${subgroup}"
  local encoded_path
  encoded_path=$(python3 -c \
    "import urllib.parse; print(urllib.parse.quote('$full_path', safe=''))")

  local existing
  existing=$(curl -s \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    "$REMOTE_URL/api/v4/groups/$encoded_path" \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('id', ''))
except Exception:
    print('')
")

  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi

  # Create subgroup under parent
  local parent_id
  parent_id=$(curl -s \
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

  if [ -z "$parent_id" ]; then
    log "   ❌ Could not find parent group"
    echo ""
    return 1
  fi

  log "   🆕 Creating subgroup: $subgroup"
  curl -s \
    --request POST \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"$subgroup\",\"path\":\"$subgroup\",\"parent_id\":$parent_id,\"visibility\":\"private\"}" \
    "$REMOTE_URL/api/v4/groups" \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('id', ''))
except Exception:
    print('')
"
}

# ── Get GitLab project ID from path ──────────────────────────
get_project_id() {
  local path="$1"
  local encoded
  encoded=$(python3 -c \
    "import urllib.parse; print(urllib.parse.quote('${path}', safe=''))")
  curl -s \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    "$REMOTE_URL/api/v4/projects/$encoded" \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    pid = data.get('id', '')
    print(pid if pid else '')
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# ── Move GitLab project to a different namespace ──────────────
move_project() {
  local project_id="$1"
  local target_namespace_id="$2"

  log "   🚚 Moving repo to subgroup..."
  local result
  result=$(curl -s -o /dev/null -w "%{http_code}" \
    --request PUT \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"namespace_id\": $target_namespace_id}" \
    "$REMOTE_URL/api/v4/projects/$project_id")

  if [ "$result" == "200" ]; then
    log "   ✅ Repo moved to subgroup"
    return 0
  else
    log "   ❌ Move failed (HTTP $result)"
    return 1
  fi
}

# ── Ensure destination repo exists under correct namespace ────
ensure_remote_repo() {
  local repo_name="$1"
  local namespace_id="$2"
  local subgroup="$3"

  if [ -n "$subgroup" ]; then
    local full_path="${PARENT_FOLDER}/${subgroup}/${repo_name}"
    local root_path="${PARENT_FOLDER}/${repo_name}"

    # Case 1: already exists at subgroup path ✅
    local subgroup_proj_id
    subgroup_proj_id=$(get_project_id "$full_path")
    if [ -n "$subgroup_proj_id" ]; then
      log "   📦 Repo exists at subgroup path"
      return 0
    fi

    # Case 2: exists at root → move it to subgroup
    local root_proj_id
    root_proj_id=$(get_project_id "$root_path")
    if [ -n "$root_proj_id" ]; then
      log "   📦 Repo found at root — moving to subgroup"
      if move_project "$root_proj_id" "$namespace_id"; then
        RESOLVED_DEST_URL="${REMOTE_URL/https:\/\//https://oauth2:${REMOTE_TOKEN}@}/${full_path}.git"
        return 0
      else
        log "   ⚠️  Move failed — creating fresh under subgroup"
      fi
    fi

  else
    # No subgroup — check root only
    local root_path="${PARENT_FOLDER}/${repo_name}"
    local root_proj_id
    root_proj_id=$(get_project_id "$root_path")
    if [ -n "$root_proj_id" ]; then
      log "   📦 Repo exists at root"
      return 0
    fi
  fi

  # Case 3: does not exist anywhere → create under correct namespace
  local response result body
  response=$(curl -s -w "\n%{http_code}" \
    --request POST \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"$repo_name\",\"path\":\"$repo_name\",\"namespace_id\":$namespace_id,\"visibility\":\"private\"}" \
    "$REMOTE_URL/api/v4/projects")

  result=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)

  if [ "$result" != "201" ]; then
    local api_error
    api_error=$(echo "$body" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('message', 'unknown error'))
except Exception:
    print('unknown error')
" 2>/dev/null)
    log "   ❌ Failed to create repo (HTTP $result): $api_error"
    return 1
  fi
}

# ── Sync a single repo ────────────────────────────────────────
sync_repo() {
  local source_url="$1"
  local subgroup="$2"   # may be empty

  local repo_name
  repo_name=$(basename "$source_url" .git)
  local owner
  owner=$(echo "$source_url" | sed 's|https://github.com/||' | cut -d/ -f1)
  local work_dir="$WORK_DIR/$repo_name"

  # Build dest URL with subgroup path if present
  local dest_path
  if [ -n "$subgroup" ]; then
    dest_path="${PARENT_FOLDER}/${subgroup}/${repo_name}.git"
  else
    dest_path="${PARENT_FOLDER}/${repo_name}.git"
  fi
  local dest_url
  dest_url="${REMOTE_URL/https:\/\//https://oauth2:${REMOTE_TOKEN}@}/${dest_path}"

  local display_name
  [ -n "$subgroup" ] && display_name="$subgroup/$repo_name" || display_name="$repo_name"
  log "⏳ $display_name"

  # ── LFS check ─────────────────────────────────────────────────
  touch "$LFS_FILE"
  if grep -qF "$source_url" "$LFS_FILE" 2>/dev/null; then
    log "⏭️  $display_name — already in LFS exclusion list"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if has_lfs "$owner" "$repo_name"; then
    log "🗂️  $display_name — LFS detected, moving to exclusion list"
    move_to_lfs_file "$source_url"
    LFS_MOVED=$((LFS_MOVED + 1))
    return 0
  fi

  # ── SHA check ─────────────────────────────────────────────────
  local current_sha="" last_sha=""

  if [ "$FORCE_FULL" = "true" ]; then
    log "   🔁 Force full sync"
  else
    current_sha=$(get_latest_sha "$owner" "$repo_name")
    last_sha=$(get_last_sha "$source_url")

    if [ -n "$current_sha" ] && [ -n "$last_sha" ] && [ "$current_sha" = "$last_sha" ]; then
      log "⏭️  $display_name — no changes since last sync"
      add_result "$source_url" "$subgroup" "skipped" 0 0 0 "—" 0 0 0 "$current_sha"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
    [ -z "$current_sha" ] && log "   ⚠️  Could not fetch SHA — proceeding anyway"
  fi

  # ── Ensure namespace + repo exist ────────────────────────────
  local namespace_id
  namespace_id=$(ensure_namespace "$subgroup")

  if [ -z "$namespace_id" ]; then
    log "❌ $display_name — could not prepare namespace"
    add_result "$source_url" "$subgroup" "failed" 0 0 0 "—" 0 0 0 "$current_sha"
    FAILED=$((FAILED + 1))
    FAILED_REPOS+=("$display_name")
    return 1
  fi

  # RESOLVED_DEST_URL may be updated by ensure_remote_repo
  # if repo found at a different path (e.g. root instead of subgroup)
  RESOLVED_DEST_URL="$dest_url"

  if ! ensure_remote_repo "$repo_name" "$namespace_id" "$subgroup"; then
    log "❌ $display_name — could not prepare destination repo"
    add_result "$source_url" "$subgroup" "failed" 0 0 0 "—" 0 0 0 "$current_sha"
    FAILED=$((FAILED + 1))
    FAILED_REPOS+=("$display_name")
    return 1
  fi

  # Use resolved dest URL (may have changed if repo found at root)
  dest_url="$RESOLVED_DEST_URL"

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
    log "❌ $display_name — fetch failed"
    rm -rf "$work_dir"
    add_result "$source_url" "$subgroup" "failed" 0 0 0 "—" 0 0 0 "$current_sha"
    FAILED=$((FAILED + 1))
    FAILED_REPOS+=("$display_name")
    return 1
  fi

  clone_end=$(date +%s)
  clone_time=$((clone_end - clone_start))

  # ── Metrics ───────────────────────────────────────────────────
  local repo_size repo_size_bytes branch_count tag_count
  repo_size_bytes=$(du -sb "$work_dir" 2>/dev/null | cut -f1 || echo 0)
  repo_size=$(python3 -c "
s=$repo_size_bytes
if s<1024: print(f'{s} B')
elif s<1048576: print(f'{s/1024:.1f} KB')
elif s<1073741824: print(f'{s/1048576:.1f} MB')
else: print(f'{s/1073741824:.2f} GB')
")
  cd "$work_dir"
  branch_count=$(git branch | wc -l | tr -d ' ')
  tag_count=$(git tag | wc -l | tr -d ' ')

  # ── Push ──────────────────────────────────────────────────────
  local push_start push_end push_time retries=0
  push_start=$(date +%s)
  local push_attempt=1 push_ok=false

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
    log "❌ $display_name — push failed"
    add_result "$source_url" "$subgroup" "failed" \
      "$clone_time" "$push_time" "$total_time" \
      "$repo_size" "$branch_count" "$tag_count" "$retries" "$current_sha"
    FAILED=$((FAILED + 1))
    FAILED_REPOS+=("$display_name")
    return 1
  fi

  log "✅ $display_name (clone: ${clone_time}s push: ${push_time}s total: ${total_time}s size: $repo_size)"
  add_result "$source_url" "$subgroup" "success" \
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

  # Check PyYAML available
  python3 -c "import yaml" 2>/dev/null || {
    log "📦 Installing PyYAML..."
    pip install pyyaml -q --break-system-packages 2>/dev/null || \
    pip3 install pyyaml -q 2>/dev/null || true
  }

  mkdir -p "$WORK_DIR"
  touch "$LFS_FILE"

  TOTAL_START=$(date +%s)

  # Parse repos.yml into "url subgroup" lines
  mapfile -t REPO_LINES < <(python3 scripts/parse-repos.py "$REPOS_FILE" 2>/dev/null || true)

  for line in "${REPO_LINES[@]}"; do
    local url subgroup
    url=$(echo "$line" | awk '{print $1}')
    subgroup=$(echo "$line" | awk '{print $2}')
    subgroup="${subgroup:-}"
    [ -z "$url" ] && continue
    sync_repo "$url" "$subgroup"
  done

  TOTAL_END=$(date +%s)
  TOTAL_RUN=$((TOTAL_END - TOTAL_START))

  # Write results JSON safely via Python
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
  log "📊 Done — ✅ $SUCCESS synced  ⏭️  $SKIPPED skipped  🗂️  $LFS_MOVED LFS moved  ❌ ${#FAILED_REPOS[@]} failed  ⏱️  ${TOTAL_RUN}s"

  if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
    log "🔴 Failed:"
    for r in "${FAILED_REPOS[@]}"; do
      log "   - $r"
    done
  fi
  hr

  if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then exit 1; else exit 0; fi
}

main