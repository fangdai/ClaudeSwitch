#requires -Version 5.1
# Account quota cache. Authentication material stays inside the request and DPAPI profiles.
$script:UsageCachePath = Join-Path $StoreDir 'usage.json'

function Read-UsageCache {
    $cache = Read-JsonFile $script:UsageCachePath
    if (-not (Test-DictHas $cache 'accounts')) { return @{ accounts = @{} } }
    return $cache
}

function Get-UsageAccountIds {
    $ids = @{}
    foreach ($profile in @(Get-Profiles)) { $ids[[string]$profile.Uuid] = $true }
    $cliRoot = Join-Path $script:CliRoot 'profiles'
    if (Test-Path -LiteralPath $cliRoot) {
        foreach ($directory in Get-ChildItem -LiteralPath $cliRoot -Directory) {
            if ($directory.Name -match $script:GuidRx) { $ids[[string]$directory.Name] = $true }
        }
    }
    return @($ids.Keys | Sort-Object)
}

function Get-UsageAuthentication([string]$uuid, $current = $null) {
    if (-not $current) { $current = Get-CliLiveState }
    if ($current.Verified -and $current.Uuid -ieq $uuid) { return @{ oauth = $current.Oauth; active = $true } }
    try {
        $profile = Read-CliProfile $uuid
        return @{ oauth = $profile['oauth']; active = $false }
    } catch { return $null }
}

function Request-UsageHttp([string]$url, [string]$token, $body = $null) {
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    $method = if ($null -eq $body) { [Net.Http.HttpMethod]::Get } else { [Net.Http.HttpMethod]::Post }
    $request = New-Object Net.Http.HttpRequestMessage($method, $url)
    try {
        if ($token) {
            $request.Headers.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token)
            [void]$request.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
        }
        if ($null -ne $body) {
            $request.Content = New-Object Net.Http.StringContent($script:Ser.Serialize($body), [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $payload = $null
            if ($response.IsSuccessStatusCode) {
                try { $payload = $script:Ser.DeserializeObject($response.Content.ReadAsStringAsync().GetAwaiter().GetResult()) } catch {}
            }
            $retrySeconds = 300
            if ($response.Headers.RetryAfter) {
                if ($response.Headers.RetryAfter.Delta) { $retrySeconds = [Math]::Max(300, ([TimeSpan]$response.Headers.RetryAfter.Delta).TotalSeconds) }
                elseif ($response.Headers.RetryAfter.Date) { $retrySeconds = [Math]::Max(300, ([DateTimeOffset]$response.Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds) }
            }
            return @{ status = [int]$response.StatusCode; body = $payload; retrySeconds = [Math]::Min(86400, $retrySeconds) }
        } finally { $response.Dispose() }
    } catch { return @{ status = 0; body = $null; retrySeconds = 60 } }
    finally { $request.Dispose(); $client.Dispose(); $handler.Dispose() }
}

function Renew-InactiveUsageAuthentication([string]$uuid) {
    # Refresh only an inactive CLI profile. The normal CLI owns renewal of its active login.
    $script:LastRenewStatus = 0
    $result = Invoke-CliLocked {
        $current = Get-CliLiveState
        if ($current.Verified -and $current.Uuid -ieq $uuid) { return $null }
        $profile = Read-CliProfile $uuid
        $oauth = $profile['oauth']
        $expiresAt = $oauth['expiresAt']
        if ($expiresAt -and [double]$expiresAt -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 60000) { return $oauth }
        $reply = Request-UsageHttp 'https://platform.claude.com/v1/oauth/token' '' @{
            grant_type = 'refresh_token'
            refresh_token = (Get-DictString $oauth 'refreshToken')
            client_id = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
        }
        Write-Log ('Usage: làm mới đăng nhập CLI {0}, HTTP {1}.' -f $uuid, $reply.status)
        $script:LastRenewStatus = [int]$reply.status
        $data = $reply.body
        if ($reply.status -ne 200 -or -not (Get-DictString $data 'access_token') -or -not (Test-DictHas $data 'expires_in')) { return $null }
        $renewed = @{}
        foreach ($key in $oauth.Keys) { $renewed[[string]$key] = $oauth[$key] }
        $renewed['accessToken'] = Get-DictString $data 'access_token'
        $refreshToken = Get-DictString $data 'refresh_token'
        if ($refreshToken) { $renewed['refreshToken'] = $refreshToken }
        $renewed['expiresAt'] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + [double]$data['expires_in'] * 1000
        $scope = Get-DictString $data 'scope'
        if ($scope) { $renewed['scopes'] = @($scope -split ' ') }
        $state = @{ LoggedIn = $true; Verified = $true; Uuid = [string]$uuid; Oauth = $renewed; Account = $profile['account'] }
        $state = $script:Ser.DeserializeObject(($state | ConvertTo-Json -Depth 20 -Compress))
        Save-CliProfile $state
        return $renewed
    }
    return $result
}

function ConvertTo-UsageWindows($payload) {
    $labels = [ordered]@{
        five_hour = '5 giờ'
        seven_day = '7 ngày'
        seven_day_opus = 'Opus · 7 ngày'
        seven_day_sonnet = 'Sonnet · 7 ngày'
        seven_day_overage_included = 'Fable · 7 ngày'
    }
    $windows = New-Object System.Collections.ArrayList
    foreach ($key in $labels.Keys) {
        if (-not (Test-DictHas $payload $key)) { continue }
        $window = $payload[$key]
        if (-not (Test-DictHas $window 'utilization')) { continue }
        $percent = $window['utilization']
        if ($null -eq $percent -or $percent -is [string] -or $percent -is [bool]) { continue }
        try { $percent = [double]$percent } catch { continue }
        if ([double]::IsNaN($percent) -or [double]::IsInfinity($percent) -or $percent -lt 0 -or $percent -gt 100) { continue }
        $reset = $null
        $timestamp = Get-DictString $window 'resets_at'
        if ($timestamp) {
            $date = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { $reset = $date.ToUniversalTime().ToString('o') }
        }
        [void]$windows.Add(@{ id = [string]$key; label = [string]$labels[$key]; usedPercent = [double]$percent; resetsAt = $reset })
    }
    return ,$windows.ToArray()
}

function Get-UsageAuthFingerprint($auth) {
    if (-not $auth) { return '' }
    $token = Get-DictString $auth.oauth 'accessToken'
    if (-not $token) { return '' }
    return [string](Get-Sha256Bytes $script:Utf8NoBom.GetBytes($token))
}

function Read-UsageDate($value) {
    $date = [DateTimeOffset]::MinValue
    if ($value -is [string] -and [DateTimeOffset]::TryParse($value, [ref]$date)) { return $date }
    return [DateTimeOffset]::MinValue
}

function Use-DesktopUsageFallback([string]$uuid, $record) {
    if ($record.state -eq 'ok' -or -not $DataDir) { return $record }
    $history = Read-JsonFile (Join-Path $DataDir 'plan-usage-history.json')
    $meta = Read-JsonFile (Join-Path (Get-ProfileDir $uuid) 'meta.json')
    $org = Get-DictString $meta 'orgUuid'
    if (-not $org -or -not (Test-DictHas $history 'samples')) { return $record }
    # Native Desktop v2 stores explicit organization IDs. Legacy unscoped samples are excluded.
    $sample = @($history['samples'] | Where-Object { (Get-DictString $_ 'org') -ieq $org } | Sort-Object { $_['t'] } -Descending | Select-Object -First 1)
    if ($sample.Count -eq 0) { return $record }
    $sample = $sample[0]
    try { $time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$sample['t']) } catch { return $record }
    if ($time -lt (Read-UsageDate $record.updatedAt) -or $time -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) { return $record }
    $payload = @{}
    $mapping = @{ fh='five_hour'; sd='seven_day'; so='seven_day_opus'; sn='seven_day_sonnet' }
    foreach ($key in $mapping.Keys) {
        if (Test-DictHas $sample['u'] $key) { $payload[$mapping[$key]] = @{ utilization=$sample['u'][$key]; resets_at=$null } }
    }
    $windows = ConvertTo-UsageWindows $payload
    if ($windows.Count -eq 0) { return $record }
    $record.state = 'cached'
    $record.updatedAt = $time.ToUniversalTime().ToString('o')
    $record.windows = $windows
    $record.message = 'Dữ liệu gần nhất từ Desktop. Chưa lấy được số liệu trực tiếp.'
    return $record
}

function Update-AccountUsage([string]$uuid, $previous, [bool]$force, $live = $null) {
    $now = [DateTimeOffset]::UtcNow
    $auth = Get-UsageAuthentication $uuid $live
    $fingerprint = Get-UsageAuthFingerprint $auth
    $sameAuth = $previous -and (Get-DictString $previous 'authFingerprint') -ceq $fingerprint
    if ($sameAuth -and (Read-UsageDate $previous['retryAt']) -gt $now) { return (Use-DesktopUsageFallback $uuid $previous) }
    $maxAgeSeconds = if ($force) { 60 } else { 120 }
    if ($sameAuth -and (Read-UsageDate $previous['checkedAt']) -gt $now.AddSeconds(-$maxAgeSeconds)) { return (Use-DesktopUsageFallback $uuid $previous) }
    $record = @{ state = 'unavailable'; checkedAt = $now.ToString('o'); updatedAt = $null; authFingerprint = $fingerprint; windows = @(); message = ''; retryAt = $null }
    if ($previous) { $record.updatedAt = $previous['updatedAt']; $record.windows = $previous['windows'] }
    if (-not $auth) {
        $record.state = 'missing_login'; $record.message = 'Đăng nhập account này trong mục CLI để xem usage.'
        $removed = Get-DictString (Read-JsonFile (Join-Path (Get-CliProfileDir $uuid) 'meta.json')) 'authRemovedReason'
        if ($removed) { $record.message = $removed }
        # Never keep showing numbers that may belong to another account.
        if ($removed) { $record.windows = @(); $record.updatedAt = $null }
        return (Use-DesktopUsageFallback $uuid $record)
    }
    $oauth = $auth.oauth
    $expired = $oauth['expiresAt'] -and [double]$oauth['expiresAt'] -le $now.ToUnixTimeMilliseconds() + 60000
    if ($expired -and -not $auth.active) {
        try { $renewed = Renew-InactiveUsageAuthentication $uuid } catch { $renewed = $null }
        if ($renewed) { $oauth = $renewed; $record.authFingerprint = Get-UsageAuthFingerprint @{ oauth = $oauth } }
        elseif ($script:LastRenewStatus -in @(400, 401)) {
            $record.state = 'login_expired'; $record.message = 'Đăng nhập CLI đã lưu của account này đã bị thu hồi. Đăng nhập lại account này trong mục CLI.'; $record.retryAt = $now.AddHours(6).ToString('o')
            return (Use-DesktopUsageFallback $uuid $record)
        }
    }
    # A token saved under this account must really belong to it, otherwise two cards show one account's quota.
    $owner = Resolve-CliTokenOwner $oauth $uuid -SkipSavedProfiles
    if ($owner -and $owner -ine $uuid) {
        $record.state = 'wrong_account'; $record.windows = @(); $record.updatedAt = $null
        $record.message = 'Đăng nhập đã lưu thuộc account khác. Đăng nhập lại account này trong mục CLI.'
        return $record
    }
    if ($oauth['expiresAt'] -and [double]$oauth['expiresAt'] -le $now.ToUnixTimeMilliseconds()) {
        $record.state = 'login_expired'; $record.message = 'Đăng nhập CLI đã hết hạn. Mở CLI hoặc đăng nhập lại để cập nhật.'; $record.retryAt = $now.AddMinutes(10).ToString('o')
        return (Use-DesktopUsageFallback $uuid $record)
    }
    $reply = Request-UsageHttp 'https://api.anthropic.com/api/oauth/usage' (Get-DictString $oauth 'accessToken')
    switch ($reply.status) {
        200 {
            $windows = ConvertTo-UsageWindows $reply.body
            if ($windows.Count -gt 0) { $record.state = 'ok'; $record.windows = $windows; $record.updatedAt = [DateTimeOffset]::UtcNow.ToString('o') }
            else { $record.message = 'Máy chủ chưa trả về cửa sổ usage của account này.' }
        }
        401 { $record.state = 'login_expired'; $record.message = 'Đăng nhập CLI cần được làm mới để xem usage.'; $record.retryAt = $now.AddMinutes(10).ToString('o') }
        403 { $record.message = 'Đăng nhập này chưa được phép đọc usage.'; $record.retryAt = $now.AddMinutes(10).ToString('o') }
        429 { $record.state = 'limited'; $record.message = 'Máy chủ đang giới hạn lượt kiểm tra usage. Công cụ sẽ thử lại sau.'; $record.retryAt = $now.AddSeconds($reply.retrySeconds).ToString('o') }
        default { $record.message = 'Chưa kết nối được máy chủ usage. Bấm cập nhật để thử lại.'; $record.retryAt = $now.AddMinutes(1).ToString('o') }
    }
    return (Use-DesktopUsageFallback $uuid $record)
}

# Saved CLI profiles written before token-owner checks existed may hold another account's
# login (Desktop-embedded Claude Code rewrites ~/.claude.json). Move such copies aside.
function Repair-CliProfileOwners {
    $root = Join-Path $script:CliRoot 'profiles'
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory) {
        if ($dir.Name -notmatch $script:GuidRx) { continue }
        $auth = Join-Path $dir.FullName 'auth.bin'
        if (-not (Test-Path -LiteralPath $auth)) { continue }
        try { $saved = Read-CliProfile $dir.Name } catch { continue }
        $owner = Resolve-CliTokenOwner $saved['oauth'] $dir.Name -SkipSavedProfiles
        if (-not $owner -or $owner -ieq $dir.Name) { continue }
        Invoke-CliLocked {
            # Keep the login for its real owner when it is newer than that owner's saved copy.
            $ownerSaved = $null
            try { $ownerSaved = Read-CliProfile $owner } catch {}
            $ownerExpires = if ($ownerSaved -and $ownerSaved['oauth']['expiresAt']) { [double]$ownerSaved['oauth']['expiresAt'] } else { 0 }
            $wrongExpires = if ($saved['oauth']['expiresAt']) { [double]$saved['oauth']['expiresAt'] } else { 0 }
            if ($ownerSaved -and $wrongExpires -gt $ownerExpires) {
                Save-CliProfile @{ LoggedIn = $true; Verified = $true; Uuid = $owner; Oauth = $saved['oauth']; Account = $ownerSaved['account'] }
            }
            $aside =Join-Path $dir.FullName ('auth.wrong-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bin')
            Move-Item -LiteralPath $auth -Destination $aside
            $metaPath = Join-Path $dir.FullName 'meta.json'
            $meta = Read-JsonFile $metaPath
            if (-not $meta) { $meta = @{} }
            $meta['authRemovedReason'] = 'Đăng nhập đã lưu bị lẫn sang account khác nên đã được gỡ. Đăng nhập lại account này trong mục CLI.'
            Write-JsonFile $metaPath $meta
        }
        Write-Log ('CLI: profile {0} chứa đăng nhập của {1}; đã chuyển sang file .wrong.' -f $dir.Name, $owner)
    }
}

function Invoke-RefreshUsage([bool]$force = $false) {
    $lockName = 'Local\ClaudeSwitch.Usage.' + (Get-Sha256Bytes $script:Utf8NoBom.GetBytes($StoreDir.ToLowerInvariant())).Substring(0,16)
    $mutex = New-Object Threading.Mutex($false, $lockName)
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return (Read-UsageCache) }
        $cache = Read-UsageCache
        if (-not $NoAppControl) {
            try { Repair-CliProfileOwners } catch { Write-Log ('Usage: kiểm tra account CLI lỗi: ' + $_.Exception.Message) }
            $live = Get-CliLiveState
            if ($live.Verified) { Sync-ActiveCliProfile $live }
            foreach ($uuid in @(Get-UsageAccountIds)) {
                $previous = if (Test-DictHas $cache['accounts'] $uuid) { $cache['accounts'][$uuid] } else { $null }
                try { $cache['accounts'][$uuid] = Update-AccountUsage $uuid $previous $force $live }
                catch { $cache['accounts'][$uuid] = @{ state = 'unavailable'; checkedAt = [DateTimeOffset]::UtcNow.ToString('o'); updatedAt = $null; windows = @(); message = 'Chưa đọc được usage của account này.' } }
            }
            $cache = $script:Ser.DeserializeObject(($cache | ConvertTo-Json -Depth 20 -Compress))
            Write-JsonFile $script:UsageCachePath $cache
        }
        return $cache
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
