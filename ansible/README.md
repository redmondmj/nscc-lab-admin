# Ansible control node

Target: **Docker-Host (VM 103)**, node `pve`, Proxmox-Prod cluster.

## One-time control node setup

Ubuntu 24.04+ / Debian 12+ block a plain `pip3 install` system-wide (PEP
668, "externally-managed-environment"). Don't reach for
`--break-system-packages` - use a venv, it's the correct fix, not a
workaround:

```bash
# On Docker-Host:
sudo apt install -y python3-full python3-venv
python3 -m venv ~/ansible-venv
~/ansible-venv/bin/pip install ansible pywinrm
echo 'export PATH="$HOME/ansible-venv/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
ansible-playbook --version   # should just work from here on, no manual activate needed
```

`pywinrm` is required for the `winrm` connection plugin - Ansible can't talk
to Windows over WinRM without it.

## Vault password

Don't put the vault password in git. On the control node:

```bash
echo "your-vault-password" > ~/.ansible_vault_pass
chmod 600 ~/.ansible_vault_pass
```

Then either export `ANSIBLE_VAULT_PASSWORD_FILE=~/.ansible_vault_pass` in
your shell profile, or pass `--vault-password-file ~/.ansible_vault_pass`
per command instead of `--ask-vault-pass`.

## Per-machine workflow

1. Run `bootstrap/Liberate-FromNSCC.ps1` then `bootstrap/Bootstrap-WinRM-Ansible.ps1`
   on the machine (USB, elevated via Make Me Admin) - see the scripts'
   comment headers for prerequisites.
2. Add the machine to `inventory/hosts.yml` under `windows_lab`.
3. Set the same password you used in the bootstrap script into
   `inventory/group_vars/windows_lab/vault.yml` (see `vault.yml.example`
   in the same folder). This location matters - Ansible only auto-loads
   `group_vars/` when it's adjacent to the inventory file or the playbook,
   not just anywhere in the project.
4. `ansible-playbook playbooks/ping.yml --vault-password-file ~/.ansible_vault_pass`
5. `ansible-playbook playbooks/baseline.yml --vault-password-file ~/.ansible_vault_pass`

## Entra ID join (nscctruro.ca)

Separate from the physical bootstrap - run this from Docker-Host, at scale,
against every machine already onboarded to Ansible:

1. Copy the provisioning package built in Windows Configuration Designer to
   `ansible/files/Bulk-Enrollment.ppkg` (gitignored - it embeds a live bulk
   enrollment token, never commit it).
2. `scp` (or re-sync) that file to Docker-Host if it isn't there yet.
3. `ansible-playbook playbooks/entra-join.yml --vault-password-file ~/.ansible_vault_pass`

Safe to re-run as new machines get added to inventory - already-joined
machines are skipped. The bulk token expires ~30 days after generation;
regenerate in WCD and re-copy the file if you're still onboarding machines
past that window.

Students sign into these machines with their own `nscctruro.ca` account as
standard users. Y2 SysMan students get local admin via a dedicated Entra ID
security group under Device settings -> "Additional local administrators
on Entra joined devices" - not a shared local account.

## Rotating the ansible-ops password fleet-wide

There's no LAPS here (deliberate - no Entra join for this fleet), so
rotation is manual:

1. Pick a new password.
2. Update `vault.yml` (`ansible-vault edit vault.yml`).
3. Push it out: add a `win_user` task that sets the password to the new
   vaulted value and run it against the fleet *before* changing
   `ansible_winrm_*` vars, so the old connection still works for that one run.
