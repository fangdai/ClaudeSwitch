#requires -Version 5.1
param(
    [ValidateSet('login','open')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$CliPath,
    [string]$ConfigDir
)
$ErrorActionPreference='Stop'
if ($Mode -eq 'open') { & $CliPath; return }
if (-not $ConfigDir -or -not(Test-Path -LiteralPath $ConfigDir -PathType Container)) { throw 'Missing login directory.' }
$env:CLAUDE_CONFIG_DIR=$ConfigDir
$env:CLAUDE_SECURESTORAGE_CONFIG_DIR=$ConfigDir
$success=$false
try {
    & $CliPath auth login --claudeai
    $success=($LASTEXITCODE -eq 0)
} finally {
    [IO.File]::WriteAllText((Join-Path $ConfigDir 'complete.json'), ('{"ok":'+$success.ToString().ToLowerInvariant()+'}'),(New-Object Text.UTF8Encoding($false)))
}
if (-not $success) { [void](Read-Host 'Chua dang nhap xong. Nhan Enter de dong cua so va thu lai trong Claude Switch') }
