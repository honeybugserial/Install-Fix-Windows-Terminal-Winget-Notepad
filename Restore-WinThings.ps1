<#
.SYNOPSIS
    Installs Windows Terminal, winget, and Notepad, and makes sure they stay installed.

.DESCRIPTION

    1. Clears Deprovisioned / EndOfLife registry markers
    2. Removes broken or half-installed copies.
    3. Installs the latest stable winget from github.com/microsoft/winget-cli.
    4. Installs the latest stable Windows Terminal from github.com/microsoft/terminal.
    5. Adds the Notepad optional feature if it is missing.
    6. Shows the final state and offers to reboot.

    Both apps are provisioned (installed for all users) as well as installed for you.

.PARAMETER CheckOnly
    Only show the current state. Changes nothing.

.PARAMETER Yes
    Do not ask for confirmation (the reboot prompt is still asked).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Restore-Essentials.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Restore-Essentials.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$Yes,
    [switch]$NoRelaunch   # internal
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$TerminalName   = 'Microsoft.WindowsTerminal'
$WingetName     = 'Microsoft.DesktopAppInstaller'
$ProtectedNames = @($TerminalName, $WingetName)
$MarkerPattern  = '^(Microsoft\.WindowsTerminal|Microsoft\.DesktopAppInstaller)_'
$StoreKey       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
$WinhanceDir    = 'C:\ProgramData\Winhance\Scripts'
$WorkRoot       = Join-Path $env:TEMP 'Restore-Essentials'

# ---------------------------------------------------------------------------
# Relaunch elevated, in Windows PowerShell 5.1, in a classic console window
# (conhost), so installing Terminal can't close the window running this script.
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $NoRelaunch) {
    $needs = (-not (Test-IsAdmin)) -or ($PSVersionTable.PSEdition -eq 'Core') -or ($env:WT_SESSION -and -not $CheckOnly)
    if ($needs) {
        Write-Host 'Relaunching as administrator in a console window...' -ForegroundColor Cyan
        $psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argList = @("`"$psExe`"", '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
                     '-File', "`"$PSCommandPath`"", '-NoRelaunch')
        if ($CheckOnly) { $argList += '-CheckOnly' }
        if ($Yes)       { $argList += '-Yes' }
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\conhost.exe') -ArgumentList $argList -Verb RunAs
        return
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Header ($Text) { Write-Host ''; Write-Host "== $Text ==" -ForegroundColor Cyan }
function Write-Good   ($Text) { Write-Host "  [OK]  $Text" -ForegroundColor Green }
function Write-Info   ($Text) { Write-Host "  [..]  $Text" -ForegroundColor Gray }
function Write-Warn   ($Text) { Write-Host "  [!!]  $Text" -ForegroundColor Yellow }
function Write-Bad    ($Text) { Write-Host "  [XX]  $Text" -ForegroundColor Red }

function Confirm-Step ([string]$Question) {
    if ($Yes) { return $true }
    while ($true) {
        $a = Read-Host "$Question [y/n]"
        if ($a -match '^(y|yes)$') { return $true }
        if ($a -match '^(n|no)$')  { return $false }
    }
}

function Get-OsArch {
    switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
}

function Invoke-AsSystem ([string]$Command) {
    $taskName = 'RestoreEssentials-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $encoded  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ErrorActionPreference='Stop'; $Command"))
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddSeconds(60)
        do {
            Start-Sleep -Milliseconds 500
            $state  = (Get-ScheduledTask -TaskName $taskName).State
            $result = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
        } while (($state -eq 'Running' -or $result -eq 267011) -and (Get-Date) -lt $deadline)
        if ($result -ne 0) { throw "SYSTEM task finished with code $result" }
    }
    finally { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
}

function Remove-RegistryKeyHard ([string]$KeyName) {
    try { Remove-Item -LiteralPath "Registry::$KeyName" -Recurse -Force }
    catch {
        Write-Info 'Access denied as administrator; retrying as SYSTEM...'
        Invoke-AsSystem "Remove-Item -LiteralPath 'Registry::$KeyName' -Recurse -Force"
    }
    if (Test-Path -LiteralPath "Registry::$KeyName") { throw "Key still exists: $KeyName" }
}

function Get-LatestRelease ([string]$Repo) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing `
        -Headers @{ 'User-Agent' = 'Restore-Essentials'; 'Accept' = 'application/vnd.github+json' }
}

function Save-Asset ($Release, [string]$Pattern, [string]$Dir) {
    $a = $Release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $a) { throw "Release $($Release.tag_name) has no asset matching '$Pattern'." }
    $dest = Join-Path $Dir $a.name
    Write-Info "Downloading $($a.name) ($([math]::Round($a.size / 1MB, 1)) MB)..."
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        # curl.exe ships with Windows 10 1803+ and shows a live progress bar
        & $curl -L --fail --retry 3 --progress-bar -A 'Restore-Essentials' -o $dest $a.browser_download_url
        if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit code $LASTEXITCODE)." }
    } else {
        Invoke-WebRequest -Uri $a.browser_download_url -OutFile $dest -UseBasicParsing -Headers @{ 'User-Agent' = 'Restore-Essentials' }
    }
    if ((Get-Item $dest).Length -ne $a.size) { throw "Downloaded file size doesn't match ($((Get-Item $dest).Length) of $($a.size) bytes)." }
    Get-Item $dest
}

function New-WorkDir ([string]$Name) {
    $d = Join-Path $WorkRoot $Name
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $d
}

function ConvertTo-Version ([string]$Text) {
    $v = $null
    if ([version]::TryParse(($Text -replace '^v', '' -replace '-.*$', ''), [ref]$v)) { return $v }
    $null
}

# ---------------------------------------------------------------------------
# Who are we installing for?
# ---------------------------------------------------------------------------
$Arch          = Get-OsArch
$RunningAs     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$TargetSid     = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ConsoleUser   = $null
$DifferentUser = $false
try {
    $ConsoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($ConsoleUser -and $ConsoleUser -ne $RunningAs) {
        $DifferentUser = $true
        $TargetSid = (New-Object Security.Principal.NTAccount($ConsoleUser)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
} catch { }

# ---------------------------------------------------------------------------
# State checks
# ---------------------------------------------------------------------------
function Get-PackageState ([string]$Name) {
    $all = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)
    $good = $null; $broken = @()
    foreach ($p in $all) {
        $installedFor = @($p.PackageUserInformation | Where-Object { "$($_.InstallState)" -eq 'Installed' })
        if ("$($p.Status)" -ne 'Ok' -or $installedFor.Count -eq 0) { $broken += $p; continue }
        $forTarget = @($installedFor | Where-Object { $_.UserSecurityId.Sid -eq $TargetSid }).Count -gt 0
        if ($forTarget -and (-not $good -or [version]$p.Version -gt [version]$good.Version)) { $good = $p }
    }
    [pscustomobject]@{ Installed = $good; Broken = $broken }
}

function Get-WingetVersion {
    $exe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (-not (Test-Path $exe)) {
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $cmd) { return $null }
        $exe = $cmd.Source
    }
    try {
        $v = & $exe --version 2>$null | Select-Object -First 1
        if ($v) { return "$v".Trim() }
    } catch { }
    $null
}

function Test-NotepadPresent { Test-Path (Join-Path $env:SystemRoot 'System32\notepad.exe') }

function Get-RemovalMarkers {
    @(Get-ChildItem "$StoreKey\Deprovisioned", "$StoreKey\EndOfLife" -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.PSChildName -match $MarkerPattern })
}

function Test-ProtectedLine ([string]$Line) {
    foreach ($n in $ProtectedNames) {
        if ($Line -match "^\s*'$([regex]::Escape($n))'\s*,?\s*$") { return $n }
    }
    $null
}

function Get-WinhanceHits {
    if (-not (Test-Path $WinhanceDir)) { return @() }
    $hits = @()
    foreach ($f in Get-ChildItem $WinhanceDir -Filter '*.ps1' -ErrorAction SilentlyContinue) {
        $lines = [IO.File]::ReadAllLines($f.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $n = Test-ProtectedLine $lines[$i]
            if ($n) { $hits += [pscustomobject]@{ File = $f.FullName; Line = $i + 1; Name = $n } }
        }
    }
    $hits
}

function Get-WinhanceTask {
    Get-ScheduledTask -TaskPath '\Winhance\' -TaskName 'BloatRemoval' -ErrorAction SilentlyContinue
}

function Show-Status {
    $t = Get-PackageState $TerminalName
    if ($t.Installed) { Write-Good "Windows Terminal $($t.Installed.Version)" }
    else              { Write-Bad  'Windows Terminal: not installed' }
    foreach ($b in $t.Broken) { Write-Warn "Broken Terminal package: $($b.PackageFullName) ($($b.Status))" }

    $w  = Get-PackageState $WingetName
    $wv = Get-WingetVersion
    if ($w.Installed -and $wv) { Write-Good "winget $wv (App Installer $($w.Installed.Version))" }
    elseif ($w.Installed)      { Write-Warn "App Installer $($w.Installed.Version) is installed but winget did not respond (try a new window)" }
    else                       { Write-Bad  'winget: not installed' }
    foreach ($b in $w.Broken) { Write-Warn "Broken App Installer package: $($b.PackageFullName) ($($b.Status))" }

    if (Test-NotepadPresent) { Write-Good 'Notepad' } else { Write-Bad 'Notepad: missing' }

    $markers = Get-RemovalMarkers
    if ($markers.Count -eq 0) { Write-Good 'No removal markers in the registry' }
    foreach ($m in $markers) { Write-Bad "Removal marker: $($m.Name -replace '^.*AppxAllUserStore\\', '')" }

    $hits = @(Get-WinhanceHits)
    if (Test-Path $WinhanceDir) {
        if ($hits.Count -eq 0) { Write-Good "Winhance removal scripts don't target these apps" }
        foreach ($h in $hits) { Write-Bad "Winhance removes $($h.Name) at startup ($(Split-Path $h.File -Leaf) line $($h.Line))" }
        $task = Get-WinhanceTask
        if ($task) { Write-Info "Winhance BloatRemoval task: $($task.State)" }
    }
}

# ---------------------------------------------------------------------------
# Repair / install steps
# ---------------------------------------------------------------------------
function Step-Winhance {
    $hits = @(Get-WinhanceHits)
    if ($hits.Count -eq 0) { Write-Good 'Nothing to change.' }
    foreach ($file in ($hits | Select-Object -ExpandProperty File -Unique)) {
        Copy-Item $file "$file.bak" -Force
        $keep = [IO.File]::ReadAllLines($file) | Where-Object { -not (Test-ProtectedLine $_) }
        [IO.File]::WriteAllLines($file, [string[]]$keep, (New-Object Text.UTF8Encoding $false))
        $removed = ($hits | Where-Object File -eq $file | ForEach-Object Name) -join ', '
        Write-Good "Removed $removed from $(Split-Path $file -Leaf) (backup: $(Split-Path $file -Leaf).bak)"
    }

    $task = Get-WinhanceTask
    if ($task -and "$($task.State)" -eq 'Disabled') {
        Write-Info 'Winhance BloatRemoval task is disabled. It no longer targets Terminal or winget, so it is safe to turn back on.'
        if (Confirm-Step '  Re-enable it?') {
            Enable-ScheduledTask -TaskPath '\Winhance\' -TaskName 'BloatRemoval' | Out-Null
            Write-Good 'Re-enabled.'
        }
    }
}

function Step-Markers {
    $markers = Get-RemovalMarkers
    if ($markers.Count -eq 0) { Write-Good 'None found.' }
    foreach ($m in $markers) {
        Remove-RegistryKeyHard $m.Name
        Write-Good "Cleared $($m.Name -replace '^.*AppxAllUserStore\\', '')"
    }
}

function Step-Broken {
    $any = $false
    foreach ($name in $ProtectedNames) {
        foreach ($b in (Get-PackageState $name).Broken) {
            $any = $true
            Write-Info "Removing $($b.PackageFullName) ($($b.Status))..."
            Remove-AppxPackage -Package $b.PackageFullName -AllUsers
            Write-Good 'Removed.'
        }
    }
    if (-not $any) { Write-Good 'None found.' }
}

function Install-Dependencies ([System.IO.FileInfo[]]$Files) {
    foreach ($d in $Files) {
        $parts = $d.BaseName -split '_'
        $depName = $parts[0]
        $depVer  = if ($parts.Count -gt 1) { ConvertTo-Version $parts[1] } else { $null }
        if ($depVer) {
            $have = @(Get-AppxPackage -AllUsers -Name $depName -ErrorAction SilentlyContinue |
                      Where-Object { "$($_.Architecture)" -eq $Arch -and [version]$_.Version -ge $depVer })
            if ($have.Count -gt 0) { Write-Good "$depName $($have[0].Version) already present"; continue }
        }
        Write-Info "Installing dependency $($d.Name)..."
        try { Add-AppxPackage -Path $d.FullName }
        catch {
            if ($_.Exception.HResult -eq -2147009274) { Write-Good "${depName}: newer version already installed" }  # 0x80073D06
            else { throw }
        }
    }
}

function Install-Bundle ($Bundle, [System.IO.FileInfo[]]$Deps, $License) {
    $prov = @{ Online = $true; PackagePath = $Bundle.FullName }
    if ($Deps.Count -gt 0) { $prov.DependencyPackagePath = @($Deps | ForEach-Object FullName) }
    if ($License) { $prov.LicensePath = $License.FullName } else { $prov.SkipLicense = $true }
    Write-Info 'Provisioning for all users...'
    try { Add-AppxProvisionedPackage @prov | Out-Null; Write-Good 'Provisioned.' }
    catch { Write-Warn "Provisioning failed ($($_.Exception.Message)); continuing with a normal install." }

    if ($DifferentUser) {
        Write-Info "Provisioned only: $ConsoleUser gets it at next sign-in."
    } else {
        Write-Info "Installing for $RunningAs..."
        Add-AppxPackage -Path $Bundle.FullName -ForceApplicationShutdown
        Write-Good 'Installed.'
    }
}

function Step-Winget {
    $rel = Get-LatestRelease 'microsoft/winget-cli'
    $latest = ConvertTo-Version $rel.tag_name
    $current = Get-WingetVersion
    Write-Info "Latest stable: $($rel.tag_name)"
    if ($current -and $latest -and (ConvertTo-Version $current) -ge $latest) {
        Write-Good "winget $current is already current."
        return
    }

    $dir     = New-WorkDir 'winget'
    $bundle  = Save-Asset $rel '\.msixbundle$' $dir
    $license = Save-Asset $rel '_License1\.xml$' $dir
    $depsZip = Save-Asset $rel '^DesktopAppInstaller_Dependencies\.zip$' $dir
    Expand-Archive -Path $depsZip.FullName -DestinationPath (Join-Path $dir 'deps') -Force
    $deps = @(Get-ChildItem (Join-Path $dir 'deps') -Recurse -Include '*.appx', '*.msix' |
              Where-Object { $_.FullName -match "\\$Arch\\" -or $_.Name -match "_$($Arch)(_|\.)" })

    Install-Dependencies $deps
    Install-Bundle $bundle $deps $license
}

function Step-Terminal {
    $rel = Get-LatestRelease 'microsoft/terminal'
    $latest = ConvertTo-Version $rel.tag_name
    $current = (Get-PackageState $TerminalName).Installed
    Write-Info "Latest stable: $($rel.tag_name)"
    if ($current -and $latest -and [version]$current.Version -ge $latest) {
        Write-Good "Terminal $($current.Version) is already current."
        return
    }

    $dir = New-WorkDir 'terminal'
    $zip = Save-Asset $rel 'PreinstallKit\.zip$' $dir
    $kit = Join-Path $dir 'kit'
    Write-Info 'Extracting...'
    Expand-Archive -Path $zip.FullName -DestinationPath $kit -Force

    $bundle  = Get-ChildItem $kit -Recurse -Filter '*.msixbundle' | Select-Object -First 1
    $license = Get-ChildItem $kit -Recurse -Filter '*License*.xml' | Select-Object -First 1
    $deps    = @(Get-ChildItem $kit -Recurse -Include '*.appx', '*.msix' | Where-Object { $_.Name -match "_$($Arch)__" })
    if (-not $bundle) { throw 'No .msixbundle in the PreinstallKit.' }

    Install-Dependencies $deps
    Install-Bundle $bundle $deps $license
}

function Step-Notepad {
    if (Test-NotepadPresent) { Write-Good 'Notepad is present.'; return }
    $caps = @(Get-WindowsCapability -Online | Where-Object { $_.Name -like 'Microsoft.Windows.Notepad*' -and "$($_.State)" -ne 'Installed' })
    if ($caps.Count -eq 0) { Write-Warn 'Notepad is missing but no Notepad optional feature was found to add.'; return }
    foreach ($c in $caps) {
        Write-Info "Adding $($c.Name) from Windows Update (can take a few minutes)..."
        try { Add-WindowsCapability -Online -Name $c.Name | Out-Null; Write-Good 'Added.' }
        catch {
            Write-Bad "Failed: $($_.Exception.Message)"
            Write-Info 'If this mentions 0x800f0954 or similar, Windows Update is likely blocked or disabled on this machine.'
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Restore Windows Terminal, winget and Notepad' -ForegroundColor White
Write-Info "Running as $RunningAs ($Arch)"
if ($DifferentUser) { Write-Warn "Signed-in user is $ConsoleUser; apps will be provisioned and appear for them at next sign-in." }

Write-Header 'Current state'
Show-Status

if ($CheckOnly) { return }

Write-Host ''
Write-Host 'This will: take Terminal and winget off Winhance''s removal list, clear removal markers,' -ForegroundColor White
Write-Host 'remove broken copies, install the latest winget and Terminal from GitHub, and add Notepad if missing.' -ForegroundColor White
if (-not (Confirm-Step 'Proceed?')) { Write-Info 'Nothing changed.'; return }

New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$failed = @()
$steps = [ordered]@{
    'Winhance removal list' = { Step-Winhance }
    'Removal markers'       = { Step-Markers }
    'Broken packages'       = { Step-Broken }
    'winget'                = { Step-Winget }
    'Windows Terminal'      = { Step-Terminal }
    'Notepad'               = { Step-Notepad }
}
foreach ($name in $steps.Keys) {
    Write-Header $name
    try { & $steps[$name] }
    catch { Write-Bad "Failed: $($_.Exception.Message)"; $failed += $name }
}

Remove-Item $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Header 'Final state'
Show-Status

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Warn "Steps with errors: $($failed -join ', '). Run the script again, or send the output above."
}
Write-Host 'Tip: in Winhance, don''t re-apply app removals with Terminal or App Installer selected.' -ForegroundColor DarkGray
Write-Host 'After rebooting, run this again with -CheckOnly to confirm everything stuck.' -ForegroundColor Cyan

$answer = Read-Host 'Reboot now? [y/n]'
if ($answer -match '^(y|yes)$') {
    Write-Host 'Rebooting in 5 seconds... (Ctrl+C to cancel)' -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}
