# NSCC Lab — Independent Lab Administration

Migrates a lab's physical machines off NSCC's domain/Intune tenant and
into self-managed administration for IT Systems Management & Security
coursework. Managed going forward via **Ansible** (not Intune/Entra) —
Intune/MDM concepts are taught separately on the course VM fleet.

## Status

Status of the reference deployment this was built for — a 24-machine lab,
useful mainly as evidence of what the tooling has actually been run against:

- [x] Ansible/WinRM bootstrap validated end-to-end against a throwaway test
      VM first - control node setup, `Bootstrap-WinRM-Ansible.ps1`, vault
      password flow, and `ping.yml` all confirmed before touching real
      lab hardware.
- [x] Decommission request sent (`docs/nscc-decommission-request.md`)
- [x] All 24 machines liberated end-to-end: domain-disconnected, moved to
      the lab VLAN with reserved IPs, and Ansible-managed
      (the room is 24 machines; a 25th port belongs to the instructor dock)
- [x] Bulk Entra enrollment (`entra-join.yml`) pushed fleet-wide
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

## Troubleshooting

Things that cost real time on the reference deployment, and how each
announces itself.

**UAC prompts after elevating with Make Me Admin want the full UPN.**
Once elevated, subsequent UAC dialogs will not accept a bare username —
they need `username@your-tenant`. A Windows Hello PIN works too and is
far quicker. This reads to students as "it's rejecting my password," so
it is worth saying out loud in class rather than fielding it one desk at
a time.

**"The specified credentials were rejected by the server" — but the
password is right.** Institutional Intune/GPO policy can silently
re-lock WinRM's Basic-auth setting on reboot, even on a machine that
worked yesterday. Confirm by checking `Basic` in
`winrm get winrm/config/service`. Re-running
`bootstrap/Bootstrap-WinRM-Ansible.ps1` fixes it, because it removes the
policy-backed registry key before re-enabling Basic. If it recurs, the
underlying fix is completing the device's removal from the previous
tenant, not repeating the repair.

Note that script also resets the service account's password as a side
effect, so it repairs a credential mismatch at the same time — which
makes it easy to conflate two different causes. If both auth transports
(`basic` *and* `ntlm`) reject the same credentials, the problem is the
account, not the transport.

**A provisioning package reporting success is not proof of enrollment.**
`Install-ProvisioningPackage` returning `rc=0` and `Get-ProvisioningPackage`
reporting the package as installed both mean only that the package was
*staged*. The Entra join happens at next boot, and if that step fails it
fails silently while every local check keeps saying success. Three machines
sat unjoined for four days looking perfectly healthy. **Verify with
`dsregcmd /status` and require both `AzureAdJoined : YES` and a
`TenantName` line** — the absence of `TenantName` is the tell.

A package can also wedge: `IsInstalled : False` while still blocking
reinstall with `0x800700B7` (`ERROR_ALREADY_EXISTS`).
`Remove-ProvisioningPackage` sometimes clears it and sometimes does not.
Cap the remote attempts and join by hand — Settings → Accounts → Access
work or school → Connect → *Join this device to Microsoft Entra ID*.

**Device join may be restricted to admins.** A plain member account will
be refused when joining manually. Use an admin account, or loosen Entra →
Devices → Device settings. Bulk-enrollment packages are unaffected, since
the bulk token carries its own join rights.

**An unreachable machine is often just asleep.** A sleeping machine
produces a connection timeout indistinguishable from a real fault. Set
`powercfg /change standby-timeout-ac 0` via `baseline.yml` rather than
diagnosing it repeatedly.

**Don't trust the controller's client status.** UniFi reported every
machine offline, last seen four days earlier, while Intune showed the same
machines checking in that afternoon. Where the network controller and the
device disagree, believe the device.

**A manual join sets a primary user; bulk enrollment does not.** Machines
joined by hand show whoever signed in as primary user, which makes them
inconsistent with the rest of the fleet. Clear it in Intune → Devices →
Properties if uniformity matters.

## Architecture decisions (and why)

- **Joined to our own tenant, not the institution's.** The point was never
  "no Entra" — it was "not *their* Entra." Machines are Entra-joined to a
  tenant we control, so students sign in with tenant accounts, while
  configuration management stays with Ansible over WinRM rather than MDM
  policy. Identity from Entra, configuration from Ansible.
- **Local admin via Make Me Admin, left unrestricted — deliberately.**
  Make Me Admin is inherited from the original image and its allow-list is
  unconfigured, which means any interactive user can self-elevate. That is
  a conscious decision, not an oversight: students had the same access on
  the institution's network, so restricting it here would be a downgrade
  rather than a safeguard. Note it operates as a local SYSTEM service and
  consults Entra not at all, so it is invisible to Device settings and
  Intune account-protection policy — if you *do* want it scoped, that is
  `HKLM\SOFTWARE\Policies\SinclairCC\MakeMeAdmin` (`Allowed Entities` /
  `Denied Entities`), and it belongs in `baseline.yml` so the state is
  asserted rather than inherited.
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
