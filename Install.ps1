#requires -Version 5.1
<#
  Cài đặt Claude Switch: chép ứng dụng vào %LOCALAPPDATA%\ClaudeSwitch\app và tạo shortcut
  "Claude Switch" trên Desktop (phím tắt Ctrl+Alt+C). Không cần quyền quản trị.
#>
param(
    [string]$InstallDir,
    [string]$DesktopDir,
    [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'ClaudeSwitch\app' }
if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath('Desktop') }
$src = $PSScriptRoot

try {
    Write-Host 'Đang cài đặt Claude Switch…' -ForegroundColor Cyan
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    $files = 'ClaudeSwitch.ps1', 'ClaudeSwitch.Engine.ps1', 'ClaudeSwitch.Cli.ps1', 'ClaudeSwitch.CliHost.ps1', 'ClaudeSwitch.CliUI.ps1', 'ClaudeSwitch.Usage.ps1', 'ClaudeSwitch.UsageUI.ps1', 'ClaudeSwitch.bat', 'Uninstall.ps1', 'README.md', 'Go cai dat.bat'
    foreach ($f in $files) {
        $p = Join-Path $src $f
        if (Test-Path -LiteralPath $p) {
            if ((Resolve-Path -LiteralPath $p).Path -ne (Join-Path (Resolve-Path $InstallDir).Path $f)) { Copy-Item -LiteralPath $p -Destination (Join-Path $InstallDir $f) -Force }
        }
    }
    if (-not (Test-Path (Join-Path $InstallDir 'ClaudeSwitch.ps1'))) { throw 'Không chép được ClaudeSwitch.ps1.' }

    New-Item -ItemType Directory -Force $DesktopDir | Out-Null
    $lnk = Join-Path $DesktopDir 'Claude Switch.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + (Join-Path $InstallDir 'ClaudeSwitch.ps1') + '"'
    $sc.WorkingDirectory = $InstallDir
    $sc.WindowStyle = 7
    $sc.Hotkey = 'CTRL+ALT+C'
    $sc.Description = 'Claude Switch - chuyển nhanh giữa 2 account Claude'
    $sc.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',109'
    $sc.Save()

    Write-Host ''
    Write-Host 'Cài đặt xong!' -ForegroundColor Green
    Write-Host ('  Ứng dụng : ' + $InstallDir)
    Write-Host ('  Shortcut : ' + $lnk + '  (phím tắt Ctrl+Alt+C)')
    if (-not $NoLaunch) {
        Start-Process -FilePath $sc.TargetPath -ArgumentList $sc.Arguments -WindowStyle Hidden
    }
    exit 0
} catch {
    Write-Host ('Cài đặt không thành công: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
