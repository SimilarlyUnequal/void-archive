#!/usr/bin/env python3

import sys
import yaml

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

if group:
    if group not in data["groups"] or not isinstance(data["groups"][group], list):
        data["groups"][group] = []
    data["groups"][group].append(url)
else:
    data["ungrouped"].append(url)

with open(repos_file, "w") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

print(f"✅ Added {url} to {'groups.' + group if group else 'ungrouped'}")