#!/usr/bin/env python3
# =============================================================
#  void-archive — prepare-test.py
#  Reads test.yml (repos.yml format) and writes a single-entry
#  repos.yml to /tmp/test-repos.yml based on mode
#  Usage: python3 prepare-test.py test.yml <mode>
#  mode: single | group
# =============================================================

import sys
import yaml

test_file = sys.argv[1]
mode      = sys.argv[2].strip()
output    = "/tmp/test-repos.yml"

try:
    with open(test_file) as f:
        config = yaml.safe_load(f) or {}
except Exception as e:
    print(f"❌ Error reading test.yml: {e}", file=sys.stderr)
    sys.exit(1)

data = {"groups": {}, "ungrouped": []}

if mode == "single":
    ungrouped = config.get("ungrouped") or []
    if not ungrouped:
        print("❌ No ungrouped URLs in test.yml", file=sys.stderr)
        sys.exit(1)
    url = ungrouped[0].strip()
    data["ungrouped"] = [url]
    print(f"🎯 Single test: {url.split('/')[-1]}")

elif mode == "group":
    groups = config.get("groups") or {}
    if not groups:
        print("❌ No groups in test.yml", file=sys.stderr)
        sys.exit(1)
    group_name = next(iter(groups))
    urls = groups[group_name] or []
    if not urls:
        print(f"❌ No URLs in group '{group_name}'", file=sys.stderr)
        sys.exit(1)
    url = urls[0].strip()
    data["groups"][group_name] = [url]
    print(f"🎯 Group test: {group_name}/{url.split('/')[-1]}")

else:
    print(f"❌ Unknown mode: {mode}", file=sys.stderr)
    sys.exit(1)

with open(output, "w") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

print(f"✅ Test repos.yml written to {output}")