<#
.SYNOPSIS
One-time boot selector for Windows 10/11 on UEFI systems.

.DESCRIPTION
Lists the UEFI firmware boot entries, sets the chosen one as the one-time boot
target ({fwbootmgr} bootsequence) and restarts the computer. The regular boot
order is not changed: the choice applies to the next restart only.

Generic firmware entries (USB, CD/DVD, PXE/network, EFI shell, diagnostics,
firmware settings) are hidden unless -All is given.

Requires Administrator rights. When started without them, the script relaunches
itself elevated (UAC prompt) with the same parameters.

.PARAMETER Target
Boot target to use instead of showing the menu. Can be:
  - the number shown in the menu or by -List, e.g. 2
  - the system name or description, case-insensitive, partial match allowed, e.g. ubuntu
  - the identifier, with or without braces, e.g. {bootmgr}

.PARAMETER NoReboot
Sets the one-time boot target without restarting.

.PARAMETER Delay
Seconds to wait before restarting, during which Ctrl+C cancels. Default is 5.

.PARAMETER All
Also includes the generic firmware entries (USB, CD/DVD, network, ...).
Numbers shown with -All are only valid together with -All.

.PARAMETER List
Lists the boot targets with their identifiers, and the pending one-time boot
target if any, then exits.

.PARAMETER Clear
Removes a pending one-time boot target, e.g. one set with -NoReboot.

.EXAMPLE
.\reboot.ps1
Shows the menu.

.EXAMPLE
.\reboot.ps1 ubuntu
Restarts into Ubuntu once.

.EXAMPLE
.\reboot.ps1 2 -Delay 0
Restarts into menu entry 2 without waiting.

.EXAMPLE
.\reboot.ps1 windows -NoReboot
Boots into Windows on the next restart, without restarting now.

.EXAMPLE
.\reboot.ps1 ubuntu -WhatIf
Shows what would be done, without changing anything.

.EXAMPLE
.\reboot.ps1 -List -All
Lists every firmware entry, including USB drives and network boot.

.EXAMPLE
.\reboot.ps1 -Clear
Cancels a pending one-time boot target.
#>
#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Boot', SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0, ParameterSetName = 'Boot')]
    [string]$Target,

    [Parameter(ParameterSetName = 'Boot')]
    [switch]$NoReboot,

    [Parameter(ParameterSetName = 'Boot')]
    [ValidateRange(0, 3600)]
    [int]$Delay = 5,

    [Parameter(ParameterSetName = 'Boot')]
    [Parameter(ParameterSetName = 'List')]
    [switch]$All,

    [Parameter(Mandatory = $true, ParameterSetName = 'List')]
    [switch]$List,

    [Parameter(Mandatory = $true, ParameterSetName = 'Clear')]
    [switch]$Clear,

    # Internal: set when the script relaunches itself as Administrator
    [Parameter(DontShow = $true)]
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Descriptions of generic firmware entries, hidden unless -All is given
$NoisePattern = 'firmware settings|hard drive|cd/dvd|cdrom|pxe|network|usb|ipv4|ipv6|diagnostic|shell'

# Descriptions kept even when the entry has no EFI path
$KnownOsPattern = 'windows|ubuntu|debian|fedora|\barch|manjaro|centos|rocky|almalinux|opensuse|mint|pop!_os|opencore|macos'

# Display name => pattern matched against the description or the EFI path
$FriendlyNames = [ordered]@{
    'Windows'  = 'windows boot manager|\\efi\\microsoft\\boot\\bootmgfw\.efi'
    'Ubuntu'   = 'ubuntu'
    'OpenCore' = 'opencore|\\efi\\oc\\opencore\.efi'
    'macOS'    = 'macos|\\system\\library\\coreservices\\boot\.efi'
}

function Invoke-Bcdedit {
    # Runs bcdedit.exe and returns its output lines; throws with the output when it fails.
    # Sysnative is the 64-bit System32 as seen from 32-bit PowerShell.
    $exe = "$env:SystemRoot\Sysnative\bcdedit.exe"
    if (-not (Test-Path -LiteralPath $exe)) { $exe = "$env:SystemRoot\System32\bcdedit.exe" }

    # Windows PowerShell turns redirected stderr into terminating errors under 'Stop'
    $ErrorActionPreference = 'Continue'
    $output = @(& $exe @args 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit $args failed:`n$($output -join "`n")"
    }
    $output
}

function ConvertFrom-BcdeditOutput {
    # Turns `bcdedit /enum` output into objects: { Id; Props = @{ name = [string[]] } }.
    # Each block is a title, a dashed line, then "name   value" lines; list values
    # continue on indented lines. The first element is the identifier, whose name
    # is localized (identifier, Bezeichner, ...), so it is read by position. The
    # other element names (description, device, path, ...) are not localized.
    param([string[]]$Lines)

    $block = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($Lines) + '') {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $block.Add($line)
            continue
        }

        if ($block.Count -ge 3 -and $block[1] -match '^-+\s*$' -and $block[2] -match '(\{[^{}]+\})\s*$') {
            $id = $Matches[1]
            $name = $null
            $props = @{}
            foreach ($item in $block.GetRange(2, $block.Count - 2)) {
                if ($item -match '^(\S+)\s*(.*)$') {
                    $name = $Matches[1]
                    $props[$name] = @($Matches[2].Trim())
                }
                elseif ($name) {
                    $props[$name] += $item.Trim()
                }
            }
            [pscustomobject]@{ Id = $id; Props = $props }
        }
        $block.Clear()
    }
}

function Get-VolumeDiskMap {
    # Maps the volumes bcdedit shows ("\Device\HarddiskVolume1", "C:") to "<disk name> (Disk N)"
    $ProgressPreference = 'SilentlyContinue'   # no progress flash from the storage cmdlets
    $map = @{}
    try {
        if (-not ('BootSelector.Kernel32' -as [type])) {
            Add-Type -Namespace BootSelector -Name Kernel32 -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
public static extern uint QueryDosDevice(string deviceName, System.Text.StringBuilder targetPath, int maxLength);
'@
        }

        $disks = @{}
        foreach ($disk in Get-Disk) {
            $disks[[int]$disk.Number] = "$($disk.FriendlyName) (Disk $($disk.Number))"
        }

        foreach ($partition in Get-Partition) {
            $diskName = $disks[[int]$partition.DiskNumber]
            if ("$($partition.DriveLetter)" -match '^[A-Z]$') {
                $map["$($partition.DriveLetter):"] = $diskName
            }
            foreach ($path in $partition.AccessPaths) {
                if ($path -match '^\\\\\?\\(Volume\{[^}]+\})\\$') {
                    $device = [System.Text.StringBuilder]::new(260)
                    if ([BootSelector.Kernel32]::QueryDosDevice($Matches[1], $device, $device.Capacity)) {
                        $map[$device.ToString()] = $diskName
                    }
                }
            }
        }
    }
    catch {
        Write-Verbose "Cannot map volumes to disks: $($_.Exception.Message)"
    }
    $map
}

function Get-FriendlyName {
    param([string]$Description, [string]$Path, [string]$Identifier)

    foreach ($name in $FriendlyNames.Keys) {
        if ($Description -match $FriendlyNames[$name] -or $Path -match $FriendlyNames[$name]) {
            return $name
        }
    }
    if ($Description) { return $Description }
    if ($Path) { return Split-Path -Path $Path -Leaf }
    return $Identifier
}

function Format-BootEntry {
    param($Entry)

    (@($Entry.Name, $Entry.Device, $Entry.Identifier) -ne '') -join '  |  '
}

function Get-BootConfiguration {
    # Returns the firmware boot entries in boot order and the pending one-time boot target
    param([switch]$All)

    $objects = @(ConvertFrom-BcdeditOutput (Invoke-Bcdedit /enum firmware))
    $fwbootmgr = @($objects | Where-Object { $_.Id -eq '{fwbootmgr}' })
    if (-not $fwbootmgr) {
        throw 'The firmware boot manager {fwbootmgr} was not found. This script requires a UEFI system.'
    }
    $fwProps = $fwbootmgr[0].Props

    $order = @($fwProps['displayorder'] | Where-Object { $_ })
    $rank = @{}
    for ($i = 0; $i -lt $order.Count; $i++) { $rank[$order[$i]] = $i }

    $disks = Get-VolumeDiskMap
    $index = 0
    $entries = @(foreach ($obj in $objects) {
        if ($obj.Id -eq '{fwbootmgr}') { continue }

        $description = "$($obj.Props['description'])"
        $path = "$($obj.Props['path'])"
        $device = "$($obj.Props['device'])"
        if ($device -match '^partition=(.+)$' -and $disks[$Matches[1]]) { $device = $disks[$Matches[1]] }
        $isEfi = $path -match '\.efi$|\\efi\\'

        [pscustomobject]@{
            Number      = 0
            Name        = Get-FriendlyName -Description $description -Path $path -Identifier $obj.Id
            Description = $description
            Device      = $device
            Type        = if ($isEfi) { 'UEFI' } else { 'Device' }
            Identifier  = $obj.Id
            IsOS        = $description -notmatch $NoisePattern -and ($isEfi -or $description -match $KnownOsPattern)
            # Firmware boot order first, then entries missing from it in bcdedit order
            Order       = if ($rank.ContainsKey($obj.Id)) { $rank[$obj.Id] } else { $order.Count + $index }
        }
        $index++
    })
    $entries = @($entries | Sort-Object Order)

    $shown = @($entries | Where-Object { $All -or $_.IsOS })
    for ($i = 0; $i -lt $shown.Count; $i++) { $shown[$i].Number = $i + 1 }

    $pending = ''
    $pendingId = $fwProps['bootsequence'] | Where-Object { $_ } | Select-Object -First 1
    if ($pendingId) {
        $match = @($entries | Where-Object { $_.Identifier -eq $pendingId })
        $pending = if ($match) { Format-BootEntry $match[0] } else { $pendingId }
    }

    [pscustomobject]@{ Entries = $shown; Pending = $pending }
}

function Show-BootEntries {
    param([object[]]$Entries, [switch]$WithIdentifier)

    $columns = @(
        @{ Label = 'No.'; Expression = { $_.Number } }
        @{ Label = 'System'; Expression = { $_.Name } }
        'Device'
        'Type'
    )
    if ($WithIdentifier) { $columns += 'Identifier' }
    $Entries | Format-Table -Property $columns -AutoSize | Out-Host
}

function Resolve-BootEntry {
    param([object[]]$Entries, [string]$Target)

    $value = $Target.Trim()

    # Number shown in the menu
    $number = 0
    if ([int]::TryParse($value, [ref]$number)) {
        $found = @($Entries | Where-Object { $_.Number -eq $number })
        if ($found.Count -eq 1) { return $found[0] }
        throw "Invalid number: $number. Choose a number from 1 to $($Entries.Count)."
    }

    # Identifier (braces optional), then exact name/description, then partial name/description
    $id = $value.Trim('{}')
    $found = @($Entries | Where-Object { $_.Identifier.Trim('{}') -eq $id })
    if ($found.Count -eq 0) {
        $found = @($Entries | Where-Object { $_.Name -eq $value -or $_.Description -eq $value })
    }
    if ($found.Count -eq 0) {
        $pattern = [regex]::Escape($value)
        $found = @($Entries | Where-Object { $_.Name -match $pattern -or $_.Description -match $pattern })
    }

    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -eq 0) {
        throw "No boot target matches '$value'. Run with -List to see the boot targets."
    }

    $candidates = foreach ($entry in $found) { "  $($entry.Number)) $(Format-BootEntry $entry)" }
    throw "'$value' matches more than one boot target:`n$($candidates -join "`n")`nUse the number or the identifier instead."
}

function Read-BootEntry {
    param([object[]]$Entries)

    while ($true) {
        $answer = "$(Read-Host 'Select boot target (number or name, 0 = exit)')".Trim()
        if ($answer -in '0', 'q', 'exit') { return $null }
        if (-not $answer) { continue }

        try {
            return Resolve-BootEntry -Entries $Entries -Target $answer
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
    }
}

function Wait-BeforeClose {
    # The elevated window closes as soon as the script ends
    if ($Elevated) {
        Write-Host ''
        [void](Read-Host 'Press Enter to close')
    }
}

function ConvertTo-CommandLineArgument {
    # Quotes a value for a Windows command line (CommandLineToArgvW rules)
    param([string]$Value)

    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Main {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $config = Get-BootConfiguration -All:$All

    if ($Clear) {
        if (-not $config.Pending) {
            Write-Host 'No one-time boot target is set.'
        }
        elseif ($PSCmdlet.ShouldProcess($config.Pending, 'Clear one-time boot target')) {
            Invoke-Bcdedit /deletevalue '{fwbootmgr}' bootsequence | Out-Null
            Write-Host "One-time boot target cleared: $($config.Pending)"
        }
        return
    }

    $entries = $config.Entries
    if ($entries.Count -eq 0) {
        throw 'No boot targets found. Use -All to include every firmware entry.'
    }

    if ($List) {
        Show-BootEntries -Entries $entries -WithIdentifier
        if ($config.Pending) { Write-Host "Pending one-time boot: $($config.Pending)" }
        return
    }

    if ($Target) {
        $entry = Resolve-BootEntry -Entries $entries -Target $Target
    }
    else {
        Show-BootEntries -Entries $entries
        if ($config.Pending) { Write-Host "Pending one-time boot: $($config.Pending)`n" }
        $entry = Read-BootEntry -Entries $entries
        if (-not $entry) { exit 0 }
    }

    $summary = Format-BootEntry $entry
    if ($NoReboot) {
        if ($PSCmdlet.ShouldProcess($summary, 'Set one-time boot target')) {
            Invoke-Bcdedit /set '{fwbootmgr}' bootsequence $entry.Identifier | Out-Null
            Write-Host "The next restart boots into: $summary"
            Write-Host 'This applies once. Run with -Clear to cancel it.'
        }
        return
    }

    if ($PSCmdlet.ShouldProcess($summary, 'Set one-time boot target and restart')) {
        Write-Host "Restarting into: $summary"
        if ($Delay -gt 0) {
            Write-Host "Restarting in $Delay seconds. Press Ctrl+C to cancel."
            Start-Sleep -Seconds $Delay
        }

        # Set only now, so that cancelling the countdown leaves nothing behind
        Invoke-Bcdedit /set '{fwbootmgr}' bootsequence $entry.Identifier | Out-Null
        & shutdown.exe /r /t 0
        if ($LASTEXITCODE -ne 0) {
            throw "shutdown.exe failed (exit code $LASTEXITCODE). The one-time boot target is set: restart manually, or run with -Clear."
        }
        exit 0
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # Relaunch elevated with the same parameters, wait for it and pass on its exit code
    $PSBoundParameters['Elevated'] = [switch]$true
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-CommandLineArgument $PSCommandPath))
    foreach ($p in $PSBoundParameters.GetEnumerator()) {
        if ($p.Value -is [switch]) {
            if ($p.Value) { $arguments += "-$($p.Key)" }
        }
        else {
            $arguments += "-$($p.Key)", (ConvertTo-CommandLineArgument $p.Value)
        }
    }
    $shell = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })

    try {
        $process = Start-Process -FilePath $shell -ArgumentList ($arguments -join ' ') -Verb RunAs -Wait -PassThru
        exit $process.ExitCode
    }
    catch {
        Write-Host "Administrator rights are required: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

try {
    Main
    Wait-BeforeClose
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Wait-BeforeClose
    exit 1
}
