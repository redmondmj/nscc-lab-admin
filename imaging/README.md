# Golden-image reset workflow (FOG)

Replaces the "reset this PC" idea entirely - a factory reset on these
machines is not a safe reset mechanism (see warning below). FOG gives you
the same "quick clean slate" outcome without touching Windows' own
reset/OOBE flow at all.

## ⚠️ Why not just use Windows' built-in Reset this PC

These machines came from NSCC's Intune, possibly Autopilot-registered.
**Do not factory-reset a machine until NSCC has confirmed the Autopilot
de-registration** (see `docs/nscc-decommission-request.md`). If the
hardware-hash → NSCC-tenant binding is still live, a reset calls home at
OOBE and can re-enroll the machine straight back into NSCC's Intune -
pulling it out of your management, not resetting it into a clean state for
yours. Once NSCC confirms de-registration, this risk goes away permanently
for that machine - but until then, treat "Reset this PC" as off-limits.

FOG sidesteps this entirely: it's a raw disk image push over the network,
not a Windows-mediated reset, so it never touches OOBE/Autopilot logic.

## FOG server setup (on the control node)

FOG isn't natively containerized upstream - run it in a small dedicated VM
or LXC container on the control node rather than fighting the installer into a
container:

1. Debian/Ubuntu Server VM or LXC, 2 vCPU / 4GB RAM / 60GB+ disk is plenty
   for a lab this size.
2. Static IP on the lab VLAN, DHCP option 66/67 pointed at it (or let FOG's
   installer manage DHCP if nothing else on that VLAN needs to).
3. Install: https://wiki.fogproject.org/wiki/index.php/Quick_Install_Guide

## Capturing the golden image

1. Fully liberate + Ansible-bootstrap one machine (both scripts, added to
   inventory, baseline playbook run clean).
2. Sysprep it (`sysprep /generalize /oobe /shutdown`) - **note**: sysprep
   will require re-running `Bootstrap-WinRM-Ansible.ps1` after deploying
   from the image, since sysprep wipes local accounts including
   `ansible-ops`. That's expected - it becomes the standard first-boot step
   for every machine deployed from this image, same as the very first one.
3. PXE-boot into FOG, register the host, capture.

## Deploying the reset

1. PXE-boot the messy machine, select "Deploy" for the golden image task.
2. On first boot after deploy: re-run `Bootstrap-WinRM-Ansible.ps1` (sysprep
   cleared the local account - see above).
3. `ansible-playbook playbooks/baseline.yml` to bring it back to current
   baseline (in case the golden image predates recent playbook changes).

Consider making step 2-3 itself a short unattended script triggered post-
deploy, once the manual flow is proven out - but get the manual version
working first.
