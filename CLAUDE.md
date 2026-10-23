# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small set of Windows PowerShell/VBS scripts that automate switching an LG TV (used as a monitor) between two HDMI inputs — **HDMI 1 (a Mac)** and **HDMI 2 (this Windows PC)** — by driving the third-party [LGTV Companion](https://github.com/JPersson77/LGTVCompanion) CLI. There is no package manager, build step, or test suite; the scripts are run directly by Windows (tray icon autostart or a VBS launcher).

Git repo, remote `origin` = `git@github.com:Monarchinnovation2009/LG-TV.git`, branch `master`.

## Running / iterating

- Run with visible errors: `powershell.exe -ExecutionPolicy Bypass -File "LG TV TrayApp.ps1"`.
- The tray app is single-instance (named mutex `Local\LGTVTrayApp_SingleInstance`); a second launch exits silently. To pick up code changes, Exit the running instance from the tray menu (or kill it) and relaunch via `launch_tray_app.vbs`.
- When killing it from a script, do NOT match on the literal string `TrayApp` in a command that itself contains that string — the filter matches your own shell and kills it. Build the pattern dynamically (`'Tray' + 'App'`).
- Autostart: `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\LGTVTrayApp` → `wscript.exe "...\launch_tray_app.vbs"`, toggled by Settings → "Start with Windows".
- The VBS files are silent launchers for the matching `.ps1`. Edit the `.ps1`, not the `.vbs`.
- `Script for task scedular of PowerShell.txt` is a one-off setup/cleanup script: it regenerates `LG TV Toggle.vbs` and **unregisters** the obsolete `LGTV_Switch_On_Lock` task. It no longer registers a task or embeds toggle logic.
- `tray_debug.txt` (gitignored) is a decision log: every switch request, which gate refused it, and session/cable events. Read it first when a behaviour report comes in.
- Every `Write-TrayLog` line is also a Windows notification when `NotifyAll` is on (config default `true`, Settings → "Notify on every TV action"). Lines are queued (`$script:NoticeQueue`) and shown by `$scrollLockTimer` on the UI thread as one notice per 1.5 s, split at Windows' 255-char limit. Each trigger logs a `rule:` line stating the rule applied, so the user can check behaviour against intent — keep those lines accurate when changing a rule.
- State file `$env:TEMP\lgtv_state.txt`: `"1"` = HDMI1 (Mac), `"2"` = HDMI2 (PC). It is a cache, not truth — the TV's real input is `LGTVcli.exe -request com.webos.applicationManager/getForegroundAppInfo`.

## Architecture

1. **`LG TV TrayApp.ps1`** — the primary app. A persistent `NotifyIcon` running `[System.Windows.Forms.Application]::Run()`, with a global hotkey (Ctrl+Alt+P, embedded C# `HotkeyManager`), tray menu, and Settings submenu (rename HDMI labels, "Only switch when TV cable is connected", "Start with Windows"). Config in `$env:APPDATA\LGTVTrayApp\config.json`: `Hdmi1Label` (default "Mac"), `Hdmi2Label` (default "PC"), `RequireCable` (default `true`).
2. **`LG TV Toggle.ps1`** — a one-shot toggle for external invocation. Has the reachability guard but no cable/input checks and no knowledge of the tray config.

### Switch gates (`Switch-ToHDMI1` / `Switch-ToHDMI2`), cheapest first

0. Manual (non-`-Silent`) switches first call `Wake-TV`, which checks the TV's **power state**, not just ping: in `Active Standby` the TV is off but still answers ping (measured). `Active` → nothing; `Screen Off` → `-screenOn`; anything else or no answer → `-powerOn` (Wake-on-LAN via Companion). Then waits up to `$WakeTimeoutSeconds` (20) for `Active`, plus 4 s for HDMI to re-enumerate. Automatic triggers never wake the TV.
1. `Test-SwitchAllowed` — if `RequireCable`, requires `Test-TVCableConnected` (an active LG/GSM monitor in WMI `WmiMonitorID`; EDID fields can be null, so decode via `Convert-EdidString`).
2. `Test-TVConnected` — raw `System.Net.NetworkInformation.Ping` (400 ms × 2) to the TV IP read from `C:\ProgramData\LGTV Companion\config.json`. Never use `Test-Connection` here: it blocks the UI thread ~9 s when the TV is off.
3. `Test-HdmiInputAvailable` — `LGTVcli.exe -request tv/getExternalInputList` (no `ssap://` prefix). Keys on `connected` only; `hdmiPlugIn` was measured to stay `true` with the cable out. Fails open on query error.

### Scroll Lock = Deskflow cursor lock

The PC is the Deskflow server (layout: PC left, Mac mini right). Deskflow treats Scroll Lock ON as "lock cursor to current screen". So Scroll Lock must follow what the TV shows: **ON while the TV shows the PC** (otherwise the cursor slides onto the invisible Mac and takes keyboard input with it), **OFF while it shows the Mac** (so the cursor can cross).

- **Deskflow's state is read from its log, never from the Scroll Lock light.** Deskflow flips its lock on every Scroll Lock press it sees, independently of the light; one press seen by only one of them (e.g. around the lock screen) left them permanently inverted. `Get-CursorLockState` scans the tail of `C:\ProgramData\Deskflow\deskflow-daemon.log` for `cursor locked/unlocked`, `scroll lock is on` (restart) and `stopped server`; it falls back to the light only if Deskflow isn't running.
- Set only after a command is sent. `Set-ScrollLock` presses Scroll Lock only if Deskflow is in the wrong state, then verifies against the log; a press Deskflow misses stays pending and `$scrollLockTimer` retries it — but never within `$ScrollPressSettleSeconds` (5 s) of the last press, up to 6 times. Around the lock screen Deskflow takes ~3 s to log a press; retrying sooner overshot (locked → unlocked → locked).
- **Deskflow's lock means "lock to the CURRENT screen", not "lock to the PC".** Locking while the cursor was on the Mac trapped keyboard and mouse there for an hour while the TV showed the PC. `Set-ScrollLock $true` therefore checks `Test-CursorOnPC` (last `switch from X to "Y"` in Deskflow's log; `stopped server` = back on the PC; unknown = PC; server name from `computerName=` in `%APPDATA%\Deskflow\Deskflow.conf`). If the cursor is on the Mac, the lock is deferred (`$script:LockDeferred`), the cursor is unlocked if needed so the user can move it back, and `$scrollLockTimer` applies the lock once it is on the PC.
- The app cannot move the cursor back itself: Deskflow ignores injected mouse moves (relative, absolute and `SetCursorPos`) while the cursor is on the Mac. Injected *keys* do reach it (they toggled the lock while on the Mac).
- Injected keys only reach Deskflow while the cursor is on the PC: with the cursor on the Mac, Deskflow forwards them to the Mac. Test live only when the last `switch from` log line ends `to "Harsh"`.
- The tray's "Cursor locked to PC" item shows and sets Deskflow's real state.
- When no switch is sent (unlock/startup refused), `Sync-ScrollLockFromTV` derives it from the TV's real input (`getForegroundAppInfo`): OFF only if confirmed on HDMI1.
- `Switch-ToHDMI1/2` return `$true` only if a command was sent; keep them free of other pipeline output.

### Automatic triggers

- **Lock** → `Hide-TVScreen`: `Hide-TVContent` (HDMI2, cursor locked to PC) then LGTVcli `-screenOff`, so nothing at all shows — HDMI2 alone still shows the Windows lock screen. Only when `Test-SwitchAllowed`. Sets `$script:ScreenBlanked`.
- **Cable disconnect** (`DisplaySettingsChanged`, acting only on a connected→disconnected transition) → `Hide-TVContent`.
- **Unlock** and **startup** → `Show-TVScreen -CheckTV` (`-screenOn` if we blanked it or the TV reports `Screen Off`, regardless of the cable gate), then `Switch-ToHDMI2 -Silent`; if refused, `Sync-ScrollLockFromTV`. Manual switches also call `Show-TVScreen`.
- TV power state: `LGTVcli -request com.webos.service.tvpower/power/getPowerState` → `Active` / `Screen Off`.
- `Hide-TVContent` deliberately bypasses the cable and input gates (a dead input is the goal); it still requires reachability.

LGTV Companion's own `SetHdmiInput` is set to `false` in its config, because it switched to HDMI2 on resume with no cable check; the tray app replaces it.
