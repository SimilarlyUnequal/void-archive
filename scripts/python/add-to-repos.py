#!/usr/bin/env python3
# =============================================================
#  void-archive — add-to-repos.py
#  Add or remove a URL from repos.yml
#  Usage:
#    Add:    python3 add-to-repos.py repos.yml <url> <group>
#    Remove: python3 add-to-repos.py --remove repos.yml <url>
# =============================================================

import sys
import yaml

# Parse args
if sys.argv[1] == "--remove":
    repos_file = sys.argv[2]
    url        = sys.argv[3].strip()
    group      = None
else:
    repos_file = sys.argv[1]
    url        = sys.argv[2].strip()
    group      = sys.argv[3].strip() if len(sys.argv) > 3 else ""

try:
    with open(repos_file) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    data = {}

if not isinstance(data.get("groups"), dict):
    data["groups"] = {}
if not isinstance(data.get("ungrouped"), list):
    data["ungrouped"] = []

if group is None:
    # Remove mode
    for g in data["groups"]:
        if url in (data["groups"][g] or []):
            data["groups"][g].remove(url)
    if url in data["ungrouped"]:
        data["ungrouped"].remove(url)
    print(f"✅ Removed {url} from repos.yml")
else:
    # Add mode
    if group:
        if group not in data["groups"] or not isinstance(data["groups"][group], list):
            data["groups"][group] = []
        data["groups"][group].append(url)
    else:
        data["ungrouped"].append(url)
    print(f"✅ Added {url} to {'groups.' + group if group else 'ungrouped'}")

with open(repos_file, "w") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)