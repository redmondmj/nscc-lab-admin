# state-snapshot.ps1 - read-only capture of one lab machine's configuration.
#
# Output is sorted, line-oriented text in "## section" blocks so two
# machines (or one machine at two points in time) can be compared with
# plain diff, and the whole fleet can be compared with
# tools/snapshot-tool.py. Changes nothing on the machine.
#
# Runs on Windows PowerShell 5.1, elevated. Pushed and fetched by
# playbooks/state-snapshot.yml, which is the normal way to run it.
param(
    [string]$OutFile = "$env:WINDIR\Temp\state-snapshot.txt"
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Section([string]$Name) { ''; "## $Name" }

# Every value under a registry tree, one "key\name = data" line each.
function Get-KeyValues([string]$Root) {
    if (-not (Test-Path $Root)) { return }
    $keys = @(Get-Item $Root) + @(Get-ChildItem $Root -Recurse)
    foreach ($k in $keys) {
        foreach ($n in $k.GetValueNames()) {
            $v = $k.GetValue($n)
            if ($v -is [array]) { $v = $v -join ',' }
            $name = if ($n) { $n } else { '(default)' }
            # Per-enrollment GUIDs differ on every machine and would bury
            # real differences in noise; keep the fact, mask the value.
            if ($name -like '*_WinningProvider') { $v = '<provider-id>' }
            # Office records whoever last signed in; on a shared lab that
            # is student names and W-numbers. Never collect it.
            if ($name -like 'LastLoggedInUser*') { $v = '<redacted>' }
            '{0}\{1} = {2}' -f $k.Name, $name, $v
        }
    }
}

$lines = & {
    Section 'meta'
    'captured = ' + (Get-Date -Format s)
    'computer = ' + $env:COMPUTERNAME

    Section 'os'
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    '{0} {1} build {2}.{3}' -f $cv.ProductName, $cv.DisplayVersion, $cv.CurrentBuildNumber, $cv.UBR

    Section 'join'
    dsregcmd /status | Select-String -Pattern '^\s*(AzureAdJoined|DomainJoined|TenantName)\s*:' |
        ForEach-Object { ($_.Line -replace '\s+', ' ').Trim() }

    Section 'programs'
    # Some vendors prefix DisplayName with a U+FEFF byte-order mark
    # (Packet Tracer does); strip it so names compare equal everywhere.
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName } |
        ForEach-Object { '{0} | {1}' -f ($_.DisplayName -replace '^﻿', '').Trim(), $_.DisplayVersion } |
        Sort-Object -Unique

    Section 'store-apps'
    Get-AppxPackage -AllUsers | Select-Object -ExpandProperty Name | Sort-Object -Unique

    Section 'services'
    # Per-user service instances carry a random hex suffix; skip them.
    Get-CimInstance Win32_Service |
        Where-Object { $_.Name -notmatch '_[0-9a-f]{4,8}$' } |
        Sort-Object Name |
        ForEach-Object { '{0} | {1}' -f $_.Name, $_.StartMode }

    Section 'local-users'
    Get-LocalUser | Sort-Object Name | ForEach-Object { '{0} | enabled={1}' -f $_.Name, $_.Enabled }

    Section 'local-admins'
    # Local accounts come back as "<COMPUTERNAME>\name"; swap the machine
    # name for a placeholder so the same account looks the same everywhere.
    $me = '^' + [regex]::Escape($env:COMPUTERNAME) + '\\'
    Get-LocalGroupMember -Group 'Administrators' |
        ForEach-Object { '{0} | {1}' -f ($_.Name -replace $me, '<host>\'), $_.ObjectClass } |
        Sort-Object

    Section 'policies'
    Get-KeyValues 'HKLM:\SOFTWARE\Policies' | Sort-Object
    Get-KeyValues 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies' | Sort-Object

    Section 'mdm-policy'
    # \knobs\ is ~900 lines of power-scheme tuning data, not policy intent.
    Get-KeyValues 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device' |
        Where-Object { $_ -notlike '*\knobs\*' } | Sort-Object

    Section 'startup'
    Get-KeyValues 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' | Sort-Object
    Get-KeyValues 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' | Sort-Object
    Get-KeyValues 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' | Sort-Object

    Section 'winrm'
    Get-ChildItem WSMan:\localhost\Service\Auth | Sort-Object Name |
        ForEach-Object { 'auth-{0} = {1}' -f $_.Name, $_.Value }
    'allow-unencrypted = ' + (Get-Item WSMan:\localhost\Service\AllowUnencrypted).Value
    Get-ChildItem WSMan:\localhost\Listener |
        ForEach-Object { 'listener = ' + (($_.Keys | Sort-Object) -join ' ') }

    Section 'power'
    foreach ($p in @(@('SUB_SLEEP', 'STANDBYIDLE', 'standby-timeout'), @('SUB_VIDEO', 'VIDEOIDLE', 'display-timeout'))) {
        powercfg /q SCHEME_CURRENT $p[0] $p[1] |
            Select-String -Pattern 'Current (AC|DC) Power Setting Index: (\S+)' |
            ForEach-Object { '{0}-{1} = {2}' -f $p[2], $_.Matches[0].Groups[1].Value.ToLower(), $_.Matches[0].Groups[2].Value }
    }

    Section 'defender'
    $mp = Get-MpComputerStatus
    if ($mp) {
        'realtime-protection = ' + $mp.RealTimeProtectionEnabled
        'antivirus = ' + $mp.AntivirusEnabled
    }
    $pref = Get-MpPreference
    if ($pref) {
        foreach ($e in (@($pref.ExclusionPath) | Where-Object { $_ })) { 'exclusion-path = ' + $e }
        foreach ($e in (@($pref.ExclusionProcess) | Where-Object { $_ })) { 'exclusion-process = ' + $e }
        foreach ($e in (@($pref.ExclusionExtension) | Where-Object { $_ })) { 'exclusion-extension = ' + $e }
    }

    Section 'firewall'
    Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow |
        Sort-Object DisplayName |
        ForEach-Object { '{0} | profile={1}' -f $_.DisplayName, $_.Profile }

    Section 'scheduled-tasks'
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
        Sort-Object TaskPath, TaskName |
        ForEach-Object { $_.TaskPath + $_.TaskName }

    Section 'hosts-file'
    Get-Content "$env:WINDIR\System32\drivers\etc\hosts" | Where-Object { $_ -match '^\s*[^#\s]' }

    Section 'environment'
    [Environment]::GetEnvironmentVariables('Machine').GetEnumerator() | Sort-Object Name |
        ForEach-Object { '{0} = {1}' -f $_.Name, $_.Value }
}

# LF line endings, UTF-8 without a BOM: byte-for-byte what the analysis
# tool and diff expect, regardless of the console code page.
[System.IO.File]::WriteAllText($OutFile, (($lines | ForEach-Object { "$_" }) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))
