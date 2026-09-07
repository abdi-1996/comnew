param(
    [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceExe = Join-Path $sourceDir 'PCRemoteServer.exe'
if (-not (Test-Path $sourceExe)) {
    throw "PCRemoteServer.exe не найден рядом с установщиком: $sourceExe"
}

$targetDir = Join-Path $env:LOCALAPPDATA 'PCRemoteServer'
$targetExe = Join-Path $targetDir 'PCRemoteServer.exe'
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

# Stop every older PCRemoteServer copy before replacing the stable server.
# Two server processes cannot listen on TCP 8765 at the same time.
Get-Process PCRemoteServer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# Preserve an existing stable config. If the freshly downloaded package has a
# config.json beside it and the stable location has none, carry it forward.
$sourceConfig = Join-Path $sourceDir 'config.json'
$targetConfig = Join-Path $targetDir 'config.json'
if ((Test-Path $sourceConfig) -and -not (Test-Path $targetConfig)) {
    Copy-Item $sourceConfig $targetConfig -Force
}

Copy-Item $sourceExe $targetExe -Force

# Add a port-based rule. Unlike an app-path rule, this survives future EXE
# replacements and is the reason the same stable server can be updated safely.
$ruleName = "PC Remote Stable TCP $Port"
$adminScript = @"
`$ErrorActionPreference = 'Stop'
Get-NetFirewallRule -DisplayName '$ruleName' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any | Out-Null
"@
$temp = Join-Path $env:TEMP 'PCRemote_Firewall_Stable.ps1'
Set-Content -Path $temp -Value $adminScript -Encoding UTF8
Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$temp`""
Set-Content -Path (Join-Path $targetDir "firewall_${Port}.ok") -Value "ok" -Encoding ASCII

# Stable Startup shortcut: future updates replace the EXE at this same path.
$startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\PC Remote Server.lnk'
$ws = New-Object -ComObject WScript.Shell
$shortcut = $ws.CreateShortcut($startup)
$shortcut.TargetPath = $targetExe
$shortcut.WorkingDirectory = $targetDir
$shortcut.WindowStyle = 7
$shortcut.Save()

Start-Process $targetExe
Write-Host "PC Remote Server установлен: $targetExe"
Write-Host "Firewall TCP port: $Port"
