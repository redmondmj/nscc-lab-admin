#!/usr/bin/env python3
"""
Turns liberated-machines.csv (written by bootstrap/Run-Full-Migration.ps1,
one row appended per machine on the USB stick) into a ready-to-paste YAML
block for inventory/hosts.yml - so you paste once for the whole batch
instead of hand-editing hosts.yml 25 times.

Doesn't touch hosts.yml directly - deliberately just prints the block, so
it can't clobber your comments/formatting. Copy the CSV off the USB stick
(or just re-run this each time you add more rows to it) and pipe it in:

    python3 tools/csv-to-inventory.py liberated-machines.csv
"""
import csv
import sys

if len(sys.argv) != 2:
    print(f"Usage: {sys.argv[0]} <path-to-liberated-machines.csv>", file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1], newline="") as f:
    rows = list(csv.DictReader(f))

if not rows:
    print("No rows found.", file=sys.stderr)
    sys.exit(1)

seen = set()
for row in rows:
    host, ip = row["Hostname"], row["IPAddress"]
    if host in seen:
        continue  # keep the latest row per hostname if it was re-run
    seen.add(host)
    print(f"        {host}:")
    print(f"          ansible_host: {ip}")

print(f"\n# {len(seen)} host(s) - paste the block above into inventory/hosts.yml under `hosts:`", file=sys.stderr)
