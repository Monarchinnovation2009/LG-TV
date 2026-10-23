Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Single-instance guard. A stale instance keeps ownership of the global hotkey
# and its own SessionSwitch handler, so two copies double-handle every lock and
# only one of them responds to Ctrl+Alt+P. Second launch exits immediately.
$script:InstanceMutex = New-Object System.Threading.Mutex($false, "Local\LGTVTrayApp_SingleInstance")
try {
    $acquired = $script:InstanceMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # Previous instance was killed instead of exiting cleanly. An abandoned
    # mutex still transfers ownership to us, so this counts as acquired.
    $acquired = $true
}
if (-not $acquired) { exit 0 }

# Paths and configuration
$LgtvPath = "C:\Program Files\LGTV Companion\LGTV Companion.exe"
$StateFile = "$env:TEMP\lgtv_state.txt"
$ConfigFile = "$env:APPDATA\LGTVTrayApp\config.json"
$CompanionConfigFile = "C:\ProgramData\LGTV Companion\config.json"
$CliPath = "C:\Program Files\LGTV Companion\LGTVcli.exe"
# Cap on the input-list query. It runs on the UI thread, so a hung CLI must not
# be able to freeze the tray.
$CliTimeoutMs = 2000
# How long a manual switch waits for a sleeping TV to come up after power on.
$WakeTimeoutSeconds = 20
# Deskflow writes every cursor-lock change here; it is the source of truth for
# whether the cursor is locked (see Get-CursorLockState).
$DeskflowLogFile = "C:\ProgramData\Deskflow\deskflow-daemon.log"
# This PC's Deskflow screen name (the server); the Mac is any other screen.
$DeskflowServerName = $env:COMPUTERNAME
try {
    $nameLine = Get-Content "$env:APPDATA\Deskflow\Deskflow.conf" -ErrorAction Stop | Where-Object { $_ -match '^computerName=(.+)$' } | Select-Object -First 1
    if ($nameLine -match '^computerName=(.+)$') { $DeskflowServerName = $Matches[1].Trim() }
} catch {}
# Ping budget per attempt. Kept small: this runs on the UI thread, and
# Test-Connection against an unreachable TV blocks for ~9 seconds.
$PingTimeoutMs = 400
$PingAttempts = 2
$VbsLauncherPath = Join-Path $PSScriptRoot "launch_tray_app.vbs"
$RunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunValueName = "LGTVTrayApp"

# C# Code for Global Hotkey Registration
$code = @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class HotkeyManager : NativeWindow, IDisposable {
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
    
    public static void ToggleScrollLock() {
        const int KEYEVENTF_EXTENDEDKEY = 0x1;
        const int KEYEVENTF_KEYUP = 0x2;
        byte VK_SCROLL = 0x91;

        // Force release Ctrl and Alt keys in case they are physically held down
        keybd_event(0x11, 0, KEYEVENTF_KEYUP, 0); // VK_CONTROL
        keybd_event(0xA2, 0, KEYEVENTF_KEYUP, 0); // VK_LCONTROL
        keybd_event(0xA3, 0, KEYEVENTF_KEYUP, 0); // VK_RCONTROL
        keybd_event(0x12, 0, KEYEVENTF_KEYUP, 0); // VK_MENU (Alt)
        keybd_event(0xA4, 0, KEYEVENTF_KEYUP, 0); // VK_LMENU
        keybd_event(0xA5, 0, KEYEVENTF_KEYUP, 0); // VK_RMENU

        keybd_event(VK_SCROLL, 0x45, KEYEVENTF_EXTENDEDKEY, 0);
        keybd_event(VK_SCROLL, 0x45, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0);
    }


    public event EventHandler HotkeyPressed;
    private int id = 0;

    public HotkeyManager() {
        this.CreateHandle(new CreateParams());
    }

    public bool Register(int id, uint modifiers, uint key) {
        this.id = id;
        return RegisterHotKey(this.Handle, id, modifiers, key);
    }

    protected override void WndProc(ref Message m) {
        const int WM_HOTKEY = 0x0312;
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == id) {
            if (HotkeyPressed != null) {
                HotkeyPressed(this, EventArgs.Empty);
            }
        }
        base.WndProc(ref m);
    }

    public void Dispose() {
        UnregisterHotKey(this.Handle, id);
        this.DestroyHandle();
    }
}
"@

Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms

# WScript Shell for sending keys
$wsh = New-Object -ComObject WScript.Shell

# Decision log. Records why a switch happened or was refused - "Update-TrayStatus
# called" on its own could not distinguish a real bug from expected behaviour.
$LogFile = Join-Path $PSScriptRoot "tray_debug.txt"
function Write-TrayLog($Message) {
    try {
        "$(Get-Date -Format 'HH:mm:ss.fff') $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
    } catch {}
    # Every logged action also becomes a notification (Settings > "Notify on
    # every TV action"). Queued, not shown here: this runs on the SystemEvents
    # thread for lock/unlock/cable events, and toasts fired a few ms apart
    # replace each other. $scrollLockTimer shows the queue as one notice.
    if ($script:Config -and $script:Config.NotifyAll) { $script:NoticeQueue.Enqueue($Message.Trim()) }
}
$script:NoticeQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:NoticeBacklog = New-Object System.Collections.Generic.List[string]

# State Management Helper
function Get-TVState {
    if (-not (Test-Path $StateFile)) { Set-Content -Path $StateFile -Value "1" }
    return Get-Content -Path $StateFile
}

function Set-TVState($State) {
    Set-Content -Path $StateFile -Value $State
}

# HDMI Label Configuration (user-defined names for HDMI1 / HDMI2)
function Get-Config {
    # RequireCable: only switch the TV while this PC is cabled to it. On by
    # default - switching a TV this PC is not plugged into is rarely wanted.
    $default = @{ Hdmi1Label = "Mac"; Hdmi2Label = "PC"; RequireCable = $true; NotifyAll = $true }
    if (Test-Path $ConfigFile) {
        try {
            $loaded = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
            return @{
                Hdmi1Label = if ($loaded.Hdmi1Label) { $loaded.Hdmi1Label } else { $default.Hdmi1Label }
                Hdmi2Label = if ($loaded.Hdmi2Label) { $loaded.Hdmi2Label } else { $default.Hdmi2Label }
                # Absent from configs written before this option existed.
                RequireCable = if ($null -ne $loaded.RequireCable) { [bool]$loaded.RequireCable } else { $default.RequireCable }
                NotifyAll = if ($null -ne $loaded.NotifyAll) { [bool]$loaded.NotifyAll } else { $default.NotifyAll }
            }
        } catch { return $default }
    }
    return $default
}

function Save-Config($Config) {
    $dir = Split-Path -Path $ConfigFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Config | ConvertTo-Json | Set-Content -Path $ConfigFile
}

$script:Config = Get-Config
# Pending Scroll Lock change, retried by $scrollLockTimer (see Set-ScrollLock).
$script:ScrollLockTarget = $null
$script:ScrollLockRetries = 0
$script:LastScrollPress = [DateTime]::MinValue
$script:LockDeferred = $false
# Seconds to wait for Deskflow to log a Scroll Lock press before pressing again.
$ScrollPressSettleSeconds = 5
# Set while Hide-TVScreen has the TV panel blanked.
$script:ScreenBlanked = $false

function Set-HdmiLabel($HdmiNumber) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $current = if ($HdmiNumber -eq 1) { $script:Config.Hdmi1Label } else { $script:Config.Hdmi2Label }
    $newLabel = [Microsoft.VisualBasic.Interaction]::InputBox("Enter a name for HDMI $HdmiNumber (e.g. PC, Mac, Xbox):", "LG TV Companion - Rename HDMI $HdmiNumber", $current)
    if (-not [string]::IsNullOrWhiteSpace($newLabel)) {
        if ($HdmiNumber -eq 1) { $script:Config.Hdmi1Label = $newLabel.Trim() } else { $script:Config.Hdmi2Label = $newLabel.Trim() }
        Save-Config $script:Config
        Update-TrayStatus
    }
}

# Startup (Run on Login) Management
function Test-StartupEnabled {
    return [bool](Get-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue)
}

function Set-StartupEnabled([bool]$Enabled) {
    if ($Enabled) {
        Set-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value "wscript.exe `"$VbsLauncherPath`""
    } else {
        Remove-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue
    }
}

# TV Connection Check
# Reads the TV address straight out of LGTV Companion's own config so there is
# only one place the IP is defined. Cached after the first successful read.
function Get-TVAddress {
    if ($script:TVAddress) { return $script:TVAddress }
    try {
        $cfg = Get-Content -Path $CompanionConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($entry in $cfg.PSObject.Properties) {
            if ($entry.Name -eq "LGTV Companion") { continue }
            $ip = $entry.Value.IP
            if (-not [string]::IsNullOrWhiteSpace($ip)) {
                $script:TVAddress = $ip
                return $ip
            }
        }
    } catch {}
    return $null
}

# Decodes a WmiMonitorID EDID field. These arrive as integer arrays and are null
# on some panels (this laptop's internal display is one), which used to throw and
# abort the whole enumeration.
function Convert-EdidString($Bytes) {
    if (-not $Bytes) { return "" }
    try { return ([System.Text.Encoding]::ASCII.GetString([byte[]]$Bytes)).Trim([char]0, ' ') } catch { return "" }
}

# Is this PC physically cabled to the TV? A different question from reachability:
# the TV can be on the network while this PC is not plugged into it at all.
# Gates the automatic (lock/unlock) switches only - if we are not cabled to the
# TV then its input is not ours to change.
function Test-TVCableConnected {
    try {
        $monitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
    } catch { return $false }
    foreach ($monitor in $monitors) {
        if (-not $monitor.Active) { continue }
        $name = Convert-EdidString $monitor.UserFriendlyName
        $mfg = Convert-EdidString $monitor.ManufacturerName
        if ($name -match "LG" -or $mfg -match "GSM") { return $true }
    }
    return $false
}

# Network reachability, not display enumeration: a TV that is powered on but
# showing another input may drop HPD/EDID, so it would not appear as a screen
# even though the command would have worked.
function Test-TVConnected {
    $ip = Get-TVAddress
    if (-not $ip) { return $false }
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($i = 0; $i -lt $PingAttempts; $i++) {
            try {
                if ($ping.Send($ip, $PingTimeoutMs).Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    return $true
                }
            } catch {}
        }
        return $false
    } finally {
        $ping.Dispose()
    }
}

# Asks the TV what is plugged into each of its inputs. Returns $null if the
# query could not be completed. Endpoint takes no "ssap://" prefix.
function Get-TVInputList { return (Invoke-TVRequest "tv/getExternalInputList") }

# Sends one LGTVcli request and returns the parsed JSON, or $null on failure or
# timeout.
function Invoke-TVRequest($Endpoint) { return (Invoke-TVCli @("-request", $Endpoint)) }

# Runs LGTVcli with the given arguments and returns its parsed JSON output, or
# $null on failure or timeout.
function Invoke-TVCli([string[]]$Arguments, [int]$TimeoutMs = $CliTimeoutMs) {
    $out = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $CliPath -ArgumentList $Arguments `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $out
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch {}
            return $null
        }
        return (Get-Content -Path $out -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch {
        return $null
    } finally {
        Remove-Item -Path $out -Force -ErrorAction SilentlyContinue
    }
}

# Is anything actually plugged into the TV's HDMI[$Number]? Guards against
# switching the TV to a dead input and leaving it on "No Signal".
# Deliberately fails OPEN: returns $true whenever the TV could not tell us, so a
# failed query degrades to the old "switch anyway" behaviour rather than
# silently refusing to switch. Only a positive "nothing there" blocks.
#
# Keys on "connected" only. Measured with this PC's cable physically out:
# HDMI_2 reported connected=false but hdmiPlugIn=TRUE, so hdmiPlugIn is stale
# and must not be part of the test.
function Test-HdmiInputAvailable([int]$Number) {
    $json = Get-TVInputList
    if (-not $json) { return $true }
    foreach ($device in $json.PSObject.Properties) {
        foreach ($tvInput in $device.Value.payload.devices) {
            if ($tvInput.id -eq "HDMI_$Number") {
                return [bool]$tvInput.connected
            }
        }
    }
    return $true
}

# Is Deskflow's cursor currently locked to this PC? Read from Deskflow's own
# log, NOT the Scroll Lock light: Deskflow flips its lock on every Scroll Lock
# press it sees, independently of the light. A press seen by only one of them
# (e.g. during the lock-screen transition) left the two permanently inverted -
# the light said "off" while Deskflow kept the cursor locked to the PC.
# Returns $null if Deskflow is not running or the log says nothing usable; the
# caller then falls back to the light.
function Get-CursorLockState {
    if (-not (Get-Process -Name "deskflow-core" -ErrorAction SilentlyContinue)) { return $null }
    try {
        $fs = [System.IO.File]::Open($DeskflowLogFile, 'Open', 'Read', 'ReadWrite')
        try {
            $len = [Math]::Min($fs.Length, 65536)
            [void]$fs.Seek(-$len, 'End')
            $buf = New-Object byte[] $len
            [void]$fs.Read($buf, 0, $len)
        } finally { $fs.Close() }
        $lines = [System.Text.Encoding]::UTF8.GetString($buf) -split "`n"
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if ($line -match 'cursor locked to current screen|scroll lock is on, locking cursor') { return $true }
            if ($line -match 'cursor unlocked from current screen') { return $false }
            # A restart starts unlocked unless "scroll lock is on" follows it,
            # which the backwards scan would already have returned on.
            if ($line -match 'NOTE: stopped server') { return $false }
        }
    } catch {}
    return $null
}

# Which Deskflow screen is the cursor on? From the last "switch from X to Y"
# in Deskflow's log; a server restart puts it back on this PC. $null if unknown.
function Get-CursorScreen {
    try {
        $fs = [System.IO.File]::Open($DeskflowLogFile, 'Open', 'Read', 'ReadWrite')
        try {
            $len = [Math]::Min($fs.Length, 262144)
            [void]$fs.Seek(-$len, 'End')
            $buf = New-Object byte[] $len
            [void]$fs.Read($buf, 0, $len)
        } finally { $fs.Close() }
        $lines = [System.Text.Encoding]::UTF8.GetString($buf) -split "`n"
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match 'switch from ".*" to "(.*)" at') { return $Matches[1] }
            if ($lines[$i] -match 'NOTE: stopped server') { return $DeskflowServerName }
        }
    } catch {}
    return $null
}

# Unknown counts as on the PC, so a missing log never blocks the lock.
function Test-CursorOnPC {
    $screen = Get-CursorScreen
    return ($null -eq $screen -or $screen -eq $DeskflowServerName)
}

function Test-CursorLocked {
    $state = Get-CursorLockState
    if ($null -ne $state) { return $state }
    return [System.Windows.Forms.Control]::IsKeyLocked([System.Windows.Forms.Keys]::Scroll)
}

# Drives Deskflow's "lock cursor to current screen" (toggled by Scroll Lock):
#   locked   while the TV shows this PC (HDMI2) - the cursor must not slide
#            onto the Mac, which is not visible, taking keyboard input with it.
#   unlocked while the TV shows the Mac (HDMI1) - the cursor has to cross over.
# Presses Scroll Lock only when Deskflow is in the wrong state, then verifies
# against Deskflow's log. A press Deskflow misses (Windows drops injected keys
# around the lock screen) is left pending and retried by $scrollLockTimer.
function Set-ScrollLock([bool]$On) {
    $script:ScrollLockTarget = $On
    $script:ScrollLockRetries = 0
    $script:LockDeferred = $false
    # Deskflow's lock means "lock to the CURRENT screen". Locking while the
    # cursor is on the Mac trapped keyboard and mouse there for an hour while
    # the TV showed the PC. The app cannot pull the cursor back (Deskflow
    # ignores injected mouse moves while on the Mac), so instead make sure the
    # cursor is free, and let $scrollLockTimer lock it once it is back on the PC.
    if ($On -and -not (Test-CursorOnPC)) {
        $script:LockDeferred = $true
        Write-TrayLog "rule: cursor is on the Mac -> lock deferred; cursor left free so you can move it back to the PC"
        if (Test-CursorLocked) {
            [HotkeyManager]::ToggleScrollLock()
            $script:LastScrollPress = Get-Date
            Write-TrayLog "  -> cursor unlocked so it can come back"
        }
        return
    }
    if ((Test-CursorLocked) -ne $On) {
        [HotkeyManager]::ToggleScrollLock()
        $script:LastScrollPress = Get-Date
        Start-Sleep -Milliseconds 300
    }
    if ((Test-CursorLocked) -eq $On) {
        $script:ScrollLockTarget = $null
        Write-TrayLog "  -> cursor $(if ($On) { 'locked to PC' } else { 'unlocked' }) (Deskflow)"
    } else {
        Write-TrayLog "  cursor lock change to $(if ($On) { 'locked' } else { 'unlocked' }) did not take - retrying"
    }
}

# Sets Scroll Lock from what the TV is actually showing, for when no switch was
# sent. OFF only when the TV is confirmed on the Mac; an unreachable TV means the
# Mac is not visible either, so ON. Falls back to the state file if the query
# itself fails.
function Sync-ScrollLockFromTV {
    $onMac = $false
    if (Test-TVConnected) {
        $resp = Invoke-TVRequest "com.webos.applicationManager/getForegroundAppInfo"
        if ($resp) {
            $appId = foreach ($device in $resp.PSObject.Properties) { $device.Value.payload.appId }
            $onMac = ("$appId" -eq "com.webos.app.hdmi1")
        } else {
            $onMac = ((Get-TVState) -eq "1")
        }
    }
    Write-TrayLog "  Scroll Lock sync: TV showing Mac = $onMac"
    Set-ScrollLock (-not $onMac)
    Update-TrayStatus
}

# A TV in standby does not answer ping, so the reachability gate alone would
# refuse every switch while it sleeps. The old scripts sent the command blind
# and LGTV Companion woke the TV (Wake-on-LAN). For explicit requests, do the
# same: power it on, then wait until it answers. Returns $true once reachable.
function Wake-TV {
    if (Test-TVConnected) { return $true }
    Write-TrayLog "  TV asleep - sending power on"
    if (-not $script:Config.NotifyAll) { $notifyIcon.ShowBalloonTip(3000, "LG TV", "Waking the TV...", [System.Windows.Forms.ToolTipIcon]::Info) }
    Start-Process -FilePath $CliPath -ArgumentList "-powerOn" -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($WakeTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TVConnected) {
            # Network comes up before HDMI/EDID; give Windows time to see the
            # display again so the cable gate does not refuse.
            Start-Sleep -Seconds 4
            Write-TrayLog "  TV awake"
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    Write-TrayLog "  TV did not wake within $WakeTimeoutSeconds s"
    return $false
}

function Show-TVUnreachable {
    if (-not $script:Config.NotifyAll) { $notifyIcon.ShowBalloonTip(3000, "LG TV", "TV is not reachable - input unchanged.", [System.Windows.Forms.ToolTipIcon]::Info) }
}

# Central policy gate for every switch, manual or automatic. Checked before the
# ping because it is local and cheap, so an uncabled PC never waits on the network.
function Test-SwitchAllowed {
    if (-not $script:Config.RequireCable) { return $true }
    return (Test-TVCableConnected)
}

function Show-NoCable {
    if (-not $script:Config.NotifyAll) { $notifyIcon.ShowBalloonTip(3000, "LG TV", "This PC is not connected to the TV by cable - input unchanged. Settings > 'Only switch when TV cable is connected' turns this off.", [System.Windows.Forms.ToolTipIcon]::Info) }
}

function Show-InputEmpty($Label, $Number) {
    if (-not $script:Config.NotifyAll) { $notifyIcon.ShowBalloonTip(3000, "LG TV", "Nothing is plugged into HDMI $Number ($Label) - input unchanged.", [System.Windows.Forms.ToolTipIcon]::Warning) }
}

# TV Action Functions
# Scroll Lock is set only AFTER the TV is confirmed reachable and the command is
# sent; setting it first made the LED report an input change that never happened.
# Three gates, cheapest first: cable policy, then reachability, then whether the
# target input has anything plugged into it.
function Switch-ToHDMI1([switch]$Silent) {
    Write-TrayLog "Switch-ToHDMI1 requested (silent=$Silent)"
    # Explicit requests wake a sleeping TV first; automatic (silent) ones never
    # do - lock should leave the TV dark, and unlock must not turn it on.
    if (-not $Silent) {
        Write-TrayLog "rule: manual switch -> wake TV if asleep; needs cable (if setting on), TV reachable, device on target input"
        [void](Wake-TV)
    }
    if (-not (Test-SwitchAllowed)) {
        Write-TrayLog "  refused: this PC is not cabled to the TV (RequireCable on)"
        if (-not $Silent) { Show-NoCable }
        Update-TrayStatus
        return $false
    }
    if (-not (Test-TVConnected)) {
        Write-TrayLog "  refused: TV not reachable on the network"
        if (-not $Silent) { Show-TVUnreachable }
        Update-TrayStatus
        return $false
    }
    if (-not (Test-HdmiInputAvailable 1)) {
        Write-TrayLog "  refused: TV reports nothing plugged into HDMI1"
        if (-not $Silent) { Show-InputEmpty $script:Config.Hdmi1Label 1 }
        Update-TrayStatus
        return $false
    }
    Show-TVScreen
    Write-TrayLog "  -> TV to HDMI1 ($($script:Config.Hdmi1Label))"
    Write-TrayLog "rule: TV shows Mac -> cursor unlocked so it can cross to the Mac"
    Start-Process $LgtvPath -ArgumentList "-sethdmi1" -WindowStyle Hidden
    Set-TVState "1"
    Start-Sleep -Seconds 1
    Set-ScrollLock $false
    Update-TrayStatus
    return $true
}

function Switch-ToHDMI2([switch]$Silent) {
    Write-TrayLog "Switch-ToHDMI2 requested (silent=$Silent)"
    # Explicit requests wake a sleeping TV first; automatic (silent) ones never
    # do - lock should leave the TV dark, and unlock must not turn it on.
    if (-not $Silent) {
        Write-TrayLog "rule: manual switch -> wake TV if asleep; needs cable (if setting on), TV reachable, device on target input"
        [void](Wake-TV)
    }
    if (-not (Test-SwitchAllowed)) {
        Write-TrayLog "  refused: this PC is not cabled to the TV (RequireCable on)"
        if (-not $Silent) { Show-NoCable }
        Update-TrayStatus
        return $false
    }
    if (-not (Test-TVConnected)) {
        Write-TrayLog "  refused: TV not reachable on the network"
        if (-not $Silent) { Show-TVUnreachable }
        Update-TrayStatus
        return $false
    }
    if (-not (Test-HdmiInputAvailable 2)) {
        Write-TrayLog "  refused: TV reports nothing plugged into HDMI2"
        if (-not $Silent) { Show-InputEmpty $script:Config.Hdmi2Label 2 }
        Update-TrayStatus
        return $false
    }
    Show-TVScreen
    Write-TrayLog "  -> TV to HDMI2 ($($script:Config.Hdmi2Label))"
    Write-TrayLog "rule: TV shows PC -> cursor locked to PC so it can't drift to the hidden Mac"
    Start-Process $LgtvPath -ArgumentList "-sethdmi2" -WindowStyle Hidden
    Set-TVState "2"
    Set-ScrollLock $true
    Update-TrayStatus
    return $true
}

# Privacy action for lock / cable-disconnect: point the TV at this PC's input so
# whatever was on the other input stops being visible. With the cable out that
# input is dead, which is the desired outcome - "show nothing" rather than "show
# the Mac".
#
# Deliberately bypasses BOTH the RequireCable gate and the input-availability
# gate. Those exist to stop us switching to a useless input; here a useless
# input IS the point, and on a cable disconnect both would otherwise refuse the
# one switch that matters. Reachability is still required - without it there is
# nothing we can do anyway.
function Hide-TVContent {
    Write-TrayLog "Hide-TVContent (lock or cable disconnect) - forcing HDMI2, gates bypassed"
    if (-not (Test-TVConnected)) {
        Write-TrayLog "  refused: TV not reachable on the network"
        return
    }
    Start-Process $LgtvPath -ArgumentList "-sethdmi2" -WindowStyle Hidden
    Set-TVState "2"
    Set-ScrollLock $true
    Update-TrayStatus
}

# Lock: nothing at all on the TV. Switching to HDMI2 alone still shows the
# Windows lock screen, so park the TV on this PC's input (so nothing of the Mac
# appears if someone wakes the panel with the remote), then blank the panel.
# Cursor stays locked to the PC (Hide-TVContent): with the TV dark, the Mac is
# not visible anywhere.
function Hide-TVScreen {
    Write-TrayLog "Hide-TVScreen (lock) - HDMI2 then screen off"
    if (-not (Test-TVConnected)) {
        Write-TrayLog "  refused: TV not reachable on the network"
        return
    }
    Hide-TVContent
    # Give the input switch a moment so it does not wake the panel again.
    Start-Sleep -Milliseconds 1500
    # Right after an input change the TV can take over 2 s to answer, which
    # left every lock logging an empty, unconfirmed reply. Wait longer, then
    # check the real power state and send once more if the panel is still lit.
    $script:ScreenBlanked = $true
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        [void](Invoke-TVCli @("-screenOff") 6000)
        $state = Get-TVPowerState (Invoke-TVRequest "com.webos.service.tvpower/power/getPowerState")
        if ($state -eq "Screen Off") {
            Write-TrayLog "  -> screen off (confirmed by TV)"
            return
        }
        Write-TrayLog "  screen off attempt $attempt not confirmed - TV reports '$state'"
        Start-Sleep -Milliseconds 1500
    }
    Write-TrayLog "  -> screen may still be ON (TV did not confirm screen off)"
}

# Undoes Hide-TVScreen. Also checks the TV itself when -CheckTV is given, so a
# panel blanked before this instance started (app restarted while locked) is
# restored too.
function Show-TVScreen([switch]$CheckTV) {
    if (-not $script:ScreenBlanked -and -not $CheckTV) { return }
    if (-not (Test-TVConnected)) { return }
    if (-not $script:ScreenBlanked) {
        if ((Get-TVPowerState (Invoke-TVRequest "com.webos.service.tvpower/power/getPowerState")) -ne "Screen Off") { return }
    }
    $state = Get-TVPowerState (Invoke-TVCli @("-screenOn"))
    $script:ScreenBlanked = $false
    Write-TrayLog "  screen on sent, TV reports '$state'"
}

function Get-TVPowerState($Json) {
    if (-not $Json) { return $null }
    foreach ($device in $Json.PSObject.Properties) { return $device.Value.payload.state }
}

function Switch-TVState {
    $CurrentState = Get-TVState
    if ($CurrentState -eq "1") {
        Switch-ToHDMI2
    } else {
        Switch-ToHDMI1
    }
}

# Refreshes tray tooltip + menu text/checkmarks to reflect the active HDMI input, Scroll Lock state, and current labels
function Update-TrayStatus {
    $state = Get-TVState
    $activeLabel = if ($state -eq "1") { $script:Config.Hdmi1Label } else { $script:Config.Hdmi2Label }
    # Deskflow's real cursor-lock state, not the Scroll Lock light (they can disagree).
    $scrollLocked = Test-CursorLocked
    $notifyIcon.Text = "LG TV: {0} active (HDMI{1})" -f $activeLabel, $state
    $itemHdmi1.Text = "Switch to $($script:Config.Hdmi1Label) (HDMI 1)"
    $itemHdmi2.Text = "Switch to $($script:Config.Hdmi2Label) (HDMI 2)"
    $itemHdmi1.Checked = ($state -eq "1")
    $itemHdmi2.Checked = ($state -eq "2")
    $itemScrollLock.Text = "Cursor locked to PC: $(if ($scrollLocked) { 'On' } else { 'Off' })"
    $itemScrollLock.Checked = $scrollLocked
    if ($itemRequireCable) { $itemRequireCable.Checked = [bool]$script:Config.RequireCable }
}

# Setup Tray Icon
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
try {
    # Try to extract LGTV Companion icon if it exists, otherwise fallback to powershell icon
    if (Test-Path $LgtvPath) {
        $notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($LgtvPath)
    } else {
        $notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$pshome\powershell.exe")
    }
} catch {
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
}

$notifyIcon.Text = "LG TV Companion App"
$notifyIcon.Visible = $true

# Setup Context Menu
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$itemToggle = $contextMenu.Items.Add("Toggle TV (Ctrl+Alt+P)")
$itemToggle.add_Click({ Switch-TVState })

$itemHdmi1 = $contextMenu.Items.Add("Switch to HDMI 1")
$itemHdmi1.add_Click({ Switch-ToHDMI1 })

$itemHdmi2 = $contextMenu.Items.Add("Switch to HDMI 2")
$itemHdmi2.add_Click({ Switch-ToHDMI2 })

$contextMenu.Items.Add("-") | Out-Null # Separator

$itemScrollLock = New-Object System.Windows.Forms.ToolStripMenuItem "Scroll Lock"
$itemScrollLock.add_Click({
    # Sets Deskflow's lock to the opposite of its real state, rather than
    # blind-toggling Scroll Lock (which inverts when the two disagree).
    Set-ScrollLock (-not (Test-CursorLocked))
    Update-TrayStatus
})
$contextMenu.Items.Add($itemScrollLock) | Out-Null

$contextMenu.Items.Add("-") | Out-Null # Separator

# Settings Submenu
$settingsMenu = New-Object System.Windows.Forms.ToolStripMenuItem "Settings"

$itemRename1 = $settingsMenu.DropDownItems.Add("Rename HDMI 1...")
$itemRename1.add_Click({ Set-HdmiLabel 1 })

$itemRename2 = $settingsMenu.DropDownItems.Add("Rename HDMI 2...")
$itemRename2.add_Click({ Set-HdmiLabel 2 })

$settingsMenu.DropDownItems.Add("-") | Out-Null # Separator

$itemRequireCable = New-Object System.Windows.Forms.ToolStripMenuItem "Only switch when TV cable is connected"
$itemRequireCable.CheckOnClick = $true
$itemRequireCable.Checked = [bool]$script:Config.RequireCable
$itemRequireCable.ToolTipText = "On: leave the TV alone unless this PC is plugged into it. Off: switch whenever the TV is reachable on the network."
$itemRequireCable.add_Click({
    $script:Config.RequireCable = $itemRequireCable.Checked
    Save-Config $script:Config
    Update-TrayStatus
})
$settingsMenu.DropDownItems.Add($itemRequireCable) | Out-Null

$itemNotifyAll = New-Object System.Windows.Forms.ToolStripMenuItem "Notify on every TV action"
$itemNotifyAll.CheckOnClick = $true
$itemNotifyAll.Checked = [bool]$script:Config.NotifyAll
$itemNotifyAll.ToolTipText = "Show a notification for each action, with the rule that was applied. Everything is also written to tray_debug.txt."
$itemNotifyAll.add_Click({
    $script:Config.NotifyAll = $itemNotifyAll.Checked
    Save-Config $script:Config
})
$settingsMenu.DropDownItems.Add($itemNotifyAll) | Out-Null

$settingsMenu.DropDownItems.Add("-") | Out-Null # Separator

$itemStartup = New-Object System.Windows.Forms.ToolStripMenuItem "Start with Windows"
$itemStartup.CheckOnClick = $true
$itemStartup.Checked = Test-StartupEnabled
$itemStartup.add_Click({ Set-StartupEnabled $itemStartup.Checked })
$settingsMenu.DropDownItems.Add($itemStartup) | Out-Null

$contextMenu.Items.Add($settingsMenu) | Out-Null

$contextMenu.Items.Add("-") | Out-Null # Separator

$itemExit = $contextMenu.Items.Add("Exit")
$itemExit.add_Click({
    $notifyIcon.Visible = $false
    $script:hotkeyManager.Dispose()
    $script:InstanceMutex.ReleaseMutex()
    [Microsoft.Win32.SystemEvents]::remove_SessionSwitch($sessionSwitchHandler)
    [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($displaySettingsHandler)
    [System.Windows.Forms.Application]::Exit()
})

$contextMenu.add_Opening({ Update-TrayStatus })

$notifyIcon.ContextMenuStrip = $contextMenu
Update-TrayStatus

# Register Global Hotkey
# Ctrl (2) + Alt (1) = 3
$script:hotkeyManager = New-Object HotkeyManager
$MOD_ALT = 1
$MOD_CONTROL = 2
$Modifiers = $MOD_ALT -bor $MOD_CONTROL
$VK_P = 80
$hotkeyRegistered = $script:hotkeyManager.Register(1, $Modifiers, $VK_P)

if (-not $hotkeyRegistered) {
    [System.Windows.Forms.MessageBox]::Show("Failed to register global hotkey Ctrl+Alt+P. It might be in use by another application. Try quitting the old script if it is running.", "LG TV Tray App", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
}

$script:hotkeyManager.add_HotkeyPressed({
    Switch-TVState
})

# Register SessionSwitch Event for Win+L (Screen Lock) using native .NET event
$sessionSwitchHandler = [Microsoft.Win32.SessionSwitchEventHandler]{
    param($sender, $e)
    # The cable policy is enforced inside Switch-ToHDMI1/2, so these just ask.
    if ($e.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionLock) {
        # Locking: nothing should show on the TV - not the Mac, not the lock
        # screen. Blank the panel (see Hide-TVScreen).
        Write-TrayLog "event: PC locked"
        Write-TrayLog "rule: lock -> TV to PC input, then screen off (only if PC cabled to TV)"
        # Only when this PC is actually on the TV (honours RequireCable).
        # Uncabled, the TV is showing something else and is not ours to touch.
        if (Test-SwitchAllowed) {
            Hide-TVScreen
        } else {
            Write-TrayLog "  skipped: this PC is not cabled to the TV"
        }
    } elseif ($e.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionUnlock) {
        Write-TrayLog "event: PC unlocked"
        Write-TrayLog "rule: unlock -> screen on if dark; TV to PC (HDMI2) if cabled; never wakes a sleeping TV"
        # Light the panel first, regardless of the cable gate: if we blanked it,
        # we must not leave it dark.
        Show-TVScreen -CheckTV
        # Coming back - take the TV to this PC. This replaces LGTV Companion's
        # own unconditional SetHdmiInput-on-resume, which had no cable check.
        # If no switch was sent, Scroll Lock may still hold whatever the lock
        # screen left it at, so re-derive it from the TV.
        if (-not (Switch-ToHDMI2 -Silent)) { Sync-ScrollLockFromTV }
    }
}
[Microsoft.Win32.SystemEvents]::add_SessionSwitch($sessionSwitchHandler)

# Cable-disconnect detection. DisplaySettingsChanged also fires for resolution
# changes, DPI changes and monitor rearrangement, so act only on a real
# connected -> disconnected transition rather than on every event.
$script:LastCableState = Test-TVCableConnected
$displaySettingsHandler = [EventHandler]{
    param($sender, $e)
    $nowConnected = Test-TVCableConnected
    if ($script:LastCableState -ne $nowConnected) {
        Write-TrayLog "event: TV cable $(if ($nowConnected) { 'connected' } else { 'disconnected' })"
        if (-not $nowConnected) { Write-TrayLog "rule: cable unplugged -> TV to HDMI2 (dead input) so nothing shows" }
        else { Write-TrayLog "rule: cable plugged in -> no action" }
    }
    if ($script:LastCableState -and -not $nowConnected) {
        Hide-TVContent
    }
    $script:LastCableState = $nowConnected
    Update-TrayStatus
}
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($displaySettingsHandler)

# Initial sync on launch (covers cold boot, since this app autostarts at logon).
# Replaces LGTV Companion's SetHdmiInput-on-resume, which fired with no cable
# check. Cable-gated: if this PC is not plugged into the TV, leave the TV alone.
# Remove this line if you would rather nothing switched at startup.
Write-TrayLog "--- tray app started (pid $PID) ---"
Write-TrayLog "rule: app start -> screen on if dark; TV to PC (HDMI2) if cabled"
Show-TVScreen -CheckTV
if (-not (Switch-ToHDMI2 -Silent)) { Sync-ScrollLockFromTV }

# Shows queued action notices as one notification. Text is capped at 255
# chars by Windows, so a long sequence is split and the rest shown on the next
# ticks.
function Show-QueuedNotices {
    $line = $null
    $lines = New-Object System.Collections.Generic.List[string]
    while ($script:NoticeQueue.TryDequeue([ref]$line)) { $lines.Add($line) }
    if ($lines.Count -gt 0) {
        $chunk = ""
        foreach ($l in $lines) {
            if ($l.Length -gt 240) { $l = $l.Substring(0, 237) + "..." }
            if (($chunk.Length + $l.Length + 1) -gt 250) { $script:NoticeBacklog.Add($chunk); $chunk = "" }
            $chunk = if ($chunk) { "$chunk`n$l" } else { $l }
        }
        if ($chunk) { $script:NoticeBacklog.Add($chunk) }
    }
    if ($script:NoticeBacklog.Count -gt 0) {
        $text = $script:NoticeBacklog[0]
        $script:NoticeBacklog.RemoveAt(0)
        $notifyIcon.ShowBalloonTip(5000, "LG TV", $text, [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

# Retries a pending cursor-lock change (see Set-ScrollLock): checks every 1.5 s,
# presses again at most every $ScrollPressSettleSeconds s, up to 6 times. Bounded so it never fights a manual Scroll Lock press for long;
# unlock re-syncs anyway.
$scrollLockTimer = New-Object System.Windows.Forms.Timer
$scrollLockTimer.Interval = 1500
$scrollLockTimer.add_Tick({
    Show-QueuedNotices
    if ($null -eq $script:ScrollLockTarget) { return }
    if ($script:ScrollLockTarget -and -not (Test-CursorOnPC)) {
        # Still on the Mac: keep it free (a lock now would trap it there).
        if ((Test-CursorLocked) -and ((Get-Date) - $script:LastScrollPress).TotalSeconds -ge $ScrollPressSettleSeconds) {
            [HotkeyManager]::ToggleScrollLock()
            $script:LastScrollPress = Get-Date
        }
        return
    }
    if ($script:LockDeferred) {
        $script:LockDeferred = $false
        Write-TrayLog "  cursor back on the PC - locking it there now"
        Set-ScrollLock $true
        return
    }
    $want = if ($script:ScrollLockTarget) { "locked" } else { "unlocked" }
    if ((Test-CursorLocked) -eq $script:ScrollLockTarget) {
        Write-TrayLog "  cursor now $want after $($script:ScrollLockRetries) retries"
        $script:ScrollLockTarget = $null
        Update-TrayStatus
        return
    }
    if ($script:ScrollLockRetries -ge 6) {
        Write-TrayLog "  cursor still not $want after 6 retries - giving up until next unlock"
        $script:ScrollLockTarget = $null
        return
    }
    # Deskflow can take ~3 s to process a press around the lock screen; a
    # retry fired before it lands overshoots (locked -> unlocked -> locked was
    # seen in the log). Only press again once the last press has had time to
    # show up in Deskflow's log.
    if (((Get-Date) - $script:LastScrollPress).TotalSeconds -lt $ScrollPressSettleSeconds) { return }
    $script:ScrollLockRetries++
    [HotkeyManager]::ToggleScrollLock()
    $script:LastScrollPress = Get-Date
})
$scrollLockTimer.Start()

# Start Application Loop
[System.Windows.Forms.Application]::Run()
