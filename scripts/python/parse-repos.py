#!/usr/bin/env python3

import sys
import yaml

if len(sys.argv) < 2:
    print("Usage: parse-repos.py <repos.yml>", file=sys.stderr)
    sys.exit(1)

repos_file = sys.argv[1]

try:
    with open(repos_file) as f:
        data = yaml.safe_load(f)
except Exception as e:
    print(f"Error reading repos.yml: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print("Invalid repos.yml format", file=sys.stderr)
    sys.exit(1)

# Grouped repos
groups = data.get("groups", {}) or {}
for group, urls in groups.items():
    if not urls:
        continue
    for url in urls:
        url = url.strip()
        if url and url.startswith("http"):
            print(f"{url} {group}")

# Ungrouped repos
ungrouped = data.get("ungrouped", []) or []
for url in ungrouped:
    url = url.strip()
    if url and url.startswith("http"):
        print(f"{url} ")