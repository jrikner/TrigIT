# SPDX-License-Identifier: GPL-3.0-or-later
# Runs the packaged spike in TrigIT-Windows/ with no Swift on the PATH, against
# Art-Net Timecode sent on this machine, and checks that the example Set fired.
# Run after scripts/package-windows.ps1. CI and the release workflow both use it.

$ErrorActionPreference = "Stop"
Set-Location TrigIT-Windows
$env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
.\TrigITWindows.exe --help
if ($LASTEXITCODE -ne 0) { exit 1 }
$spike = Start-Process .\TrigITWindows.exe -PassThru -NoNewWindow `
  -ArgumentList 'windows-spike-example.trigit', '--duration', '8', '--report', 'ci-smoke-report.txt', '--no-browser'
Start-Sleep -Seconds 2
$udp = New-Object System.Net.Sockets.UdpClient
$clock = [Diagnostics.Stopwatch]::StartNew()
# Three seconds of 30 fps Art-Net Timecode from 00:00:09:00, across Song 1's start at 00:00:10:00.
for ($n = 0; $n -lt 90; $n++) {
  $f = 270 + $n
  $packet = [byte[]](0x41, 0x72, 0x74, 0x2D, 0x4E, 0x65, 0x74, 0x00, 0x00, 0x97, 0x00, 14, 0x00, 0x00,
                     ($f % 30), ([math]::Floor($f / 30) % 60), 0, 0, 3)
  [void]$udp.Send($packet, $packet.Length, '127.0.0.1', 6454)
  while ($clock.Elapsed.TotalMilliseconds -lt ($n + 1) * 1000 / 30) { }
}
# The browser UI answers on loopback and shows the Song that just fired.
$page = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:7319/
if ($page.Content -notmatch 'fetch\("/status"') { throw "the UI page is missing" }
$status = Invoke-RestMethod http://127.0.0.1:7319/status
$status | ConvertTo-Json -Depth 4
if ($status.fired -ne 1) { throw "the UI status does not show the fire" }
if (-not $spike.WaitForExit(30000)) { $spike.Kill(); throw "the spike did not stop by itself" }
Get-Content ci-smoke-report.txt
if (-not (Select-String -Path ci-smoke-report.txt -Pattern 'Songs fired: 1 ' -Quiet)) { throw "Song 1 did not fire" }
Remove-Item ci-smoke-report.txt # not part of the package
