#!/bin/bash
# =============================================================
#  void-archive — generate-readme.sh
#  Generates a dashboard README.md for the remote group page
#  - Auto-categorizes repos by GitHub topic tags (API)
#  - Topics cached in state.json to minimize API calls
#  - Manual # comments in repos.txt override auto categories
#  - Per-repo last synced timestamps from state.json
# =============================================================

set -euo pipefail

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

# ── Required variables ────────────────────────────────────────
: "${REMOTE_TOKEN:?❌  REMOTE_TOKEN is not set}"
: "${REMOTE_URL:?❌  REMOTE_URL is not set}"
: "${PARENT_FOLDER:?❌  PARENT_FOLDER is not set}"
: "${PROFILE_REPO:?❌  PROFILE_REPO is not set}"
: "${REPOS_FILE:?❌  REPOS_FILE is not set}"

# ── Optional: GitHub token for higher API rate limit ─────────
# Unauthenticated: 60 req/hr — Authenticated: 5000 req/hr
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# ── Config ────────────────────────────────────────────────────
WORK_DIR="/tmp/void-profile"
RESULTS_FILE="/tmp/sync-results.json"
NOW=$(date '+%Y-%m-%d %H:%M UTC')
TODAY=$(date '+%Y-%m-%d')

PROFILE_REMOTE="${REMOTE_URL/https:\/\//https://oauth2:${REMOTE_TOKEN}@}/${PARENT_FOLDER}/${PROFILE_REPO}.git"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Step 1: Ensure profile repo exists ───────────────────────
ensure_profile_repo() {
  local encoded_path
  encoded_path=$(python3 -c \
    "import urllib.parse; print(urllib.parse.quote('${PARENT_FOLDER}/${PROFILE_REPO}', safe=''))")

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    "$REMOTE_URL/api/v4/projects/$encoded_path")

  if [ "$status" == "200" ]; then
    log "📦 Profile repo exists"
    return 0
  fi

  log "🆕 Creating profile repo..."
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

  curl -s -o /dev/null \
    --request POST \
    --header "PRIVATE-TOKEN: $REMOTE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"$PROFILE_REPO\",\"path\":\"$PROFILE_REPO\",\"namespace_id\":$group_id,\"visibility\":\"public\",\"initialize_with_readme\":true}" \
    "$REMOTE_URL/api/v4/projects"

  log "✅ Profile repo created"
  sleep 2
}

# ── Step 2: Clone profile repo ────────────────────────────────
clone_profile_repo() {
  rm -rf "$WORK_DIR"
  git clone "$PROFILE_REMOTE" "$WORK_DIR" 2>/dev/null || {
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    git init
    git remote add origin "$PROFILE_REMOTE"
  }
  cd "$WORK_DIR"
  git config user.email "void-archive@noreply"
  git config user.name "void-archive"
}

# ── Step 3: Fetch topics + update state ───────────────────────
update_state() {
  local state_file="$WORK_DIR/state.json"

  [ -f "$state_file" ] || echo "{}" > "$state_file"

  python3 << PYEOF
import json, urllib.request, urllib.error
from datetime import date

today = "$TODAY"
github_token = "$GITHUB_TOKEN"

with open("$state_file") as f:
    state = json.load(f)

with open("$RESULTS_FILE") as f:
    results = json.load(f)

def fetch_topics(owner, repo):
    """Fetch GitHub topic tags. Returns list of topics or []."""
    url = f"https://api.github.com/repos/{owner}/{repo}/topics"
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github.mercy-preview+json",
        "User-Agent": "void-archive",
        **({"Authorization": f"Bearer {github_token}"} if github_token else {})
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            return data.get("names", [])
    except Exception:
        return []

def url_to_owner_repo(url):
    """Extract owner/repo from GitHub URL."""
    parts = url.rstrip("/").rstrip(".git").split("/")
    if len(parts) >= 2:
        return parts[-2], parts[-1]
    return None, None

for url, sync_status in results.items():
    if url not in state:
        state[url] = {
            "last_success": None,
            "last_attempt": today,
            "status": sync_status,
            "topics": None   # will be fetched below
        }
    else:
        state[url]["last_attempt"] = today
        state[url]["status"] = sync_status

    if sync_status == "success":
        state[url]["last_success"] = today

    # Fetch topics only if not cached yet
    if state[url].get("topics") is None:
        owner, repo = url_to_owner_repo(url)
        if owner and repo:
            topics = fetch_topics(owner, repo)
            state[url]["topics"] = topics if topics else []
            print(f"  🏷️  {repo}: {topics if topics else 'no topics'}")
        else:
            state[url]["topics"] = []

with open("$state_file", "w") as f:
    json.dump(state, f, indent=2)

print("✅ State updated")
PYEOF
}

# ── Step 4: Generate README.md ────────────────────────────────
generate_readme() {
  local readme="$WORK_DIR/README.md"
  local state_file="$WORK_DIR/state.json"

  python3 << PYEOF
import json, re
from collections import defaultdict

with open("$state_file") as f:
    state = json.load(f)

with open("$REPOS_FILE") as f:
    lines = f.readlines()

# ── Parse repos.txt ──────────────────────────────────────────
# Manual # comments = explicit category override
# No comment above URL = use GitHub topics from state.json
current_manual_category = None
url_manual_category = {}   # url → manually set category (if any)
all_urls = []

for line in lines:
    line = line.rstrip()
    if not line:
        current_manual_category = None
        continue
    cat_match = re.match(r'^#\s*[-–—]?\s*(.+?)\s*[-–—]?\s*$', line)
    if cat_match and not line.startswith('# void-archive'):
        current_manual_category = cat_match.group(1).strip()
        continue
    if line.startswith('#') or not line.startswith('http'):
        continue
    url = line.strip()
    all_urls.append(url)
    if current_manual_category:
        url_manual_category[url] = current_manual_category

# ── Assign categories ─────────────────────────────────────────
def get_category(url):
    # 1. Manual comment in repos.txt takes priority
    if url in url_manual_category:
        return url_manual_category[url].title()
    # 2. First GitHub topic tag
    topics = state.get(url, {}).get("topics", [])
    if topics:
        return topics[0].replace("-", " ").title()
    # 3. Fallback
    return "General"

categories = defaultdict(list)
for url in all_urls:
    categories[get_category(url)].append(url)

# ── Build README ──────────────────────────────────────────────
out = []

total = len(all_urls)
success = sum(1 for u in all_urls if state.get(u, {}).get("status") == "success")
failed = total - success

out.append("# 🪐 void-archive\n\n")
out.append("> A curated backup of essential open source projects.\n\n")
out.append(f"**Last sync:** $NOW\n\n")
out.append(
    f"![total](https://img.shields.io/badge/total-{total}-blue) "
    f"![synced](https://img.shields.io/badge/synced-{success}-brightgreen) "
    f"![failed](https://img.shields.io/badge/failed-{failed}-red)\n\n"
)

# Table of contents
out.append("## Categories\n\n")
for cat in sorted(categories.keys()):
    anchor = cat.lower().replace(" ", "-")
    count = len(categories[cat])
    out.append(f"- [{cat}](#{anchor}) ({count})\n")
out.append("\n")

# Category sections
for cat in sorted(categories.keys()):
    out.append(f"## {cat}\n\n")
    out.append("| Repo | Topics | Last Synced | Status |\n")
    out.append("|------|--------|-------------|--------|\n")

    for url in categories[cat]:
        repo_name = url.rstrip("/").split("/")[-1].replace(".git", "")
        info = state.get(url, {})
        status = info.get("status", "pending")
        last_success = info.get("last_success") or "—"
        topics = info.get("topics") or []
        topic_str = " ".join(f"`{t}`" for t in topics[:3]) if topics else "—"

        if status == "success":
            badge = "✅"
            date_str = last_success
        elif status == "failed":
            badge = "❌"
            date_str = f"last ok: {last_success}" if last_success != "—" else "never"
        else:
            badge = "⏳"
            date_str = "—"

        out.append(f"| [{repo_name}]({url}) | {topic_str} | {date_str} | {badge} |\n")

    out.append("\n")

out.append("---\n\n")
out.append("*Auto-generated — do not edit manually.*\n")

with open("$readme", "w") as f:
    f.writelines(out)

print("✅ README.md generated")
PYEOF
}

# ── Step 5: Commit and push ───────────────────────────────────
commit_and_push() {
  cd "$WORK_DIR"
  git add README.md state.json

  if git diff --cached --quiet; then
    log "📋 No changes to commit"
    return 0
  fi

  git commit -m "readme: $TODAY"
  git push origin HEAD:main 2>/dev/null || git push origin HEAD:master 2>/dev/null
  log "✅ README pushed"
}

# ── Main ──────────────────────────────────────────────────────
main() {
  log "📝 Generating README"

  if [ ! -f "$RESULTS_FILE" ]; then
    log "❌ No sync results found — skipping README generation"
    exit 0
  fi

  ensure_profile_repo
  clone_profile_repo
  update_state
  generate_readme
  commit_and_push

  log "🏁 Done"
}

main
