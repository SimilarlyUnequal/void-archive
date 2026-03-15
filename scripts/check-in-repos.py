#!/usr/bin/env python3

import sys
import yaml

repos_file = sys.argv[1]
url        = sys.argv[2].strip()

try:
    with open(repos_file) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    print("no")
    sys.exit(0)

all_urls = []
for urls in (data.get("groups") or {}).values():
    all_urls.extend(urls or [])
all_urls.extend(data.get("ungrouped") or [])

print("yes" if url in all_urls else "no")