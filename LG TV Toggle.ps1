$LgtvPath = "C:\Program Files\LGTV Companion\LGTV Companion.exe"
$StateFile = "$env:TEMP\lgtv_state.txt"
$CompanionConfigFile = "C:\ProgramData\LGTV Companion\config.json"
$PingTimeoutMs = 400
$PingAttempts = 2

# Reads the TV address from LGTV Companion's own config so the IP is defined in
# one place only.
function Get-TVAddress {
    try {
        $cfg = Get-Content -Path $CompanionConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($entry in $cfg.PSObject.Properties) {
            if ($entry.Name -eq "LGTV Companion") { continue }
            $ip = $entry.Value.IP
            if (-not [string]::IsNullOrWhiteSpace($ip)) { return $ip }
        }
    } catch {}
    return $null
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

# Bail out before touching Scroll Lock or the state file, so neither drifts out
# of sync with the TV's real input when the TV is unreachable.
if (-not (Test-TVConnected)) { exit 1 }

if (-not (Test-Path $StateFile)) { Set-Content -Path $StateFile -Value "1" }
$CurrentState = (Get-Content -Path $StateFile -Raw).Trim()
$wsh = New-Object -ComObject WScript.Shell

if ($CurrentState -eq "1") {
    Start-Process $LgtvPath -ArgumentList "-sethdmi2" -WindowStyle Hidden
    Set-Content -Path $StateFile -Value "2"
    if (-not [console]::ScrollLock) { $wsh.SendKeys("{SCROLLLOCK}") }
} else {
    Start-Process $LgtvPath -ArgumentList "-sethdmi1" -WindowStyle Hidden
    Set-Content -Path $StateFile -Value "1"
    Start-Sleep -Seconds 1
    if ([console]::ScrollLock) { $wsh.SendKeys("{SCROLLLOCK}") }
}
