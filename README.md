# NSCC Lab 312 — Independent Lab Administration

Migrates the Lab 312 physical machines off NSCC's domain/Intune tenant and
into self-managed administration for IT Systems Management & Security
coursework. Managed going forward via **Ansible** (not Intune/Entra) —
Intune/MDM concepts are taught separately on the course VM fleet.

## Status

- [x] Ansible/WinRM bootstrap validated end-to-end against a test VM
      (`Ansible-Windows11-1`, Proxmox-Prod pve2/3500) - control node setup,
      `Bootstrap-WinRM-Ansible.ps1`, vault password flow, and `ping.yml`
      all confirmed working before touching real lab hardware.
- [x] NSCC decommission request sent (`docs/nscc-decommission-request.md`)
- [x] LAB312-01 through 12 fully processed end-to-end: liberated, VLAN 20
      (reserved IPs 10.20.0.11-22), Ansible-managed - all confirmed reachable
      via `ping.yml` as of 2026-09-04. LAB312-01 also Entra-joined to
      nscctruro.ca + Intune-enrolled (pipeline proven; 02-12 still need the
      entra-join.yml pass)
- [ ] Remaining 13 machines (see `docs/lab312-port-map.md`)
- [ ] NSCC confirms Intune retirement + Autopilot de-registration
- [ ] Per-machine liberation (`bootstrap/Liberate-FromNSCC.ps1`)
- [ ] Per-machine Ansible bootstrap (`bootstrap/Bootstrap-WinRM-Ansible.ps1`)
- [ ] Golden image captured in FOG
- [ ] Baseline playbook run against full inventory

## Real hardware rollout (per machine)

1. Log in with NSCC account → Make Me Admin → elevated terminal
2. `Set-ExecutionPolicy -Scope Process Bypass -Force`
3. Run `bootstrap\Run-Bootstrap.local.ps1` from the USB stick (wraps
   `Run-Full-Migration.ps1` - bootstraps WinRM/Ansible, checks it landed,
   disconnects from NSCC, logs the IP, reboots once). One MMA elevation,
   one reboot, not two round trips.
4. Note the hostname/IP printed at the end (also appended to
   `liberated-machines.csv` on the USB stick either way).
5. Log back in as `.\ansible-ops` to confirm the local account survived the
   disconnect.
6. Once all machines for the session are done: `python3 ansible/tools/csv-to-inventory.py liberated-machines.csv`
   on Docker-Host, paste the output into `inventory/hosts.yml` in one batch.
7. `ansible-playbook playbooks/ping.yml` to confirm the whole batch.

`Run-Full-Migration.ps1` refuses to run past the NSCC-disconnect step
without `-ReleaseConfirmed` (set once in `Run-Bootstrap.local.ps1`, not
per-machine) - only flip that once the decommission request has actually
been sent.

## Layout

```
docs/        Decommission request + process notes
bootstrap/   One-time, per-machine USB scripts (run once via elevated session)
ansible/     Control-node config, inventory, playbooks (targets Docker-Host VM 103, pve/Proxmox-Prod)
imaging/     FOG setup notes — golden-image reset workflow
```

## Local-only files (not in git)

This repo is public, so anything carrying device identifiers or internal
topology is deliberately excluded. Redacted `.example` templates are
committed in their place.

| Real file (gitignored) | Template committed here | What it holds |
|---|---|---|
| `docs/lab312-port-map.md` | `docs/lab312-port-map.example.md` | Per-desk switch/port map: MACs, serials, legacy IPs |
| `ansible/inventory/hosts.yml` | `ansible/inventory/hosts.yml.example` | Live inventory (hostname comments embed serials) |
| `ansible/inventory/group_vars/windows_lab/vault.yml` | `vault.yml.example` | ansible-vault encrypted `ansible_password` |
| `bootstrap/Run-Bootstrap.local.ps1` | — | USB wrapper carrying the ansible-ops password |
| `ansible/files/Bulk-Enrollment.ppkg` | — | Bulk enrollment package (embedded token) |
| `docs/network-modernization-status.md` | — | Point-in-time network assessment |

**These are not recoverable from git.** They exist in exactly two places:
the working checkout, and the Ansible control node. Keep both.

Note: the hostname suffixes on these machines (e.g. `HOSTNAME-AAAAAAA`) are
the Dell service tags, i.e. the device serial numbers — which is why the
port map and inventory are excluded rather than just the obvious secrets.

## Architecture decisions (and why)

- **No Entra ID / Intune enrollment for this fleet.** Deliberate choice —
  students already get Intune/MDM hands-on via the VM lab. These machines
  stay workgroup, managed purely over WinRM/Ansible. This means local admin
  is Ansible-managed (vaulted password), not Entra-group/LAPS-based.
- **NSCC release is a hard prerequisite, not a nice-to-have.** The
  liberation script only strips *local* enrollment artifacts. The Intune
  device object and any Autopilot registration live server-side in NSCC's
  tenant and only they can remove them. See `docs/nscc-decommission-request.md`.
  Do not reset a machine before NSCC confirms the Autopilot de-registration —
  see the warning in `imaging/README.md`.
- **FOG over MDT/ConfigMgr for the reset workflow.** MDT was
  [retired by Microsoft on 2026-01-06](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/mdt/mdt-retirement) —
  no more updates or Win11 compatibility work. ConfigMgr is supported but
  wants AD + SQL + a site server, which conflicts with the workgroup-only
  decision above. FOG is lightweight, Linux-hosted, and fits directly
  alongside the Ansible control node on Docker-Host.
