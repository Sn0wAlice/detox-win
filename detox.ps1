<#
detox-win - hardcore Windows cleanup, last stop before a reset.
PowerShell 5.1+ (built into Windows 10/11). Nothing to install.

  powershell -ExecutionPolicy Bypass -File .\detox.ps1 <command> [targets] [-Yes] [-DryRun] [-Hard]

Commands
  scan                 sizes of every clean target (default)
  doctor               who crashes: app crashes, BSODs, disk health, Firefox crash reports
  clean [targets|all]  wipe targets, asks per target unless -Yes; -DryRun shows only
  ram                  RAM by application (processes grouped by product)
  startup              list autostart (Run keys, startup folders, non-MS tasks/services)
  startup off|on <name>  disable/enable a Run-key entry (same switch as Task Manager)
  debloat              remove preinstalled junk Appx packages (asks first)
  registry             broken refs: dead uninstall/run/app-path/service/shell-ext/task entries + hijacks
  registry fix         same, then removes them after a .reg backup per entry (admin)
  repair               DISM RestoreHealth + SFC + chkdsk scan (admin, slow)
  nuke                 clean all -Hard, registry fix, then repair
#>
param(
    [Parameter(Position = 0)][string]$Command = 'scan',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Args2,
    [switch]$Yes, [switch]$DryRun, [switch]$Hard
)
$ErrorActionPreference = 'Continue'
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$L = $env:LOCALAPPDATA; $R = $env:APPDATA; $W = $env:windir; $PD = $env:ProgramData

function Fmt([double]$b) {
    if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) }
}
function Ask($q) {
    if ($Yes) { return $true }
    (Read-Host "$q [y/N]") -match '^(y|o)'
}
function FreeC { (Get-PSDrive C).Free }

# Size of a set of paths. Returns @{Bytes; Unknown}: unreadable trees are flagged, never counted as 0.
function Measure-Paths($paths) {
    $bytes = 0; $unknown = $false
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $err = $null
        $s = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue -ErrorVariable err | Measure-Object Length -Sum).Sum
        if ($s) { $bytes += $s }
        if ($err) { $unknown = $true }
    }
    @{ Bytes = $bytes; Unknown = $unknown }
}

# Directories get emptied (kept), files get deleted. Locked files are skipped and counted.
function Remove-Paths($paths) {
    $locked = 0
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $err = $null
        if ((Get-Item -LiteralPath $p -Force).PSIsContainer) {
            Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +err
        } else {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue -ErrorVariable +err
        }
        $locked += @($err).Count
    }
    $locked
}

function Profiles($root) { if (Test-Path $root) { Get-ChildItem $root -Directory -Force | ForEach-Object FullName } }

function Chromium($ud) {
    if (-not (Test-Path $ud)) { return }
    foreach ($d in 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache', 'Crashpad\reports') { Join-Path $ud $d }
    Get-ChildItem $ud -Directory -Force | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
        foreach ($d in 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache') { Join-Path $_.FullName $d }
    }
}

# ---- Targets ---------------------------------------------------------------
# Paths: scriptblock returning paths. Procs: must be closed first. Admin: needs elevation.
# Pre/Post: run around the delete. Cmd: a tool-native cleanup instead of (or after) deleting.
$Targets = [ordered]@{
    temp       = @{ Desc = 'User + Windows temp'; Paths = { $env:TEMP; "$W\Temp" } }
    firefox    = @{ Desc = 'Firefox caches, startup cache, crash dumps, stale addon/compat state'; Procs = 'firefox'
        Paths = {
            foreach ($p in Profiles "$L\Mozilla\Firefox\Profiles") { "$p\cache2"; "$p\startupCache"; "$p\thumbnails"; "$p\jumpListCache"; "$p\shader-cache" }
            foreach ($p in Profiles "$R\Mozilla\Firefox\Profiles") {
                "$p\compatibility.ini"; "$p\addonStartup.json.lz4"; "$p\startupCache"; "$p\minidumps"; "$p\crashes"
                "$p\saved-telemetry-pings"; "$p\datareporting\archived"
                if ($Hard) { "$p\extensions.json" }   # rebuilt on next start; fixes broken-addon crashes
            }
            "$R\Mozilla\Firefox\Crash Reports\pending"; "$R\Mozilla\Firefox\Crash Reports\submitted"
        } }
    chrome     = @{ Desc = 'Chrome caches'; Procs = 'chrome'; Paths = { Chromium "$L\Google\Chrome\User Data" } }
    edge       = @{ Desc = 'Edge caches'; Procs = 'msedge'; Paths = { Chromium "$L\Microsoft\Edge\User Data" } }
    brave      = @{ Desc = 'Brave caches'; Procs = 'brave'; Paths = { Chromium "$L\BraveSoftware\Brave-Browser\User Data" } }
    apps       = @{ Desc = 'Electron app caches (Discord, Teams, Slack, VS Code, Spotify)'; Procs = 'Discord', 'ms-teams', 'Teams', 'slack', 'Code', 'Spotify'
        Paths = {
            foreach ($a in "$R\discord", "$R\Slack", "$R\Code", "$L\Microsoft\Teams", "$R\Microsoft\Teams") {
                foreach ($d in 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'Service Worker\CacheStorage', 'CachedData', 'logs') { "$a\$d" }
            }
            "$L\Spotify\Data"; "$L\Spotify\Browser\Cache"
        } }
    shaders    = @{ Desc = 'GPU shader caches (DirectX, NVIDIA, AMD, Intel)'
        Paths = { "$L\D3DSCache"; "$L\NVIDIA\DXCache"; "$L\NVIDIA\GLCache"; "$L\NVIDIA Corporation\NV_Cache"; "$L\AMD\DxCache"; "$L\AMD\DxcCache"; "$L\AMD\VkCache"; "$L\AMD\GLCache"; "$L\Intel\ShaderCache"; "$PD\NVIDIA Corporation\NV_Cache" } }
    crashdumps = @{ Desc = 'Crash dumps + Windows Error Reporting'; Admin = $true
        Paths = { "$L\CrashDumps"; "$W\Minidump"; "$W\MEMORY.DMP"; "$PD\Microsoft\Windows\WER\ReportArchive"; "$PD\Microsoft\Windows\WER\ReportQueue"; "$PD\Microsoft\Windows\WER\Temp"; "$L\Microsoft\Windows\WER" } }
    logs       = @{ Desc = 'Windows logs (CBS, DISM, setup, panther)'; Admin = $true
        Paths = { "$W\Logs\CBS"; "$W\Logs\DISM"; "$W\Logs\MoSetup"; "$W\Panther"; "$W\inf\setupapi.dev.log"; "$W\Logs\WindowsUpdate"; "$W\SoftwareDistribution\DataStore\Logs" } }
    update     = @{ Desc = 'Windows Update downloads + Delivery Optimization'; Admin = $true
        Paths = { "$W\SoftwareDistribution\Download"; "$W\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" }
        Pre = { Stop-Service wuauserv, bits, dosvc -Force -ErrorAction SilentlyContinue }
        Post = { Start-Service wuauserv, bits, dosvc -ErrorAction SilentlyContinue } }
    thumbs     = @{ Desc = 'Explorer thumbnail + icon cache (Explorer restarts)'; Procs = 'explorer'
        Paths = { Get-ChildItem "$L\Microsoft\Windows\Explorer" -Filter '*cache_*.db' -Force -ErrorAction SilentlyContinue | ForEach-Object FullName }
        Post = { Start-Process explorer } }
    dev        = @{ Desc = 'Package manager caches (npm, yarn, pnpm, pip, nuget, gradle)'
        Paths = { "$L\npm-cache"; "$L\Yarn\Cache"; "$L\pnpm\store"; "$L\pip\Cache"; "$env:USERPROFILE\.nuget\packages"; "$L\NuGet\v3-cache"; "$env:USERPROFILE\.gradle\caches" }
        Cmd = {
            # native commands first: they know their own layout and lock state
            if (Get-Command npm -ErrorAction SilentlyContinue) { npm cache clean --force 2>$null }
            if (Get-Command pip -ErrorAction SilentlyContinue) { pip cache purge 2>$null }
            if (Get-Command dotnet -ErrorAction SilentlyContinue) { dotnet nuget locals all --clear 2>$null }
        } }
    recycle    = @{ Desc = 'Recycle Bin (all drives)'; Cmd = { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        Paths = { Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root '$Recycle.Bin' } }; NoDelete = $true; Admin = $true }
    winsxs     = @{ Desc = 'Component store cleanup (DISM; -Hard adds /ResetBase = no update uninstall)'; Admin = $true; Paths = { }
        Cmd = { if ($Hard) { Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase } else { Dism.exe /Online /Cleanup-Image /StartComponentCleanup } } }
    network    = @{ Desc = 'DNS flush, Winsock + TCP/IP reset (-Hard only, needs reboot)'; Admin = $true; Paths = { }
        Cmd = { ipconfig /flushdns | Out-Null; if ($Hard) { netsh winsock reset; netsh int ip reset } } }
}

function Do-Scan {
    "{0,-11} {1,12}  {2}" -f 'target', 'size', 'what'
    $total = 0
    foreach ($k in $Targets.Keys) {
        $t = $Targets[$k]
        $m = Measure-Paths (& $t.Paths)
        $total += $m.Bytes
        $sz = if ($m.Bytes -or -not $t.Cmd) { Fmt $m.Bytes } else { 'cmd' }
        if ($m.Unknown) { $sz += '+?' }
        $flag = if ($t.Admin -and -not $IsAdmin) { ' (admin)' } else { '' }
        "{0,-11} {1,12}  {2}{3}" -f $k, $sz, $t.Desc, $flag
    }
    ''
    "total ~{0}   C: free {1}" -f (Fmt $total), (Fmt (FreeC))
    if (-not $IsAdmin) { "'+?' = unreadable without admin, real size is larger. Run from an admin terminal." }
}

function Do-Clean($names) {
    if (-not $names -or $names -contains 'all') { $names = @($Targets.Keys) }
    $bad = $names | Where-Object { -not $Targets.Contains($_) }
    if ($bad) { "unknown target(s): $($bad -join ', ')   known: $($Targets.Keys -join ' ')"; return }
    $before = FreeC
    foreach ($k in $names) {
        $t = $Targets[$k]
        if ($t.Admin -and -not $IsAdmin) { "[$k] skipped: needs admin"; continue }
        $paths = @(& $t.Paths)
        $m = Measure-Paths $paths
        $sz = (Fmt $m.Bytes) + $(if ($m.Unknown) { '+?' } else { '' })
        if ($DryRun) {
            "[$k] would free $sz"
            $paths | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { "    $_" }
            continue
        }
        if (-not $m.Bytes -and -not $m.Unknown -and -not $t.Cmd) { "[$k] nothing to clean"; continue }
        if (-not (Ask "[$k] $($t.Desc) - $sz. Clean?")) { continue }
        if ($t.Procs) {
            $run = Get-Process -Name $t.Procs -ErrorAction SilentlyContinue
            if ($run) {
                $names2 = ($run | Select-Object -Expand Name -Unique) -join ', '
                if (-not (Ask "    $names2 running, kill it?")) { "    skipped"; continue }
                $run | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
        if ($t.Pre) { & $t.Pre }
        $locked = 0
        if ($t.Cmd) { & $t.Cmd }
        if (-not $t.NoDelete) { $locked = Remove-Paths $paths }
        if ($t.Post) { & $t.Post }
        $after = Measure-Paths $paths
        "    done, {0} left{1}" -f (Fmt $after.Bytes), $(if ($locked) { " ($locked locked, in use)" } else { '' })
    }
    if (-not $DryRun) { ''; "C: free: {0} -> {1}  (+{2})" -f (Fmt $before), (Fmt (FreeC)), (Fmt ([math]::Max(0, (FreeC) - $before))) }
}

function Do-Doctor {
    $since = (Get-Date).AddDays(-14)
    '== App crashes, last 14 days (Application log, event 1000/1002)'
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = $since } -ErrorAction SilentlyContinue
    if ($ev) {
        $ev | ForEach-Object { [pscustomobject]@{ App = $_.Properties[0].Value; Module = if ($_.Id -eq 1000) { $_.Properties[3].Value } else { 'HANG' }; Time = $_.TimeCreated } } |
            Group-Object App, Module | Sort-Object Count -Descending | Select-Object -First 15 |
            ForEach-Object { "{0,4}x  {1}   last {2:yyyy-MM-dd HH:mm}" -f $_.Count, $_.Name, ($_.Group | Sort-Object Time -Descending)[0].Time }
        '    module = DLL that faulted. Same GPU driver DLL (nvwgf2umx, atidxx64, igd*) across apps = driver; ntdll/ucrtbase everywhere = RAM or system files.'
    } else { '    none recorded' }
    ''
    '== Unexpected shutdowns / BSOD (System log 41, 1001, 6008)'
    $sys = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1001, 6008; StartTime = $since } -ErrorAction SilentlyContinue
    if ($sys) { $sys | Select-Object -First 10 | ForEach-Object { "    {0:yyyy-MM-dd HH:mm}  id {1}  {2}" -f $_.TimeCreated, $_.Id, ($_.Message -split "`n")[0] } } else { '    none' }
    ''
    '== WHEA hardware errors (CPU/RAM/PCIe)'
    $wh = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -ErrorAction SilentlyContinue
    if ($wh) { "    {0} event(s) - hardware is reporting errors; test RAM (mdsched) before blaming software" -f @($wh).Count } else { '    none' }
    ''
    '== Disks'
    Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object { "    {0}  {1}  health={2}  status={3}" -f $_.FriendlyName, (Fmt $_.Size), $_.HealthStatus, $_.OperationalStatus }
    Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { "    {0}: {1} free of {2}" -f $_.DriveLetter, (Fmt $_.SizeRemaining), (Fmt $_.Size) }
    ''
    '== Firefox'
    $cr = "$R\Mozilla\Firefox\Crash Reports"
    if (Test-Path $cr) {
        $dumps = Get-ChildItem "$cr\pending", "$cr\submitted" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        "    {0} crash report(s), last {1}" -f @($dumps).Count, $(if ($dumps) { $dumps[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { '-' })
        '    submitted IDs are readable at about:crashes in Firefox (gives the crash signature)'
    } else { '    no Firefox crash dir' }
    foreach ($p in Profiles "$R\Mozilla\Firefox\Profiles") {
        $ext = @(Get-ChildItem "$p\extensions" -File -ErrorAction SilentlyContinue).Count
        "    profile {0}: {1} extension(s)" -f (Split-Path $p -Leaf), $ext
    }
    ''
    '== Devices with driver problems'
    $bad = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -notin 'OK', 'Unknown' }
    if ($bad) { $bad | ForEach-Object { "    [{0}] {1}  ({2})" -f $_.Status, $_.FriendlyName, $_.Class } } else { '    none' }
    ''
    '== GPU driver'
    Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { "    {0}  v{1}  {2:yyyy-MM-dd}" -f $_.Name, $_.DriverVersion, $_.DriverDate }
    '    driver older than ~6 months + GPU DLL in the crash list above = update it (clean install)'
    ''
    '== Broken registry / hijacks'
    '    run: detox registry'
    ''
    '== Pending reboot'
    $pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    "    $pend"
}

function Do-Ram {
    $os = Get-CimInstance Win32_OperatingSystem
    "RAM used {0} of {1}" -f (Fmt (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1KB)), (Fmt ($os.TotalVisibleMemorySize * 1KB))
    ''
    # ponytail: groups by FileVersionInfo.Product; protected system processes have none and fall back to process name
    Get-Process | ForEach-Object {
        $prod = $null; try { $prod = $_.MainModule.FileVersionInfo.ProductName } catch {}
        if (-not $prod) { $prod = $_.Name }
        [pscustomobject]@{ App = $prod; WS = $_.WorkingSet64 }
    } | Group-Object App | ForEach-Object { [pscustomobject]@{ App = $_.Name; N = $_.Count; WS = ($_.Group | Measure-Object WS -Sum).Sum } } |
        Sort-Object WS -Descending | Select-Object -First 25 |
        ForEach-Object { "{0,10}  {1,-45} {2,3} proc" -f (Fmt $_.WS), $_.App, $_.N }
}

$RunKeys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
function Approved($key) { ($key -replace '\\Software\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Run', '\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run') + $(if ($key -match 'WOW6432') { '32' } else { '' }) }

function Do-Startup($verb, $name) {
    if ($verb -in 'off', 'on') {
        foreach ($k in $RunKeys) {
            if ((Get-ItemProperty $k -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains $name) {
                $ak = Approved $k
                if (-not (Test-Path $ak)) { New-Item $ak -Force | Out-Null }
                # first byte 02 = enabled, 03 = disabled (what Task Manager writes)
                $val = [byte[]](@($(if ($verb -eq 'off') { 3 } else { 2 })) + @(0) * 11)
                Set-ItemProperty $ak -Name $name -Value $val -Type Binary
                "$name -> $verb ($k)"; return
            }
        }
        "no Run entry named '$name'"; return
    }
    '== Run keys'
    foreach ($k in $RunKeys) {
        $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $appr = Get-ItemProperty (Approved $k) -ErrorAction SilentlyContinue
        $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
            $st = 'on'; if ($appr -and $appr.($_.Name) -and ($appr.($_.Name)[0] -band 1)) { $st = 'off' }
            "    [{0,-3}] {1,-30} {2}" -f $st, $_.Name, $_.Value
        }
    }
    '== Startup folders'
    "$R\Microsoft\Windows\Start Menu\Programs\Startup", "$PD\Microsoft\Windows\Start Menu\Programs\Startup" |
        ForEach-Object { Get-ChildItem $_ -File -ErrorAction SilentlyContinue } | Where-Object Name -ne 'desktop.ini' | ForEach-Object { "    $($_.FullName)" }
    '== Scheduled tasks (enabled, not Microsoft)'
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } |
        ForEach-Object { "    {0}{1}   {2}" -f $_.TaskPath, $_.TaskName, ($_.Actions | Select-Object -First 1).Execute }
    '== Auto-start services (not under Windows dir)'
    Get-CimInstance Win32_Service -Filter "StartMode='Auto'" | Where-Object { $_.PathName -and $_.PathName -notmatch '(?i)\\Windows\\' } |
        ForEach-Object { "    [{0,-7}] {1,-35} {2}" -f $_.State, $_.Name, $_.PathName }
    ''
    'Disable a Run entry:  detox startup off <name>.  Tasks: Disable-ScheduledTask.  Services: Set-Service <name> -StartupType Manual'
}

$Bloat = 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.People', 'Microsoft.WindowsFeedbackHub', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.549981C3F5F10', 'Clipchamp.Clipchamp', 'Microsoft.PowerAutomateDesktop',
    'Microsoft.WindowsMaps', 'Microsoft.MixedReality.Portal', 'Microsoft.SkypeApp', 'Microsoft.Microsoft3DViewer', 'Microsoft.ZuneVideo', 'MicrosoftCorporationII.MicrosoftFamily',
    'Microsoft.Copilot', 'Microsoft.Windows.DevHome', 'king.com.*', '*Disney*', '*CandyCrush*', '*TikTok*', '*Instagram*', '*Facebook*', 'AmazonVideo.PrimeVideo', '*LinkedIn*'
function Do-Debloat {
    $found = $Bloat | ForEach-Object { Get-AppxPackage -Name $_ -ErrorAction SilentlyContinue } | Sort-Object Name -Unique
    if (-not $found) { 'no known bloat installed'; return }
    $found | ForEach-Object { "    $($_.Name)" }
    if ($DryRun) { return }
    if (-not (Ask "Remove these $(@($found).Count) package(s) for this user?")) { return }
    $found | ForEach-Object { Remove-AppxPackage $_ -ErrorAction SilentlyContinue; if ($?) { "    removed $($_.Name)" } else { "    failed  $($_.Name)" } }
    if ($IsAdmin -and (Ask 'Also deprovision them (not reinstalled for new users / after feature updates)?')) {
        $names = $found.Name
        Get-AppxProvisionedPackage -Online | Where-Object { $names -contains $_.DisplayName } | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
        '    deprovisioned'
    }
}

function Do-Repair {
    if (-not $IsAdmin) { 'repair needs an admin terminal'; return }
    if ($DryRun) { 'would run: DISM RestoreHealth, sfc /scannow, chkdsk C: /scan'; return }
    if (-not (Ask 'Run DISM RestoreHealth + SFC + chkdsk scan (15-45 min)?')) { return }
    Dism.exe /Online /Cleanup-Image /RestoreHealth
    sfc.exe /scannow
    chkdsk.exe C: /scan
    ''
    'Then: reboot. Still crashing -> mdsched.exe (RAM test) and clean-install GPU drivers (DDU).'
}

# ---- Broken registry / dangling references --------------------------------
# Rule: a finding needs a concrete absolute path, on a mounted drive, that does not exist.
# Anything we can't pin down (host exes, relative paths, WindowsApps, unmounted drives) is unknown: never flagged.
$HostExe = 'rundll32.exe', 'msiexec.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe', 'wscript.exe', 'cscript.exe', 'explorer.exe', 'svchost.exe', 'conhost.exe', 'regsvr32.exe', 'mshta.exe'
function Get-TargetPath([string]$cmd) {
    if (-not $cmd) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
    $c = $c -replace '^\\\?\?\\', '' -replace '^(?i)\\SystemRoot\\', "$W\" -replace '^(?i)system32\\', "$W\System32\"
    if ($c -match '^"([^"]+)"') { $p = $Matches[1] }
    elseif ($c -match '^(.+?\.(exe|dll|sys|com|cpl|ocx|scr|bat|cmd))(\s|,|$)') { $p = $Matches[1] }
    else { $p = $c }
    if ($p -notmatch '^[A-Za-z]:\\') { return $null }
    if ($HostExe -contains (Split-Path $p -Leaf).ToLower()) { return $null }
    if ($p -match '(?i)\\WindowsApps\\') { return $null }
    if (-not (Test-Path -LiteralPath $p.Substring(0, 3))) { return $null }
    $p
}
function Missing($cmd) {
    $p = Get-TargetPath ([string]$cmd)
    if (-not $p -or (Test-Path -LiteralPath $p)) { return }
    $alt = $p -ireplace '\\System32\\', '\SysWOW64\'   # 32-bit entries name System32 but live in SysWOW64
    if ($alt -ne $p -and (Test-Path -LiteralPath $alt)) { return }
    $p
}
function Props($k) { $i = Get-ItemProperty "Registry::$k" -ErrorAction SilentlyContinue; if ($i) { $i.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } } }
function Find($area, $key, $value, $detail, $fix) { [pscustomobject]@{ Area = $area; Key = $key; Value = $value; Detail = $detail; Fix = $fix } }
$DelValue = { param($f) Remove-ItemProperty "Registry::$($f.Key)" -Name $f.Value -Force }
$DelKey = { param($f) Remove-Item -LiteralPath "Registry::$($f.Key)" -Recurse -Force }
$HKLMSW = 'HKEY_LOCAL_MACHINE\SOFTWARE'; $HKCUSW = 'HKEY_CURRENT_USER\Software'; $CV = 'Microsoft\Windows\CurrentVersion'

function Scan-Registry {
    # Uninstall entries whose uninstaller AND install folder are gone (MSI entries skipped: msiexec is a host exe)
    foreach ($r in "$HKLMSW\$CV\Uninstall", "$HKLMSW\WOW6432Node\$CV\Uninstall", "$HKCUSW\$CV\Uninstall") {
        Get-ChildItem "Registry::$r" -ErrorAction SilentlyContinue | ForEach-Object {
            $m = Missing $_.GetValue('UninstallString')
            $loc = $_.GetValue('InstallLocation')
            if ($m -and -not ($loc -and (Test-Path -LiteralPath $loc))) { Find 'uninstall' $_.Name $null "$($_.GetValue('DisplayName')) -> $m" $DelKey }
        }
    }
    foreach ($k in "$HKCUSW\$CV\Run", "$HKCUSW\$CV\RunOnce", "$HKLMSW\$CV\Run", "$HKLMSW\$CV\RunOnce", "$HKLMSW\WOW6432Node\$CV\Run", "$HKLMSW\WOW6432Node\$CV\RunOnce") {
        Props $k | ForEach-Object { $m = Missing $_.Value; if ($m) { Find 'run' $k $_.Name "$($_.Name) -> $m" $DelValue } }
    }
    foreach ($r in "$HKLMSW\$CV\App Paths", "$HKLMSW\WOW6432Node\$CV\App Paths", "$HKCUSW\$CV\App Paths") {
        Get-ChildItem "Registry::$r" -ErrorAction SilentlyContinue | ForEach-Object {
            $m = Missing ('"' + $_.GetValue('') + '"'); if ($m) { Find 'app-path' $_.Name $null "$($_.PSChildName) -> $m" $DelKey }
        }
    }
    foreach ($k in "$HKLMSW\$CV\SharedDLLs", "$HKLMSW\WOW6432Node\$CV\SharedDLLs") {
        Props $k | ForEach-Object { $m = Missing ('"' + $_.Name + '"'); if ($m) { Find 'shared-dll' $k $_.Name $m $DelValue } }
    }
    # Services pointing at a deleted binary. Outside Windows dir = leftover of an uninstalled app -> sc delete.
    # Inside Windows dir = damaged system -> report only, repair fixes that.
    Get-ChildItem 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object {
        $m = Missing $_.GetValue('ImagePath')
        if ($m) {
            if ($m -like "$W\*") { Find 'service' $_.Name $_.PSChildName "$($_.PSChildName) -> $m  (system file missing: run 'repair')" $null }
            else { Find 'service' $_.Name $_.PSChildName "$($_.PSChildName) -> $m" { param($f) sc.exe delete $f.Value | Out-Null; if ($LASTEXITCODE) { throw "sc delete exit $LASTEXITCODE" } } }
        }
    }
    # Context-menu handlers whose DLL is gone: classic cause of Explorer / file-dialog crashes (Firefox save dialog included)
    foreach ($base in '*', 'Directory', 'Directory\Background', 'Folder', 'Drive', 'AllFilesystemObjects') {
        Get-ChildItem -LiteralPath "Registry::HKEY_CLASSES_ROOT\$base\shellex\ContextMenuHandlers" -ErrorAction SilentlyContinue | ForEach-Object {
            $clsid = if ($_.PSChildName -match '^\{') { $_.PSChildName } else { $_.GetValue('') }
            if ($clsid -notmatch '^\{[0-9A-Fa-f-]+\}$') { return }
            $srv = Get-Item -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\InprocServer32" -ErrorAction SilentlyContinue
            if (-not $srv) { return }
            $m = Missing ('"' + $srv.GetValue('') + '"'); if ($m) { Find 'shell-ext' $_.Name $null "$base\$($_.PSChildName) -> $m" $DelKey }
        }
    }
    Get-ChildItem "Registry::$HKCUSW\Classes\Applications" -ErrorAction SilentlyContinue | ForEach-Object {
        $c = Get-Item -LiteralPath "Registry::$($_.Name)\shell\open\command" -ErrorAction SilentlyContinue
        if ($c) { $m = Missing $c.GetValue(''); if ($m) { Find 'open-with' $_.Name $null "$($_.PSChildName) -> $m" $DelKey } }
    }
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
        $a = $_.Actions | Select-Object -First 1
        if ($a.Execute) { $m = Missing ('"' + $a.Execute.Trim('"') + '"'); if ($m) { Find 'task' "$($_.TaskPath)$($_.TaskName)" $null "$($_.TaskName) -> $m" { param($f) $tp, $tn = TaskParts $f.Key; Unregister-ScheduledTask -TaskPath $tp -TaskName $tn -Confirm:$false } } }
    }
    $sh = New-Object -ComObject WScript.Shell
    "$R\Microsoft\Windows\Start Menu\Programs\Startup", "$PD\Microsoft\Windows\Start Menu\Programs\Startup" | ForEach-Object { Get-ChildItem $_ -Filter *.lnk -ErrorAction SilentlyContinue } | ForEach-Object {
        $m = Missing ('"' + $sh.CreateShortcut($_.FullName).TargetPath + '"'); if ($m) { Find 'startup-lnk' $_.FullName $null "$($_.Name) -> $m" { param($f) Remove-Item -LiteralPath $f.Key -Force } }
    }

    # ---- hijacks: things adware/malware set that make browsers crash or misbehave
    foreach ($k in "$HKLMSW\Microsoft\Windows NT\CurrentVersion\Windows", "$HKLMSW\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Windows") {
        $i = Get-Item "Registry::$k" -ErrorAction SilentlyContinue
        if ($i -and $i.GetValue('AppInit_DLLs') -and $i.GetValue('LoadAppInit_DLLs') -eq 1) {
            Find 'hijack' $k 'LoadAppInit_DLLs' "AppInit_DLLs injected into every GUI process: $($i.GetValue('AppInit_DLLs'))" { param($f) Set-ItemProperty "Registry::$($f.Key)" -Name LoadAppInit_DLLs -Value 0 }
        }
    }
    Get-ChildItem "Registry::$HKLMSW\Microsoft\Windows NT\CurrentVersion\Image File Execution Options" -ErrorAction SilentlyContinue | ForEach-Object {
        $d = $_.GetValue('Debugger'); if ($d) { Find 'hijack' $_.Name 'Debugger' "$($_.PSChildName) is redirected to: $d" $DelValue }
    }
    $wl = Get-Item "Registry::$HKLMSW\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction SilentlyContinue
    if ($wl) {
        $s = $wl.GetValue('Shell'); if ($s -and $s -ine 'explorer.exe') { Find 'hijack' $wl.Name 'Shell' "Winlogon Shell = $s (expected explorer.exe)" $null }
        $u = $wl.GetValue('Userinit'); if ($u -and $u.TrimEnd(',', ' ') -ine "$W\system32\userinit.exe") { Find 'hijack' $wl.Name 'Userinit' "Winlogon Userinit = $u" $null }
    }
    foreach ($k in "$HKLMSW\Policies\Mozilla\Firefox", "$HKCUSW\Policies\Mozilla\Firefox", "$HKLMSW\Policies\Google\Chrome", "$HKCUSW\Policies\Google\Chrome") {
        if (Test-Path "Registry::$k") { Find 'policy' $k $null "$k exists (forced extensions/homepage/search; legit only if a work IT manages this PC)" $DelKey }
    }
    foreach ($pj in "$env:ProgramFiles\Mozilla Firefox\distribution\policies.json", "${env:ProgramFiles(x86)}\Mozilla Firefox\distribution\policies.json") {
        if (Test-Path -LiteralPath $pj) { Find 'policy' $pj $null "Firefox policies.json present: $pj" { param($f) Remove-Item -LiteralPath $f.Key -Force } }
    }
    $is = Get-Item "Registry::$HKCUSW\$CV\Internet Settings" -ErrorAction SilentlyContinue
    if ($is -and $is.GetValue('ProxyEnable') -eq 1) { Find 'proxy' $is.Name 'ProxyEnable' "system proxy ON: $($is.GetValue('ProxyServer'))" { param($f) Set-ItemProperty "Registry::$($f.Key)" -Name ProxyEnable -Value 0 } }
    if ($is -and $is.GetValue('AutoConfigURL')) { Find 'proxy' $is.Name 'AutoConfigURL' "proxy PAC script: $($is.GetValue('AutoConfigURL'))" $DelValue }
    $h = Get-Content "$W\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*[^#\s]' }
    if ($h) { Find 'hosts' "$W\System32\drivers\etc\hosts" $null "$(@($h).Count) active hosts line(s): $((@($h) | Select-Object -First 3) -join ' | ')" $null }
}
function TaskParts($full) { $i = $full.LastIndexOf('\'); $full.Substring(0, $i + 1), $full.Substring($i + 1) }

function Do-Registry($verb) {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'run from 64-bit PowerShell (32-bit sees a redirected registry and gives false positives)'; return }
    $f = @(Scan-Registry)
    if (-not $f) { 'no broken references found'; return }
    $f | Group-Object Area | ForEach-Object { "== $($_.Name) ($($_.Count))"; $_.Group | ForEach-Object { "    {0}{1}" -f $(if ($_.Fix) { '' } else { '[report] ' }), $_.Detail } }
    ''
    "$($f.Count) finding(s). Flagged only when a concrete path on a mounted drive is gone; unparseable entries are skipped, not guessed."
    if ($verb -ne 'fix') { 'Fix:  detox registry fix   (exports each key to .reg first; no backup = no change)'; return }
    if (-not $IsAdmin) { 'registry fix needs an admin terminal'; return }
    $bk = Join-Path $env:USERPROFILE ('detox-backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item $bk -ItemType Directory -Force | Out-Null
    $i = 0
    foreach ($x in @($f | Where-Object Fix)) {
        if ($DryRun) { "would fix: [$($x.Area)] $($x.Detail)"; continue }
        if (-not (Ask "fix [$($x.Area)] $($x.Detail)?")) { continue }
        $i++
        $ok = $true
        if ($x.Key -like 'HKEY_*') { reg.exe export $x.Key (Join-Path $bk "$i-$($x.Area).reg") /y 2>&1 | Out-Null; $ok = ($LASTEXITCODE -eq 0) }
        elseif ($x.Area -eq 'task') { $tp, $tn = TaskParts $x.Key; try { Export-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop | Set-Content (Join-Path $bk "$i-task.xml") } catch { $ok = $false } }
        else { try { Copy-Item -LiteralPath $x.Key (Join-Path $bk "$i-$(Split-Path $x.Key -Leaf)") -ErrorAction Stop } catch { $ok = $false } }
        if (-not $ok) { "    backup failed, left untouched"; continue }
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Stop'
        try { & $x.Fix $x; '    fixed' } catch { "    failed: $($_.Exception.Message)" } finally { $ErrorActionPreference = $eap }
    }
    "backup: $bk   (undo: reg import <file>.reg / Register-ScheduledTask -Xml / copy the file back)"
}

switch ($Command) {
    'scan' { Do-Scan }
    'doctor' { Do-Doctor }
    'clean' { Do-Clean $Args2 }
    'ram' { Do-Ram }
    'startup' { if ($Args2) { Do-Startup $Args2[0] (@($Args2 | Select-Object -Skip 1) -join ' ') } else { Do-Startup } }
    'debloat' { Do-Debloat }
    'registry' { Do-Registry $(if ($Args2) { $Args2[0] }) }
    'repair' { Do-Repair }
    'nuke' { $script:Hard = $true; Do-Clean @('all'); Do-Registry 'fix'; Do-Repair }
    default { Get-Content $PSCommandPath -TotalCount 18 | Select-Object -Skip 1 }
}
