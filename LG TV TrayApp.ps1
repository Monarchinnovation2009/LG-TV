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
# Deskflow writes every cursor-lock change here; it is the source of truth for
# whether the cursor is locked (see Get-CursorLockState).
$DeskflowLogFile = "C:\ProgramData\Deskflow\deskflow-daemon.log"
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
}

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
    $default = @{ Hdmi1Label = "Mac"; Hdmi2Label = "PC"; RequireCable = $true }
    if (Test-Path $ConfigFile) {
        try {
            $loaded = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
            return @{
                Hdmi1Label = if ($loaded.Hdmi1Label) { $loaded.Hdmi1Label } else { $default.Hdmi1Label }
                Hdmi2Label = if ($loaded.Hdmi2Label) { $loaded.Hdmi2Label } else { $default.Hdmi2Label }
                # Absent from configs written before this option existed.
                RequireCable = if ($null -ne $loaded.RequireCable) { [bool]$loaded.RequireCable } else { $default.RequireCable }
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
function Invoke-TVRequest($Endpoint) {
    $out = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $CliPath -ArgumentList "-request", $Endpoint `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $out
        if (-not $proc.WaitForExit($CliTimeoutMs)) {
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
    if ((Test-CursorLocked) -ne $On) {
        [HotkeyManager]::ToggleScrollLock()
        Start-Sleep -Milliseconds 300
    }
    if ((Test-CursorLocked) -eq $On) {
        $script:ScrollLockTarget = $null
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

function Show-TVUnreachable {
    $notifyIcon.ShowBalloonTip(3000, "LG TV", "TV is not reachable - input unchanged.", [System.Windows.Forms.ToolTipIcon]::Info)
}

# Central policy gate for every switch, manual or automatic. Checked before the
# ping because it is local and cheap, so an uncabled PC never waits on the network.
function Test-SwitchAllowed {
    if (-not $script:Config.RequireCable) { return $true }
    return (Test-TVCableConnected)
}

function Show-NoCable {
    $notifyIcon.ShowBalloonTip(3000, "LG TV", "This PC is not connected to the TV by cable - input unchanged. Settings > 'Only switch when TV cable is connected' turns this off.", [System.Windows.Forms.ToolTipIcon]::Info)
}

function Show-InputEmpty($Label, $Number) {
    $notifyIcon.ShowBalloonTip(3000, "LG TV", "Nothing is plugged into HDMI $Number ($Label) - input unchanged.", [System.Windows.Forms.ToolTipIcon]::Warning)
}

# TV Action Functions
# Scroll Lock is set only AFTER the TV is confirmed reachable and the command is
# sent; setting it first made the LED report an input change that never happened.
# Three gates, cheapest first: cable policy, then reachability, then whether the
# target input has anything plugged into it.
function Switch-ToHDMI1([switch]$Silent) {
    Write-TrayLog "Switch-ToHDMI1 requested (silent=$Silent)"
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
    Write-TrayLog "  sending -sethdmi1"
    Start-Process $LgtvPath -ArgumentList "-sethdmi1" -WindowStyle Hidden
    Set-TVState "1"
    Start-Sleep -Seconds 1
    Set-ScrollLock $false
    Update-TrayStatus
    return $true
}

function Switch-ToHDMI2([switch]$Silent) {
    Write-TrayLog "Switch-ToHDMI2 requested (silent=$Silent)"
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
    Write-TrayLog "  sending -sethdmi2"
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
        # Locking this PC means moving over to the Mac via Deskflow: hand the TV
        # to the Mac and release the cursor (Scroll Lock OFF). Hiding on lock
        # left Scroll Lock ON and trapped the cursor on the locked PC.
        Write-TrayLog "event: session locked"
        # Only when this PC is actually on the TV (honours RequireCable).
        # Uncabled, the TV is showing something else and is not ours to touch.
        if (Test-SwitchAllowed) {
            # Mac off or unplugged: fall back to hiding rather than leaving the
            # locked PC's input up.
            if (-not (Switch-ToHDMI1 -Silent)) { Hide-TVContent }
        } else {
            Write-TrayLog "  skipped: this PC is not cabled to the TV"
        }
    } elseif ($e.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionUnlock) {
        Write-TrayLog "event: session unlocked"
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
if (-not (Switch-ToHDMI2 -Silent)) { Sync-ScrollLockFromTV }

# Retries a pending cursor-lock change (see Set-ScrollLock) every 1.5 s for up
# to 30 s. Bounded so it never fights a manual Scroll Lock press for long;
# unlock re-syncs anyway.
$scrollLockTimer = New-Object System.Windows.Forms.Timer
$scrollLockTimer.Interval = 1500
$scrollLockTimer.add_Tick({
    if ($null -eq $script:ScrollLockTarget) { return }
    $want = if ($script:ScrollLockTarget) { "locked" } else { "unlocked" }
    if ((Test-CursorLocked) -eq $script:ScrollLockTarget) {
        Write-TrayLog "  cursor now $want after $($script:ScrollLockRetries) retries"
        $script:ScrollLockTarget = $null
        Update-TrayStatus
        return
    }
    if ($script:ScrollLockRetries -ge 20) {
        Write-TrayLog "  cursor still not $want after 20 retries - giving up until next unlock"
        $script:ScrollLockTarget = $null
        return
    }
    $script:ScrollLockRetries++
    [HotkeyManager]::ToggleScrollLock()
})
$scrollLockTimer.Start()

# Start Application Loop
[System.Windows.Forms.Application]::Run()
