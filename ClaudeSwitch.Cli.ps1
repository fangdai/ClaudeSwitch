#requires -Version 5.1
# CLI helpers. Loaded by the engine; secrets never appear in status, metadata or logs.
$script:CliRoot = Join-Path $StoreDir 'cli'
$cliDirectoryWasSpecified = [bool]$CliConfigDir
if (-not $CliConfigDir) {
    $CliConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
}
$CliConfigDir = [IO.Path]::GetFullPath($CliConfigDir)
if (-not $CliConfigFile) {
    $CliConfigFile = if ($cliDirectoryWasSpecified -or $env:CLAUDE_CONFIG_DIR) { Join-Path $CliConfigDir '.claude.json' } else { Join-Path $env:USERPROFILE '.claude.json' }
}
$script:CliCredentialsPath = Join-Path $(if ($env:CLAUDE_SECURESTORAGE_CONFIG_DIR) { $env:CLAUDE_SECURESTORAGE_CONFIG_DIR } else { $CliConfigDir }) '.credentials.json'

function Find-CliPath {
    if ($CliPath) { if (Test-Path -LiteralPath $CliPath -PathType Leaf) { return [IO.Path]::GetFullPath($CliPath) }; return $null }
    foreach ($candidate in @((Join-Path $env:USERPROFILE '.local\bin\claude.exe'), (Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    foreach ($name in @('claude.exe','claude.cmd','claude.ps1')) {
        $cmd = Get-Command $name -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Get-CliOverrides {
    $names = New-Object System.Collections.ArrayList
    foreach ($key in @('ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_PROFILE')) {
        if ([Environment]::GetEnvironmentVariable($key)) { [void]$names.Add($key) }
    }
    foreach ($key in @('CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_VERTEX','CLAUDE_CODE_USE_FOUNDRY')) {
        if ([Environment]::GetEnvironmentVariable($key) -in @('1','true')) { [void]$names.Add($key) }
    }
    $settings = Read-JsonFile (Join-Path $CliConfigDir 'settings.json')
    if (Get-DictString $settings 'apiKeyHelper') { [void]$names.Add('apiKeyHelper') }
    return @($names.ToArray())
}

function Get-CliRunningCount {
    if ($NoAppControl) { return 0 }
    return @(Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path -notmatch '\\WindowsApps\\|\\Claude-Data\\' } catch { $false }
    }).Count
}

function Assert-CliCanChange {
    if (-not (Find-CliPath)) { throw 'Chưa tìm thấy Claude CLI trên máy.' }
    if (@(Get-CliOverrides).Count) { throw 'CLI đang dùng API key, token hoặc nhà cung cấp từ cấu hình bên ngoài. Hãy bỏ cấu hình ghi đè trước khi chuyển account đăng nhập.' }
    if ((Get-CliRunningCount) -gt 0) { throw 'Hãy thoát các phiên Claude CLI đang chạy rồi chuyển account. Công cụ không tự đóng phiên CLI của bạn.' }
}

function Invoke-CliLocked([scriptblock]$body) {
    $hash = (Get-Sha256Bytes $script:Utf8NoBom.GetBytes($script:CliCredentialsPath.ToLowerInvariant())).Substring(0,16)
    $mutex = New-Object Threading.Mutex($false, ('Local\ClaudeSwitch.Cli.' + $hash))
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'CLI đang được cập nhật trong một thao tác khác. Hãy thử lại.' }
        & $body
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

# Replace one root JSON property, preserving every byte outside its value.
function Set-CliJsonField([string]$text, [string]$key, $value) {
    try { $parsed = $script:Ser.DeserializeObject($text) } catch { throw 'File cấu hình CLI bị lỗi định dạng. Chưa thay đổi đăng nhập.' }
    if ($parsed -isnot [System.Collections.IDictionary]) { throw 'Cấu hình CLI phải là một đối tượng JSON.' }
    $depth = 0; $matches = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ($ch -eq '"') {
            $start = $i; $i++
            while ($i -lt $text.Length) { if ($text[$i] -eq '\') { $i += 2; continue }; if ($text[$i] -eq '"') { break }; $i++ }
            $end = $i + 1; $j = $end
            while ($j -lt $text.Length -and [char]::IsWhiteSpace($text[$j])) { $j++ }
            if ($depth -eq 1 -and $j -lt $text.Length -and $text[$j] -eq ':' -and $script:Ser.DeserializeObject($text.Substring($start, $end-$start)) -ceq $key) {
                $j++; while ([char]::IsWhiteSpace($text[$j])) { $j++ }
                $valueStart = $j; $nested = 0; $inString = $false
                for (; $j -lt $text.Length; $j++) {
                    $v = $text[$j]
                    if ($inString) { if ($v -eq '\') { $j++; continue }; if ($v -eq '"') { $inString = $false }; continue }
                    if ($v -eq '"') { $inString = $true; continue }
                    if ($nested -eq 0 -and ($v -eq ',' -or $v -eq '}')) { break }
                    if ($v -eq '{' -or $v -eq '[') { $nested++ }
                    if ($v -eq '}' -or $v -eq ']') { $nested-- }
                }
                $valueEnd = $j; while ($valueEnd -gt $valueStart -and [char]::IsWhiteSpace($text[$valueEnd-1])) { $valueEnd-- }
                [void]$matches.Add(@{ Start=$valueStart; End=$valueEnd })
            }
            continue
        }
        if ($ch -eq '{' -or $ch -eq '[') { $depth++ }
        elseif ($ch -eq '}' -or $ch -eq ']') { $depth-- }
    }
    if ($matches.Count -gt 1) { throw ('Cấu hình CLI có khóa trùng: ' + $key) }
    $json = $script:Ser.Serialize($value)
    if ($matches.Count -eq 1) { $span=$matches[0]; return $text.Substring(0,$span.Start)+$json+$text.Substring($span.End) }
    $brace = $text.IndexOf('{'); $rest = $text.Substring($brace+1)
    $comma = if ($rest.TrimStart().StartsWith('}')) { '' } else { ',' }
    return $text.Substring(0,$brace+1)+(ConvertTo-JsonLiteral $key)+':'+$json+$comma+$rest
}

function Read-CliState([string]$credentialsPath = $script:CliCredentialsPath, [string]$configPath = $CliConfigFile) {
    $creds = Read-JsonFile $credentialsPath; $config = Read-JsonFile $configPath
    $oauth = if (Test-DictHas $creds 'claudeAiOauth') { $creds['claudeAiOauth'] } else { $null }
    $account = if (Test-DictHas $config 'oauthAccount') { $config['oauthAccount'] } else { $null }
    $uuid = Get-DictString $account 'accountUuid'
    $loggedIn = [bool]($uuid -match $script:GuidRx -and (Get-DictString $oauth 'accessToken') -and (Get-DictString $oauth 'refreshToken'))
    return @{ LoggedIn=$loggedIn; Uuid=$uuid; Account=$account; Oauth=$oauth; Credentials=$creds; Config=$config }
}

function Get-CliProfileDir([string]$uuid) { return (Join-Path (Join-Path $script:CliRoot 'profiles') $uuid) }

# ---- Token identity -------------------------------------------------------------
# ~/.claude.json is shared with the Claude Code sessions embedded in Claude Desktop. They
# rewrite "oauthAccount" to the Desktop account while .credentials.json still holds the
# CLI login of another account. The token owner is therefore resolved from the token
# itself (known hashes, saved profiles, then the OAuth profile endpoint), never from the
# config claim alone. Only SHA-256 hashes of tokens are stored here.
$script:CliIdentityPath = Join-Path $script:CliRoot 'identity.json'
$script:CliVerifyOwner = -not $NoAppControl

function Get-CliTokenKey([string]$token) {
    if (-not $token) { return '' }
    return (Get-Sha256Bytes $script:Utf8NoBom.GetBytes($token))
}

function Read-CliIdentityMap {
    $data = Read-JsonFile $script:CliIdentityPath
    $map = @{}
    if (Test-DictHas $data 'tokens') { foreach ($k in $data['tokens'].Keys) { $map[[string]$k] = $data['tokens'][$k] } }
    return $map
}

function Write-CliIdentityMap($map) {
    # Keep the newest entries only; each login rotates tokens every few hours.
    $keep = @{}
    foreach ($entry in @($map.GetEnumerator() | Sort-Object { [long](Get-DictString $_.Value 't') } -Descending | Select-Object -First 80)) { $keep[$entry.Key] = $entry.Value }
    Ensure-Dir $script:CliRoot
    Write-JsonFile $script:CliIdentityPath @{ version = 1; tokens = $keep }
}

function Add-CliIdentity([string]$uuid, $oauth) {
    if ($uuid -notmatch $script:GuidRx -or -not $oauth) { return }
    $map = Read-CliIdentityMap
    $now = [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach ($name in @('accessToken','refreshToken')) {
        $key = Get-CliTokenKey (Get-DictString $oauth $name)
        if ($key) { $map[$key] = @{ uuid = $uuid; t = $now } }
    }
    Write-CliIdentityMap $map
}

function Request-CliTokenOwner($oauth) {
    $token = Get-DictString $oauth 'accessToken'
    if (-not $token) { return $null }
    if ($oauth['expiresAt'] -and [double]$oauth['expiresAt'] -le [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { return $null }
    $reply = Request-UsageHttp 'https://api.anthropic.com/api/oauth/profile' $token
    if ($reply.status -ne 200 -or -not (Test-DictHas $reply.body 'account')) { return $null }
    $owner = Get-DictString $reply.body['account'] 'uuid'
    if ($owner -notmatch $script:GuidRx) { return $null }
    return $owner
}

# Returns the verified owner uuid of an OAuth token set, or $null when it cannot be proven.
function Resolve-CliTokenOwner($oauth, [string]$claimedUuid, [switch]$SkipSavedProfiles) {
    $access = Get-DictString $oauth 'accessToken'; $refresh = Get-DictString $oauth 'refreshToken'
    if (-not $access) { return $null }
    $map = Read-CliIdentityMap
    foreach ($key in @((Get-CliTokenKey $access), (Get-CliTokenKey $refresh))) {
        if ($key -and $map.ContainsKey($key)) {
            $known = Get-DictString $map[$key] 'uuid'
            if ($known -match $script:GuidRx) { return $known }
        }
    }
    if (-not $SkipSavedProfiles) {
        $root = Join-Path $script:CliRoot 'profiles'
        if (Test-Path -LiteralPath $root) {
            foreach ($dir in Get-ChildItem -LiteralPath $root -Directory) {
                if ($dir.Name -notmatch $script:GuidRx) { continue }
                try { $saved = Read-CliProfile $dir.Name } catch { continue }
                if ((Get-DictString $saved['oauth'] 'accessToken') -ceq $access -or ($refresh -and (Get-DictString $saved['oauth'] 'refreshToken') -ceq $refresh)) {
                    # Saved copies are trusted only once their own identity was proven.
                    $savedKey = Get-CliTokenKey (Get-DictString $saved['oauth'] 'accessToken')
                    if (-not $script:CliVerifyOwner -or ($map.ContainsKey($savedKey) -and (Get-DictString $map[$savedKey] 'uuid') -ieq $dir.Name)) { return [string]$dir.Name }
                }
            }
        }
    }
    if (-not $script:CliVerifyOwner) {
        # Offline/test mode: no network check is possible, keep the previous behaviour.
        if ($claimedUuid -match $script:GuidRx) { return $claimedUuid }
        return $null
    }
    $owner = $null
    try { $owner = Request-CliTokenOwner $oauth } catch {}
    if ($owner) {
        Add-CliIdentity $owner $oauth
        if ($claimedUuid -and $owner -ine $claimedUuid) { Write-Log ('CLI: token thuộc account {0}, cấu hình ghi {1}.' -f $owner, $claimedUuid) }
    }
    return $owner
}

# Live CLI login with the token owner verified. Uuid is the real owner; ClaimedUuid is what
# ~/.claude.json says. Verified=$false means the owner could not be proven yet.
function Get-CliLiveState {
    $state = Read-CliState
    $state.ClaimedUuid = $state.Uuid
    $state.Verified = $false
    $state.Mismatch = $false
    $hasToken = (Get-DictString $state.Oauth 'accessToken') -and (Get-DictString $state.Oauth 'refreshToken')
    if (-not $hasToken) { return $state }
    $owner = Resolve-CliTokenOwner $state.Oauth $state.ClaimedUuid
    if (-not $owner) { return $state }
    $state.Verified = $true
    $state.Uuid = $owner
    $state.LoggedIn = $true
    if ($owner -ine $state.ClaimedUuid) {
        $state.Mismatch = $true
        $account = $null
        try { $account = (Read-CliProfile $owner)['account'] } catch {}
        if (-not $account) { $account = @{ accountUuid = $owner } }
        $state.Account = $account
    }
    return $state
}

function Save-CliProfile($state) {
    if (-not $state.LoggedIn) { throw 'CLI chưa đăng nhập đầy đủ. Hãy bấm Đăng nhập CLI trước.' }
    if (-not $state.Verified) { throw 'Chưa xác minh được account của đăng nhập CLI hiện tại. Chưa lưu gì.' }
    if ((Get-DictString $state.Account 'accountUuid') -ine $state.Uuid) { throw 'Thông tin account CLI không khớp token. Chưa lưu gì.' }
    $dir = Get-CliProfileDir $state.Uuid
    $payload = @{ version=1; uuid=$state.Uuid; oauth=$state.Oauth; account=$state.Account }
    $plain = $script:Utf8NoBom.GetBytes($script:Ser.Serialize($payload))
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    Write-FileAtomic (Join-Path $dir 'auth.bin') $encrypted
    Add-CliIdentity $state.Uuid $state.Oauth
    $old = Read-JsonFile (Join-Path $dir 'meta.json')
    $email = Get-DictString $state.Account 'emailAddress'
    $label = Get-DictString $old 'label'
    if (-not $label) {
        $desktopMeta = Read-JsonFile (Join-Path (Get-ProfileDir $state.Uuid) 'meta.json')
        $label = Get-DictString $desktopMeta 'label'
    }
    if (-not $label) { $label = if ($email) { $email } else { 'Account ' + $state.Uuid.Substring(0,4) } }
    Write-JsonFile (Join-Path $dir 'meta.json') @{ label=$label; email=$email; savedAt=(Get-Date).ToString('o') }
    Write-Log 'Đã lưu account Claude CLI (DPAPI).'
}

function Read-CliProfile([string]$uuid) {
    if ($uuid -notmatch $script:GuidRx) { throw 'Mã account CLI không hợp lệ.' }
    try {
        $bytes = [IO.File]::ReadAllBytes((Join-Path (Get-CliProfileDir $uuid) 'auth.bin'))
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $d = $script:Ser.DeserializeObject($script:Utf8NoBom.GetString($plain))
        if ((Get-DictString $d 'uuid') -ine $uuid -or (Get-DictString $d['account'] 'accountUuid') -ine $uuid -or -not (Get-DictString $d['oauth'] 'accessToken') -or -not (Get-DictString $d['oauth'] 'refreshToken')) { throw 'invalid' }
        return $d
    } catch { throw 'Account CLI đã lưu bị hỏng hoặc không giải mã được. Chưa thay đổi đăng nhập hiện tại.' }
}

function Get-CliPending {
    $pending = Read-JsonFile (Join-Path $script:CliRoot 'pending-login.json')
    $id = Get-DictString $pending 'id'
    if ($id -notmatch '^[a-f0-9]{32}$') { return $null }
    $dir = Join-Path (Join-Path $script:CliRoot 'login') $id
    $result = Read-JsonFile (Join-Path $dir 'complete.json')
    $state = 'waiting'
    if ($result) { $state = if ($result['ok']) { 'ready' } else { 'failed' } }
    elseif ($pending['pid']) {
        $proc = Get-Process -Id ([int]$pending['pid']) -ErrorAction SilentlyContinue
        if (-not $proc -or $proc.StartTime.ToUniversalTime().Ticks.ToString() -ne (Get-DictString $pending 'startedTicks')) { $state='failed' }
    }
    return @{ id=$id; state=$state; directory=$dir }
}

# The CLI renews and rotates its own tokens while it runs. Keep the saved copy of the
# active account current, otherwise a later switch back restores a revoked refresh token.
function Sync-ActiveCliProfile($current) {
    if (-not $current.LoggedIn -or -not $current.Verified) { return }
    if (-not (Test-Path -LiteralPath (Join-Path (Get-CliProfileDir $current.Uuid) 'auth.bin'))) { return }
    $saved = $null
    try { $saved = Read-CliProfile $current.Uuid } catch {}
    if ($saved -and (Get-DictString $saved['oauth'] 'refreshToken') -ceq (Get-DictString $current.Oauth 'refreshToken') -and (Get-DictString $saved['oauth'] 'accessToken') -ceq (Get-DictString $current.Oauth 'accessToken')) { return }
    try {
        Invoke-CliLocked {
            $again = Get-CliLiveState
            if ($again.Verified -and $again.Uuid -ieq $current.Uuid) { Save-CliProfile $again }
        }
    } catch {}
}

function Get-CliStatus {
    $path = [string](Find-CliPath); $current = Get-CliLiveState
    $overrides = @(Get-CliOverrides)
    if (-not $overrides.Count) { Sync-ActiveCliProfile $current }
    $profiles = New-Object System.Collections.ArrayList
    $root = Join-Path $script:CliRoot 'profiles'
    if (Test-Path -LiteralPath $root) {
        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name) {
            if ($dir.Name -notmatch $script:GuidRx) { continue }
            $meta = Read-JsonFile (Join-Path $dir.FullName 'meta.json')
            [void]$profiles.Add(@{ uuid=[string]$dir.Name; label=(Get-DictString $meta 'label'); email=(Get-DictString $meta 'email'); hasAuth=[bool](Test-Path -LiteralPath (Join-Path $dir.FullName 'auth.bin')); isActive=($current.Verified -and -not $overrides.Count -and $current.Uuid -ieq $dir.Name); authRemovedReason=(Get-DictString $meta 'authRemovedReason') })
        }
    }
    $pending = Get-CliPending
    $usable = ($current.Verified -and -not $overrides.Count)
    $status = @{ installed=[bool]$path; path=$path; configDir=$CliConfigDir; loggedIn=($current.LoggedIn -and -not $overrides.Count); activeUuid=$(if($usable){$current.Uuid}else{$null}); email=(Get-DictString $current.Account 'emailAddress'); profiles=$profiles.ToArray(); unsavedCurrent=($usable -and -not(Test-Path -LiteralPath (Join-Path (Get-CliProfileDir $current.Uuid) 'auth.bin'))); identityMismatch=($usable -and $current.Mismatch); claimedUuid=$current.ClaimedUuid; unverified=($current.LoggedIn -and -not $current.Verified -and -not $overrides.Count); authOverrides=$overrides; runningCount=(Get-CliRunningCount); pendingLogin=$(if($pending){@{id=$pending.id;state=$pending.state}}else{$null}) }
    # Remove PowerShell adapter wrappers before JavaScriptSerializer sees nested values.
    return $script:Ser.DeserializeObject(($status | ConvertTo-Json -Depth 15 -Compress))
}

function Read-CliFileSnapshot([string]$path) {
    if (Test-Path -LiteralPath $path) { return @{ Exists=$true; Bytes=(Read-AllBytesShared $path); Info=(Read-TextInfo $path) } }
    return @{ Exists=$false; Bytes=$null; Info=@{Text='{}';Pre=[byte[]]@();Enc=$script:Utf8NoBom} }
}
function Restore-CliFile([string]$path, $snapshot) {
    if ($snapshot.Exists) { Write-FileAtomic $path $snapshot.Bytes }
    elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Invoke-CliSwitch([string]$uuid, [switch]$Force) {
    Assert-CliCanChange
    $target = Read-CliProfile $uuid
    $current = Get-CliLiveState
    if (-not $Force -and $current.Verified -and $current.Uuid -ieq $uuid -and -not $current.Mismatch) { Write-Step 'cli' 'ok' 'CLI đang dùng account này.'; return }
    # A login whose owner cannot be proven (offline, or expired while the CLI was closed) is never
    # saved under a guessed account; it remains only in the encrypted backup written below.
    # Do not hand the CLI a dead login: it would show the account name but fail or fall back.
    $expiresAt = $target['oauth']['expiresAt']
    if (-not $Force -and $expiresAt -and [double]$expiresAt -le [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 60000) {
        $renewed = $null
        if (-not $NoAppControl) { try { $renewed = Renew-InactiveUsageAuthentication $uuid } catch {} }
        if (-not $renewed) {
            $name = Get-DictString (Read-JsonFile (Join-Path (Get-CliProfileDir $uuid) 'meta.json')) 'label'
            if (-not $name) { $name = Get-DictString $target['account'] 'emailAddress' }
            throw ('Đăng nhập CLI đã lưu của ' + $name + ' đã hết hiệu lực. Bấm "Thêm account CLI" và đăng nhập lại account đó. CLI hiện tại chưa bị thay đổi.')
        }
        $target = Read-CliProfile $uuid
    }
    $credentials = Read-CliFileSnapshot $script:CliCredentialsPath
    $config = Read-CliFileSnapshot $CliConfigFile
    # Parse and validate both files before backing up or changing either.
    $newCreds = Set-CliJsonField $credentials.Info.Text 'claudeAiOauth' $target['oauth']
    $newConfig = Set-CliJsonField $config.Info.Text 'oauthAccount' $target['account']
    if ($current.Verified -and $current.Uuid -ine $uuid) { Save-CliProfile $current }
    $backup = @{ credentials=$(if($credentials.Exists){[Convert]::ToBase64String($credentials.Bytes)}else{$null}); config=$(if($config.Exists){[Convert]::ToBase64String($config.Bytes)}else{$null}); credentialsExisted=$credentials.Exists; configExisted=$config.Exists }
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($script:Utf8NoBom.GetBytes($script:Ser.Serialize($backup)),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    Write-FileAtomic (Join-Path (Join-Path $script:CliRoot 'backups') ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.bin')) $encrypted
    if (($credentials.Exists -and (Get-Sha256File $script:CliCredentialsPath) -ne (Get-Sha256Bytes $credentials.Bytes)) -or (-not $credentials.Exists -and (Test-Path -LiteralPath $script:CliCredentialsPath))) { throw 'Đăng nhập CLI vừa thay đổi. Hãy thử lại.' }
    if (($config.Exists -and (Get-Sha256File $CliConfigFile) -ne (Get-Sha256Bytes $config.Bytes)) -or (-not $config.Exists -and (Test-Path -LiteralPath $CliConfigFile))) { throw 'Cấu hình CLI vừa thay đổi. Hãy thử lại.' }
    try {
        Write-FileAtomic $script:CliCredentialsPath (Get-TextBytes $credentials.Info $newCreds)
        if ($FailAt -eq 'cliAfterCredentials') { throw 'Lỗi giả lập khi cập nhật CLI.' }
        Write-FileAtomic $CliConfigFile (Get-TextBytes $config.Info $newConfig)
        $check = Read-CliState
        if (-not $check.LoggedIn -or $check.Uuid -ine $uuid) { throw 'Kiểm tra đăng nhập CLI sau khi ghi không khớp.' }
    } catch {
        $why=$_.Exception.Message
        try { Restore-CliFile $script:CliCredentialsPath $credentials; Restore-CliFile $CliConfigFile $config } catch { throw 'Không khôi phục tự động được CLI. Bản sao lưu mã hóa nằm trong thư mục cli\backups.' }
        throw ('Chưa chuyển được CLI; đã khôi phục đăng nhập cũ. '+$why)
    }
    if ($current.LoggedIn -and -not $current.Verified) {
        Write-Log 'CLI: đăng nhập trước khi chuyển chưa xác minh được chủ sở hữu, chỉ giữ trong bản sao lưu.'
        Write-Step 'cli' 'ok' 'Đã chuyển account CLI. Đăng nhập cũ chưa xác minh được account nên không lưu đè; nếu chuyển lại bị lỗi, đăng nhập lại account đó.'
        return
    }
    Write-Step 'cli' 'ok' 'Đã chuyển account CLI. Mở phiên Claude CLI mới để sử dụng.'
}

function Start-CliHost([string]$mode, [string]$directory='') {
    $path = Find-CliPath
    if (-not $path) { throw 'Chưa tìm thấy Claude CLI.' }
    $hostFile = Join-Path $PSScriptRoot 'ClaudeSwitch.CliHost.ps1'
    $args = '-NoProfile -ExecutionPolicy Bypass '
    if ($mode -eq 'open') { $args += '-NoExit ' }
    $args += '-File "'+$hostFile+'" -Mode '+$mode+' -CliPath "'+$path+'"'
    if ($directory) { $args += ' -ConfigDir "'+$directory+'"' }
    return (Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -WorkingDirectory $env:USERPROFILE -PassThru)
}

function Invoke-CliLogin {
    Assert-CliCanChange
    $pending=Get-CliPending
    if ($pending -and $pending.state -eq 'waiting') { return }
    if ($pending) {
        $oldCredentials=Join-Path $pending.directory '.credentials.json'
        if (Test-Path -LiteralPath $oldCredentials) { Remove-Item -LiteralPath $oldCredentials -Force }
    }
    $id=[guid]::NewGuid().ToString('N')
    $dir=Join-Path (Join-Path $script:CliRoot 'login') $id
    Ensure-Dir $dir
    $proc=Start-CliHost 'login' $dir
    Write-JsonFile (Join-Path $script:CliRoot 'pending-login.json') @{id=$id;pid=[int]$proc.Id;startedTicks=$proc.StartTime.ToUniversalTime().Ticks.ToString()}
    Write-Step 'cli' 'ok' 'Đã mở đăng nhập CLI. Hoàn tất trong trình duyệt và cửa sổ CLI.'
}

function Complete-CliLogin {
    $pending=Get-CliPending
    if (-not $pending -or $pending.state -ne 'ready') { throw 'Chưa hoàn tất đăng nhập CLI.' }
    $credentialsPath=Join-Path $pending.directory '.credentials.json'
    $configPath=Join-Path $pending.directory '.claude.json'
    $state=Read-CliState $credentialsPath $configPath
    if (-not $state.LoggedIn) { throw 'Đăng nhập CLI chưa đầy đủ. Hãy đăng nhập lại.' }
    # The isolated login directory is written only by that login, but still prefer the token's own answer.
    $owner = $null
    if ($script:CliVerifyOwner) { try { $owner = Request-CliTokenOwner $state.Oauth } catch {} }
    if ($owner -and $owner -ine $state.Uuid) { throw 'Account đăng nhập không khớp token trả về. Hãy đăng nhập lại.' }
    $state.Verified = $true
    Save-CliProfile $state
    Invoke-CliSwitch $state.Uuid -Force
    Remove-Item -LiteralPath (Join-Path $script:CliRoot 'pending-login.json') -Force
    if (Test-Path -LiteralPath $credentialsPath) { Remove-Item -LiteralPath $credentialsPath -Force }
    Write-Step 'cli' 'ok' 'Đã lưu và chọn account CLI vừa đăng nhập.'
}
