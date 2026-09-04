# NSCC Intune decommission request

Send before running `bootstrap/Liberate-FromNSCC.ps1` on any machine that is
Autopilot-registered. See `imaging/README.md` for why this matters for the
reset workflow specifically, not just cleanup.

Fill in serials/asset tags below (keep the actual list in a local
`serials.csv`, which is gitignored — don't commit device identifiers).

---

**To:** [NSCC IT / Intune admin contact]
**Subject:** Device decommission request — Lab 312 hardware, [N] units

Hi [name/team],

As part of [reference to the approved Lab 312 reallocation], we're moving
the following [N] devices out of NSCC's Intune management into our own
sandbox tenant:

[Serial numbers / asset tags — list or attach CSV]

Could you:
1. Retire/delete these devices from Intune, and
2. Remove them from Windows Autopilot (if registered)

No other action needed on your end — we're handling re-provisioning
ourselves. Removing the Autopilot registration specifically means a
factory reset won't try to pull the device back into NSCC's tenant, which
we'd like as a clean, reliable baseline for lab resets going forward.

Thanks!
[Your name / contact]

---

## Tracking

| Serial/Asset Tag | Sent | NSCC confirmed retired | NSCC confirmed Autopilot removed | Liberated | Ansible-managed |
|---|---|---|---|---|---|
| AAAAAAA (LAB3XX-01) | Yes | pending | pending | Yes | Yes |
| | | | | | |
