<#
.SYNOPSIS
    One-time per-machine step: disconnects this device from NSCC's Entra ID /
    Intune enrollment (local artifacts only) and preps it for Ansible-based
    management.

.DESCRIPTION
    This does NOT release the device from NSCC's tenant. The Intune device
    object and any Autopilot registration live server-side and only NSCC's
    Intune admin can remove them - see docs/nscc-decommission-request.md.
    Confirm that request has been sent (and, if these devices are
    Autopilot-registered, that NSCC has confirmed the de-registration)
    before running this against a machine you intend to factory-reset later -
    otherwise a future reset can pull the machine straight back into NSCC's
    tenant at OOBE.

    This script is meant to run ONCE per machine, from the USB stick, under
    an elevated (Make Me Admin) session. It is not a repeatable "reset"
    mechanism - see imaging/README.md for that.

.NOTES
    Must be run as Administrator.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $env:PUBLIC "Documents\lab-liberate-$($env:COMPUTERNAME)-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Force | Out-Null

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Not running elevated. Run this via Make Me Admin, as Administrator."
    }
}

Assert-Admin

if (-not $Force) {
    Write-Host "This will disconnect $env:COMPUTERNAME from NSCC's local Entra ID/MDM enrollment and reboot." -ForegroundColor Yellow
    Write-Host "Confirm the NSCC decommission request has been sent (docs/nscc-decommission-request.md) before continuing." -ForegroundColor Yellow
    $confirm = Read-Host "Type YES to continue"
    if ($confirm -ne 'YES') { Write-Host "Aborted." -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
}

# 1. Leave Entra ID join (local artifacts)
Write-Host "Disconnecting local Entra ID join..." -ForegroundColor Cyan
dsregcmd /leave
Start-Sleep -Seconds 5

$dsregStatus = dsregcmd /status
if ($dsregStatus -match 'AzureAdJoined\s*:\s*YES') {
    Write-Warning "dsregcmd still reports AzureAdJoined: YES after /leave. Investigate before proceeding to a reset."
}

# 2. Scrub MDM enrollment registry keys
$enrollmentPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
if (Test-Path $enrollmentPath) {
    Write-Host "Scrubbing MDM enrollment registry keys..." -ForegroundColor Cyan
    Get-ChildItem -Path $enrollmentPath |
        Where-Object { $_.PSChildName -match '^\{[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}\}$' } |
        ForEach-Object {
            Write-Verbose "Removing $($_.PSPath)"
            Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
}

# 3. Remove EnterpriseMgmt scheduled tasks (MDM sync/poll)
$taskFolder = "\Microsoft\Windows\EnterpriseMgmt"
Write-Host "Removing EnterpriseMgmt scheduled tasks..." -ForegroundColor Cyan
Get-ScheduledTask -TaskPath "$taskFolder\*" -ErrorAction SilentlyContinue | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false
}
$taskDir = "C:\Windows\System32\Tasks\Microsoft\Windows\EnterpriseMgmt"
if (Test-Path $taskDir) {
    Get-ChildItem -Path $taskDir -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
}

Write-Host "`nLocal disconnection complete. Log saved to $logPath" -ForegroundColor Green
Write-Host "Next: run Bootstrap-WinRM-Ansible.ps1, then reboot when it tells you to." -ForegroundColor Green
Stop-Transcript | Out-Null
