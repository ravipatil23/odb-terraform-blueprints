#!/usr/bin/env python3
"""Pin a blueprint's providers to the minimum versions it claims to support.

Every blueprint declares floor-only constraints (version = ">= X"), so a plain
`terraform init` always tests against the newest providers. This writes a
ci_floor_override.tf into the given root module that pins each provider to
exactly X, so CI can prove the stated floor still works.

Usage: pin_floor.py <blueprint-dir>
"""
import pathlib
import re
import sys

# A provider entry inside required_providers: name = { source = "...", version = ">= X" }.
# Provider entries hold no nested braces, so [^{}] keeps each match to one entry.
PROVIDER = re.compile(
    r'(\w+)\s*=\s*\{[^{}]*?source\s*=\s*"([^"]+)"[^{}]*?version\s*=\s*">=\s*([0-9][0-9.]*)"[^{}]*\}',
    re.DOTALL,
)

root = pathlib.Path(sys.argv[1])
floors = {}
for tf in sorted(root.glob("*.tf")):
    if tf.name.endswith("_override.tf"):
        continue
    for name, source, version in PROVIDER.findall(tf.read_text(encoding="utf-8")):
        floors[name] = (source, version)

if not floors:
    sys.exit(f"no '>= X' provider constraints found in {root}/*.tf")

lines = ["terraform {", "  required_providers {"]
for name, (source, version) in sorted(floors.items()):
    lines.append(f'    {name} = {{ source = "{source}", version = "{version}" }}')
    print(f"{root}: {source} = {version}")
lines += ["  }", "}", ""]
(root / "ci_floor_override.tf").write_text("\n".join(lines), encoding="utf-8")
