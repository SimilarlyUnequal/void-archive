#!/bin/bash

set -euo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

# ── Required variables ────────────────────────────────────────
: "${REMOTE_TOKEN:?❌  REMOTE_TOKEN is not set}"
: "${REMOTE_URL:?❌  REMOTE_URL is not set}"
: "${PARENT_FOLDER:?❌  PARENT_FOLDER is not set}"
: "${PROFILE_REPO:?❌  PROFILE_REPO is not set}"
: "${REPOS_FILE:?❌  REPOS_FILE is not set}"
: "${STATE_REPO_URL:?❌  STATE_REPO_URL is not set}"
: "${STATE_REPO_TOKEN:?❌  STATE_REPO_TOKEN is not set}"
: "${GITHUB_TOKEN:?❌  GITHUB_TOKEN is not set}"

# ── Config ────────────────────────────────────────────────────
GITLAB_WORK="/tmp/void-profile"
STATE_WORK="/tmp/void-state"
RESULTS_FILE="/tmp/sync-results.json"
README_ONLY="${README_ONLY:-false}"
NOW=$(date '+%Y-%m-%d %H:%M UTC')
TODAY=$(date '+%Y-%m-%d')
NEXT_SUNDAY=$(python3 -c "
from datetime import date, timedelta
d = date.today()
days = (6 - d.weekday()) % 7
days = 7 if days == 0 else days
print((d + timedelta(days=days)).strftime('%Y-%m-%d'))
")

REPOS_FILE=$(realpath "$REPOS_FILE")
export REPOS_FILE

PROFILE_REMOTE="${REMOTE_URL/https:\/\//https://oauth2:${REMOTE_TOKEN}@}/${PARENT_FOLDER}/${PROFILE_REPO}.git"
STATE_REMOTE="https://${STATE_REPO_TOKEN}@${STATE_REPO_URL#https://}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Ensure profile repo exists ────────────────────────────────
ensure_profile_repo() {
  local encoded_path
  encoded_path=$(python3 -c \
    "import urllib.parse; print(urllib.parse.quote('${PARENT_FOLDER}/${PROFILE_REPO}', safe=''))")

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    "$REMOTE_URL/api/v4/projects/$encoded_path")

  [ "$status" == "200" ] && return 0

  log "🆕 Creating profile repo..."
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

  [ -z "$group_id" ] && { log "❌ Could not find group"; return 1; }

  curl -s -o /dev/null \
    --request POST \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"$PROFILE_REPO\",\"path\":\"$PROFILE_REPO\",\"namespace_id\":$group_id,\"visibility\":\"public\",\"initialize_with_readme\":true}" \
    "$REMOTE_URL/api/v4/projects"

  log "✅ Profile repo created"
  sleep 2
}

# ── Clone or init ─────────────────────────────────────────────
clone_or_init() {
  local dir="$1"
  local remote="$2"
  local label="$3"

  rm -rf "$dir"
  if git clone "$remote" "$dir" 2>/dev/null; then
    log "📦 Cloned $label"
  else
    log "🆕 Init fresh $label"
    mkdir -p "$dir"
    cd "$dir"
    git init
    git remote add origin "$remote"
    cd /
  fi
  cd "$dir"
  git config user.email "void-archive@noreply"
  git config user.name "void-archive"
  cd /
}

# ── Merge sync results into state ────────────────────────────
merge_results() {
  local state_file="$1"
  local results_file="$2"

  python3 - "$state_file" "$results_file" "$TODAY" << 'PYEOF'
import json, sys

state_file   = sys.argv[1]
results_file = sys.argv[2]
today        = sys.argv[3]

try:
    with open(state_file) as f:
        state = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, Exception) as e:
    print(f"[merge] state load warning: {e} — starting fresh", file=sys.stderr)
    state = {}

try:
    with open(results_file) as f:
        results = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, Exception) as e:
    print(f"[merge] results load error: {e}", file=sys.stderr)
    sys.exit(1)

for url, metrics in results.items():
    existing = state.get(url, {})
    status   = metrics.get("status", "failed")

    if "first_synced" not in existing:
        existing["first_synced"] = today

    existing["last_attempt"] = today
    existing["status"]       = status
    existing["topics"]       = existing.get("topics", None)

    sha = metrics.get("last_commit_sha", "")
    if sha:
        existing["last_commit_sha"] = sha

    if status == "skipped":
        pass  # keep all previous values unchanged
    elif status == "success":
        existing["last_success"] = today
        existing["clone_time"]   = metrics.get("clone_time", 0)
        existing["push_time"]    = metrics.get("push_time", 0)
        existing["total_time"]   = metrics.get("total_time", 0)
        existing["size"]         = metrics.get("size", "—")
        existing["branches"]     = metrics.get("branches", 0)
        existing["tags"]         = metrics.get("tags", 0)
        existing["retries"]      = metrics.get("retries", 0)
    else:
        existing["clone_time"]   = metrics.get("clone_time", 0)
        existing["push_time"]    = metrics.get("push_time", 0)
        existing["total_time"]   = metrics.get("total_time", 0)
        existing["retries"]      = metrics.get("retries", 0)

    state[url] = existing

try:
    with open(state_file, "w") as f:
        json.dump(state, f, indent=2)
    print("✅ State merged")
except Exception as e:
    print(f"[merge] state write error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ── Fetch GitHub topics (cached) ──────────────────────────────
fetch_topics() {
  local state_file="$1"

  python3 - "$state_file" "$REPOS_FILE" << PYEOF
import json, sys, urllib.request

state_file   = sys.argv[1]
repos_file   = sys.argv[2]
github_token = "$GITHUB_TOKEN"

try:
    with open(state_file) as f:
        state = json.load(f)
except Exception as e:
    print(f"[topics] state load error: {e}", file=sys.stderr)
    state = {}

def fetch(owner, repo):
    url = f"https://api.github.com/repos/{owner}/{repo}/topics"
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github.mercy-preview+json",
        "User-Agent": "void-archive",
        **({"Authorization": f"Bearer {github_token}"} if github_token else {})
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()).get("names", [])
    except Exception:
        return []

try:
    with open(repos_file) as f:
        lines = f.readlines()
except Exception as e:
    print(f"[topics] repos file error: {e}", file=sys.stderr)
    sys.exit(1)

for line in lines:
    line = line.strip()
    if not line or line.startswith("#") or not line.startswith("http"):
        continue
    parts = line.rstrip("/").rstrip(".git").split("/")
    if len(parts) < 2:
        continue
    owner, repo = parts[-2], parts[-1]
    if line in state and state[line].get("topics") is not None:
        continue
    topics = fetch(owner, repo)
    if line not in state:
        state[line] = {}
    state[line]["topics"] = topics
    print(f"  🏷️  {repo}: {topics if topics else 'no topics'}")

try:
    with open(state_file, "w") as f:
        json.dump(state, f, indent=2)
    print("✅ Topics updated")
except Exception as e:
    print(f"[topics] state write error: {e}", file=sys.stderr)
PYEOF
}

# ── Generate README.md ────────────────────────────────────────
generate_readme() {
  local state_file="$1"
  local readme="$2"

  python3 - "$state_file" "$REPOS_FILE" "$readme" "$NOW" "$TODAY" "$NEXT_SUNDAY" << 'PYEOF'
import json, sys, re
from collections import defaultdict

state_file  = sys.argv[1]
repos_file  = sys.argv[2]
readme_file = sys.argv[3]
now         = sys.argv[4]
today       = sys.argv[5]
next_sunday = sys.argv[6]

try:
    with open(state_file) as f:
        state = json.load(f)
except Exception as e:
    print(f"[readme] state load error: {e} — using empty state", file=sys.stderr)
    state = {}

try:
    with open(repos_file) as f:
        lines = f.readlines()
except Exception as e:
    print(f"[readme] repos file error: {e}", file=sys.stderr)
    sys.exit(1)

current_category = None
url_category     = {}
all_urls         = []

for line in lines:
    line = line.rstrip()
    if not line:
        current_category = None
        continue
    cat = re.match(r'^#\s*[-–—]?\s*(.+?)\s*[-–—]?\s*$', line)
    if cat and not line.startswith('# void-archive'):
        current_category = cat.group(1).strip()
        continue
    if line.startswith('#') or not line.startswith('http'):
        continue
    url = line.strip()
    all_urls.append(url)
    if current_category:
        url_category[url] = current_category

def get_category(url):
    if url in url_category:
        return url_category[url].title()
    topics = state.get(url, {}).get("topics") or []
    if topics:
        return topics[0].replace("-", " ").title()
    return "General"

def fmt_time(secs):
    try:
        secs = int(secs)
        if secs == 0:  return "—"
        if secs < 60:  return f"{secs}s"
        return f"{secs//60}m {secs%60}s"
    except Exception:
        return "—"

categories = defaultdict(list)
for url in all_urls:
    categories[get_category(url)].append(url)

total   = len(all_urls)
success = sum(1 for u in all_urls if state.get(u, {}).get("status") == "success")
skipped = sum(1 for u in all_urls if state.get(u, {}).get("status") == "skipped")
failed  = sum(1 for u in all_urls if state.get(u, {}).get("status") == "failed")
pending = total - success - skipped - failed

total_sync_time = sum(
    state.get(u, {}).get("total_time", 0) or 0
    for u in all_urls if state.get(u, {}).get("status") == "success"
)
timed   = [(u, state.get(u,{}).get("total_time",0) or 0) for u in all_urls if state.get(u,{}).get("status")=="success"]
slowest = max(timed, key=lambda x: x[1], default=None)
fastest = min(timed, key=lambda x: x[1], default=None)

out = []
out.append("# 🪐 void-archive\n\n")
out.append("> A curated backup of essential open source projects.\n\n")
out.append("| | |\n|---|---|\n")
out.append(f"| 🕐 Last sync | {now} |\n")
out.append(f"| 📅 Next sync | {next_sunday} |\n")
out.append(f"| ⏱️ Active sync duration | {fmt_time(total_sync_time)} |\n")
if slowest:
    sname = slowest[0].rstrip('/').split('/')[-1]
    out.append(f"| 🐢 Slowest | {sname} ({fmt_time(slowest[1])}) |\n")
if fastest:
    fname = fastest[0].rstrip('/').split('/')[-1]
    out.append(f"| 🐇 Fastest | {fname} ({fmt_time(fastest[1])}) |\n")
out.append("\n")
out.append(
    f"![total](https://img.shields.io/badge/total-{total}-blue) "
    f"![synced](https://img.shields.io/badge/synced-{success}-brightgreen) "
    f"![skipped](https://img.shields.io/badge/skipped-{skipped}-lightgrey) "
    f"![failed](https://img.shields.io/badge/failed-{failed}-red) "
    f"![pending](https://img.shields.io/badge/pending-{pending}-yellow)\n\n"
)

out.append("## Contents\n\n")
for cat in sorted(categories.keys()):
    anchor = cat.lower().replace(" ", "-")
    out.append(f"- [{cat}](#{anchor}) ({len(categories[cat])})\n")
out.append("\n")

for cat in sorted(categories.keys()):
    out.append(f"## {cat}\n\n")
    out.append(
        "| Repo | Topics | First Synced | Last Synced | Size | "
        "Branches | Tags | Clone | Push | Total | Retries | Status |\n"
    )
    out.append(
        "|------|--------|-------------|-------------|------|"
        "----------|------|-------|------|-------|---------|--------|\n"
    )
    for url in categories[cat]:
        name         = url.rstrip("/").split("/")[-1].replace(".git", "")
        info         = state.get(url, {})
        status       = info.get("status", "pending")
        topics       = info.get("topics") or []
        topic_str    = " ".join(f"<code>{t}</code>" for t in topics[:3]) if topics else "—"
        first_synced = info.get("first_synced", "—")
        last_success = info.get("last_success") or "—"
        size         = info.get("size", "—") or "—"
        branches     = info.get("branches", "—")
        tags         = info.get("tags", "—")
        clone_t      = fmt_time(info.get("clone_time", 0))
        push_t       = fmt_time(info.get("push_time", 0))
        total_t      = fmt_time(info.get("total_time", 0))
        retries      = info.get("retries", 0)

        if status == "success":
            badge = "✅"; date_str = last_success
        elif status == "skipped":
            badge = "⏭️"; date_str = last_success
            clone_t = push_t = total_t = "—"
        elif status == "failed":
            badge = "❌"; date_str = f"last ok: {last_success}"
        else:
            badge = "⏳"; date_str = "—"
            clone_t = push_t = total_t = "—"

        out.append(
            f"| [{name}]({url}) | {topic_str} | {first_synced} | {date_str} |"
            f" {size} | {branches} | {tags} | {clone_t} | {push_t} | {total_t} |"
            f" {retries} | {badge} |\n"
        )
    out.append("\n")

out.append("---\n\n*Auto-generated — do not edit manually.*\n")

try:
    with open(readme_file, "w") as f:
        f.writelines(out)
    print("✅ README.md generated")
except Exception as e:
    print(f"[readme] write error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ── Commit and push ───────────────────────────────────────────
commit_and_push() {
  local dir="$1"
  local message="$2"

  cd "$dir"
  git add -A

  if git diff --cached --quiet; then
    log "📋 No changes to commit"
    cd /
    return 0
  fi

  git commit -m "$message"
  git push origin HEAD:main 2>/dev/null || \
  git push origin HEAD:master 2>/dev/null || {
    log "⚠️  Push failed — trying force"
    git push --force origin HEAD:main 2>/dev/null || true
  }
  cd /
}

# ── Backup state + results to GitHub private repo ────────────
backup_to_state_repo() {
  local state_file="$1"

  log "💾 Backing up to private repo..."
  clone_or_init "$STATE_WORK" "$STATE_REMOTE" "state backup"
  cp "$state_file" "$STATE_WORK/state.json"

  # Also backup raw results if available
  if [ -f "$RESULTS_FILE" ]; then
    cp "$RESULTS_FILE" "$STATE_WORK/sync-results.json"
  fi

  commit_and_push "$STATE_WORK" "state: $TODAY"
  log "✅ Backed up state.json + sync-results.json"
}

# ── Main ──────────────────────────────────────────────────────
main() {
  log "📝 Starting README generation (mode: ${README_ONLY})"

  ensure_profile_repo

  local state_file

  if [ "$README_ONLY" = "true" ]; then
    # ── README-only: read state from GitHub private backup ─────
    log "📥 Fetching state from private backup..."
    clone_or_init "$STATE_WORK" "$STATE_REMOTE" "state backup"
    state_file="$STATE_WORK/state.json"

    if [ ! -f "$state_file" ]; then
      log "❌ No state.json in private backup — cannot generate README"
      exit 1
    fi

    clone_or_init "$GITLAB_WORK" "$PROFILE_REMOTE" "profile repo"
    cp "$state_file" "$GITLAB_WORK/state.json"

  else
    # ── Sync mode ──────────────────────────────────────────────
    clone_or_init "$GITLAB_WORK" "$PROFILE_REMOTE" "profile repo"
    state_file="$GITLAB_WORK/state.json"

    [ ! -f "$state_file" ] && echo "{}" > "$state_file"

    if [ -f "$RESULTS_FILE" ]; then
      log "🔀 Merging sync results..."
      if ! merge_results "$state_file" "$RESULTS_FILE"; then
        # ── Fallback: try backed-up results from private repo ──
        log "⚠️  Merge failed — trying fallback from private backup..."
        clone_or_init "$STATE_WORK" "$STATE_REMOTE" "state backup"

        if [ -f "$STATE_WORK/sync-results.json" ]; then
          log "📥 Using backed-up sync-results.json"
          merge_results "$state_file" "$STATE_WORK/sync-results.json" || {
            log "❌ Fallback merge also failed — generating README from existing state only"
          }
        else
          log "⚠️  No backup results found — generating README from existing state only"
        fi
      fi
    else
      log "⚠️  No sync results — using existing state"
    fi

    log "🏷️  Fetching topics..."
    fetch_topics "$state_file" || log "⚠️  Topics fetch failed — continuing"

    backup_to_state_repo "$state_file"
  fi

  log "📄 Generating README..."
  generate_readme "$state_file" "$GITLAB_WORK/README.md"

  commit_and_push "$GITLAB_WORK" "readme: $TODAY"
  log "✅ README pushed"
  log "🏁 Done"
}

main