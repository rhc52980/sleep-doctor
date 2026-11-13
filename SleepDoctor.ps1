<#
.SYNOPSIS
  Sleep Doctor - finds out why a Windows PC will not sleep and shows an HTML dashboard.
.DESCRIPTION
  Read-only: changes nothing on your system.
  Normally started by double-clicking Start-SleepDoctor.cmd (it asks about Administrator).
  Works on Windows 10 / 11 with the built-in Windows PowerShell 5.1.
.PARAMETER OutDir   Folder for the dashboard and reports. Default: Desktop.
.PARAMETER Energy   Also run 'powercfg /energy' (adds ~30 seconds, Administrator only).
.PARAMETER NoOpen   Do not open the dashboard when finished.
#>
param(
    [string]$OutDir,
    [switch]$Elevated,
    [switch]$Energy,
    [switch]$NoOpen
)

$ErrorActionPreference = 'SilentlyContinue'
$script:AppVersion = '1.0'

try {

# ============================================================== setup / admin prompt
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $OutDir) { $OutDir = [Environment]::GetFolderPath('Desktop') }
if (-not (Test-Path $OutDir)) { $OutDir = $env:USERPROFILE }
$OutDir = $OutDir.TrimEnd('\')

if (-not $isAdmin -and -not $Elevated) {
    $ans = 'No'
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $msg = "Sleep Doctor finds much more with Administrator access:`n" +
               "it can see what is blocking sleep right now and which wake timers are set.`n`n" +
               "Run as Administrator?`n`n" +
               "   Yes - Windows will show a permission prompt`n" +
               "   No   - continue with limited results"
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Sleep Doctor', 'YesNo', 'Question').ToString()
    } catch {}
    if ($ans -eq 'Yes') {
        try {
            $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated -OutDir "{1}"' -f $PSCommandPath, $OutDir
            if ($Energy) { $argList += ' -Energy' }
            if ($NoOpen) { $argList += ' -NoOpen' }
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -ErrorAction Stop
            exit
        } catch {
            Write-Host "Administrator access was declined - continuing with limited results." -ForegroundColor Yellow
        }
    }
}

try { $Host.UI.RawUI.WindowTitle = 'Sleep Doctor' } catch {}
Write-Host ""
Write-Host "  SLEEP DOCTOR  v$($script:AppVersion)" -ForegroundColor Cyan
Write-Host "  Checking why this PC won't sleep. Nothing is changed. Please wait..." -ForegroundColor Gray
if (-not $isAdmin) { Write-Host "  (Limited mode: not running as Administrator)" -ForegroundColor Yellow }
Write-Host ""

$TOTAL = 9
function Step($n, $text) { Write-Host ("  [{0}/{1}] {2}" -f $n, $TOTAL, $text) }

# ============================================================== helpers
$findings = New-Object System.Collections.Generic.List[object]
$fixes    = New-Object System.Collections.Generic.List[object]
$files    = New-Object System.Collections.Generic.List[object]
function Add-Finding($level, $title, $detail) { $findings.Add([pscustomobject]@{ Level = $level; Title = $title; Detail = $detail }) }
function Add-Fix($title, $cmd, $note) {
    if ($cmd -and ($fixes | Where-Object { $_.Command -eq $cmd })) { return }
    $fixes.Add([pscustomobject]@{ Title = $title; Command = $cmd; Note = $note })
}
function Get-Cim($cls) {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) { Get-CimInstance $cls } else { Get-WmiObject $cls }
}
function Enc($s) {
    if ($null -eq $s) { return '' }
    ([string]$s) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
}
$inv = [Globalization.CultureInfo]::InvariantCulture
function N($v) { ([double]$v).ToString('0.##', $inv) }

function Get-PwrSetting($sub, $setting) {
    $q = (powercfg /q SCHEME_CURRENT $sub $setting) -join "`n"
    $ac = $null; $dc = $null
    $m1 = [regex]::Match($q, 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
    $m2 = [regex]::Match($q, 'Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
    if ($m1.Success) { $ac = [Convert]::ToInt32($m1.Groups[1].Value, 16) }
    if ($m2.Success) { $dc = [Convert]::ToInt32($m2.Groups[1].Value, 16) }
    return @{ AC = $ac; DC = $dc }
}
function Fmt-Time($s)   { if ($null -eq $s) { 'not present' } elseif ($s -eq 0) { 'Never' } elseif ($s -lt 120) { "$s sec" } else { "{0} min" -f ($s / 60) } }
function Fmt-Action($v) { switch ($v) { 0 {'Do nothing'} 1 {'Sleep'} 2 {'Hibernate'} 3 {'Shut down'} 4 {'Turn off display'} default { if ($null -eq $v) {'not present'} else {"code $v"} } } }
function Fmt-Wake($v)   { switch ($v) { 0 {'Disabled'} 1 {'Enabled'} 2 {'Important only'} default { if ($null -eq $v) {'not present'} else {"code $v"} } } }
function Fmt-OnOff($v)  { switch ($v) { 0 {'Off'} 1 {'On'} default { if ($null -eq $v) {'not present'} else {"code $v"} } } }
function Fmt-Conn($v)   { switch ($v) { 0 {'Disconnected'} 1 {'Connected'} 2 {'Managed by Windows'} default { if ($null -eq $v) {'not present'} else {"code $v"} } } }

# ============================================================== 1. System
Step 1 "Reading system information"
$cs   = Get-Cim Win32_ComputerSystem | Select-Object -First 1
$os   = Get-Cim Win32_OperatingSystem | Select-Object -First 1
$bios = Get-Cim Win32_BIOS | Select-Object -First 1
$cpu  = Get-Cim Win32_Processor | Select-Object -First 1
$enc  = Get-Cim Win32_SystemEnclosure | Select-Object -First 1
$bat  = Get-Cim Win32_Battery | Select-Object -First 1
$gpus = @(Get-Cim Win32_VideoController)
$laptopTypes = 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
$isLaptop = [bool]$bat
if ($enc -and ($enc.ChassisTypes | Where-Object { $laptopTypes -contains $_ })) { $isLaptop = $true }
$boot = $os.LastBootUpTime
if ($boot -isnot [datetime]) { try { $boot = [Management.ManagementDateTimeConverter]::ToDateTime($boot) } catch { $boot = Get-Date } }
$uptimeH = ((Get-Date) - $boot).TotalHours
$sysPairs = New-Object System.Collections.Generic.List[object]
$sysPairs.Add(@('Computer', $env:COMPUTERNAME))
$sysPairs.Add(@('Model', ("{0} {1}" -f $cs.Manufacturer, $cs.Model)))
$sysPairs.Add(@('Type', $(if ($isLaptop) { 'Laptop / portable' } else { 'Desktop / other' })))
$sysPairs.Add(@('Windows', ("{0} (build {1})" -f $os.Caption, $os.BuildNumber)))
$sysPairs.Add(@('Last restart', ("{0}  ({1:N1} hours ago)" -f $boot, $uptimeH)))
$sysPairs.Add(@('BIOS', ("{0} {1}" -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion)))
$sysPairs.Add(@('Processor', $(if ($cpu.Name) { $cpu.Name.Trim() } else { '' })))
$sysPairs.Add(@('Memory', ("{0:N1} GB" -f ($cs.TotalPhysicalMemory / 1GB))))
foreach ($g in $gpus) { $sysPairs.Add(@('Graphics', ("{0} (driver {1})" -f $g.Name, $g.DriverVersion))) }
$sysPairs.Add(@('Battery', $(if ($bat) { "{0}% charge" -f $bat.EstimatedChargeRemaining } else { 'none' })))
if ($uptimeH -lt 0.25) { Add-Finding 'info' 'PC restarted very recently' 'Startup activity (updates, indexing, sync) can delay sleep for a few minutes after boot.' }

# ============================================================== 2. Sleep mode
Step 2 "Detecting the sleep mode"
$avail = @(powercfg /a)
$availText = $avail -join "`n"
$splitOk = $availText -match 'The following sleep states are not available'
$availPart = if ($splitOk) { ($availText -split 'The following sleep states are not available')[0] } else { $availText }
$pw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
if ($splitOk) { $modern = ($availPart -match 'S0 Low Power Idle') -or ($pw.CsEnabled -eq 1) }
else          { $modern = ($pw.CsEnabled -eq 1) }
$hasS3  = $splitOk -and ($availPart -match 'Standby \(S3\)')
$hasHib = $splitOk -and ($availPart -match 'Hibernate')
if     ($modern) { $modeText = 'Modern Standby (S0 Low Power Idle)'; $modeShort = 'Modern Standby' }
elseif ($hasS3)  { $modeText = 'Classic Sleep (S3)';                 $modeShort = 'Classic Sleep (S3)' }
elseif ($hasHib) { $modeText = 'Hibernate only (no standby available)'; $modeShort = 'Hibernate only' }
else             { $modeText = 'Unknown';                            $modeShort = 'Unknown' }
$modeNote = switch ($modeShort) {
    'Modern Standby'    { 'Works like a phone: screen off but the system stays partly awake, so the network can wake it. Fans and lights may keep running on some desktops.' }
    'Classic Sleep (S3)'{ 'Traditional sleep: only memory stays powered. Fans and lights normally turn off.' }
    'Hibernate only'    { 'No standby state is available - only hibernate. Check the BIOS and Windows settings.' }
    default             { 'The sleep mode could not be determined.' }
}
if ($modern) { Add-Finding 'info' 'This PC uses Modern Standby (S0)' 'It sleeps differently from classic S3. Normal items such as Windows Update requests and maintenance wake timers are usually harmless. Fans or lights staying on during standby is common on desktops.' }
if (-not $modern -and -not $hasS3 -and $splitOk) { Add-Finding 'problem' 'No standby state is available' 'Sleep may be disabled by the BIOS, a driver or a policy. See the Sleep states section.' }

$hf = Get-Item 'C:\hiberfil.sys' -Force
$sysSettings = New-Object System.Collections.Generic.List[object]
$sysSettings.Add(@('Modern Standby override (PlatformAoAcOverride)', $(if ($null -eq $pw.PlatformAoAcOverride) { 'not set' } else { $pw.PlatformAoAcOverride })))
$sysSettings.Add(@('Modern Standby enabled (CsEnabled)', $(if ($null -eq $pw.CsEnabled) { 'not present' } else { $pw.CsEnabled })))
$sysSettings.Add(@('Fast Startup (HiberbootEnabled)', $(if ($null -eq $pw.HiberbootEnabled) { 'not set' } else { $pw.HiberbootEnabled })))
$sysSettings.Add(@('Hibernate enabled (HibernateEnabled)', $(if ($null -eq $pw.HibernateEnabled) { 'not set' } else { $pw.HibernateEnabled })))
$sysSettings.Add(@('Hibernate file (hiberfil.sys)', $(if ($hf) { "{0:N1} GB" -f ($hf.Length / 1GB) } else { 'not present (hibernate off)' })))

# ============================================================== 3. Power plan
Step 3 "Reading the power plan"
$planList = @(powercfg /list)
$activePlan = (powercfg /getactivescheme) -join ' '
$rows = @(
    @('SUB_SLEEP', 'STANDBYIDLE', 'Sleep after', 'time', 'STANDBYIDLE'),
    @('SUB_SLEEP', 'HIBERNATEIDLE', 'Hibernate after', 'time', 'HIBERNATEIDLE'),
    @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0', 'Unattended sleep timeout', 'time', 'UNATTENDSLEEP'),
    @('SUB_VIDEO', 'VIDEOIDLE', 'Turn off display after', 'time', 'VIDEOIDLE'),
    @('SUB_SLEEP', 'RTCWAKE', 'Allow wake timers', 'wake', 'RTCWAKE'),
    @('SUB_SLEEP', 'HYBRIDSLEEP', 'Hybrid sleep', 'onoff', 'HYBRIDSLEEP'),
    @('4f971e89-eebd-4455-a8de-9e59040e7347', '7648efa3-dd9c-4e3e-b566-50f929386280', 'Power button action', 'action', 'PBUTTONACTION'),
    @('4f971e89-eebd-4455-a8de-9e59040e7347', '96996bc0-ad50-47ec-923b-6f41874dd9eb', 'Sleep button action', 'action', 'SBUTTONACTION'),
    @('4f971e89-eebd-4455-a8de-9e59040e7347', '5ca83367-6e45-459f-a27b-476b1d01c936', 'Lid close action', 'action', 'LIDACTION'),
    @('fea3413e-7e05-4911-9a71-700331f1c294', 'f15576e8-98b7-4186-b944-eafa664402d9', 'Network connectivity in standby', 'conn', 'CONNECTIVITYINSTANDBY')
)
$settings = @{}
$planRows = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
    $v = Get-PwrSetting $r[0] $r[1]
    $settings[$r[4]] = $v
    switch ($r[3]) {
        'time'   { $a = Fmt-Time $v.AC;   $d = Fmt-Time $v.DC }
        'wake'   { $a = Fmt-Wake $v.AC;   $d = Fmt-Wake $v.DC }
        'action' { $a = Fmt-Action $v.AC; $d = Fmt-Action $v.DC }
        'conn'   { $a = Fmt-Conn $v.AC;   $d = Fmt-Conn $v.DC }
        default  { $a = Fmt-OnOff $v.AC;  $d = Fmt-OnOff $v.DC }
    }
    $planRows.Add(@($r[2], $a, $d))
}
$sleepAfterAC = $settings['STANDBYIDLE'].AC
$sleepAfterText = Fmt-Time $sleepAfterAC
if ($sleepAfterAC -eq 0) {
    Add-Finding 'problem' "'Sleep after' is set to Never while plugged in" 'The power plan tells the PC never to sleep. This is a setting, not a blocker.'
    Add-Fix 'Sleep after 30 minutes when plugged in' 'powercfg /change standby-timeout-ac 30' 'Run in any PowerShell or Command Prompt.'
}
if ($settings['VIDEOIDLE'].AC -eq 0) {
    Add-Finding 'warn' "'Turn off display' is Never while plugged in" 'The screen stays on, which is easy to mistake for the PC not sleeping.'
    Add-Fix 'Turn the display off after 10 minutes' 'powercfg /change monitor-timeout-ac 10' ''
}
$polRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings'
$polLines = @()
if (Test-Path $polRoot) {
    Get-ChildItem $polRoot -Recurse | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        $vals = $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { "$($_.Name)=$($_.Value)" }
        $polLines += ("{0}: {1}" -f $_.Name, ($vals -join ', '))
    }
    if ($polLines.Count) { Add-Finding 'info' 'Group Policy power settings are present' 'Company or local policy can override the settings you change. See Power plan details.' }
}

# ============================================================== 4. Requests / timers
Step 4 "Checking what is blocking sleep"
$reqs = [ordered]@{}
$reqReadable = $false
$req = @(powercfg /requests 2>$null)
if ($isAdmin -and (($req -join "`n") -notmatch 'requires administrator|administrator privileges')) {
    $reqReadable = $true
    $cur = $null
    foreach ($line in $req) {
        if ($line -match '^([A-Z ]+):\s*$') { $cur = $Matches[1].Trim(); $reqs[$cur] = @(); continue }
        if ($cur -and $line.Trim() -and $line.Trim() -ne 'None.') {
            $tl = $line.Trim()
            # a request is "[TYPE] path" followed by an optional description line - keep them together as one item
            if ($tl -notmatch '^\[' -and @($reqs[$cur]).Count -gt 0) { $reqs[$cur][@($reqs[$cur]).Count - 1] += " ($tl)" }
            else { $reqs[$cur] += $tl }
        }
    }
    $blockCount = 0
    foreach ($k in 'SYSTEM', 'AWAYMODE', 'EXECUTION') {
        foreach ($item in @($reqs[$k])) {
            if ($modern -and $k -eq 'EXECUTION') { continue }
            $blockCount++
            Add-Finding 'problem' "$k request is blocking sleep" $item
            if ($item -match '^\[(PROCESS|DRIVER|SERVICE)\]\s+(.+)$' -and $item -notmatch 'MoUsoCoreWorker|TiWorker|svchost') {
                $type = $Matches[1]; $short = Split-Path $Matches[2] -Leaf
                Add-Fix "Ignore the '$short' $k request" "powercfg /requestsoverride $type `"$short`" $k" "Undo with:  powercfg /requestsoverride $type `"$short`""
            }
        }
    }
    foreach ($item in @($reqs['DISPLAY'])) { $blockCount++; Add-Finding 'problem' 'DISPLAY request is keeping the screen on' "$item (usually a video player or presentation app)" }
    foreach ($item in @($reqs['EXECUTION'])) {
        if ($modern) { Add-Finding 'info' 'Background task is active (EXECUTION request)' "$item - normal on Modern Standby PCs, often Windows Update; it finishes on its own." }
    }
    if ($blockCount -eq 0) { Add-Finding 'ok' 'Nothing is blocking sleep right now' 'No app, driver or service has an active power request that stops the PC from sleeping.' }
} else {
    Add-Finding 'warn' 'Could not check what is blocking sleep' 'Power requests and wake timers need Administrator access. Run Sleep Doctor again and choose Yes at the prompt.'
}
$overrides = @(powercfg /requestsoverride)

$timers = New-Object System.Collections.Generic.List[object]
$wtRaw = @(powercfg /waketimers 2>$null)
if ($isAdmin -and (($wtRaw -join "`n") -notmatch 'requires administrator|administrator privileges')) {
    $curT = $null
    foreach ($l in $wtRaw) {
        if ($l -match '^Timer set by (.+?) expires at (.+?)\.?\s*$') { $curT = [pscustomobject]@{ Owner = $Matches[1]; Expires = $Matches[2]; Reason = '' }; $timers.Add($curT) }
        elseif ($l -match '^\s*Reason:\s*(.+)$' -and $curT) { $curT.Reason = $Matches[1] }
    }
    if ($timers.Count) {
        $other = @($timers | Where-Object { $_.Reason -notmatch 'Maintenance Activator|Schedule Wake To Work|Reboot|UpdateOrchestrator' })
        if ($other.Count) {
            Add-Finding 'problem' 'A wake timer is set that is not routine Windows maintenance' 'Wake timers can wake the PC after it goes to sleep. See Wake timers for the owner and reason.'
        } else {
            Add-Finding 'info' 'Routine Windows maintenance wake timers are set' 'Windows Update / maintenance wakes the PC at night. Normal; can be disabled below.'
        }
        Add-Fix 'Stop scheduled wake-ups (plugged in)' 'powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0 && powercfg /setactive SCHEME_CURRENT' 'Turns off "Allow wake timers" for the current plan. Windows Update may then install later.'
    }
}
$wakeTasks = New-Object System.Collections.Generic.List[object]
Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' -and $_.Settings.WakeToRun } | ForEach-Object {
    $ti = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath
    $wakeTasks.Add([pscustomobject]@{ Task = ($_.TaskPath + $_.TaskName); State = $_.State; Next = $ti.NextRunTime })
}

# ============================================================== 5. Wake devices
Step 5 "Looking at wake sources and devices"
$lastWake = @(powercfg /lastwake)
$armed = @(powercfg /devicequery wake_armed | Where-Object { $_.Trim() })
$progr = @(powercfg /devicequery wake_programmable | Where-Object { $_.Trim() })
if ($armed.Count -gt 0 -and (($armed -join '') -match 'Network|Ethernet|Wi-?Fi|Wireless|Mouse|Bluetooth|Keyboard|Xbox|Controller')) {
    Add-Finding 'info' ("{0} devices are allowed to wake the PC" -f $armed.Count) 'Keyboards, mice and network cards can wake the PC. Normal, but a jittery mouse or network traffic can cause unwanted wake-ups.'
    Add-Fix 'Stop a device waking the PC' $null 'Device Manager > the device > Properties > Power Management > untick "Allow this device to wake the computer".'
}
$nics = New-Object System.Collections.Generic.List[object]
Get-NetAdapter -Physical | ForEach-Object {
    $pm = Get-NetAdapterPowerManagement -Name $_.Name
    $nics.Add([pscustomobject]@{ Name = $_.Name; Status = $_.Status; Speed = $_.LinkSpeed; Desc = $_.InterfaceDescription
        Magic = $pm.WakeOnMagicPacket; Pattern = $pm.WakeOnPattern; TurnOff = $pm.AllowComputerToTurnOffDevice })
}
$usbNames = @(Get-PnpDevice -PresentOnly -Class USB, HIDClass, Bluetooth, Xbox360Peripherals, XboxComposite | Where-Object { $_.FriendlyName } |
              Select-Object -ExpandProperty FriendlyName -Unique | Sort-Object)

# ============================================================== 6. Sessions / activity
Step 6 "Checking sessions, remote access and activity"
$qu = @(quser 2>$null)
$rdpSessions = @($qu | Select-Object -Skip 1 | Where-Object { $_ -match 'rdp-tcp' })
$ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$rdpEnabled = ($ts.fDenyTSConnections -eq 0)
$rdpConn = @(Get-NetTCPConnection -LocalPort 3389 -State Established)
if ($rdpSessions.Count) { Add-Finding 'warn' 'A Remote Desktop session is connected' 'Remote sessions can wake the PC or keep it active. The standby history below shows whether it still sleeps while connected.' }
if ($rdpConn.Count)     { Add-Finding 'warn' 'A Remote Desktop network connection is established' ("From " + (($rdpConn | ForEach-Object { $_.RemoteAddress }) -join ', ')) }
$remoteTools = @(Get-Process -Name 'AnyDesk', 'TeamViewer*', 'parsec*', 'sunshine*', 'Moonlight*', 'rustdesk', 'remoting_host', 'LogMeIn*', 'vncserver*', 'tvnserver', 'ScreenConnect*' | Select-Object -ExpandProperty ProcessName -Unique)
if ($remoteTools.Count) { Add-Finding 'warn' 'Remote access / streaming software is running' (($remoteTools -join ', ') + ' - these often keep the PC awake or wake it.') }

$idleSec = $null
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SdIdle {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    public static double Seconds() {
        LASTINPUTINFO l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(l);
        if (!GetLastInputInfo(ref l)) return -1;
        return (unchecked((int)Environment.TickCount - (int)l.dwTime)) / 1000.0;
    }
}
"@
} catch {}
try { $idleSec = [SdIdle]::Seconds() } catch {}

$cores = [Environment]::ProcessorCount
$s1 = @{}
Get-Process | ForEach-Object { $s1[$_.Id] = @{ N = $_.ProcessName; T = $_.TotalProcessorTime.TotalSeconds } }
Start-Sleep -Seconds 3
$topCpu = @(Get-Process | ForEach-Object {
    if ($s1.ContainsKey($_.Id) -and $null -ne $_.TotalProcessorTime) {
        [pscustomobject]@{ Name = $_.ProcessName; Id = $_.Id; Cpu = [math]::Round((($_.TotalProcessorTime.TotalSeconds - $s1[$_.Id].T) / 3 / $cores) * 100, 1) }
    }
} | Sort-Object Cpu -Descending | Select-Object -First 8)
$busy = $topCpu | Where-Object { $_.Cpu -ge 15 -and $_.Name -ne 'Idle' } | Select-Object -First 1
if ($busy) { Add-Finding 'warn' ("{0} is using {1}% CPU" -f $busy.Name, $busy.Cpu) 'Sustained CPU activity can keep the PC awake and the fans running.' }

$netTop = @()
$conns = @(Get-NetTCPConnection -State Established | Where-Object { $_.RemoteAddress -notin '127.0.0.1', '::1' })
if ($conns.Count) {
    $netTop = @($conns | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
        [pscustomobject]@{ Name = (Get-Process -Id $_.Name).ProcessName; Count = $_.Count } })
}
$svcList = @(Get-Service -Name wuauserv, UsoSvc, BITS, TrustedInstaller, WSearch, SysMain, DoSvc, LanmanServer, Spooler)
$pending = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'Component servicing' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' }
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations) { $pending += 'Pending file renames' }
if ($pending.Count) { Add-Finding 'info' 'A restart is pending' (($pending -join ', ') + ' - install updates and restart; leftover update activity can keep the PC busy.') }
$suspectNames = 'Teams', 'ms-teams', 'Zoom', 'Spotify', 'vlc', 'Plex*', 'steam*', 'obs64', 'chrome', 'msedge', 'firefox', 'Discord', 'OneDrive', 'qbittorrent', 'utorrent', 'Docker*', 'vmware*', 'VirtualBox*', 'vmms', 'Code', 'MsMpEng', 'SearchIndexer', 'iTunes', 'wmplayer', 'Dropbox', 'GoogleDriveFS', 'Slack', 'Battle.net', 'EpicGamesLauncher', 'EADesktop'
$suspects = @(Get-Process -Name $suspectNames | Group-Object ProcessName | ForEach-Object { "{0} ({1})" -f $_.Name, $_.Count })

# ============================================================== 7. History
Step 7 "Reading 7 days of sleep history"
$since = (Get-Date).AddDays(-7)
$evAll = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter', 'Microsoft-Windows-Kernel-Power'; StartTime = $since } -MaxEvents 1500)
$enterId = if ($modern) { 506 } else { 42 }
$exitId  = if ($modern) { 507 } else { 107 }
$kp = @($evAll | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and ($_.Id -eq $enterId -or $_.Id -eq $exitId) } | Sort-Object TimeCreated)
$sessions = New-Object System.Collections.Generic.List[object]
$enterT = $null
foreach ($e in $kp) {
    if ($e.Id -eq $enterId) { $enterT = $e.TimeCreated }
    elseif ($e.Id -eq $exitId -and $enterT) {
        $sessions.Add([pscustomobject]@{ Start = $enterT; End = $e.TimeCreated; Minutes = [math]::Round(($e.TimeCreated - $enterT).TotalMinutes, 1) })
        $enterT = $null
    }
}
if (-not $modern) {
    # Classic sleep: the Power-Troubleshooter "returned from a low power state" event carries the real sleep and wake times (UTC)
    $sessions = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($evAll | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Power-Troubleshooter' -and $_.Id -eq 1 })) {
        # Windows puts invisible direction marks inside these timestamps and uses 9 fractional digits - clean both
        $clean = $e.Message -replace '[^\x09\x0A\x0D\x20-\x7E]', ''
        if ($clean -match 'Sleep Time:\s*(\S+)' ) {
            $sT = $Matches[1] -replace '(\.\d{1,7})\d*', '$1'
            if ($clean -match 'Wake Time:\s*(\S+)') {
                $wT = $Matches[1] -replace '(\.\d{1,7})\d*', '$1'
                try {
                    $a = [datetime]::Parse($sT, $inv, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
                    $b = [datetime]::Parse($wT, $inv, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
                    if ($b -gt $a) { $sessions.Add([pscustomobject]@{ Start = $a; End = $b; Minutes = [math]::Round(($b - $a).TotalMinutes, 1) }) }
                } catch {}
            }
        }
    }
    $sorted = @($sessions | Sort-Object Start)
    $sessions = New-Object System.Collections.Generic.List[object]
    foreach ($s in $sorted) { $sessions.Add($s) }
}
function Get-Reason($e) { if ($e.Message -match '(?:Entry |Exit )?Reason:\s*([^\r\n]+)') { return $Matches[1].Trim().TrimEnd('.') } return $null }
$enterReasons = @($kp | Where-Object { $_.Id -eq $enterId } | ForEach-Object { Get-Reason $_ } | Where-Object { $_ })
$wakeReasons  = if ($modern) { @($kp | Where-Object { $_.Id -eq $exitId } | ForEach-Object { Get-Reason $_ } | Where-Object { $_ }) }
                else { @($evAll | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Power-Troubleshooter' -and $_.Id -eq 1 -and $_.Message -match 'Wake Source:\s*([^\r\n]+)' } | ForEach-Object { $Matches[1].Trim() }) }
$enterGroups = @($enterReasons | Group-Object | Sort-Object Count -Descending)
$wakeGroups  = @($wakeReasons | Group-Object | Sort-Object Count -Descending)
$shortSessions = @($sessions | Where-Object { $_.Minutes -lt 2 })
$totalAsleepH = (($sessions | Measure-Object Minutes -Sum).Sum) / 60
if ($sessions.Count) {
    $idleEntries = @($enterReasons | Where-Object { $_ -match 'Idle' })
    if ($idleEntries.Count) { Add-Finding 'ok' 'The PC does go to sleep on its idle timeout' ("It entered sleep on idle timeout {0} times in the last 7 days." -f $idleEntries.Count) }
    else { Add-Finding 'ok' 'The PC has been sleeping' ("{0} sleep sessions in the last 7 days." -f $sessions.Count) }
    if ($shortSessions.Count -ge 3) {
        Add-Finding 'warn' ("{0} very short sleep sessions (under 2 minutes)" -f $shortSessions.Count) 'Usually something wakes the PC right after it sleeps - a remote connection, network traffic, a device, or a scheduled task. The wake-reason chart shows what.'
    }
} else {
    Add-Finding 'warn' 'No sleep sessions found in the last 7 days' 'The PC may not have slept at all this week. Check the findings above for what blocks it.'
}
$unexpected = @($evAll | Where-Object { $_.Id -eq 41 })
if ($unexpected.Count) { Add-Finding 'warn' ("{0} unexpected shutdown(s) in the last 7 days" -f $unexpected.Count) 'Kernel-Power event 41: the PC lost power or crashed. Not a sleep problem by itself, but worth knowing.' }
$evTable = New-Object System.Collections.Generic.List[object]
$evAll | Where-Object { $_.Id -in 1, 41, 42, 107, 109, 506, 507 } | Select-Object -First 40 | ForEach-Object {
    $line = ($_.Message -split "`r?`n")[0]
    $why = Get-Reason $_
    if (-not $why -and $_.Message -match 'Wake Source:\s*([^\r\n]+)') { $why = 'Wake source: ' + $Matches[1].Trim() }
    $evTable.Add(@($_.TimeCreated.ToString('MM-dd HH:mm'), $_.Id, $line, $why))
}

# ============================================================== 8. Reports
Step 8 "Creating Windows power reports"
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$sleepStudyName = $null; $powerReportName = $null; $energyName = $null
if ($isAdmin) {
    if ($modern) {
        $sleepStudyName = 'sleepstudy.html'
        powercfg /sleepstudy /output (Join-Path $OutDir $sleepStudyName) | Out-Null
        if (Test-Path (Join-Path $OutDir $sleepStudyName)) {
            $files.Add(@($sleepStudyName, 'Sleep Study - each standby session, its DRIPS % (deep low-power time) and the top offender'))
            Add-Finding 'info' 'Open the Sleep Study report' 'It lists every standby session with its DRIPS % and what kept the hardware active - the best tool for fans or battery drain during standby.'
        } else { $sleepStudyName = $null }
    }
    $powerReportName = 'system-power-report.html'
    powercfg /systempowerreport /output (Join-Path $OutDir $powerReportName) | Out-Null
    if (Test-Path (Join-Path $OutDir $powerReportName)) { $files.Add(@($powerReportName, 'System power report - power events and device state')) } else { $powerReportName = $null }
    if ($Energy) {
        Write-Host "      Running the energy test for 30 seconds - please do not use the PC..." -ForegroundColor Gray
        $energyName = 'energy-report.html'
        powercfg /energy /duration 30 /output (Join-Path $OutDir $energyName) | Out-Null
        if (Test-Path (Join-Path $OutDir $energyName)) { $files.Add(@($energyName, 'Energy report - efficiency errors and warnings')) } else { $energyName = $null }
    }
}

# ============================================================== verdict
$probs = @($findings | Where-Object { $_.Level -eq 'problem' })
$warns = @($findings | Where-Object { $_.Level -eq 'warn' })
$sleptOk = ($sessions.Count -gt 0)
if (-not $isAdmin -and -not $reqReadable) {
    $vClass = 'warn'; $vHead = 'Limited results'
    $vSub = 'Run Sleep Doctor again and choose Yes at the Administrator prompt to see what is blocking sleep.'
} elseif ($probs.Count) {
    $vClass = 'problem'; $vHead = 'Something is likely stopping this PC from sleeping'
    $vSub = ("{0} problem(s) found. Start with the first one below." -f $probs.Count)
} elseif ($warns.Count) {
    $vClass = 'warn'; $vHead = $(if ($sleptOk) { 'Sleep works, but a few things are worth checking' } else { 'Nothing is hard-blocking sleep, but check these' })
    $vSub = ("{0} item(s) to look at." -f $warns.Count)
} else {
    $vClass = 'ok'; $vHead = 'No sleep problems found'
    $vSub = 'Nothing is blocking sleep and the PC has been sleeping normally.'
}
if ($sessions.Count) { $vSub += (" It slept {0} time(s) in the last 7 days ({1:N1} hours total)." -f $sessions.Count, $totalAsleepH) }

# ============================================================== 9. Build HTML
Step 9 "Building the dashboard"

function Tbl($headers, $rowsList) {
    $s = New-Object System.Text.StringBuilder
    [void]$s.Append("<div class='tw'><table><thead><tr>")
    foreach ($hd in $headers) { [void]$s.Append("<th>" + (Enc $hd) + "</th>") }
    [void]$s.Append("</tr></thead><tbody>")
    foreach ($r in $rowsList) {
        [void]$s.Append("<tr>")
        foreach ($c in $r) { [void]$s.Append("<td>" + (Enc $c) + "</td>") }
        [void]$s.Append("</tr>")
    }
    [void]$s.Append("</tbody></table></div>")
    $s.ToString()
}
function KV($pairs) {
    $s = New-Object System.Text.StringBuilder
    [void]$s.Append("<div class='tw'><table class='kv'><tbody>")
    foreach ($p in $pairs) { [void]$s.Append("<tr><th>" + (Enc $p[0]) + "</th><td>" + (Enc $p[1]) + "</td></tr>") }
    [void]$s.Append("</tbody></table></div>")
    $s.ToString()
}
function Pre($lines) { "<pre>" + (Enc ((@($lines) | Where-Object { $_ -ne $null }) -join "`n")) + "</pre>" }
function Section($id, $title, $badge, $body) {
    $b = ''
    if ($badge) { $b = "<span class='badge'>" + (Enc $badge) + "</span>" }
    "<details class='card sec' id='$id'><summary><span class='st'>" + (Enc $title) + "</span>$b</summary><div class='sbody'>$body</div></details>"
}
function Empty-Msg($t) { "<p class='muted'>" + (Enc $t) + "</p>" }

function Build-Timeline($sess, $days) {
    $ml = 86; $pw = 840; $rh = 26; $top = 28
    $w = $ml + $pw + 14; $hgt = $top + $days * $rh + 6
    $today = (Get-Date).Date
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $w $hgt' class='tl' role='img' aria-label='Timeline of when the PC was asleep over the last $days days'>")
    foreach ($hr in 0, 3, 6, 9, 12, 15, 18, 21, 24) {
        $x = N ($ml + $pw * $hr / 24)
        [void]$sb.Append("<line x1='$x' y1='$($top - 4)' x2='$x' y2='$($hgt - 4)' class='gl'/>")
        [void]$sb.Append("<text x='$x' y='14' class='ax' text-anchor='middle'>{0:00}:00</text>" -f $hr)
    }
    for ($i = 0; $i -lt $days; $i++) {
        $day = $today.AddDays(-($days - 1 - $i)); $y = $top + $i * $rh
        [void]$sb.Append("<text x='$($ml - 8)' y='$($y + 16)' class='ax' text-anchor='end'>" + (Enc $day.ToString('ddd MMM d')) + "</text>")
        [void]$sb.Append("<rect x='$ml' y='$($y + 3)' width='$pw' height='18' rx='3' class='track'/>")
        $dayEnd = $day.AddDays(1)
        foreach ($s in $sess) {
            $st = if ($s.Start -gt $day) { $s.Start } else { $day }
            $en = if ($s.End -lt $dayEnd) { $s.End } else { $dayEnd }
            if ($en -gt $st) {
                $x1 = N ($ml + $pw * (($st - $day).TotalHours / 24))
                $wd = N ([math]::Max(2.5, $pw * (($en - $st).TotalHours / 24)))
                $cls = if ($s.Minutes -lt 2) { 'short' } else { 'ok' }
                $tip = ("Asleep {0} - {1} ({2} min)" -f $s.Start.ToString('MMM d HH:mm'), $s.End.ToString('HH:mm'), $s.Minutes)
                [void]$sb.Append("<rect x='$x1' y='$($y + 3)' width='$wd' height='18' rx='2' class='$cls tipme' data-tip='" + (Enc $tip) + "'/>")
            }
        }
    }
    [void]$sb.Append("</svg>")
    $sb.ToString()
}
function Build-Bars($groups) {
    if (-not $groups -or $groups.Count -eq 0) { return (Empty-Msg 'No data in the last 7 days.') }
    $max = ($groups | Measure-Object Count -Maximum).Maximum
    $s = New-Object System.Text.StringBuilder
    [void]$s.Append("<div class='bars'>")
    foreach ($g in ($groups | Select-Object -First 8)) {
        $pct = N (100 * $g.Count / $max)
        [void]$s.Append("<div class='br tipme' data-tip='" + (Enc ("{0}: {1} time(s)" -f $g.Name, $g.Count)) + "'><span class='bl'>" + (Enc $g.Name) + "</span><span class='bt'><span class='bf' style='width:$pct%'></span></span><span class='bn'>$($g.Count)</span></div>")
    }
    [void]$s.Append("</div>")
    $s.ToString()
}

$whenName = Get-Date -Format 'dddd, MMMM d, yyyy h:mm tt'
$adminChip = if ($isAdmin) { "<span class='chip ok'>Administrator</span>" } else { "<span class='chip warn'>Limited (not admin)</span>" }

$h = New-Object System.Text.StringBuilder
function Put($s) { [void]$h.Append($s); [void]$h.Append("`n") }

$css = @'
:root{color-scheme:light;--bg:#f9f9f7;--surface:#fcfcfb;--surface2:#f0efec;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;--grid:#e1e0d9;--border:rgba(11,11,11,.10);--s1:#2a78d6;--s2:#eb6834;--good:#0ca30c;--goodtx:#006300;--warn:#fab219;--warntx:#7a5200;--crit:#d03b3b;--crittx:#b02a2a;--info:#2a78d6}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])){color-scheme:dark;--bg:#0d0d0d;--surface:#1a1a19;--surface2:#262624;--ink:#f0efec;--ink2:#c3c2b7;--grid:#2c2c2a;--border:rgba(255,255,255,.10);--s1:#3987e5;--s2:#d95926;--goodtx:#3ec43e;--warntx:#fab219;--crittx:#ff7b7b;--info:#6da7ec}}
:root[data-theme="dark"]{color-scheme:dark;--bg:#0d0d0d;--surface:#1a1a19;--surface2:#262624;--ink:#f0efec;--ink2:#c3c2b7;--grid:#2c2c2a;--border:rgba(255,255,255,.10);--s1:#3987e5;--s2:#d95926;--goodtx:#3ec43e;--warntx:#fab219;--crittx:#ff7b7b;--info:#6da7ec}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
.wrap{max-width:1040px;margin:0 auto;padding:28px 20px 60px}
header.top{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;margin-bottom:18px}
h1{font-size:22px;margin:0;font-weight:650;letter-spacing:-.2px}
.sub{color:var(--ink2);font-size:13px}
.muted{color:var(--muted)}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
button,.btn{font:inherit;font-size:13px;color:var(--ink);background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:6px 12px;cursor:pointer;text-decoration:none}
button:hover,.btn:hover{background:var(--surface2)}
.chip{font-size:12px;padding:3px 9px;border-radius:99px;border:1px solid var(--border);background:var(--surface)}
.chip.ok{color:var(--goodtx)}.chip.warn{color:var(--warntx)}
.card{background:var(--surface);border:1px solid var(--border);border-radius:14px}
.verdict{display:flex;gap:16px;align-items:center;padding:22px 24px;border-left:6px solid var(--c);margin-bottom:16px}
.verdict.ok{--c:var(--good)}.verdict.warn{--c:var(--warn)}.verdict.problem{--c:var(--crit)}
.vicon{flex:none;width:46px;height:46px;border-radius:50%;display:grid;place-items:center;font-size:24px;font-weight:700;background:var(--c);color:#fff}
.verdict.warn .vicon{color:#0b0b0b}
.verdict h2{margin:0 0 2px;font-size:20px;font-weight:650}
.verdict p{margin:0;color:var(--ink2)}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:22px}
.stat{padding:14px 16px}
.stat .k{font-size:12px;color:var(--ink2);text-transform:uppercase;letter-spacing:.4px}
.stat .v{font-size:22px;font-weight:650;margin:2px 0;letter-spacing:-.3px}
.stat .n{font-size:12px;color:var(--muted)}
h3{font-size:15px;margin:26px 0 10px;font-weight:650}
.find{padding:12px 16px;margin-bottom:8px;display:flex;gap:12px;border-left:5px solid var(--c)}
.find.problem{--c:var(--crit)}.find.warn{--c:var(--warn)}.find.info{--c:var(--info)}.find.ok{--c:var(--good)}
.lvl{flex:none;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;width:64px;padding-top:2px}
.find.problem .lvl{color:var(--crittx)}.find.warn .lvl{color:var(--warntx)}.find.info .lvl{color:var(--info)}.find.ok .lvl{color:var(--goodtx)}
.find b{display:block;font-weight:600}
.find span.d{color:var(--ink2);font-size:14px}
.fix{padding:12px 16px;margin-bottom:8px}
.fix b{display:block;font-weight:600;margin-bottom:4px}
.cmd{display:flex;gap:8px;align-items:stretch;margin-top:6px}
.cmd code{flex:1;background:var(--surface2);border-radius:8px;padding:8px 10px;font:13px/1.4 ui-monospace,Consolas,monospace;overflow-x:auto;white-space:pre}
.fix .note{font-size:13px;color:var(--ink2)}
.chart{padding:16px 18px;margin-bottom:12px}
.chart h4{margin:0 0 2px;font-size:14px;font-weight:650}
.legend{display:flex;gap:16px;font-size:13px;color:var(--ink2);margin:6px 0 4px;flex-wrap:wrap}
.sw{display:inline-block;width:12px;height:12px;border-radius:3px;vertical-align:-1px;margin-right:6px}
svg.tl{width:100%;height:auto;display:block}
.tl .gl{stroke:var(--grid);stroke-width:1}
.tl .ax{fill:var(--muted);font-size:11px}
.tl .track{fill:var(--surface2)}
.tl .ok{fill:var(--s1)}.tl .short{fill:var(--s2)}
.tl rect.tipme:hover{stroke:var(--ink);stroke-width:1.5}
.two{display:grid;grid-template-columns:1fr 1fr;gap:12px}
@media(max-width:760px){.two{grid-template-columns:1fr}.verdict{flex-direction:column;align-items:flex-start}}
.bars .br{display:grid;grid-template-columns:minmax(90px,38%) 1fr 34px;gap:8px;align-items:center;margin:6px 0;font-size:13px}
.bl{color:var(--ink2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bt{background:var(--surface2);border-radius:5px;height:14px;display:block;overflow:hidden}
.bf{display:block;height:100%;background:var(--s1);border-radius:0 4px 4px 0}
.bn{text-align:right;font-variant-numeric:tabular-nums;color:var(--ink)}
details.sec{margin-bottom:8px}
details.sec>summary{cursor:pointer;padding:12px 16px;list-style:none;display:flex;align-items:center;gap:10px;font-weight:600}
details.sec>summary::-webkit-details-marker{display:none}
details.sec>summary::before{content:"\25B8";color:var(--muted);transition:transform .15s}
details.sec[open]>summary::before{transform:rotate(90deg)}
.badge{font-size:12px;font-weight:500;color:var(--ink2);background:var(--surface2);border-radius:99px;padding:1px 9px}
.sbody{padding:0 16px 14px}
.tw{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13.5px}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--grid);vertical-align:top}
thead th{color:var(--ink2);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.3px}
table.kv th{width:34%;color:var(--ink2);font-weight:500;font-size:13.5px;text-transform:none;letter-spacing:0}
pre{background:var(--surface2);border-radius:8px;padding:10px 12px;overflow:auto;font:12.5px/1.45 ui-monospace,Consolas,monospace;margin:8px 0;max-height:360px}
p.note{color:var(--ink2);font-size:13.5px;margin:6px 0}
#tip{position:fixed;pointer-events:none;background:var(--ink);color:var(--bg);font-size:12px;padding:5px 9px;border-radius:6px;opacity:0;transition:opacity .08s;z-index:9;max-width:320px}
a{color:var(--info)}
footer{margin-top:30px;color:var(--muted);font-size:12px}
@media print{#theme,.cmd button,#copysum{display:none}details.sec{break-inside:avoid}}
'@

$js = @'
(function(){
var root=document.documentElement,tb=document.getElementById('theme');
try{var t=localStorage.getItem('sd-theme');if(t)root.setAttribute('data-theme',t);}catch(e){}
if(tb)tb.onclick=function(){var cur=root.getAttribute('data-theme');if(!cur)cur=matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';var nx=cur==='dark'?'light':'dark';root.setAttribute('data-theme',nx);try{localStorage.setItem('sd-theme',nx);}catch(e){}};
var tip=document.getElementById('tip');
document.addEventListener('mousemove',function(e){var el=e.target.closest&&e.target.closest('.tipme');if(el){tip.textContent=el.getAttribute('data-tip');tip.style.opacity=1;tip.style.left=Math.min(e.clientX+14,innerWidth-330)+'px';tip.style.top=(e.clientY+16)+'px';}else tip.style.opacity=0;});
function copy(text,btn){var done=function(){var o=btn.textContent;btn.textContent='Copied';setTimeout(function(){btn.textContent=o;},1400);};
if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(text).then(done,function(){fb(text);done();});}else{fb(text);done();}}
function fb(text){var ta=document.createElement('textarea');ta.value=text;document.body.appendChild(ta);ta.select();try{document.execCommand('copy');}catch(e){}document.body.removeChild(ta);}
document.querySelectorAll('button[data-copy]').forEach(function(b){b.onclick=function(){copy(b.getAttribute('data-copy'),b);};});
var cs=document.getElementById('copysum');if(cs)cs.onclick=function(){copy(document.getElementById('sumtxt').value,cs);};
document.getElementById('expand').onclick=function(){document.querySelectorAll('details.sec').forEach(function(d){d.open=true;});};
})();
'@

# ---- summary text for "Copy summary"
$sumSb = New-Object System.Text.StringBuilder
[void]$sumSb.AppendLine("Sleep Doctor summary - $env:COMPUTERNAME - $whenName")
[void]$sumSb.AppendLine("Model: $($cs.Manufacturer) $($cs.Model) | $($os.Caption) build $($os.BuildNumber)")
[void]$sumSb.AppendLine("Sleep mode: $modeText | Sleep after (AC): $sleepAfterText | Admin: $isAdmin")
[void]$sumSb.AppendLine("Verdict: $vHead. $vSub")
[void]$sumSb.AppendLine("")
foreach ($f in $findings) { [void]$sumSb.AppendLine(("[{0}] {1}{2}" -f $f.Level.ToUpper(), $f.Title, $(if ($f.Detail) { ' - ' + $f.Detail } else { '' }))) }
if ($fixes.Count) { [void]$sumSb.AppendLine(""); [void]$sumSb.AppendLine("Suggested fixes:"); foreach ($f in $fixes) { [void]$sumSb.AppendLine(("- {0}{1}" -f $f.Title, $(if ($f.Command) { ': ' + $f.Command } else { '' }))) } }
if ($wakeGroups.Count) { [void]$sumSb.AppendLine(""); [void]$sumSb.AppendLine("Wake reasons (7d): " + (($wakeGroups | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join '; ')) }
if ($armed.Count) { [void]$sumSb.AppendLine("Wake-armed devices: " + ($armed -join '; ')) }
$summaryText = $sumSb.ToString()

# ---- page
Put "<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
Put ("<title>Sleep Doctor - " + (Enc $env:COMPUTERNAME) + "</title><style>$css</style></head><body><div class='wrap'>")
Put ("<header class='top'><div><h1>Sleep Doctor</h1><div class='sub'>" + (Enc $env:COMPUTERNAME) + " &middot; " + (Enc $whenName) + "</div></div><div class='row'>$adminChip<button id='copysum' type='button'>Copy summary</button><button id='expand' type='button'>Expand all</button><button id='theme' type='button'>Light / dark</button></div></header>")

$vIcon = switch ($vClass) { 'ok' { '&#10003;' } 'warn' { '!' } default { '&#10005;' } }
Put ("<section class='card verdict $vClass'><div class='vicon' aria-hidden='true'>$vIcon</div><div><h2>" + (Enc $vHead) + "</h2><p>" + (Enc $vSub) + "</p></div></section>")

# stat cards
$blockStat = if ($reqReadable) { [string]@($findings | Where-Object { $_.Level -eq 'problem' -and $_.Title -match 'request' }).Count } else { 'Needs admin' }
$timerStat = if ($reqReadable) { [string]$timers.Count } else { 'Needs admin' }
Put "<div class='stats'>"
Put ("<div class='card stat'><div class='k'>Sleep mode</div><div class='v' style='font-size:17px'>" + (Enc $modeShort) + "</div><div class='n'>" + (Enc $(if ($isLaptop) { 'Laptop' } else { 'Desktop' })) + "</div></div>")
Put ("<div class='card stat'><div class='k'>Sleeps after</div><div class='v'>" + (Enc $sleepAfterText) + "</div><div class='n'>plugged in</div></div>")
Put ("<div class='card stat'><div class='k'>Sleeps (7 days)</div><div class='v'>$($sessions.Count)</div><div class='n'>$($shortSessions.Count) under 2 min</div></div>")
Put ("<div class='card stat'><div class='k'>Time asleep</div><div class='v'>" + ('{0:N1} h' -f $totalAsleepH) + "</div><div class='n'>last 7 days</div></div>")
Put ("<div class='card stat'><div class='k'>Blocking requests</div><div class='v'>" + (Enc $blockStat) + "</div><div class='n'>right now</div></div>")
Put ("<div class='card stat'><div class='k'>Wake timers</div><div class='v'>" + (Enc $timerStat) + "</div><div class='n'>scheduled</div></div>")
Put "</div>"

# findings
Put "<h3>What we found</h3>"
$order = 'problem', 'warn', 'ok', 'info'
$labels = @{ problem = 'Problem'; warn = 'Check'; info = 'Info'; ok = 'OK' }
foreach ($lv in $order) {
    foreach ($f in @($findings | Where-Object { $_.Level -eq $lv })) {
        $d = if ($f.Detail) { "<span class='d'>" + (Enc $f.Detail) + "</span>" } else { '' }
        Put ("<div class='card find $lv'><div class='lvl'>" + $labels[$lv] + "</div><div><b>" + (Enc $f.Title) + "</b>$d</div></div>")
    }
}

# fixes
if ($fixes.Count) {
    Put "<h3>Suggested fixes <span class='muted' style='font-weight:400;font-size:13px'>- optional, run only what you want</span></h3>"
    foreach ($f in $fixes) {
        $cmdHtml = ''
        if ($f.Command) { $cmdHtml = "<div class='cmd'><code>" + (Enc $f.Command) + "</code><button type='button' data-copy='" + (Enc $f.Command) + "'>Copy</button></div>" }
        $note = if ($f.Note) { "<div class='note'>" + (Enc $f.Note) + "</div>" } else { '' }
        Put ("<div class='card fix'><b>" + (Enc $f.Title) + "</b>$note$cmdHtml</div>")
    }
    Put "<p class='note'>Commands run in a PowerShell or Command Prompt window opened as Administrator.</p>"
}

# charts
Put "<h3>Sleep history - last 7 days</h3>"
Put "<div class='card chart'><h4>When the PC was asleep</h4>"
if ($sessions.Count) {
    Put "<div class='legend'><span><i class='sw' style='background:var(--s1)'></i>Slept normally</span><span><i class='sw' style='background:var(--s2)'></i>Under 2 minutes (quick wake)</span></div>"
    Put (Build-Timeline $sessions 7)
} else { Put (Empty-Msg 'No sleep sessions were found in the event log for the last 7 days.') }
Put "</div>"
Put "<div class='two'>"
Put ("<div class='card chart'><h4>" + $(if ($modern) { 'What woke it from standby' } else { 'What woke it' }) + "</h4><p class='note'>Count over 7 days</p>" + (Build-Bars $wakeGroups) + "</div>")
Put ("<div class='card chart'><h4>Why it went to sleep</h4><p class='note'>Count over 7 days</p>" + (Build-Bars $enterGroups) + "</div>")
Put "</div>"
if ($wakeGroups | Where-Object { $_.Name -match '^\d{6,}$' }) {
    Put "<p class='note'>Numeric wake reasons (such as 16777220) are internal Windows codes - usually a network or system wake rather than a person. The Sleep Study report names them.</p>"
}

# detail sections
Put "<h3>Details</h3>"
Put (Section 'd-mode' 'Sleep mode and states' $modeShort ("<p class='note'>" + (Enc $modeNote) + "</p>" + (KV $sysSettings) + (Pre $avail)))
Put (Section 'd-plan' 'Power plan settings' $sleepAfterText ("<p class='note'>" + (Enc $activePlan) + "</p>" + (Tbl @('Setting', 'Plugged in', 'On battery') $planRows) + $(if ($polLines.Count) { "<p class='note'>Group Policy power settings:</p>" + (Pre $polLines) } else { '' }) + "<p class='note'>Other plans:</p>" + (Pre $planList)))

if ($reqReadable) {
    $rq = New-Object System.Collections.Generic.List[object]
    foreach ($k in $reqs.Keys) { $items = @($reqs[$k]); $rq.Add(@($k, $(if ($items.Count) { $items -join "`n" } else { 'none' }))) }
    Put (Section 'd-req' 'Power requests (what is blocking sleep now)' $(if ($blockStat -eq '0') { 'none blocking' } else { "$blockStat blocking" }) ((Tbl @('Type', 'Requested by') $rq) + "<p class='note'>Existing overrides:</p>" + (Pre $overrides)))
} else {
    Put (Section 'd-req' 'Power requests (what is blocking sleep now)' 'needs admin' (Empty-Msg 'Run Sleep Doctor as Administrator to read power requests.'))
}
if ($reqReadable) {
    $tb = if ($timers.Count) { (Tbl @('Set by', 'Expires', 'Reason') ($timers | ForEach-Object { , @($_.Owner, $_.Expires, $_.Reason) })) } else { Empty-Msg 'No active wake timers.' }
    $tk = if ($wakeTasks.Count) { "<p class='note'>Scheduled tasks allowed to wake the PC:</p>" + (Tbl @('Task', 'State', 'Next run') ($wakeTasks | ForEach-Object { , @($_.Task, $_.State, $_.Next) })) } else { '' }
    Put (Section 'd-timers' 'Wake timers and tasks' "$($timers.Count) timer(s)" ($tb + $tk))
} else {
    Put (Section 'd-timers' 'Wake timers and tasks' 'needs admin' (Empty-Msg 'Run Sleep Doctor as Administrator to read wake timers.'))
}
Put (Section 'd-wake' 'Devices that can wake the PC' "$($armed.Count) armed" ("<p class='note'>Currently allowed to wake the PC:</p>" + (Pre $armed) + "<p class='note'>Last wake:</p>" + (Pre $lastWake) + "<p class='note'>Can be set to wake the PC:</p>" + (Pre $progr)))
$nicRows = $nics | ForEach-Object { , @($_.Name, $_.Status, $_.Speed, $_.Desc, "Magic=$($_.Magic) Pattern=$($_.Pattern) TurnOff=$($_.TurnOff)") }
Put (Section 'd-net' 'Network adapters' "$($nics.Count)" $(if ($nics.Count) { Tbl @('Name', 'Status', 'Speed', 'Adapter', 'Wake settings') $nicRows } else { Empty-Msg 'No adapter info available (needs Windows 8 or newer).' }))
Put (Section 'd-usb' 'Connected USB / HID / Bluetooth devices' "$($usbNames.Count)" (Pre $usbNames))
$idleTxt = if ($null -ne $idleSec -and $idleSec -ge 0) { "{0:N0} seconds since last keyboard/mouse input in this session" -f $idleSec } else { 'unknown' }
Put (Section 'd-sess' 'Sessions and remote access' $(if ($rdpSessions.Count) { 'RDP connected' } else { 'no RDP' }) ((KV @(@('Remote Desktop enabled', $(if ($rdpEnabled) { 'Yes' } else { 'No' })), @('Established RDP connections', $rdpConn.Count), @('Remote tools running', $(if ($remoteTools.Count) { $remoteTools -join ', ' } else { 'none' })), @('Idle time', $idleTxt))) + (Pre $qu)))
$cpuRows = $topCpu | ForEach-Object { , @($_.Name, $_.Id, ("{0}%" -f $_.Cpu)) }
$netRows = $netTop | ForEach-Object { , @($_.Name, $_.Count) }
Put (Section 'd-act' 'Activity right now' '' ("<p class='note'>Busiest processes (3-second sample):</p>" + (Tbl @('Process', 'PID', 'CPU') $cpuRows) + "<p class='note'>Network connections per process:</p>" + $(if ($netRows) { Tbl @('Process', 'Connections') $netRows } else { Empty-Msg 'none' }) + "<p class='note'>Apps often involved in sleep problems that are running:</p><p>" + (Enc $(if ($suspects.Count) { $suspects -join ', ' } else { 'none found' })) + "</p>"))
$svcRows = $svcList | ForEach-Object { , @($_.Name, $_.Status, $_.StartType) }
Put (Section 'd-upd' 'Windows Update and services' $(if ($pending.Count) { 'restart pending' } else { 'no restart pending' }) ((Tbl @('Service', 'Status', 'Start type') $svcRows) + "<p class='note'>Pending restart: " + (Enc $(if ($pending.Count) { $pending -join ', ' } else { 'none' })) + "</p>"))
Put (Section 'd-ev' 'Sleep and wake events (7 days)' "$($evTable.Count) shown" $(if ($evTable.Count) { Tbl @('Time', 'Event ID', 'Event', 'Reason / source') $evTable } else { Empty-Msg 'No events found.' }))
Put (Section 'd-sys' 'System information' '' (KV $sysPairs))

# reports
if ($files.Count) {
    Put "<h3>Windows reports created</h3>"
    foreach ($f in $files) { Put ("<div class='card fix'><b><a href='" + (Enc $f[0]) + "'>" + (Enc $f[0]) + "</a></b><div class='note'>" + (Enc $f[1]) + "</div></div>") }
    Put "<p class='note'>Saved next to this dashboard. Open them in a browser.</p>"
} elseif (-not $isAdmin) {
    Put "<p class='note'>Run as Administrator to also create the Sleep Study and system power reports.</p>"
}
if (-not $Energy -and $isAdmin) { Put "<p class='note'>Tip: run Start-SleepDoctor.cmd with the word <code>energy</code> after it (or use -Energy) for an extra 30-second power-efficiency test.</p>" }

Put ("<footer>Sleep Doctor v$($script:AppVersion) &middot; read-only scan, nothing on this PC was changed. Wake reasons and event text come from the English Windows event log; some details may be blank on other languages.</footer>")
Put "</div><div id='tip'></div><textarea id='sumtxt' hidden readonly>"
Put (Enc $summaryText)
Put "</textarea>"
Put "<script>$js</script></body></html>"

$htmlPath = Join-Path $OutDir ("SleepDoctor-{0}-{1}.html" -f $env:COMPUTERNAME, $stamp)
[IO.File]::WriteAllText($htmlPath, $h.ToString(), (New-Object Text.UTF8Encoding($true)))

Write-Host ""
Write-Host "  Done. Dashboard saved:" -ForegroundColor Green
Write-Host "  $htmlPath"
if (-not $NoOpen) {
    Write-Host "  Opening it in your browser..."
    Start-Process $htmlPath
}
Write-Host ""
Write-Host "  You can close this window." -ForegroundColor Gray
if ($Elevated) { Start-Sleep -Seconds 4 }

} catch {
    Write-Host ""
    Write-Host "  Sleep Doctor hit an error:" -ForegroundColor Red
    Write-Host ("  " + $_.Exception.Message) -ForegroundColor Red
    Write-Host ("  at line " + $_.InvocationInfo.ScriptLineNumber)
    Read-Host "  Press Enter to close"
}
