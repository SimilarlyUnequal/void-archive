#!/usr/bin/env python3
# =============================================================
#  void-archive — parse-test.py
#  Reads test.yml and outputs a mini repos.yml for testing
#  Usage: python3 scripts/python/parse-test.py test.yml <mode>
#  mode: single | group
#  Output: writes /tmp/test-repos.yml
# =============================================================

import sys
import yaml

test_file = sys.argv[1]
mode      = sys.argv[2].strip()   # "single" or "group"
output    = "/tmp/test-repos.yml"

try:
    with open(test_file) as f:
        config = yaml.safe_load(f) or {}
except Exception as e:
    print(f"Error reading test.yml: {e}", file=sys.stderr)
    sys.exit(1)

data = {"groups": {}, "ungrouped": []}

if mode == "single":
    url = (config.get("single") or {}).get("url", "").strip()
    if not url:
        print("❌ No single.url defined in test.yml", file=sys.stderr)
        sys.exit(1)
    data["ungrouped"] = [url]
    print(f"🎯 Single test: {url}")

elif mode == "group":
    group_cfg = config.get("group") or {}
    name = group_cfg.get("name", "").strip()
    url  = group_cfg.get("url", "").strip()
    if not name or not url:
        print("❌ No group.name or group.url defined in test.yml", file=sys.stderr)
        sys.exit(1)
    data["groups"][name] = [url]
    print(f"🎯 Group test: {name}/{url.split('/')[-1]}")

else:
    print(f"❌ Unknown mode: {mode}", file=sys.stderr)
    sys.exit(1)

with open(output, "w") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

print(f"✅ Test repos.yml written to {output}")