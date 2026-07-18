$LgtvPath = "C:\Program Files\LGTV Companion\LGTV Companion.exe"
$StateFile = "$env:TEMP\lgtv_state.txt"

if (-not (Test-Path $StateFile)) { Set-Content -Path $StateFile -Value "1" }
$CurrentState = Get-Content -Path $StateFile
$wsh = New-Object -ComObject WScript.Shell

if ($CurrentState -eq "1") {
    if (-not [console]::ScrollLock) { $wsh.SendKeys("{SCROLLLOCK}"); Start-Sleep -Milliseconds 200 }
    Start-Process $LgtvPath -ArgumentList "-sethdmi2" -WindowStyle Hidden
    Set-Content -Path $StateFile -Value "2"
} else {
    Start-Process $LgtvPath -ArgumentList "-sethdmi1" -WindowStyle Hidden
    Set-Content -Path $StateFile -Value "1"
    Start-Sleep -Seconds 1
    if ([console]::ScrollLock) { $wsh.SendKeys("{SCROLLLOCK}") }
}
