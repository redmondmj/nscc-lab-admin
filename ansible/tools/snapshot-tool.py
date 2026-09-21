#!/usr/bin/env python3
"""
Offline analysis of state snapshots (playbooks/state-snapshot.yml) and the
software manifest (software-manifest.yml). Reads files only; touches no
machine, so it is safe to run any time and against old snapshots.

  snapshot-tool.py outliers <snapshot-dir>
      What differs across the fleet, grouped so that "these 3 machines are
      each missing the same 14 things" reads as one finding.

  snapshot-tool.py check <snapshot-dir> [--manifest FILE]
      Compare every machine to the manifest: missing, wrong version, or
      present-but-unwanted. Prints ready-to-run push-software.yml commands
      for what can be fixed. Exit status 1 if anything is out of line, so
      it can gate a scheduled run.

  snapshot-tool.py draft <snapshot-dir> [--manifest FILE] [--threshold 0.9]
      Programs found on most machines that the manifest does not mention
      yet, as YAML ready to paste in. This is how the manifest becomes
      comprehensive rather than a list of what someone remembered.

Snapshots are "## section" blocks of sorted lines, one file per host.
Needs PyYAML for the manifest (already present wherever Ansible is; if
plain `python3` lacks it, run this with the interpreter Ansible uses).
"""
import argparse
import hashlib
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ANSIBLE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ANSIBLE_DIR / "software-manifest.yml"
FILES_DIR = ANSIBLE_DIR / "files"
SKIP_SECTIONS = {"meta"}  # timestamps and hostnames: always differ


# --------------------------------------------------------------------- input
def load_snapshots(directory):
    """{host: {section: [lines]}} from every *.txt in the directory."""
    hosts = {}
    for path in sorted(Path(directory).glob("*.txt")):
        sections, current = {}, None
        for raw in path.read_text(encoding="utf-8").splitlines():
            if raw.startswith("## "):
                current = raw[3:].strip()
                sections[current] = []
            elif current is not None and raw.strip():
                sections[current].append(raw.rstrip())
        hosts[path.stem] = sections
    if not hosts:
        sys.exit(f"No *.txt snapshots found in {directory}")
    return hosts


def parse_programs(lines):
    """['name | version', ...] -> [(name, version)]"""
    out = []
    for line in lines:
        name, _, version = line.rpartition(" | ")
        out.append((name, version) if name else (line, ""))
    return out


def load_manifest(path):
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML is required for the manifest. Use the Python that "
                 "Ansible runs under (it depends on PyYAML).")
    data = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
    return data.get("software") or []


# ------------------------------------------------------------------ matching
def entry_matches(entry, name):
    if "name_regex" in entry:
        return re.fullmatch(entry["name_regex"], name) is not None
    return entry.get("name") == name


def entry_label(entry):
    return entry.get("name") or f"/{entry.get('name_regex')}/"


def version_ok(want, have):
    """'any' matches everything; otherwise exact, or a dotted prefix so
    '2.4.1' accepts an installer that reports '2.4.1.0'."""
    if want in (None, "", "any"):
        return True
    want = str(want)
    return have == want or have.startswith(want + ".")


def group_by_hosts(pairs):
    """[(item, hostset)] -> {tuple(sorted hosts): [items]}"""
    grouped = defaultdict(list)
    for item, hs in pairs:
        grouped[tuple(sorted(hs))].append(item)
    return grouped


def short_hosts(hosts, limit=8):
    hosts = list(hosts)
    if len(hosts) <= limit:
        return ", ".join(hosts)
    return ", ".join(hosts[:limit]) + f", ... (+{len(hosts) - limit} more)"


# ------------------------------------------------------------------ outliers
def cmd_outliers(args):
    snaps = load_snapshots(args.snapshots)
    names = sorted(snaps)
    n = len(names)
    wanted = {s for s in (args.section or [])}
    sections = []
    for h in names:
        for s in snaps[h]:
            if s not in SKIP_SECTIONS and s not in sections and (not wanted or s in wanted):
                sections.append(s)

    print(f"{n} snapshots: {short_hosts(names, 30)}\n")
    found_any = False
    for sec in sections:
        seen = defaultdict(set)
        for h in names:
            for line in set(snaps[h].get(sec, [])):
                seen[line].add(h)
        missing, only = [], []
        for line, hs in seen.items():
            if len(hs) == n:
                continue
            frac = len(hs) / n
            if frac >= args.common:
                missing.append((line, set(names) - hs))
            elif frac <= args.rare:
                only.append((line, hs))
        if not (missing or only):
            continue
        found_any = True
        print(f"== {sec} ==")
        for hosts, items in sorted(group_by_hosts(missing).items(), key=lambda kv: (len(kv[0]), kv[0])):
            print(f"  MISSING on {short_hosts(hosts)}  ({len(items)} item{'s' * (len(items) != 1)}):")
            for it in sorted(items)[: args.max_items]:
                print(f"      {it}")
            if len(items) > args.max_items:
                print(f"      ... and {len(items) - args.max_items} more")
        for hosts, items in sorted(group_by_hosts(only).items(), key=lambda kv: (len(kv[0]), kv[0])):
            print(f"  ONLY on {short_hosts(hosts)}  ({len(items)} item{'s' * (len(items) != 1)}):")
            for it in sorted(items)[: args.max_items]:
                print(f"      {it}")
            if len(items) > args.max_items:
                print(f"      ... and {len(items) - args.max_items} more")
        print()
    if not found_any:
        print("No outliers: every snapshot line is on all machines, or on a "
              "split that is neither 'most' nor 'few'.")


# --------------------------------------------------------------------- check
def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def push_command(entry, hosts):
    dep = entry["deploy"]
    extra = {"installer_local_path": str(FILES_DIR / dep["installer"])}
    if dep.get("product_id"):
        extra["installer_product_id"] = dep["product_id"]
    if dep.get("arguments"):
        extra["installer_arguments"] = dep["arguments"]
    return ("ansible-playbook playbooks/push-software.yml "
            "--vault-password-file ~/.ansible_vault_pass "
            f"--limit {','.join(sorted(hosts))} "
            f"-e '{json.dumps(extra)}'")


def cmd_check(args):
    snaps = load_snapshots(args.snapshots)
    manifest = load_manifest(args.manifest)
    names = sorted(snaps)
    programs = {h: parse_programs(snaps[h].get("programs", [])) for h in names}
    problems = 0
    fixes = []
    notes = []

    print(f"{len(names)} machines checked against {len(manifest)} manifest "
          f"entries ({args.manifest})\n")
    for entry in manifest:
        label = entry_label(entry)
        state = entry.get("state", "present")
        want = entry.get("version", "any")
        missing, wrong, unwanted = [], {}, []
        for h in names:
            found = [(n, v) for n, v in programs[h] if entry_matches(entry, n)]
            if state == "absent":
                if found:
                    unwanted.append(h)
            elif not found:
                missing.append(h)
            elif not any(version_ok(want, v) for _, v in found):
                wrong[h] = "/".join(sorted({v for _, v in found}))

        if not (missing or wrong or unwanted):
            tag = "absent everywhere" if state == "absent" else \
                  (f"{want}" if want != "any" else "present")
            print(f"  ok       {label}  [{tag}]")
        else:
            problems += 1
            print(f"  DRIFT    {label}")
            if missing:
                print(f"           missing on {len(missing)}: {short_hosts(missing)}")
            if unwanted:
                print(f"           unwanted, present on {len(unwanted)}: {short_hosts(unwanted)}")
            by_version = defaultdict(list)
            for h, v in wrong.items():
                by_version[v].append(h)
            for have, hs in sorted(by_version.items()):
                print(f"           version {have} (want {want}) on {len(hs)}: {short_hosts(hs)}")
            if entry.get("notes"):
                print(f"           note: {' '.join(str(entry['notes']).split())}")
            if entry.get("deploy") and (missing or wrong):
                fixes.append((label, entry, set(missing), set(wrong)))
            if unwanted:
                notes.append(f"{label}: removal is manual on purpose (uninstall can "
                             f"involve drivers/reboots); nothing here removes it.")

        dep = entry.get("deploy")
        if dep and dep.get("installer"):
            f = FILES_DIR / dep["installer"]
            # YAML turns an unquoted all-digit hash into an integer (0 is
            # falsy!), so treat the value as text and validate its shape
            # instead of trusting truthiness.
            raw = dep.get("sha256")
            recorded = "" if raw is None else str(raw).strip().lower()
            if not f.exists():
                notes.append(f"{label}: installer {dep['installer']} is not staged in {FILES_DIR}")
            elif not recorded:
                notes.append(f"{label}: no sha256 recorded in the manifest "
                             f"(local file hashes to {sha256_of(f)})")
            elif not re.fullmatch(r"[0-9a-f]{64}", recorded):
                notes.append(f"{label}: the recorded sha256 is not a 64-character hex string "
                             f"- quote it in the YAML so it is read as text")
            elif sha256_of(f) != recorded:
                notes.append(f"{label}: STAGED INSTALLER DOES NOT MATCH the recorded sha256 - "
                             f"do not push it until that is explained")

    if fixes:
        print("\nSuggested fixes (run from the ansible/ directory on the control node):")
        for label, entry, missing_hosts, wrong_hosts in fixes:
            # Two different risks, so two commands: a fresh install is
            # routine; replacing an installed version is not.
            if missing_hosts:
                print(f"\n  # {label}: install on {len(missing_hosts)} machine(s) where it is missing")
                print("  " + push_command(entry, missing_hosts))
            if wrong_hosts:
                print(f"\n  # {label}: replace the installed version on {len(wrong_hosts)} machine(s)")
                if entry["deploy"].get("type") == "exe":
                    print("  # .exe installers do not upgrade in place reliably: uninstall the "
                          "old version first, then push. Not automated.")
                else:
                    print("  # MSI upgrade over the existing version - try it on ONE machine "
                          "first (add --limit <one host>) before the whole list.")
                print("  " + push_command(entry, wrong_hosts))
    if notes:
        print("\nNotes:")
        for note in notes:
            print(f"  - {note}")
    if problems:
        plural = "y" if problems == 1 else "ies"
        print(f"\n{problems} manifest entr{plural} out of line.")
    else:
        print("\nAll machines match the manifest.")
    return 1 if problems else 0


# --------------------------------------------------------------------- draft
def cmd_draft(args):
    snaps = load_snapshots(args.snapshots)
    manifest = load_manifest(args.manifest) if Path(args.manifest).exists() else []
    names = sorted(snaps)
    n = len(names)
    where = defaultdict(set)
    versions = defaultdict(Counter)
    for h in names:
        for name, ver in parse_programs(snaps[h].get("programs", [])):
            where[name].add(h)
            versions[name][ver] += 1

    def covered(name):
        return any(entry_matches(e, name) for e in manifest)

    common = sorted(((nm, hs) for nm, hs in where.items()
                     if len(hs) / n >= args.threshold and not covered(nm)),
                    key=lambda x: x[0].lower())
    partial = sorted(((nm, hs) for nm, hs in where.items()
                      if args.partial <= len(hs) / n < args.threshold and not covered(nm)),
                     key=lambda x: x[0].lower())

    def yaml_str(s):
        return json.dumps(s, ensure_ascii=False)

    print(f"# {len(common)} program(s) on >= {int(args.threshold * 100)}% of {n} machines "
          f"and not in the manifest yet.")
    print("# Decide for each: keep it (add deploy details if it can be pushed), "
          "or delete the entry / mark it state: absent.\n")
    for nm, hs in common:
        ver = versions[nm].most_common(1)[0][0]
        print(f"  - name: {yaml_str(nm)}")
        print(f"    version: {yaml_str(ver or 'any')}   # on {len(hs)}/{n}")
    if partial:
        print(f"\n# On {int(args.partial * 100)}%-{int(args.threshold * 100)}% of machines "
              f"(split fleet - worth a decision, not auto-listed):")
        for nm, hs in partial:
            missing = sorted(set(names) - hs)
            print(f"#   {nm}  ({len(hs)}/{n}; absent on {short_hosts(missing, 5)})")
    return 0


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    o = sub.add_parser("outliers", help="what differs across the fleet")
    o.add_argument("snapshots")
    o.add_argument("--section", action="append", help="limit to a section (repeatable)")
    o.add_argument("--common", type=float, default=0.7,
                   help="a line on at least this fraction of hosts counts as 'expected' (default 0.7)")
    o.add_argument("--rare", type=float, default=0.25,
                   help="a line on at most this fraction counts as 'extra' (default 0.25)")
    o.add_argument("--max-items", type=int, default=25)
    o.set_defaults(fn=cmd_outliers)

    c = sub.add_parser("check", help="compare machines to the software manifest")
    c.add_argument("snapshots")
    c.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    c.set_defaults(fn=cmd_check)

    d = sub.add_parser("draft", help="programs the manifest does not cover yet")
    d.add_argument("snapshots")
    d.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    d.add_argument("--threshold", type=float, default=0.9)
    d.add_argument("--partial", type=float, default=0.25)
    d.set_defaults(fn=cmd_draft)

    args = ap.parse_args()
    sys.exit(args.fn(args) or 0)


if __name__ == "__main__":
    main()
