#!/usr/bin/env python3

import sys
import yaml

urls_file  = sys.argv[1]
group      = sys.argv[2].strip() if len(sys.argv) > 2 else ""
output     = sys.argv[3] if len(sys.argv) > 3 else "/tmp/newly-added.yml"

with open(urls_file) as f:
    urls = [l.strip() for l in f if l.strip()]

data = {"groups": {}, "ungrouped": []}
if group:
    data["groups"][group] = urls
else:
    data["ungrouped"] = urls

with open(output, "w") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

print(f"✅ Temp repos.yml created with {len(urls)} URL(s)")