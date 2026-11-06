#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Scratch,[switch]$VerifyGui)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$engine=Join-Path $root 'ClaudeSwitch.Engine.ps1'
$scratchRoot=[IO.Path]::GetFullPath($Scratch)
$testDir=Join-Path $scratchRoot ([guid]::NewGuid().ToString('N'))
$cliDir=Join-Path $testDir 'cli-config'
$desktopDir=Join-Path $testDir 'desktop'
$storeDir=Join-Path $testDir 'store'
$configFile=Join-Path $cliDir '.claude.json'
$credFile=Join-Path $cliDir '.credentials.json'
$fakeExe=Join-Path $testDir 'claude.exe'
$utf8=New-Object Text.UTF8Encoding($false)
[void][IO.Directory]::CreateDirectory($cliDir)
[IO.File]::WriteAllText($fakeExe,'fake executable for detection only')
$script:passed=0; $script:failed=0; $script:seq=0
$A='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; $B='bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'
function Check([bool]$condition,[string]$name){if($condition){$script:passed++;Write-Host ('PASS '+$name)}else{$script:failed++;Write-Host ('FAIL '+$name)}}
function Hash([string]$path){if(-not(Test-Path -LiteralPath $path)){return 'missing'};$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path)))}finally{$sha.Dispose()}}
function Run([string]$action,[string]$target='', [string]$failAt='', [string]$exe=$fakeExe){
    $script:seq++
    $out=Join-Path $testDir ('out-'+$script:seq+'.json')
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$engine,'-Action',$action,'-StoreDir',$storeDir,'-DataDir',$desktopDir,'-CliPath',$exe,'-CliConfigDir',$cliDir,'-CliConfigFile',$configFile,'-NoAppControl','-OutFile',$out)
    if($target){$args+=@('-TargetAccount',$target)}
    if($failAt){$args+=@('-FailAt',$failAt)}
    & powershell.exe @args 2>&1 | Out-Null
    $code=$LASTEXITCODE; $obj=$null
    if(Test-Path -LiteralPath $out){$obj=Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json}
    return @{Code=$code;Data=$obj}
}
function WriteAccount([string]$uuid,[bool]$bom=$false){
    $suffix=if($uuid -eq $A){'A'}else{'B'}
    $credentials='{"mcpOAuth":{"keep":"untouched"}, "claudeAiOauth":{"accessToken":"CLI-FAKE-SECRET-'+$suffix+'","refreshToken":"CLI-FAKE-REFRESH-'+$suffix+'","expiresAt":9999999999999,"scopes":["user:inference"]}}'
    $config='{ "counter":9007199254740993,"nested":{"oauthAccount":{"marker":"keep"}},"oauthAccount":{"accountUuid":"'+$uuid+'","emailAddress":"'+$suffix+'@example.test"},"tail":"quote \\\" and braces {}" }'
    [IO.File]::WriteAllText($credFile,$credentials,(New-Object Text.UTF8Encoding($bom)))
    [IO.File]::WriteAllText($configFile,$config,(New-Object Text.UTF8Encoding($bom)))
}
$r=Run 'Status'
Check ($r.Code -eq 0 -and $r.Data.tools.cli -and -not $r.Data.tools.desktop -and -not $r.Data.cli.loggedIn) 'CLI-only auto detection without Desktop data'
$r=Run 'Status' '' '' (Join-Path $testDir 'not-installed.exe')
Check ($r.Code -eq 0 -and -not $r.Data.tools.cli -and -not $r.Data.tools.desktop) 'Neither tool installed is detected'
$r=Run 'CliSave'
Check ($r.Code -ne 0 -and -not(Test-Path (Join-Path $storeDir 'cli\profiles'))) 'Logged-out CLI cannot overwrite saved accounts'
WriteAccount $A
$r=Run 'CliSave'
Check ($r.Code -eq 0) 'Save CLI account A'
WriteAccount $B $true
$r=Run 'CliSave'
Check ($r.Code -eq 0) 'Save CLI account B'
$r=Run 'Status'
Check ($r.Code -eq 0 -and $r.Data.cli.profiles.Count -eq 2 -and $r.Data.cli.activeUuid -eq $B) 'Both saved CLI accounts and active identity are listed'
$credsOriginal=[IO.File]::ReadAllText($credFile)
$configOriginal=[IO.File]::ReadAllText($configFile)
$r=Run 'CliSwitch' $A
Check ($r.Code -eq 0) 'Switch B to A'
$creds=Get-Content $credFile -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg=Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
Check ($creds.claudeAiOauth.accessToken -eq 'CLI-FAKE-SECRET-A' -and $cfg.oauthAccount.accountUuid -eq $A) 'Credential and account metadata change together'
Check ($creds.mcpOAuth.keep -eq 'untouched' -and $cfg.nested.oauthAccount.marker -eq 'keep') 'Other auth providers and nested account fields are preserved'
Check ([IO.File]::ReadAllText($configFile).Contains('9007199254740993') -and [IO.File]::ReadAllBytes($configFile)[0] -eq 0xEF) 'Config large integers, layout and BOM are preserved'
$r=Run 'CliSwitch' $B
Check ($r.Code -eq 0 -and (Get-Content $credFile -Raw -Encoding UTF8 | ConvertFrom-Json).claudeAiOauth.accessToken -eq 'CLI-FAKE-SECRET-B') 'Switch back restores B'
$hc=Hash $credFile; $hj=Hash $configFile
$r=Run 'CliSwitch' $A 'cliAfterCredentials'
Check ($r.Code -ne 0 -and (Hash $credFile) -eq $hc -and (Hash $configFile) -eq $hj) 'Mid-write failure rolls back both files byte-for-byte'
$bin=Join-Path $storeDir ('cli\profiles\'+$A+'\auth.bin')
$good=[IO.File]::ReadAllBytes($bin)
[IO.File]::WriteAllBytes($bin,[byte[]]@(1,2,3))
$r=Run 'CliSwitch' $A
Check ($r.Code -ne 0 -and (Hash $credFile) -eq $hc -and (Hash $configFile) -eq $hj) 'Corrupt saved credentials leave current login unchanged'
[IO.File]::WriteAllBytes($bin,$good)
$env:CLAUDE_CODE_OAUTH_TOKEN='CLI-FAKE-ENV-OVERRIDE'
$r=Run 'CliSwitch' $A
Check ($r.Code -ne 0 -and (Hash $credFile) -eq $hc) 'Environment credentials prevent misleading account switches'
Remove-Item Env:CLAUDE_CODE_OAUTH_TOKEN
$badFiles=@(Get-ChildItem -LiteralPath $storeDir -Recurse -File | Where-Object {$_.Extension -in @('.log','.json')} | Where-Object {[IO.File]::ReadAllText($_.FullName) -match 'CLI-FAKE-SECRET|CLI-FAKE-REFRESH|CLI-FAKE-ENV'})
Check ($badFiles.Count -eq 0) 'Secrets never appear in logs, metadata or status'
Check (-not [Text.Encoding]::UTF8.GetString($good).Contains('CLI-FAKE-SECRET')) 'Saved CLI credentials are DPAPI encrypted'
Remove-Item -LiteralPath $credFile
$r=Run 'CliSwitch' $A
Check ($r.Code -eq 0 -and (Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json).oauthAccount.accountUuid -eq $A) 'Saved account can be restored from logged-out CLI'
[void][IO.Directory]::CreateDirectory($desktopDir)
[IO.File]::WriteAllText((Join-Path $desktopDir 'config.json'),'{"lastKnownAccountUuid":"'+$B+'","oauth:tokenCacheV2":"DESKTOP-FAKE-UNTOUCHED"}',$utf8)
$desktopHash=Hash (Join-Path $desktopDir 'config.json')
$r=Run 'Status'
Check ($r.Code -eq 0 -and $r.Data.tools.desktop -and $r.Data.tools.cli) 'Both installed tools are detected'
$r=Run 'CliSwitch' $B
Check ($r.Code -eq 0 -and (Hash (Join-Path $desktopDir 'config.json')) -eq $desktopHash) 'CLI switching does not alter Desktop auth'
$loginId=[guid]::NewGuid().ToString('N')
$loginDir=Join-Path $storeDir ('cli\login\'+$loginId)
[void][IO.Directory]::CreateDirectory($loginDir)
WriteAccount $A
Copy-Item -LiteralPath $credFile -Destination (Join-Path $loginDir '.credentials.json')
Copy-Item -LiteralPath $configFile -Destination (Join-Path $loginDir '.claude.json')
[IO.File]::WriteAllText((Join-Path $loginDir 'complete.json'),'{"ok":true}',$utf8)
[IO.File]::WriteAllText((Join-Path $storeDir 'cli\pending-login.json'),('{"id":"'+$loginId+'"}'),$utf8)
WriteAccount $B
$r=Run 'Status'
Check ($r.Code -eq 0 -and $r.Data.cli.pendingLogin.state -eq 'ready') 'Completed isolated login is detected'
$r=Run 'CliFinishLogin'
Check ($r.Code -eq 0 -and (Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json).oauthAccount.accountUuid -eq $A) 'Completed login is saved and selected'
Check (-not(Test-Path -LiteralPath (Join-Path $loginDir '.credentials.json')) -and -not(Test-Path -LiteralPath (Join-Path $storeDir 'cli\pending-login.json'))) 'Temporary login secret is removed after encrypted save'
$renewalId=[guid]::NewGuid().ToString('N')
$renewalDir=Join-Path $storeDir ('cli\login\'+$renewalId)
[void][IO.Directory]::CreateDirectory($renewalDir)
[IO.File]::WriteAllText((Join-Path $renewalDir '.credentials.json'),[IO.File]::ReadAllText($credFile).Replace('CLI-FAKE-SECRET-A','CLI-FAKE-SECRET-A-RENEWED'),$utf8)
Copy-Item -LiteralPath $configFile -Destination (Join-Path $renewalDir '.claude.json')
[IO.File]::WriteAllText((Join-Path $renewalDir 'complete.json'),'{"ok":true}',$utf8)
[IO.File]::WriteAllText((Join-Path $storeDir 'cli\pending-login.json'),('{"id":"'+$renewalId+'"}'),$utf8)
$r=Run 'CliFinishLogin'
Check ($r.Code -eq 0 -and (Get-Content $credFile -Raw -Encoding UTF8|ConvertFrom-Json).claudeAiOauth.accessToken -eq 'CLI-FAKE-SECRET-A-RENEWED') 'Re-login to the active account installs its renewed credentials'
# The CLI rotates tokens on its own; the saved copy must follow so switching back is not revoked.
[IO.File]::WriteAllText($credFile,[IO.File]::ReadAllText($credFile).Replace('CLI-FAKE-SECRET-A-RENEWED','CLI-FAKE-SECRET-A-ROTATED').Replace('CLI-FAKE-REFRESH-A','CLI-FAKE-REFRESH-A-ROTATED'),$utf8)
$r=Run 'Status'
$r=Run 'CliSwitch' $B
$r=Run 'CliSwitch' $A
$creds=Get-Content $credFile -Raw -Encoding UTF8|ConvertFrom-Json
Check ($r.Code -eq 0 -and $creds.claudeAiOauth.accessToken -eq 'CLI-FAKE-SECRET-A-ROTATED' -and $creds.claudeAiOauth.refreshToken -eq 'CLI-FAKE-REFRESH-A-ROTATED') 'Tokens rotated by the running CLI are kept for the next switch'
$r=Run 'CliSwitch' $B
[IO.File]::WriteAllText($credFile,[IO.File]::ReadAllText($credFile).Replace('9999999999999','1000'),$utf8)
$r=Run 'Status'
$r=Run 'CliSwitch' $A
$hc=Hash $credFile; $hj=Hash $configFile
$r=Run 'CliSwitch' $B
Check ($r.Code -ne 0 -and $r.Data.message -match 'hết hiệu lực' -and (Hash $credFile) -eq $hc -and (Hash $configFile) -eq $hj) 'Expired saved login is refused without changing the current CLI'
$badFiles=@(Get-ChildItem -LiteralPath $storeDir -Recurse -File | Where-Object {$_.Extension -in @('.log','.json')} | Where-Object {[IO.File]::ReadAllText($_.FullName) -match 'CLI-FAKE-SECRET|CLI-FAKE-REFRESH'})
Check ($badFiles.Count -eq 0) 'Automatic profile sync writes no secrets in plain text'
WriteAccount $B; $r=Run 'Status'; $r=Run 'CliSwitch' $A
if($VerifyGui){
    & {
        $engineForTest=$engine
        $uiForTest=Join-Path $root 'ClaudeSwitch.CliUI.ps1'
        $usageUiForTest=Join-Path $root 'ClaudeSwitch.UsageUI.ps1'
        $gui=Join-Path $root 'ClaudeSwitch.ps1'
        $source=[IO.File]::ReadAllText($gui)
        $prefix=$source.Substring(0,$source.IndexOf('if ($IsPreview) {'))
        $prefix=$prefix.Replace('$Engine = Join-Path $PSScriptRoot ''ClaudeSwitch.Engine.ps1''','$Engine=$engineForTest').Replace('. (Join-Path $PSScriptRoot ''ClaudeSwitch.CliUI.ps1'')','. $uiForTest')
        $prefix=$prefix.Replace('. (Join-Path $PSScriptRoot ''ClaudeSwitch.UsageUI.ps1'')','. $usageUiForTest')
        . ([scriptblock]::Create($prefix)) -DataDir $desktopDir -StoreDir $storeDir -ClaudeJson (Join-Path $testDir 'unused-claude.json') -CliPath $fakeExe -CliConfigDir $cliDir -CliConfigFile $configFile -NoAppControl
        $st=Run 'Status'
        $AppState.Status=$st.Data
        Update-DetectedTools
        Render-Accounts
        Check ($DesktopTab.Visibility -eq 'Visible' -and $CliTab.Visibility -eq 'Visible') 'GUI shows both detected tools'
        $click=New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)
        $CliTab.RaiseEvent($click)
        Check ($AppState.ActiveTool -eq 'cli' -and $CliPanel.Visibility -eq 'Visible' -and $DesktopFooter.Visibility -eq 'Collapsed') 'CLI tab shows CLI accounts and hides Desktop controls'
        $deadline=(Get-Date).AddSeconds(20)
        while($AppState.Jobs.Count -gt 0 -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100;Pump-Jobs}
        $button=$null
        foreach($card in $CliCards.Children){$candidate=$card.FindName('SwitchBtn');if($candidate.Tag -eq $B){$button=$candidate;break}}
        Check ([bool]$button -and $button.IsEnabled) 'Saved inactive CLI account has an enabled switch button'
        if($button){
            $button.RaiseEvent($click)
            Check ($AppState.Busy -and -not $CliTab.IsEnabled) 'CLI click prevents overlapping operations'
            $deadline=(Get-Date).AddSeconds(20)
            while($AppState.Jobs.Count -gt 0 -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100;Pump-Jobs}
            Check (-not $AppState.Busy -and $AppState.Status.cli.activeUuid -eq $B) 'Real GUI click switches CLI through the background engine'
        }
        $AppState.Status.tools.desktop=$false
        Update-DetectedTools
        Check ($DesktopTab.Visibility -eq 'Collapsed' -and $CliTab.Visibility -eq 'Visible') 'CLI-only GUI hides Desktop tab'
        $AppState.Status.tools.desktop=$true;$AppState.Status.tools.cli=$false
        Update-DetectedTools
        Check ($AppState.ActiveTool -eq 'desktop' -and $CliTab.Visibility -eq 'Collapsed' -and $Cards.Visibility -eq 'Visible') 'Desktop-only GUI hides CLI and selects Desktop'
        $AppState.Status.tools.desktop=$false
        Update-DetectedTools
        Check ($NoToolsText.Visibility -eq 'Visible' -and $Cards.Visibility -eq 'Collapsed' -and $CliPanel.Visibility -eq 'Collapsed') 'No-tool GUI offers a rescan without broken cards'
        $win.Close()
    }
}
Write-Host ('RESULT: '+$script:passed+' passed, '+$script:failed+' failed')
exit $(if($script:failed){1}else{0})
