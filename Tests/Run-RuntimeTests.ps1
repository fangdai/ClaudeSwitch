#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Scratch)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testDir=Join-Path ([IO.Path]::GetFullPath($Scratch)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDir)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ClaudeSwitch.ps1'),[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'GUI syntax invalid'}
foreach($name in @('Quote-Arg','Start-EngineJob','Read-JobLines','Pump-Jobs','Get-FailMessage','Read-EngineError')){
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 . ([scriptblock]::Create($fn.Extent.Text))
}
$script:passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw ('FAIL '+$name)};$script:passed++;Write-Host ('PASS '+$name)}
$script:logLines=New-Object System.Collections.ArrayList
function Gui-Log([string]$message){[void]$script:logLines.Add($message)}
$StoreDir=Join-Path $testDir 'store';$DataDir=Join-Path $testDir 'desktop';$ClaudeJson=Join-Path $testDir 'claude.json';$NoAppControl=$true
$Utf8NoBom=New-Object Text.UTF8Encoding($false)
$AppState=@{Jobs=(New-Object System.Collections.ArrayList);StepOrder=@();StepUi=@{}}
$Engine=Join-Path $testDir 'fake-engine.ps1'
$fake=@'
param($DataDir,$StoreDir,$ClaudeJson,$ProgressFile,$OutFile,[switch]$NoAppControl,$Action)
[Console]::Error.WriteLine('Engine startup failed; sk-FAKE_SECRET Bearer FAKE_BEARER')
exit 17
'@
[IO.File]::WriteAllText($Engine,$fake,$Utf8NoBom)
$script:finished=$null
$job=Start-EngineJob @('-Action','Switch') $null {param($completed)$script:finished=$completed}
$deadline=(Get-Date).AddSeconds(20)
while($AppState.Jobs.Count -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100;Pump-Jobs}
Check ($null -ne $script:finished -and $script:finished.Exit -eq 17) 'Abnormal child exit reaches its completion callback'
$message=Get-FailMessage $script:finished
Check ($message.Contains('17') -and $message.Contains('Engine startup failed')) 'Startup stderr and exit code reach the UI without progress output'
Check (-not $message.Contains('FAKE_SECRET') -and -not $message.Contains('FAKE_BEARER')) 'Diagnostic output masks secrets'
Check (@($script:logLines|Where-Object {$_ -match 'engine exit 17'}).Count -eq 1) 'Child failure is recorded in the GUI log'
$progress=Join-Path $testDir 'error.jsonl'
[IO.File]::WriteAllText($progress,'{"step":"close","state":"error","message":"Cannot close Desktop"}'+"`r`n",$Utf8NoBom)
$dropped=@{Lines=@();Prog=$progress;Out='';Exit=1}
Check ((Get-FailMessage $dropped) -eq 'Cannot close Desktop') 'Progress-file fallback recovers errors missed by the timer'
$out=Join-Path $testDir 'error.json'
[IO.File]::WriteAllText($out,'{"ok":false,"message":"Structured failure"}',$Utf8NoBom)
Check ((Get-FailMessage @{Lines=@();Prog='';Out=$out;Exit=1}) -eq 'Structured failure') 'Structured error output is used if progress is unavailable'
$out=Join-Path $testDir 'real-engine-error.json'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ClaudeSwitch.Engine.ps1') -Action Switch -TargetAccount invalid -StoreDir $StoreDir -DataDir $DataDir -CliConfigDir (Join-Path $testDir 'cli') -CliConfigFile (Join-Path $testDir 'cli.json') -NoAppControl -OutFile $out 2>&1 | Out-Null
$code=$LASTEXITCODE
$errorData=Get-Content -LiteralPath $out -Raw -Encoding UTF8|ConvertFrom-Json
Check ($code -eq 1 -and $errorData.ok -eq $false -and [bool]$errorData.message) 'Real engine emits structured errors on failure'
Write-Host ('RESULT: '+$script:passed+' passed')
