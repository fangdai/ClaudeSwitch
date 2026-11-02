#requires -Version 5.1
<#
  Gỡ Claude Switch: xóa shortcut và thư mục app. Mặc định GIỮ các tài khoản đã lưu (profiles) và bản sao lưu.
  Thêm -RemoveProfiles để xóa luôn toàn bộ dữ liệu của công cụ (không đụng vào dữ liệu của Claude).
#>
param(
    [string]$InstallDir,
    [string]$DesktopDir,
    [string]$StoreDir,
    [switch]$RemoveProfiles
)
$ErrorActionPreference = 'Stop'
if (-not $StoreDir)   { $StoreDir = Join-Path $env:LOCALAPPDATA 'ClaudeSwitch' }
if (-not $InstallDir) { $InstallDir = Join-Path $StoreDir 'app' }
if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath('Desktop') }

try {
    # dung ban dang chay (neu co) de khong bi khoa file
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like ('*' + $InstallDir + '*ClaudeSwitch.ps1*') -and $_.ProcessId -ne $PID } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }

    $lnk = Join-Path $DesktopDir 'Claude Switch.lnk'
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Host 'Đã xóa shortcut.' }
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force; Write-Host 'Đã xóa thư mục ứng dụng.' }
    if ($RemoveProfiles) {
        foreach ($d in 'profiles', 'backups', 'logs', 'session-backups') {
            $p = Join-Path $StoreDir $d
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        foreach ($f in 'settings.json', 'synced.json', 'pending-add.json') {
            $p = Join-Path $StoreDir $f
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
        Write-Host 'Đã xóa các tài khoản đã lưu và sao lưu của công cụ.'
    } else {
        Write-Host ('Đã giữ lại tài khoản đã lưu tại: ' + $StoreDir)
    }
    Write-Host 'Gỡ cài đặt xong.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host ('Gỡ cài đặt không thành công: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
