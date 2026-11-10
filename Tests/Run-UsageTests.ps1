#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Scratch, [switch]$VerifyGui)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetFullPath($Scratch)) ([guid]::NewGuid().ToString('N'))
$desktopData = Join-Path $testRoot 'desktop'
$cliData = Join-Path $testRoot 'cli'
$store = Join-Path $testRoot 'store'
[void][IO.Directory]::CreateDirectory($desktopData)
[void][IO.Directory]::CreateDirectory($cliData)
$engineForTest = Join-Path $root 'ClaudeSwitch.Engine.ps1'
$source = [IO.File]::ReadAllText($engineForTest)
$prefix = $source.Substring(0, $source.IndexOf('# ---------------------------------------------------------------- main'))
. ([scriptblock]::Create($prefix)) -StoreDir $store -DataDir $desktopData -CliConfigDir $cliData -CliConfigFile (Join-Path $cliData '.claude.json') -NoAppControl
. (Join-Path $root 'ClaudeSwitch.Cli.ps1')
. (Join-Path $root 'ClaudeSwitch.Usage.ps1')
$accountA = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
$accountB = 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'
$orgA = 'a0a0a0a0-1111-4111-8111-a0a0a0a0a0a0'
$orgB = 'b0b0b0b0-2222-4222-8222-b0b0b0b0b0b0'
$script:passed = 0
function Check([bool]$condition, [string]$name) {
    if (-not $condition) { throw ('FAIL ' + $name) }
    $script:passed++
    Write-Host ('PASS ' + $name)
}
function FileHash([string]$path) { return Get-Sha256File $path }
function Set-FakeCliAccount([string]$uuid, [bool]$expired) {
    $expires = [DateTimeOffset]::UtcNow.AddHours(8).ToUnixTimeMilliseconds()
    if ($expired) { $expires = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds() }
    $oauth = @{accessToken=('FAKE-ACCESS-' + $uuid);refreshToken=('FAKE-REFRESH-' + $uuid);expiresAt=$expires}
    Write-JsonFile $script:CliCredentialsPath @{claudeAiOauth=$oauth}
    Write-JsonFile $CliConfigFile @{oauthAccount=@{accountUuid=$uuid;emailAddress=($uuid.Substring(0,1)+'@example.test')}}
}
Set-FakeCliAccount $accountA $true
Save-CliProfile (Get-CliLiveState)
Set-FakeCliAccount $accountB $false
Save-CliProfile (Get-CliLiveState)
Write-JsonFile (Join-Path (Get-ProfileDir $accountA) 'meta.json') @{orgUuid=$orgA;label='A'}
Write-JsonFile (Join-Path (Get-ProfileDir $accountB) 'meta.json') @{orgUuid=$orgB;label='B'}
$script:usageCalls = 0
$script:refreshCalls = 0
$script:reply = @{status=200;body=@{five_hour=@{utilization=26.0;resets_at='2026-11-06T10:00:00Z'};seven_day=@{utilization=100.0;resets_at='2026-11-09T10:00:00Z'}};retrySeconds=300}
function Request-UsageHttp([string]$url, [string]$token, $body=$null) {
    if ($url -eq 'https://platform.claude.com/v1/oauth/token') {
        $script:refreshCalls++
        return @{status=200;body=@{access_token='FAKE-ACCESS-RENEWED';refresh_token='FAKE-REFRESH-RENEWED';expires_in=28800}}
    }
    $script:usageCalls++
    return $script:reply
}
$windows = ConvertTo-UsageWindows @{five_hour=@{utilization=0;resets_at=$null};seven_day=@{utilization='100';resets_at=$null};extra_usage=@{utilization=$null}}
Check ($windows.Count -eq 1 -and $windows[0].usedPercent -eq 0) 'Zero usage is retained and absent/malformed fields are excluded'
$activeHash = FileHash $script:CliCredentialsPath
$recordA = Update-AccountUsage $accountA $null $false
Check ($recordA.state -eq 'ok' -and $recordA.windows.Count -eq 2) 'Successful quota fetch normalizes both windows'
Check ($script:refreshCalls -eq 1 -and (Read-CliProfile $accountA)['oauth']['accessToken'] -eq 'FAKE-ACCESS-RENEWED') 'Expired inactive account is renewed and saved encrypted'
Check ((FileHash $script:CliCredentialsPath) -eq $activeHash -and (Read-CliState).Uuid -eq $accountB) 'Inactive usage renewal preserves the active CLI login'
$calls = $script:usageCalls
$cachedA = Update-AccountUsage $accountA $recordA $false
Check ($script:usageCalls -eq $calls -and $cachedA.updatedAt -eq $recordA.updatedAt) 'Fresh cache prevents duplicate network requests'
$script:reply = @{status=429;body=$null;retrySeconds=900}
$limited = Update-AccountUsage $accountB $null $false
$calls = $script:usageCalls
$limitedAgain = Update-AccountUsage $accountB $limited $true
Check ($limited.state -eq 'limited' -and (Read-UsageDate $limited.retryAt) -gt [DateTimeOffset]::UtcNow.AddMinutes(14) -and $calls -eq $script:usageCalls) 'Rate-limit retry delay is honored even for manual refresh'
Set-FakeCliAccount $accountB $true
$calls = $script:refreshCalls
$sampleTime = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
Write-JsonFile (Join-Path $desktopData 'plan-usage-history.json') @{version=2;samples=@(
    @{t=$sampleTime;org=$orgB;u=@{fh=0;sd=97}},
    @{t=($sampleTime+1000);org=$orgA;u=@{fh=88;sd=99}}
)}
$recordB = Update-AccountUsage $accountB $null $false
Check ($script:refreshCalls -eq $calls) 'Active CLI renewal remains owned by the CLI'
Check ($recordB.state -eq 'cached' -and $recordB.windows[0].usedPercent -eq 0 -and $recordB.windows[1].usedPercent -eq 97) 'Desktop fallback selects the matching organization, including zero usage'
Check ((Read-UsageDate $recordB.updatedAt).ToUnixTimeMilliseconds() -eq $sampleTime) 'Fallback preserves its actual observation timestamp'
$oldRecord = @{}
foreach ($key in $recordB.Keys) { $oldRecord[$key] = $recordB[$key] }
$oldRecord.checkedAt = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
$oldRecord.retryAt = $null
$retriedRecord = Update-AccountUsage $accountB $oldRecord $true
Check ($retriedRecord.state -eq 'cached' -and $retriedRecord.windows.Count -eq 2) 'Repeated failed refresh retains the Desktop source label for the same snapshot'
Write-JsonFile (Join-Path $desktopData 'plan-usage-history.json') @{version=1;samples=@(@{t=$sampleTime;fh=50;sd=50})}
$unknown = Update-AccountUsage $accountB $null $false
Check ($unknown.state -eq 'login_expired' -and @($unknown.windows).Count -eq 0) 'Unscoped legacy samples are never assigned to an account'
Check (@(Get-UsageAccountIds).Count -eq 2) 'Desktop and CLI copies of one account are deduplicated'
$cache = @{accounts=@{}}
$cache.accounts[$accountA] = $recordA
$cache.accounts[$accountB] = $recordB
Write-JsonFile $script:UsageCachePath $cache
$cachedText = [IO.File]::ReadAllText($script:UsageCachePath)
Check (-not ($cachedText -match 'FAKE-ACCESS|FAKE-REFRESH|refreshToken|accessToken')) 'Usage cache contains no authentication secrets'

# ---- Token owner verification: Claude Desktop's embedded Claude Code rewrites oauthAccount
# in ~/.claude.json while .credentials.json keeps the CLI login of the other account.
$script:CliVerifyOwner = $true
$script:owners = @{}
function Request-UsageHttp([string]$url, [string]$token, $body=$null) {
    if ($url -eq 'https://api.anthropic.com/api/oauth/profile') {
        $script:profileCalls++
        if ($script:owners.ContainsKey($token)) { return @{status=200;body=@{account=@{uuid=$script:owners[$token]}};retrySeconds=300} }
        return @{status=401;body=$null;retrySeconds=300}
    }
    if ($url -eq 'https://platform.claude.com/v1/oauth/token') { return @{status=400;body=$null;retrySeconds=300} }
    $script:usageCalls++
    return @{status=200;body=@{five_hour=@{utilization=($script:owners[$token] -eq $accountB) * 50.0;resets_at=$null}};retrySeconds=300}
}
$script:profileCalls = 0
$future = [DateTimeOffset]::UtcNow.AddHours(8).ToUnixTimeMilliseconds()
$rotatedB = @{accessToken='FAKE-ACCESS-B-ROTATED';refreshToken='FAKE-REFRESH-B-ROTATED';expiresAt=$future}
$script:owners['FAKE-ACCESS-B-ROTATED'] = $accountB
$script:owners['FAKE-ACCESS-RENEWED'] = $accountA
Write-JsonFile $script:CliCredentialsPath @{claudeAiOauth=$rotatedB}
Write-JsonFile $CliConfigFile @{oauthAccount=@{accountUuid=$accountA;emailAddress='a@example.test'}}
$profileAHash = Get-Sha256File (Join-Path (Get-CliProfileDir $accountA) 'auth.bin')
$live = Get-CliLiveState
Check ($live.Verified -and $live.Uuid -eq $accountB -and $live.Mismatch -and (Get-DictString $live.Account 'accountUuid') -eq $accountB) 'Live login is attributed to the token owner, not to the rewritten config claim'
Sync-ActiveCliProfile $live
Check ((Read-CliProfile $accountB)['oauth']['accessToken'] -eq 'FAKE-ACCESS-B-ROTATED' -and (Get-Sha256File (Join-Path (Get-CliProfileDir $accountA) 'auth.bin')) -eq $profileAHash) 'Rotated token is saved under its real owner and never overwrites the claimed account'
$calls = $script:profileCalls
[void](Get-CliLiveState)
Check ($script:profileCalls -eq $calls) 'Verified token owners are cached by hash without repeated network checks'
Check (-not ([IO.File]::ReadAllText($script:CliIdentityPath) -match 'FAKE-')) 'Identity cache stores only token hashes'
$status = Get-CliStatus
Check ($status.activeUuid -eq $accountB -and $status.identityMismatch -and -not $status.unsavedCurrent) 'CLI status reports the real active account and the config mismatch'
$threw = $false
try { Save-CliProfile @{LoggedIn=$true;Verified=$false;Uuid=$accountA;Oauth=$rotatedB;Account=@{accountUuid=$accountA}} } catch { $threw = $true }
Check $threw 'Unverified logins are never saved'
$unknownLive = @{accessToken='FAKE-ACCESS-UNKNOWN';refreshToken='FAKE-REFRESH-UNKNOWN';expiresAt=$future}
Write-JsonFile $script:CliCredentialsPath @{claudeAiOauth=$unknownLive}
$unknownState = Get-CliLiveState
Check (-not $unknownState.Verified -and (Get-CliStatus).unverified -and -not (Get-CliStatus).activeUuid) 'Unprovable live login is not shown as any saved account'
# Simulate a profile corrupted by the old behaviour: account A holding B's login.
$payload = @{version=1;uuid=$accountA;oauth=$rotatedB;account=@{accountUuid=$accountA;emailAddress='a@example.test'}}
$plain = $script:Utf8NoBom.GetBytes($script:Ser.Serialize($payload))
Write-FileAtomic (Join-Path (Get-CliProfileDir $accountA) 'auth.bin') ([Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))
$poisoned = Update-AccountUsage $accountA $null $true $unknownState
Check ($poisoned.state -eq 'wrong_account' -and @($poisoned.windows).Count -eq 0) 'Usage is not shown for a profile whose token belongs to another account'
Repair-CliProfileOwners
Check (-not (Test-Path (Join-Path (Get-CliProfileDir $accountA) 'auth.bin')) -and @(Get-ChildItem (Get-CliProfileDir $accountA) -Filter 'auth.wrong-*.bin').Count -eq 1) 'Mixed-up profile is moved aside instead of deleted'
Check ((Read-CliProfile $accountB)['oauth']['accessToken'] -eq 'FAKE-ACCESS-B-ROTATED') 'Real owner keeps its login after repair'
$afterRepair = Update-AccountUsage $accountA $recordA $true $unknownState
Check ($afterRepair.state -eq 'missing_login' -and @($afterRepair.windows).Count -eq 0 -and $afterRepair.message -match 'lẫn') 'Repaired account asks for a new login and drops borrowed numbers'
$script:CliVerifyOwner = $false

if ($VerifyGui) {
    & {
        $cliUiForTest = Join-Path $root 'ClaudeSwitch.CliUI.ps1'
        $usageUiForTest = Join-Path $root 'ClaudeSwitch.UsageUI.ps1'
        $guiSource = [IO.File]::ReadAllText((Join-Path $root 'ClaudeSwitch.ps1'))
        $guiPrefix = $guiSource.Substring(0, $guiSource.IndexOf('if ($IsPreview) {'))
        $guiPrefix = $guiPrefix.Replace('$Engine = Join-Path $PSScriptRoot ''ClaudeSwitch.Engine.ps1''', '$Engine=$engineForTest')
        $guiPrefix = $guiPrefix.Replace('. (Join-Path $PSScriptRoot ''ClaudeSwitch.CliUI.ps1'')', '. $cliUiForTest')
        $guiPrefix = $guiPrefix.Replace('. (Join-Path $PSScriptRoot ''ClaudeSwitch.UsageUI.ps1'')', '. $usageUiForTest')
        . ([scriptblock]::Create($guiPrefix)) -StoreDir $store -DataDir $desktopData -CliConfigDir $cliData -CliConfigFile (Join-Path $cliData '.claude.json') -NoAppControl
        $AppState.Usage = $cache
        $AppState.Status = [pscustomobject]@{tools=[pscustomobject]@{desktop=$true;cli=$true};profiles=@();cli=[pscustomobject]@{profiles=@(
            [pscustomobject]@{uuid=$accountA;label='A';email='a@example.test';hasAuth=$true;isActive=$false},
            [pscustomobject]@{uuid=$accountB;label='B';email='b@example.test';hasAuth=$true;isActive=$true}
        );authOverrides=@();runningCount=0;loggedIn=$true;pendingLogin=$null}}
        $AppState.ActiveTool = 'cli'
        Update-DetectedTools
        Render-CliAccounts
        $slot = $CliCards.Children[1].FindName('UsageSlot')
        $bars = @($slot.Children | Where-Object {$_ -is [Windows.Controls.ProgressBar]})
        Check ($bars.Count -eq 2 -and $bars[0].Value -eq 0 -and $bars[1].Value -eq 97) 'Account cards render their own percentages correctly'
        Check (@($slot.Children | Where-Object {$_ -is [Windows.Controls.TextBlock] -and $_.Text -match 'Desktop'}).Count -eq 1) 'Cached Desktop data is visibly distinguished from live quota'
        $click = New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)
        $UsageRefreshBtn.RaiseEvent($click)
        Check ($AppState.UsageBusy -and -not $UsageRefreshBtn.IsEnabled) 'Refresh button starts one background update and prevents repeated clicks'
        $deadline = (Get-Date).AddSeconds(20)
        while ($AppState.Jobs.Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; Pump-Jobs }
        Check (-not $AppState.UsageBusy -and $UsageRefreshBtn.IsEnabled -and (Find-UsageRecord $accountB).windows[1].usedPercent -eq 97) 'Background refresh reloads the shared cache without changing account'
        $win.Close()
    }
}
Write-Host ('RESULT: ' + $script:passed + ' passed')
