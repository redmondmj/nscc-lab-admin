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
- [x] All 24 machines confirmed reachable over WinRM (`ping.yml`
      clean, `ok=24`) - the last stragglers turned out to be a mix of
      the WinRM Basic-auth relock (see Troubleshooting) and machines
      genuinely asleep or unplugged, not new faults
- [x] Baseline playbook run against full inventory (`ok=24`,
      `changed=24` on first run) - `ansible-ops` in Administrators,
      HTTPS-only WinRM, and no more sleep/display-off on AC power
      (Windows Update is deliberately not set here - see the Intune
      update ring under Architecture decisions)
- [ ] Institution confirms Intune retirement + Autopilot de-registration
- [ ] Golden image captured in FOG

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

**Windows Hello PIN complexity differs by account.** A plain member
account can set a short numeric PIN; a privileged account is held to a
longer alphanumeric-plus-symbol PIN on the same machine. Students get
the convenient experience and staff do not, which reads as a bug when
you demo it one way and they hit the other. Nothing is misconfigured —
but say it out loud rather than fielding it at the desk.

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

**Software has gone missing fleet-wide, cause unconfirmed - use
`software-inventory.yml` to find the current scope, don't assume it's
isolated.** First seen 2026-09-16, reported as "Make Me Admin missing"
on two machines but actually two separate incidents once the full
fleet was surveyed:

- **Make Me Admin** gone (service, registry uninstall entry, and
  program folder all removed - the signature of a real
  uninstall/remediation action, not corruption) on `LAB312-02, 07, 12,
  20, 24`.
- **Cisco Packet Tracer, Sassafras KeyServer, and the .NET 8.x
  runtime** all gone together (confirmed genuinely removed, not just
  version-bumped) on a different but overlapping set: `LAB312-11, 12,
  20, 21, 24`.

Five mechanisms were checked and ruled out with real data, not
assumption - worth reading before re-investigating from scratch:
- MDM enrollment status (`IntuneManagementExtension` service)
  identical (`True`) fleet-wide, so it can't explain why only some
  machines lost anything.
- OS build/UBR identical across 22 of 24 machines, including every
  affected one - not a Windows Update/feature-update side effect.
- The missing .NET runtime isn't present under a newer version string
  either - genuinely removed, not serviced/upgraded.
- Intune's own `AgentExecutor.log` and `Win32AppInventory.log` have
  zero mentions of any of the missing apps - Intune's Win32 app
  management (this tenant's, or cleanup from the prior NSCC
  enrollment) left no trace of touching them.
- No `ProgramData` remnants for Sassafras/KeyServer either - not even
  logs survived, on any of the five affected machines.

Leading theory for the Packet Tracer/Sassafras/.NET cluster: Sassafras
KeyServer is a license-metering client, cut off from NSCC's license
server since liberation - fail-closed self-removal after a grace
period would explain a clean, dependency-cascading removal without
requiring any live NSCC connectivity. Unconfirmed. The Make Me Admin
loss has no theory left standing at all - classic GPO software removal
was also considered and set aside, since it requires live domain
policy processing to trigger and these machines are confirmed
domain-disjoined (`dsregcmd` shows `DomainJoined: NO`).

Practical takeaway until this recurs with better data: run
`software-inventory.yml` periodically (a scheduled/cron run, not just
reactively) so a recurrence is caught within hours with a narrow
enough time window to actually find the trigger, instead of a blind
multi-day log search like this one.

## Tracking drift: snapshots and the software manifest

On a shared lab where students have local admin, machines will drift, and
Ansible only enforces what it has been told about. So the approach is
layered: *write down* the baseline, *capture* what is actually there, and
*compare*. None of this changes a machine except the explicit fix commands
it prints.

1. `playbooks/state-snapshot.yml` - read-only capture of every machine
   (programs, services, local users/admins, policy registry, WinRM, power,
   Defender, firewall, scheduled tasks, startup entries) into
   `ansible/snapshots/<label>/<host>.txt`. Take a `known-good` set after
   a verified-clean state, and a `pre-update`/`post-update` pair around a
   Windows update. Snapshots contain account names and are gitignored.
2. `tools/snapshot-tool.py outliers <dir>` - what differs across the
   fleet, grouped ("these 3 machines are each missing the same 14 things").
   `diff` two host files to compare a broken machine to a good one.
3. `software-manifest.yml` - the written-down list of what must (or must
   not) be installed, with version, hash and how to push it.
   `tools/snapshot-tool.py check <dir>` reports drift against it and
   prints ready-to-run `push-software.yml` commands; `draft <dir>` lists
   programs on most machines that the manifest does not mention yet, which
   is how it stays comprehensive. `check` exits non-zero on drift, so it
   can gate a scheduled run.

This is a *soft* reset in the sense that it re-applies known state; it
cannot undo a change nobody has recorded. That is what the FOG golden
image (`imaging/`) is for.

## Architecture decisions (and why)

- **Joined to our own tenant, not the institution's.** The point was never
  "no Entra" — it was "not *their* Entra." Machines are Entra-joined to a
  tenant we control, so students sign in with tenant accounts.
  Day-to-day configuration management stays with Ansible over WinRM
  regardless of MDM state. Identity from Entra, configuration from
  Ansible either way.
- **Windows Update is managed by an Intune update ring, not Ansible.**
  One place owns update behavior. `baseline.yml` used to force
  notify-only through the legacy Group Policy registry key, which
  contradicts a ring set to auto-install and can silently override it;
  that value is now actively removed rather than merely no longer set.
  Scope the ring to a dedicated lab device group (dynamic rule
  `device.displayName -startsWith "LAB312-"`) rather than All devices,
  since the tenant also holds non-lab devices, and consider a long
  feature-update deferral or a pinned feature-update target so a new
  Windows release cannot land mid-semester.
- **Intune auto-enrollment is deliberately left on, not disabled.**
  Unlike the institution's own MDM (which this fleet was liberated from),
  our own tenant's Intune is a teaching asset: having both an
  Ansible-managed and an Intune-managed device coexist in the same room
  lets Intune/MDM concepts be demonstrated hands-on, not just talked
  about on the course VM fleet. The tradeoff this creates: Intune
  policies (Endpoint Security baselines, Attack Surface Reduction rules)
  can conflict with things Ansible/the base image also set up - see the
  Make Me Admin note below and the Troubleshooting entry on it.
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
