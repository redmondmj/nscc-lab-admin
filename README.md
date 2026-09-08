# NSCC Lab — Independent Lab Administration

Migrates a lab's physical machines off NSCC's domain/Intune tenant and
into self-managed administration for IT Systems Management & Security
coursework. Managed going forward via **Ansible** (not Intune/Entra) —
Intune/MDM concepts are taught separately on the course VM fleet.

## Status

Status of the reference deployment this was built for — a 25-machine lab,
useful mainly as evidence of what the tooling has actually been run against:

- [x] Ansible/WinRM bootstrap validated end-to-end against a throwaway test
      VM first - control node setup, `Bootstrap-WinRM-Ansible.ps1`, vault
      password flow, and `ping.yml` all confirmed before touching real
      lab hardware.
- [x] Decommission request sent (`docs/nscc-decommission-request.md`)
- [x] 24 of 25 machines liberated end-to-end: domain-disconnected, moved to
      the lab VLAN with reserved IPs, and Ansible-managed
- [x] Bulk Entra enrollment (`entra-join.yml`) pushed fleet-wide
- [ ] 1 machine still to liberate
- [ ] 4 machines currently unreachable over WinRM pending an on-site fix -
      see Troubleshooting below
- [ ] Institution confirms Intune retirement + Autopilot de-registration
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
   on the control node, paste the output into `inventory/hosts.yml` in one batch.
7. `ansible-playbook playbooks/ping.yml` to confirm the whole batch.

`Run-Full-Migration.ps1` refuses to run past the NSCC-disconnect step
without `-ReleaseConfirmed` (set once in `Run-Bootstrap.local.ps1`, not
per-machine) - only flip that once the decommission request has actually
been sent.

## Layout

```
docs/        Decommission request, port map template, printable door notice
bootstrap/   One-time, per-machine USB scripts (run once via elevated session)
ansible/     Control-node config, inventory, playbooks
imaging/     FOG setup notes — golden-image reset workflow
```

## Local-only files (not in git)

This repo is public, so anything carrying device identifiers or internal
topology is deliberately excluded. Redacted `.example` templates are
committed in their place.

| Real file (gitignored) | Template committed here | What it holds |
|---|---|---|
| `docs/<lab>-port-map.md` | `docs/lab-port-map.example.md` | Per-desk switch/port map: MACs, serials, legacy IPs |
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

## Adapting this to another lab

Everything here is written against one reference deployment, so a few
things are specific to it and need substituting. Nothing is load-bearing
beyond find-and-replace:

| Replace | With | Appears in |
|---|---|---|
| Room/lab number (`312`, `LAB312-##`) | Your lab's number and host prefix | Inventory, port map, hostnames |
| Entra tenant | Your own tenant domain | `ansible/README.md`, `entra-join.yml` |
| `10.20.0.0/24` and VLAN 20 | Your lab VLAN and subnet | Inventory, port map |
| Control node address | Your Ansible control node | `Run-Bootstrap.local.ps1`, `ansible.cfg` |
| `ansible-ops` | Whatever you want the service account called | Bootstrap scripts, `group_vars` |
| Support contact name | Whoever actually fields the questions | `docs/lab-door-notice.html` |

The IP convention used throughout is `LAB###-NN -> 10.20.0.(NN+10)`, which
is arbitrary — pick whatever suits, but keep it mechanical, since the port
map and inventory are maintained by hand.

One thing worth carrying over regardless of naming: machine numbering
follows **sequential physical visit order**, not switch port order. Port
numbers do not track desk layout, and assuming they do has already caused
one real mislabeling incident here.

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
  alongside the Ansible control node.
