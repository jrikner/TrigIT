# SPDX-License-Identifier: GPL-3.0-or-later
# Packages the Windows spike into TrigIT-Windows/: the .exe plus the Swift
# runtime DLLs it loads, so it runs on a PC without a Swift toolchain, and its
# guide. Run after `swift build -c release --product TrigITWindows`. CI and the
# release workflow both use it.

$ErrorActionPreference = "Stop"
$out = "TrigIT-Windows"
New-Item -ItemType Directory $out | Out-Null
$bin = swift build -c release --show-bin-path
Copy-Item "$bin\TrigITWindows.exe" $out
$runtime = Split-Path (where.exe swiftCore.dll | Select-Object -First 1)
Write-Output "Swift runtime: $runtime"
Copy-Item "$runtime\*.dll" $out
Copy-Item docs\windows-spike.md, docs\windows-spike-example.trigit, LICENSE, NOTICE $out
Get-ChildItem $out | Format-Table Name, Length
