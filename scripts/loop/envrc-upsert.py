#!/usr/bin/env python3
"""envrc-upsert.py — set `export KEY="VALUE"` in .envrc, idempotently.

Replaces an existing assignment for KEY (with or without `export`) in place, or
appends one if absent. Other lines are left byte-for-byte untouched. Values may
contain shell-special characters (e.g. base64 +/=) — they are written verbatim
inside double quotes, so do not pass values containing a literal double quote.

Usage: envrc-upsert.py <envrc-path> <KEY> <VALUE>
"""
import sys
import re
import pathlib

if len(sys.argv) != 4:
    sys.exit("usage: envrc-upsert.py <envrc-path> <KEY> <VALUE>")

path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
if '"' in val:
    sys.exit("refusing to write a value containing a double quote")

p = pathlib.Path(path)
lines = p.read_text().splitlines() if p.exists() else []
new_line = f'export {key}="{val}"'
pat = re.compile(rf'^\s*(export\s+)?{re.escape(key)}=')

out, found = [], False
for ln in lines:
    if pat.match(ln) and not found:
        out.append(new_line)
        found = True
    elif pat.match(ln):
        continue  # drop duplicate stale assignments
    else:
        out.append(ln)
if not found:
    out.append(new_line)

p.write_text("\n".join(out) + "\n")
