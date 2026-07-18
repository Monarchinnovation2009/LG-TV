Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Paths and configuration
$LgtvPath = "C:\Program Files\LGTV Companion\LGTV Companion.exe"
$StateFile = "$env:TEMP\lgtv_state.txt"
$ConfigFile = "$env:APPDATA\LGTVTrayApp\config.json"
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
    $default = @{ Hdmi1Label = "Mac"; Hdmi2Label = "PC" }
    if (Test-Path $ConfigFile) {
        try {
            $loaded = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
            return @{ Hdmi1Label = $loaded.Hdmi1Label; Hdmi2Label = $loaded.Hdmi2Label }
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
function Test-TVConnected {
    if ([System.Windows.Forms.Screen]::AllScreens.Count -gt 1) {
        return $true
    }
    try {
        $monitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue
        foreach ($monitor in $monitors) {
            $name = [System.Text.Encoding]::ASCII.GetString($monitor.UserFriendlyName).Trim(" `0")
            $mfg = [System.Text.Encoding]::ASCII.GetString($monitor.ManufacturerName).Trim(" `0")
            if ($name -match "LG" -or $mfg -match "GSM") {
                return $true
            }
        }
    } catch {}
    return $false
}

# TV Action Functions
function Switch-ToHDMI1 {
    if ([System.Windows.Forms.Control]::IsKeyLocked([System.Windows.Forms.Keys]::Scroll)) { [HotkeyManager]::ToggleScrollLock(); Start-Sleep -Milliseconds 200 }
    if (Test-TVConnected) {
        Start-Process $LgtvPath -ArgumentList "-sethdmi1" -WindowStyle Hidden
        Set-TVState "1"
        Start-Sleep -Seconds 1
    }
    Update-TrayStatus
}

function Switch-ToHDMI2 {
    if (-not [System.Windows.Forms.Control]::IsKeyLocked([System.Windows.Forms.Keys]::Scroll)) { [HotkeyManager]::ToggleScrollLock() }
    if (Test-TVConnected) {
        Start-Process $LgtvPath -ArgumentList "-sethdmi2" -WindowStyle Hidden
        Set-TVState "2"
    }
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

# Refreshes tray tooltip + menu text/checkmarks to reflect the active HDMI input and current labels
function Update-TrayStatus {
    $state = Get-TVState
    $activeLabel = if ($state -eq "1") { $script:Config.Hdmi1Label } else { $script:Config.Hdmi2Label }
    $notifyIcon.Text = "LG TV: {0} active (HDMI{1})" -f $activeLabel, $state
    $itemHdmi1.Text = "Switch to $($script:Config.Hdmi1Label) (HDMI 1)"
    $itemHdmi2.Text = "Switch to $($script:Config.Hdmi2Label) (HDMI 2)"
    $itemHdmi1.Checked = ($state -eq "1")
    $itemHdmi2.Checked = ($state -eq "2")
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

# Settings Submenu
$settingsMenu = New-Object System.Windows.Forms.ToolStripMenuItem "Settings"

$itemRename1 = $settingsMenu.DropDownItems.Add("Rename HDMI 1...")
$itemRename1.add_Click({ Set-HdmiLabel 1 })

$itemRename2 = $settingsMenu.DropDownItems.Add("Rename HDMI 2...")
$itemRename2.add_Click({ Set-HdmiLabel 2 })

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
    [Microsoft.Win32.SystemEvents]::remove_SessionSwitch($sessionSwitchHandler)
    [System.Windows.Forms.Application]::Exit()
})

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
    if ($e.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionLock) {
        Switch-ToHDMI2
    }
}
[Microsoft.Win32.SystemEvents]::add_SessionSwitch($sessionSwitchHandler)

# Start Application Loop
[System.Windows.Forms.Application]::Run()
