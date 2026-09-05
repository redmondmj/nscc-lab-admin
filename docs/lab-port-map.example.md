# Lab 3XX — switch/port map (TEMPLATE)

> **This is a redacted template.** The real, populated version contains
> device serial numbers, MAC addresses and internal topology, so it is
> **gitignored and never committed**.
>
> **Real file location:** `docs/<your-lab>-port-map.md` (same directory)
> **Also kept on:** the Ansible control node, alongside the repo checkout
>
> If you have cloned this repo fresh and that file is missing, it has to
> come from one of those two copies — it cannot be reconstructed from git.

Build this by cross-referencing your switch port tables (`last_seen_mac`)
against the client list from your controller.

Fill in the `LAB3XX-##` column yourself as you physically visit each desk
**in visit order** — port number is *not* a reliable proxy for physical
seating, and one batch of sequentially-visited machines can span multiple
switches non-contiguously. Numbering follows the order machines are
processed into `liberated-machines.csv`, not port order.

For each row: move the port to the target VLAN, run the USB migration
script on that machine, confirm it picks up its reservation.

## SW-XX (SWITCH-NAME-HERE)

| Port | Legacy hostname | MAC | Legacy IP | LAB3XX-## | Status |
|---|---|---|---|---|---|
| 9 | HOSTNAME-AAAAAAA | 00:00:00:00:00:01 | 10.0.0.101 | **LAB3XX-01** | ✅ done (10.20.0.11) - WinRM/Ansible confirmed |
| 10 | HOSTNAME-BBBBBBB | 00:00:00:00:00:02 | 10.0.0.102 | **LAB3XX-02** | 🔄 reservation+rename+port done - not yet confirmed reachable |
| 11 | HOSTNAME-CCCCCCC | 00:00:00:00:00:03 | 10.0.0.103 | | pending |

## Status legend

- `pending` — not yet touched
- 🔄 — reservation + rename + port move done, WinRM not yet confirmed
- ⚠️ — reachable at network layer but authentication failing (see repo
  README troubleshooting notes)
- ✅ — confirmed reachable over WinRM/Ansible via `ping.yml`
