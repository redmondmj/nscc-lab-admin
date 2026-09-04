<#
.SYNOPSIS
    Combined one-visit migration: bootstraps WinRM/Ansible, sanity-checks it
    locally, then disconnects from NSCC - one MMA elevation and one reboot
    per machine instead of two separate round trips.

.DESCRIPTION
    Runs, in order: Bootstrap-WinRM-Ansible.ps1 (no reboot), a local
    configuration check (service/listener/account/firewall all actually
    came up - not a live network round-trip, since testing the HTTPS
    listener locally fights self-signed cert validation for no real
    benefit), then Liberate-FromNSCC.ps1, then one final reboot.

    Requires -ReleaseConfirmed to proceed past the NSCC-disconnect step.
    This is a deliberate ONE-TIME acknowledgment (set it once in your local
    wrapper, not typed per machine) that you've actually sent - and ideally
    gotten confirmation on - docs/nscc-decommission-request.md. Don't set
    it until that's actually true; see imaging/README.md for why a
    live/Autopilot-registered device matters here.

    Also appends this machine's hostname/IP to liberated-machines.csv next
    to this script (i.e. on the USB stick), so you can bulk-import all of
    them into Ansible's inventory afterward instead of hand-editing
    hosts.yml 25 times - see ansible/tools/csv-to-inventory.py.

.PARAMETER ReleaseConfirmed
    Required. Refuses to run the NSCC-disconnect step without it.

.NOTES
    Must be run as Administrator (Make Me Admin).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ControlNodeAddress,

    [string]$AnsibleUser = "ansible-ops",

    [Parameter(Mandatory)]
    [System.Security.SecureString]$AnsiblePassword,

    # Deliberately NOT Mandatory - a forgotten/missing flag should fail safe
    # (stop before the NSCC disconnect) rather than interactively prompt,
    # which also errors on this type (SwitchParameter binds oddly from
    # Read-Host-style input if this script is ever run directly).
    [switch]$ReleaseConfirmed,

    # Optional. If set, pauses before the final reboot instead of
    # auto-rebooting after 10 seconds - gives you a window to move this
    # machine's switch port to VLAN 20 in UniFi right then, so the reboot
    # picks up its new VLAN/IP directly instead of needing a separate
    # ipconfig /release+/renew afterward. Skip this if you'd rather batch
    # all the port moves together later instead of doing one per visit.
    [switch]$PauseForPortMove
)

$ErrorActionPreference = 'Stop'

# 1. Bootstrap WinRM/Ansible - no reboot yet, one combined reboot happens at the end.
& "$PSScriptRoot\Bootstrap-WinRM-Ansible.ps1" `
    -ControlNodeAddress $ControlNodeAddress -AnsibleUser $AnsibleUser `
    -AnsiblePassword $AnsiblePassword -NoReboot

# 2. Sanity-check the bootstrap actually landed, before burning the bridge to
# NSCC. Checks local config state directly rather than a live WinRM round
# trip - a real network test would fight self-signed cert validation on
# loopback for no real benefit, since the actual cross-machine path was
# already proven against the test VM.
Write-Host "Checking bootstrap landed correctly before disconnecting from NSCC..." -ForegroundColor Cyan
$svc = Get-Service WinRM -ErrorAction Stop
$listener = Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains "Transport=HTTPS" }
$user = Get-LocalUser -Name $AnsibleUser -ErrorAction Stop
$rule = Get-NetFirewallRule -DisplayName "WinRM-HTTPS-Ansible" -ErrorAction Stop

if ($svc.Status -ne 'Running')      { throw "WinRM service is not running." }
if (-not $listener)                 { throw "No WinRM HTTPS listener found." }
if (-not $user.Enabled)             { throw "'$AnsibleUser' account exists but is disabled." }
if ($rule.Enabled -ne $true)        { throw "WinRM-HTTPS-Ansible firewall rule exists but is disabled." }
Write-Host "Bootstrap confirmed working." -ForegroundColor Green

# 3. Log this machine now regardless of what happens next - useful for
# testing WinRM/Ansible reachability even before NSCC disconnect happens.
$csvPath = Join-Path $PSScriptRoot "liberated-machines.csv"
# Grabbing "the first IPv4 address" isn't reliable - VPN clients, Hyper-V
# switches, etc. can easily sort before the real adapter. Use the interface
# that actually owns the default route instead - that's the one reachable
# from outside this machine.
$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object -Property RouteMetric | Select-Object -First 1
$ip = if ($defaultRoute) {
    (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue |
        Select-Object -First 1).IPAddress
} else {
    (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -First 1).IPAddress
}
# MAC of that same real interface - needed to look this machine up in UniFi
# (port location, DHCP reservation, rename) once it's confirmed liberated.
$mac = if ($defaultRoute) {
    (Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue).MacAddress
} else { $null }
[PSCustomObject]@{
    Hostname  = $env:COMPUTERNAME
    IPAddress = $ip
    MACAddress = $mac
    Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
} | Export-Csv -Path $csvPath -Append -NoTypeInformation

Write-Host "`n=========================================" -ForegroundColor Green
Write-Host " $env:COMPUTERNAME -> $ip ($mac)" -ForegroundColor Green
Write-Host " (also logged to liberated-machines.csv on this USB stick)" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green

# 4. Gate: only actually disconnect from NSCC once explicitly confirmed.
# Stopping here (rather than at the top of the script) means Bootstrap - the
# fully reversible half - already ran and can be tested/verified over
# Ansible before you commit to the irreversible half.
if (-not $ReleaseConfirmed) {
    Write-Host "`n-ReleaseConfirmed not set - stopping here without touching NSCC's Entra join." -ForegroundColor Yellow
    Write-Host "Bootstrap is done and this machine should already be reachable over Ansible." -ForegroundColor Yellow
    Write-Host "Once docs/nscc-decommission-request.md is actually sent, re-run with -ReleaseConfirmed to finish the disconnect." -ForegroundColor Yellow
    exit 0
}

# 5. Disconnect from NSCC. -Force skips the interactive Y/N prompt since
# -ReleaseConfirmed above is the deliberate gate for this run.
& "$PSScriptRoot\Liberate-FromNSCC.ps1" -Force

if ($PauseForPortMove) {
    Write-Host "`nAll done. Go move this machine's switch port to VLAN 20 in UniFi now," -ForegroundColor Yellow
    Write-Host "then press any key to reboot - it'll pick up its new VLAN/IP directly," -ForegroundColor Yellow
    Write-Host "no separate ipconfig /release+/renew needed afterward." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
} else {
    Write-Host "`nAll done. Rebooting in 10 seconds - log back in as .\$AnsibleUser afterward." -ForegroundColor Green
    Start-Sleep -Seconds 10
}
Restart-Computer
