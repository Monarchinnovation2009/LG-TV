# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small set of Windows PowerShell/VBS scripts that automate switching an LG TV (used as a monitor) between two HDMI inputs — HDMI 1 (this Windows PC) and HDMI 2 (a Mac connected to the same TV) — by driving the third-party [LGTV Companion](https://github.com/JPersson77/LGTVCompanion) CLI (`LGTV Companion.exe`). This is not a buildable/testable software project — there is no package manager, build step, or test suite. It's a handful of standalone scripts run directly by Windows (via Task Scheduler, a tray icon, or a VBS launcher).

Not currently a git repository.

## Running / iterating on the scripts

- Run a script directly to test a change: `powershell.exe -ExecutionPolicy Bypass -File "LG TV TrayApp.ps1"` (add `-WindowStyle Hidden` only when you don't need to see errors/output).
- The VBS files (`launch_tray_app.vbs`, `launch_toggle.vbs`, `LG TV Toggle.vbs`) are silent launchers — they just shell out to the corresponding `.ps1` with `-WindowStyle Hidden` so no console window flashes. Edit the `.ps1`, not the `.vbs`, when changing behavior.
- `Script for task scedular of PowerShell.txt` is a one-off setup script (not itself invoked at runtime) that generates `LG TV Toggle.ps1` / `LG TV Toggle.vbs` from an embedded here-string and registers a Task Scheduler task (`LGTV_Switch_On_Lock`, trigger: `OnLock`, runs as SYSTEM). If you edit the toggle logic, keep this generator script's embedded copy in sync or it will overwrite your changes next time it's run.
- State persists across script runs in `$env:TEMP\lgtv_state.txt` (`"1"` = HDMI1/PC, `"2"` = HDMI2/Mac). Delete this file to reset state during testing.

## Architecture

There are **two independent implementations** of the same HDMI-toggle idea — know which one you're editing:

1. **`LG TV TrayApp.ps1`** — the primary, actively developed app. Runs persistently as a system-tray icon (`NotifyIcon` + `ContextMenuStrip`) via `[System.Windows.Forms.Application]::Run()`. Provides:
   - A global hotkey (Ctrl+Alt+P) registered through an embedded C# `HotkeyManager` class (P/Invoke `RegisterHotKey`/`WndProc`).
   - Tray menu items to toggle or jump directly to HDMI1/HDMI2, with the active input reflected live in the tray tooltip and a checkmark on the corresponding menu item (`Update-TrayStatus`, called after every state-changing action).
   - A **Settings** submenu to rename what HDMI1/HDMI2 are called (`Set-HdmiLabel`, via a `Microsoft.VisualBasic.Interaction]::InputBox` prompt) and a "Start with Windows" checkable item that writes/removes a `HKCU:\...\Run` registry value pointing at `launch_tray_app.vbs` (`Test-StartupEnabled`/`Set-StartupEnabled`).
   - HDMI labels persist to `$env:APPDATA\LGTVTrayApp\config.json` (`Get-Config`/`Save-Config`) — defaults are `Hdmi1Label = "Mac"`, `Hdmi2Label = "PC"`.
   - A `Microsoft.Win32.SystemEvents.SessionSwitch` handler that forces HDMI2 (PC) whenever the session locks (Win+L).
2. **`LG TV Toggle.ps1`** (+ its `.vbs` launcher) — a simpler, one-shot script meant to be invoked externally (e.g. by the Task Scheduler `OnLock` task), not run persistently. It has no knowledge of the tray app's HDMI labels/config — it only flips Scroll Lock and calls the LGTV Companion CLI.

Both read/write the same `$env:TEMP\lgtv_state.txt` state file, so they interoperate, but toggle logic is duplicated between them (and a third copy lives inside `Script for task scedular of PowerShell.txt`'s generator). A behavior fix usually needs to be applied in more than one place.

### Scroll Lock as a state signal

Scroll Lock's on/off state is deliberately kept in sync with the active HDMI input — OFF while HDMI1 (Mac) is active, ON while HDMI2 (PC) is active — for at-a-glance keyboard-LED feedback of the current input. This sync is implemented differently in each script:

- `LG TV TrayApp.ps1` uses P/Invoke `keybd_event` (`HotkeyManager.ToggleScrollLock()`) and checks state via `[System.Windows.Forms.Control]::IsKeyLocked(...)`. It only toggles when the current lock state doesn't already match the target, and additionally force-releases Ctrl/Alt before toggling (workaround for the hotkey's own modifier keys still being "held" during the callback).
- `LG TV Toggle.ps1` (and the generator's embedded copy) instead uses `WScript.Shell.SendKeys("{SCROLLLOCK}")` and checks `[console]::ScrollLock`.

`Switch-ToHDMI1`/`Switch-ToHDMI2` set Scroll Lock *before* confirming the TV is actually connected (`Test-TVConnected`, which checks for a second screen or an LG/GSM-manufacturer monitor via WMI `WmiMonitorID`), so the lock-key state can drift out of sync with the real HDMI input if the TV isn't reachable — check both the toggle order and the connectivity guard when debugging state-mismatch reports.
