#requires -Version 5.1
<#
  Claude Switch - Engine (khong co giao dien).
  Actions: Status | Save | Switch | PrepareAdd | SyncSessions | RemoveCopies | SetLabel | CheckConfig
  Exit code: 0 = thanh cong, 1 = loi, 3 = chua dang nhap (Save khong luu gi).
  Khong bao gio ghi token vao log / progress / meta.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status','Save','Switch','PrepareAdd','SyncSessions','RemoveCopies','SetLabel','CheckConfig','CliSave','CliSwitch','CliLogin','CliFinishLogin','CliOpen','CliSetLabel','RefreshUsage')]
    [string]$Action = 'Status',
    [string]$TargetAccount,
    [string]$DataDir,
    [string]$StoreDir,
    [string]$ClaudeJson,
    [string]$CliPath,
    [string]$CliConfigDir,
    [string]$CliConfigFile,
    [switch]$NoAppControl,
    [string]$ProgressFile,
    [string]$OutFile,
    [string]$Label,
    [string]$FailAt,
    [switch]$ForceUsage
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web.Extensions

$script:KeyTc   = 'oauth:tokenCache'
$script:KeyTc2  = 'oauth:tokenCacheV2'
$script:KeyUuid = 'lastKnownAccountUuid'
$script:KeyNames = @($script:KeyTc, $script:KeyTc2, $script:KeyUuid)
$script:ScalarRx = '(?:"(?:[^"\\]|\\.)*"|null|true|false|-?\d[\d.eE+\-]*)'
$script:GuidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Ser.MaxJsonLength = [int]::MaxValue
$script:Ser.RecursionLimit = 200

if (-not $StoreDir)   { $StoreDir = Join-Path $env:LOCALAPPDATA 'ClaudeSwitch' }
if (-not $ClaudeJson) { $ClaudeJson = Join-Path $env:USERPROFILE '.claude.json' }
if (-not $DataDir) {
    $c = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Directory -Filter 'claude_*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $DataDir = $c.FullName }
}
$script:ConfigPath  = if ($DataDir) { Join-Path $DataDir 'config.json' } else { $null }
$script:CookiesPath = if ($DataDir) { Join-Path (Join-Path $DataDir 'Network') 'Cookies' } else { $null }
$script:JournalPath = if ($DataDir) { Join-Path (Join-Path $DataDir 'Network') 'Cookies-journal' } else { $null }
$script:SessionsRoot = if ($DataDir) { Join-Path $DataDir 'claude-code-sessions' } else { $null }

# ---------------------------------------------------------------- tien ich chung
function Ensure-Dir([string]$p) { if ($p -and -not (Test-Path -LiteralPath $p)) { [void][IO.Directory]::CreateDirectory($p) } }

function Write-Log([string]$msg) {
    if ($Action -eq 'CheckConfig') { return }
    try {
        $dir = Join-Path $StoreDir 'logs'
        Ensure-Dir $dir
        $f = Join-Path $dir ('claude-switch-{0:yyyyMMdd}.log' -f (Get-Date))
        [IO.File]::AppendAllText($f, ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg) + "`r`n", $script:Utf8NoBom)
    } catch {}
}

function Write-Step([string]$step, [string]$state, [string]$msg) {
    Write-Log ('[{0}] {1} {2}' -f $step, $state, $msg)
    if ($ProgressFile) {
        try {
            $o = [ordered]@{ step = $step; state = $state; message = $msg; time = (Get-Date).ToString('o') }
            $line = $script:Ser.Serialize($o)
            Ensure-Dir (Split-Path -Parent $ProgressFile)
            [IO.File]::AppendAllText($ProgressFile, $line + "`r`n", $script:Utf8NoBom)
        } catch {}
    }
}

function Read-AllBytesShared([string]$path) {
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); return , $ms.ToArray() } finally { $fs.Dispose() }
}

function Write-FileAtomic([string]$path, [byte[]]$bytes) {
    Ensure-Dir (Split-Path -Parent $path)
    $tmp = $path + '.cs-tmp'
    [IO.File]::WriteAllBytes($tmp, $bytes)
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}

function Get-Sha256Bytes([byte[]]$b) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($h.ComputeHash($b))).Replace('-', '') } finally { $h.Dispose() }
}
function Get-Sha256File([string]$p) { return (Get-Sha256Bytes (Read-AllBytesShared $p)) }

function Test-DictHas($d, [string]$k) { return ($null -ne $d) -and ($d -is [System.Collections.IDictionary]) -and ([System.Collections.IDictionary]$d).Contains($k) }
function Get-DictString($d, [string]$k) {
    if (Test-DictHas $d $k) { $v = ([System.Collections.IDictionary]$d)[$k]; if ($v -is [string]) { return $v } }
    return $null
}

function Read-JsonFile([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $b = Read-AllBytesShared $path
        $skip = 0; if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $skip = 3 }
        $t = $script:Utf8NoBom.GetString($b, $skip, $b.Length - $skip)
        if ($t.Trim().Length -eq 0) { return $null }
        return $script:Ser.DeserializeObject($t)
    } catch { return $null }
}
function Write-JsonFile([string]$path, $obj) {
    Write-FileAtomic $path ($script:Utf8NoBom.GetBytes($script:Ser.Serialize($obj)))
}

function Emit($obj) {
    $json = $script:Ser.Serialize($obj)
    if ($OutFile) { Ensure-Dir (Split-Path -Parent $OutFile); [IO.File]::WriteAllText($OutFile, $json, $script:Utf8NoBom) }
    else { [Console]::Out.WriteLine($json) }
}

function Get-Settings {
    $s = @{ syncSessions = $true; skipConfirm = $false; hintShown = $false }
    $d = Read-JsonFile (Join-Path $StoreDir 'settings.json')
    if ($d -is [System.Collections.IDictionary]) {
        foreach ($k in @('syncSessions', 'skipConfirm', 'hintShown')) { if (Test-DictHas $d $k) { $s[$k] = [bool]$d[$k] } }
    }
    return $s
}

# ---------------------------------------------------------------- config.json (muc van ban)
function Read-TextInfo([string]$path) {
    $b = Read-AllBytesShared $path
    $pre = 0
    $enc = New-Object Text.UTF8Encoding($false, $true)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $pre = 3 }
    elseif ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $pre = 2; $enc = New-Object Text.UnicodeEncoding($false, $false, $true) }
    elseif ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $pre = 2; $enc = New-Object Text.UnicodeEncoding($true, $false, $true) }
    $preBytes = New-Object byte[] $pre
    if ($pre -gt 0) { [Array]::Copy($b, 0, $preBytes, 0, $pre) }
    try { $text = $enc.GetString($b, $pre, $b.Length - $pre) } catch { throw 'config.json không đọc được (sai mã hóa ký tự).' }
    return @{ Bytes = $b; Text = $text; Pre = $preBytes; Enc = $enc }
}
function Get-TextBytes($info, [string]$text) {
    $body = $info.Enc.GetBytes($text)
    $all = New-Object byte[] ($info.Pre.Length + $body.Length)
    if ($info.Pre.Length -gt 0) { [Array]::Copy($info.Pre, 0, $all, 0, $info.Pre.Length) }
    [Array]::Copy($body, 0, $all, $info.Pre.Length, $body.Length)
    return , $all
}

function ConvertTo-JsonLiteral([string]$s) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"') }
            '\'  { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            "`b" { [void]$sb.Append('\b') }
            "`f" { [void]$sb.Append('\f') }
            default {
                if ([int][char]$ch -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', [int][char]$ch) } else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-KeyCount([string]$text, [string]$key) {
    return ([regex]::Matches($text, '"' + [regex]::Escape($key) + '"\s*:')).Count
}

function Test-ConfigEditable([string]$text) {
    foreach ($k in $script:KeyNames) {
        $n = Get-KeyCount $text $k
        if ($n -gt 1) { throw "config.json có khóa '$k' xuất hiện $n lần nên công cụ không dám sửa. Chưa có gì bị thay đổi." }
        if ($n -eq 1) {
            $m = [regex]::Matches($text, '("' + [regex]::Escape($k) + '"\s*:\s*)' + $script:ScalarRx)
            if ($m.Count -ne 1) { throw "Giá trị của khóa '$k' trong config.json có định dạng lạ nên công cụ không dám sửa. Chưa có gì bị thay đổi." }
        }
    }
}

function Set-KeyText([string]$text, [string]$key, [string]$value) {
    $n = Get-KeyCount $text $key
    if ($n -gt 1) { throw "Khóa '$key' xuất hiện $n lần trong config.json." }
    $lit = ConvertTo-JsonLiteral $value
    if ($n -eq 1) {
        $m = [regex]::Matches($text, '("' + [regex]::Escape($key) + '"\s*:\s*)' + $script:ScalarRx)
        if ($m.Count -ne 1) { throw "Không khớp được giá trị khóa '$key'." }
        $g = $m[0]
        return $text.Substring(0, $g.Index) + $g.Groups[1].Value + $lit + $text.Substring($g.Index + $g.Length)
    }
    $i = $text.IndexOf('{')
    if ($i -lt 0 -or $text.Substring(0, $i).Trim().Length -ne 0) { throw 'config.json không phải là một đối tượng JSON.' }
    $rest = $text.Substring($i + 1)
    $comma = if ($rest.TrimStart().StartsWith('}')) { '' } else { ',' }
    return $text.Substring(0, $i + 1) + '"' + $key + '": ' + $lit + $comma + $rest
}

function Remove-KeyText([string]$text, [string]$key) {
    $n = Get-KeyCount $text $key
    if ($n -eq 0) { return $text }
    if ($n -gt 1) { throw "Khóa '$key' xuất hiện $n lần trong config.json." }
    $k = [regex]::Escape($key)
    $rx1 = New-Object Text.RegularExpressions.Regex('"' + $k + '"\s*:\s*' + $script:ScalarRx + '\s*,[ \t]*')
    $m = $rx1.Matches($text)
    if ($m.Count -eq 1) { return $text.Substring(0, $m[0].Index) + $text.Substring($m[0].Index + $m[0].Length) }
    $rx2 = New-Object Text.RegularExpressions.Regex(',\s*"' + $k + '"\s*:\s*' + $script:ScalarRx)
    $m = $rx2.Matches($text)
    if ($m.Count -eq 1) { return $text.Substring(0, $m[0].Index) + $text.Substring($m[0].Index + $m[0].Length) }
    $rx3 = New-Object Text.RegularExpressions.Regex('"' + $k + '"\s*:\s*' + $script:ScalarRx)
    $m = $rx3.Matches($text)
    if ($m.Count -eq 1) { return $text.Substring(0, $m[0].Index) + $text.Substring($m[0].Index + $m[0].Length) }
    throw "Không gỡ được khóa '$key'."
}

function Get-MaskedText([string]$text) {
    foreach ($k in $script:KeyNames) {
        $text = [regex]::Replace($text, '("' + [regex]::Escape($k) + '"\s*:\s*)' + $script:ScalarRx, '$1"@"')
    }
    return $text
}

function Get-OtherKeysJson($dict) {
    $copy = [System.Collections.Generic.Dictionary[string,object]]::new()
    foreach ($k in $dict.Keys) { if ($script:KeyNames -notcontains $k) { $copy[$k] = $dict[$k] } }
    return $script:Ser.Serialize($copy)
}

function Get-AuthFromDict($d) {
    $u = Get-DictString $d $script:KeyUuid
    $t1 = Get-DictString $d $script:KeyTc
    $t2 = Get-DictString $d $script:KeyTc2
    # Current Claude versions only write V2. A present legacy key must still be valid.
    if ($u -and $t2 -and ($u -match $script:GuidRx) -and ((-not (Test-DictHas $d $script:KeyTc)) -or $t1)) {
        return @{ Uuid = $u; Tc = $t1; Tc2 = $t2 }
    }
    return $null
}

function Get-ConfigState {
    if (-not $script:ConfigPath -or -not (Test-Path -LiteralPath $script:ConfigPath)) { throw 'Không tìm thấy config.json của Claude (thư mục dữ liệu chưa có).' }
    $info = Read-TextInfo $script:ConfigPath
    $dict = $null
    try { $dict = $script:Ser.DeserializeObject($info.Text) } catch { throw 'config.json đang bị lỗi định dạng nên không đọc được.' }
    if ($dict -isnot [System.Collections.IDictionary]) { throw 'config.json không phải là một đối tượng JSON.' }
    return @{ Info = $info; Dict = $dict; Auth = (Get-AuthFromDict $dict) }
}

function Assert-NewConfig($origState, [string]$newText, $expected, [bool]$expectKeys) {
    $nd = $null
    try { $nd = $script:Ser.DeserializeObject($newText) } catch { throw 'Bản config.json mới không hợp lệ.' }
    if ($nd -isnot [System.Collections.IDictionary]) { throw 'Bản config.json mới không hợp lệ.' }
    if ((Get-OtherKeysJson $nd) -ne (Get-OtherKeysJson $origState.Dict)) { throw 'Kiểm tra sau khi ghi: các khóa khác trong config.json bị thay đổi.' }
    if ($expectKeys) {
        if ((Get-DictString $nd $script:KeyUuid) -ne $expected.Uuid -or (Get-DictString $nd $script:KeyTc) -ne $expected.Tc -or (Get-DictString $nd $script:KeyTc2) -ne $expected.Tc2) {
            throw 'Kiểm tra sau khi ghi: thông tin đăng nhập mới không khớp.'
        }
        $sameKeys = $true
        foreach ($k in $script:KeyNames) { if ((Get-KeyCount $origState.Info.Text $k) -ne (Get-KeyCount $newText $k)) { $sameKeys = $false } }
        if ($sameKeys -and ((Get-MaskedText $newText) -ne (Get-MaskedText $origState.Info.Text))) { throw 'Kiểm tra sau khi ghi: byte ngoài 3 giá trị đăng nhập không còn giống bản gốc.' }
    } else {
        foreach ($k in $script:KeyNames) { if (Test-DictHas $nd $k) { throw 'Kiểm tra sau khi ghi: khóa đăng nhập vẫn còn.' } }
    }
}

function Write-ConfigText($state, [string]$newText) {
    $bytes = Get-TextBytes $state.Info $newText
    $tmp = $script:ConfigPath + '.cs-tmp'
    [IO.File]::WriteAllBytes($tmp, $bytes)
    $back = [IO.File]::ReadAllBytes($tmp)
    if ((Get-Sha256Bytes $back) -ne (Get-Sha256Bytes $bytes)) { Remove-Item -LiteralPath $tmp -Force; throw 'Ghi file tạm không khớp.' }
    [IO.File]::Replace($tmp, $script:ConfigPath, [NullString]::Value)
}

# ---------------------------------------------------------------- cookies
function Read-CookiesBytes {
    # Ok=$true va Bytes=$null nghia la khong co file; Ok=$false la bi khoa
    if (-not $script:CookiesPath -or -not (Test-Path -LiteralPath $script:CookiesPath)) { return @{ Ok = $true; Bytes = $null } }
    try { return @{ Ok = $true; Bytes = (Read-AllBytesShared $script:CookiesPath) } } catch { return @{ Ok = $false; Bytes = $null } }
}

# ---------------------------------------------------------------- profile (DPAPI)
function Get-ProfileDir([string]$uuid) { return (Join-Path (Join-Path $StoreDir 'profiles') $uuid) }

function Write-AuthBin([string]$uuid, $a, $cookiesBytes) {
    $o = [ordered]@{
        v = 1; lastKnownAccountUuid = $a.Uuid; tokenCache = $a.Tc; tokenCacheV2 = $a.Tc2
        cookies = $(if ($cookiesBytes) { [Convert]::ToBase64String($cookiesBytes) } else { $null })
        savedAt = (Get-Date).ToString('o')
    }
    $plain = $script:Utf8NoBom.GetBytes($script:Ser.Serialize($o))
    $enc = [Security.Cryptography.ProtectedData]::Protect($plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    Write-FileAtomic (Join-Path (Get-ProfileDir $uuid) 'auth.bin') $enc
}

function Read-AuthBin([string]$uuid) {
    $p = Join-Path (Get-ProfileDir $uuid) 'auth.bin'
    if (-not (Test-Path -LiteralPath $p)) { throw 'Chưa có thông tin đăng nhập đã lưu cho tài khoản này. Chưa có gì bị thay đổi.' }
    try {
        $enc = [IO.File]::ReadAllBytes($p)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $d = $script:Ser.DeserializeObject($script:Utf8NoBom.GetString($plain))
    } catch { throw 'File đăng nhập đã lưu bị hỏng hoặc không giải mã được. Chưa có gì bị thay đổi. Hãy đăng nhập lại account này rồi lưu lại.' }
    $a = $null
    $u1 = Get-DictString $d 'lastKnownAccountUuid'; $t1 = Get-DictString $d 'tokenCache'; $t2 = Get-DictString $d 'tokenCacheV2'
    if ($u1 -and $t2 -and ($u1 -match $script:GuidRx) -and (($null -eq $d['tokenCache']) -or $t1)) { $a = @{ Uuid = $u1; Tc = $t1; Tc2 = $t2 } }
    if (-not $a -or ($a.Uuid -ine $uuid)) { throw 'File đăng nhập đã lưu không hợp lệ. Chưa có gì bị thay đổi.' }
    $ck = $null
    $cs = Get-DictString $d 'cookies'
    if ($cs) { try { $ck = [Convert]::FromBase64String($cs) } catch { throw 'Phần cookie đã lưu bị hỏng. Chưa có gì bị thay đổi.' } }
    return @{ Auth = $a; Cookies = $ck }
}

function Get-ClaudeJsonAccount {
    $d = Read-JsonFile $ClaudeJson
    if ($d -and (Test-DictHas $d 'oauthAccount') -and ($d['oauthAccount'] -is [System.Collections.IDictionary])) { return $d['oauthAccount'] }
    return $null
}

function Get-OrgFolders([string]$acct) {
    if (-not $script:SessionsRoot) { return @() }
    $root = Join-Path $script:SessionsRoot $acct
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
}
function Get-NewestOrg([string]$acct) {
    $best = $null; $bestT = [datetime]::MinValue
    $folders = @(Get-OrgFolders $acct | Where-Object { $_.Name -match $script:GuidRx })
    foreach ($d in $folders) {
        $f = Get-ChildItem -LiteralPath $d.FullName -Filter 'local_*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($f -and $f.LastWriteTimeUtc -gt $bestT) { $bestT = $f.LastWriteTimeUtc; $best = $d.Name }
    }
    # A newly signed-in account can have only scheduled-tasks.json, with no sessions yet.
    if (-not $best -and $folders.Count -eq 1) { return $folders[0].Name }
    return $best
}
function Get-SessionCount([string]$acct, [string]$org) {
    if (-not $org -or -not $script:SessionsRoot) { return 0 }
    $p = Join-Path (Join-Path $script:SessionsRoot $acct) $org
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    return @(Get-ChildItem -LiteralPath $p -Filter 'local_*.json' -File -ErrorAction SilentlyContinue).Count
}

function Save-ProfileFromState($st) {
    $a = $st.Auth
    if (-not $a) { return $false }
    $uuid = $a.Uuid
    $pdir = Get-ProfileDir $uuid
    Ensure-Dir $pdir
    $existing = $null
    try { $existing = Read-AuthBin $uuid } catch {}
    $ck = Read-CookiesBytes
    $cookiesBytes = $null; $cookiesUpdated = $false
    if ($ck.Ok -and $ck.Bytes) { $cookiesBytes = $ck.Bytes; $cookiesUpdated = $true }
    elseif ($existing -and $existing.Cookies) { $cookiesBytes = $existing.Cookies }
    Write-AuthBin $uuid $a $cookiesBytes

    $metaPath = Join-Path $pdir 'meta.json'
    $old = Read-JsonFile $metaPath
    $cj = Get-ClaudeJsonAccount
    $match = $cj -and ((Get-DictString $cj 'accountUuid') -ieq $uuid)
    $email = Get-DictString $old 'email'; $disp = Get-DictString $old 'displayName'; $org = Get-DictString $old 'orgUuid'
    if ($match) {
        $e = Get-DictString $cj 'emailAddress'; if ($e) { $email = $e }
        $n = Get-DictString $cj 'displayName'; if ($n) { $disp = $n }
        $o = Get-DictString $cj 'organizationUuid'; if ($o) { $org = $o }
    } else {
        $nw = Get-NewestOrg $uuid
        if ($nw) { $org = $nw }
    }
    $label = Get-DictString $old 'label'
    if (-not $label) {
        if ($disp) { $label = $disp }
        elseif ($email) { $label = ($email -split '@')[0] }
        else { $label = 'Account ' + $uuid.Substring(0, 4) }
    }
    $addedAt = Get-DictString $old 'addedAt'; if (-not $addedAt) { $addedAt = (Get-Date).ToString('o') }
    $hasCk = [bool]$cookiesBytes
    $meta = [ordered]@{ label = $label; email = $email; displayName = $disp; orgUuid = $org; savedAt = (Get-Date).ToString('o'); addedAt = $addedAt; hasCookies = $hasCk }
    Write-JsonFile $metaPath $meta
    if ($ck.Ok -eq $false) { Write-Log 'Cookies đang bị khóa: chỉ lưu phần config, giữ cookie cũ.' }
    Write-Log ("Đã lưu profile {0} (cookie cập nhật: {1})" -f $uuid, $cookiesUpdated)

    $pend = Join-Path $StoreDir 'pending-add.json'
    if (Test-Path -LiteralPath $pend) {
        $pd = Read-JsonFile $pend
        if ((Get-DictString $pd 'previousAccount') -ine $uuid) { Remove-Item -LiteralPath $pend -Force -ErrorAction SilentlyContinue }
    }
    return $true
}

function Get-Profiles {
    $root = Join-Path $StoreDir 'profiles'
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $root) {
        foreach ($d in (Get-ChildItem -LiteralPath $root -Directory)) {
            if ($d.Name -notmatch $script:GuidRx) { continue }
            $m = Read-JsonFile (Join-Path $d.FullName 'meta.json')
            [void]$list.Add(@{ Uuid = $d.Name; Meta = $m; HasAuth = (Test-Path -LiteralPath (Join-Path $d.FullName 'auth.bin')) })
        }
    }
    $sorted = @($list | Sort-Object { [string](Get-DictString $_.Meta 'addedAt') })
    return $sorted
}

# ---------------------------------------------------------------- sao luu
function New-Backup {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $dir = Join-Path (Join-Path $StoreDir 'backups') $ts
    Ensure-Dir $dir
    $info = [ordered]@{ config = $false; cookies = $false; journal = $false }
    if (Test-Path -LiteralPath $script:ConfigPath) { [IO.File]::WriteAllBytes((Join-Path $dir 'config.json'), (Read-AllBytesShared $script:ConfigPath)); $info.config = $true }
    if (Test-Path -LiteralPath $script:CookiesPath) { [IO.File]::WriteAllBytes((Join-Path $dir 'Cookies'), (Read-AllBytesShared $script:CookiesPath)); $info.cookies = $true }
    if (Test-Path -LiteralPath $script:JournalPath) { [IO.File]::WriteAllBytes((Join-Path $dir 'Cookies-journal'), (Read-AllBytesShared $script:JournalPath)); $info.journal = $true }
    [IO.File]::WriteAllText((Join-Path $dir 'backup.json'), $script:Ser.Serialize($info), $script:Utf8NoBom)
    $all = @(Get-ChildItem -LiteralPath (Join-Path $StoreDir 'backups') -Directory | Sort-Object Name -Descending)
    if ($all.Count -gt 10) { foreach ($old in ($all | Select-Object -Skip 10)) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
    return @{ Dir = $dir; Info = $info }
}

function Restore-Backup($bk) {
    $dir = $bk.Dir
    if ($bk.Info.config) { Write-FileAtomic $script:ConfigPath ([IO.File]::ReadAllBytes((Join-Path $dir 'config.json'))) }
    if ($bk.Info.cookies) { Write-FileAtomic $script:CookiesPath ([IO.File]::ReadAllBytes((Join-Path $dir 'Cookies'))) }
    elseif (Test-Path -LiteralPath $script:CookiesPath) { Remove-Item -LiteralPath $script:CookiesPath -Force }
    if ($bk.Info.journal) { Write-FileAtomic $script:JournalPath ([IO.File]::ReadAllBytes((Join-Path $dir 'Cookies-journal'))) }
    elseif (Test-Path -LiteralPath $script:JournalPath) { Remove-Item -LiteralPath $script:JournalPath -Force }
}

# ---------------------------------------------------------------- dieu khien app
function Get-ClaudeProcs {
    return @(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object { try { -not $_.HasExited -and $_.Path -like '*\WindowsApps\Claude_*' } catch { $false } })
}

function Stop-ClaudeProcessTree($process) {
    # Target only a verified Desktop process, never the standalone CLI executable.
    try {
        $live=Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if (-not $live -or $live.HasExited -or $live.Path -notlike '*\WindowsApps\Claude_*' -or $live.StartTime -ne $process.StartTime) { return }
        $taskkill=Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=$taskkill; $psi.Arguments='/PID '+$live.Id+' /T /F'
        $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.WindowStyle='Hidden'
        $psi.RedirectStandardError=$true; $psi.RedirectStandardOutput=$true
        $killer=[Diagnostics.Process]::Start($psi)
        try {
            $stderr=$killer.StandardError.ReadToEndAsync(); $stdout=$killer.StandardOutput.ReadToEndAsync()
            if($killer.WaitForExit(5000)){$code=$killer.ExitCode}else{$code=-1;try{$killer.Kill()}catch{}}
        } finally { $killer.Dispose() }
        if ($code -ne 0) { Write-Log ('taskkill Desktop PID {0}: exit {1}' -f $live.Id,$code) }
    } catch { Write-Log ('Không đóng được tiến trình Desktop PID {0}: {1}' -f $process.Id,$_.Exception.Message) }
}

function Stop-ClaudeApp {
    if ($NoAppControl) { Write-Log 'NoAppControl: bỏ qua đóng app.'; return }
    $procs = Get-ClaudeProcs
    if ($procs.Count -eq 0) { return }
    $mainIds=@($procs | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | ForEach-Object { $_.Id })
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch {} }
    $end = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $end -and (Get-ClaudeProcs).Count -gt 0) { Start-Sleep -Milliseconds 300 }
    $end = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $end) {
        $remaining=@(Get-ClaudeProcs)
        if ($remaining.Count -eq 0) { break }
        # Kill the main tree first; re-enumerate to catch helpers spawned while closing.
        foreach ($p in @($remaining | Sort-Object { if($mainIds -contains $_.Id){0}else{1} })) { Stop-ClaudeProcessTree $p }
        Start-Sleep -Milliseconds 300
    }
    if ((Get-ClaudeProcs).Count -gt 0) { throw 'Không đóng hẳn được Claude. Hãy tự thoát Claude (kể cả ở khay hệ thống) rồi thử lại. Chưa có gì bị thay đổi.' }
    Start-Sleep -Milliseconds 800
}

function Get-ClaudeAppId {
    try {
        $a = Get-StartApps | Where-Object { $_.AppID -like 'Claude_*' -or ($_.Name -eq 'Claude' -and $_.AppID -like '*!*') } | Select-Object -First 1
        if ($a) { return $a.AppID }
    } catch {}
    try {
        $pkg = Get-AppxPackage | Where-Object { $_.PackageFamilyName -like 'Claude_*' } | Select-Object -First 1
        if ($pkg) {
            $appId = (Get-AppxPackageManifest $pkg).Package.Applications.Application.Id
            if ($appId) { return ('{0}!{1}' -f $pkg.PackageFamilyName, ($appId | Select-Object -First 1)) }
        }
    } catch {}
    return $null
}

function Start-ClaudeApp {
    if ($NoAppControl) { Write-Log 'NoAppControl: bỏ qua mở app.'; return $true }
    try {
        $id = Get-ClaudeAppId
        if (-not $id) { Write-Log 'Không tìm thấy AppID của Claude.'; return $false }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $id)
        return $true
    } catch { Write-Log 'Mở Claude thất bại.'; return $false }
}

# ---------------------------------------------------------------- dong bo session
function Get-LastActivityMs([string]$path) {
    try {
        $d = $script:Ser.DeserializeObject($script:Utf8NoBom.GetString((Read-AllBytesShared $path)))
        if ($d -is [System.Collections.IDictionary] -and (Test-DictHas $d 'lastActivityAt')) {
            $v = $d['lastActivityAt']
            if ($v -is [string]) {
                $dt = [datetime]::MinValue
                if ([datetime]::TryParse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dt)) {
                    return ([double]([DateTimeOffset]$dt).ToUnixTimeMilliseconds())
                }
            } elseif ($null -ne $v) { return [double]$v }
        }
    } catch {}
    return $null
}

function Get-SyncOrgDir($p) {
    $org = Get-DictString $p.Meta 'orgUuid'
    if (-not $org) { $org = Get-NewestOrg $p.Uuid }
    if (-not $org) { return $null }
    return (Join-Path (Join-Path $script:SessionsRoot $p.Uuid) $org)
}

function Read-Manifest {
    $m = Read-JsonFile (Join-Path $StoreDir 'synced.json')
    $seen = [System.Collections.Generic.Dictionary[string,object]]::new()
    $copies = [System.Collections.ArrayList]::new()
    if ($m -is [System.Collections.IDictionary]) {
        if ((Test-DictHas $m 'seen') -and ($m['seen'] -is [System.Collections.IDictionary])) { foreach ($k in $m['seen'].Keys) { $seen[[string]$k] = 1 } }
        if ((Test-DictHas $m 'copies') -and $m['copies']) { foreach ($c in $m['copies']) { if ($c -is [System.Collections.IDictionary]) { [void]$copies.Add($c) } } }
    }
    return @{ Seen = $seen; Copies = $copies }
}
function Save-Manifest($m) {
    $o = [ordered]@{ seen = $m.Seen; copies = $m.Copies.ToArray() }
    Write-JsonFile (Join-Path $StoreDir 'synced.json') $o
}

function Copy-SessionFile([string]$src, [string]$dst) {
    Ensure-Dir (Split-Path -Parent $dst)
    [IO.File]::Copy($src, $dst, $true)
    [IO.File]::SetLastWriteTimeUtc($dst, [IO.File]::GetLastWriteTimeUtc($src))
}

function Invoke-SyncSessions {
    $profiles = @(Get-Profiles)
    $res = @{ copied = 0; updated = 0; skipped = 0 }
    if ($profiles.Count -lt 2) { Write-Log 'Chưa đủ 2 profile để đồng bộ session.'; return $res }
    $orgDirs = @{}
    foreach ($profile in $profiles) {
        $dir = Get-SyncOrgDir $profile
        if (-not $dir) {
            $name = Get-DictString $profile.Meta 'label'
            if (-not $name) { $name = $profile.Uuid.Substring(0, 4) }
            throw ("Chưa xác định được thư mục session của account {0}. Hãy mở Claude bằng account này một lần rồi đồng bộ lại." -f $name)
        }
        $orgDirs[$profile.Uuid] = $dir
    }
    $man = Read-Manifest
    $bkRoot = Join-Path (Join-Path $StoreDir 'session-backups') (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        for ($j = $i + 1; $j -lt $profiles.Count; $j++) {
            $P = $profiles[$i]; $Q = $profiles[$j]
            $dp = $orgDirs[$P.Uuid]; $dq = $orgDirs[$Q.Uuid]
            $pair = (@($P.Uuid, $Q.Uuid) | Sort-Object) -join '|'
            $fp = @{}; $fq = @{}
            if (Test-Path -LiteralPath $dp) { foreach ($f in (Get-ChildItem -LiteralPath $dp -Filter 'local_*.json' -File)) { $fp[$f.Name] = $f } }
            if (Test-Path -LiteralPath $dq) { foreach ($f in (Get-ChildItem -LiteralPath $dq -Filter 'local_*.json' -File)) { $fq[$f.Name] = $f } }
            $names = @($fp.Keys) + @($fq.Keys) | Sort-Object -Unique
            foreach ($n in $names) {
                $key = $pair + '|' + $n
                $inP = $fp.ContainsKey($n); $inQ = $fq.ContainsKey($n)
                if ($inP -and $inQ) {
                    $man.Seen[$key] = 1
                    $a = $fp[$n].FullName; $b = $fq[$n].FullName
                    if ((Get-Sha256File $a) -eq (Get-Sha256File $b)) { continue }
                    $ta = Get-LastActivityMs $a; $tb = Get-LastActivityMs $b
                    $cmp = 0
                    if ($null -ne $ta -and $null -ne $tb) { $cmp = $ta.CompareTo($tb) }
                    if ($cmp -eq 0) { $cmp = $fp[$n].LastWriteTimeUtc.CompareTo($fq[$n].LastWriteTimeUtc) }
                    if ($cmp -eq 0) { $res.skipped++; continue }
                    if ($cmp -gt 0) { $src = $a; $dst = $b; $loserUuid = $Q.Uuid } else { $src = $b; $dst = $a; $loserUuid = $P.Uuid }
                    $bdir = Join-Path $bkRoot $loserUuid
                    Ensure-Dir $bdir
                    [IO.File]::Copy($dst, (Join-Path $bdir $n), $true)
                    Copy-SessionFile $src $dst
                    $h = Get-Sha256File $dst
                    foreach ($c in $man.Copies) { if ((Get-DictString $c 'path') -ieq $dst) { $c['hash'] = $h } }
                    $res.updated++
                } elseif ($inP -or $inQ) {
                    if ($man.Seen.ContainsKey($key)) { continue }   # nguoi dung da xoa: khong tao lai
                    if ($inP) { $src = $fp[$n].FullName; $dst = Join-Path $dq $n; $toUuid = $Q.Uuid } else { $src = $fq[$n].FullName; $dst = Join-Path $dp $n; $toUuid = $P.Uuid }
                    Copy-SessionFile $src $dst
                    $man.Seen[$key] = 1
                    [void]$man.Copies.Add([ordered]@{ path = [string]$dst; hash = [string](Get-Sha256File $dst); account = [string]$toUuid; at = [string](Get-Date).ToString('o') })
                    $res.copied++
                }
            }
        }
    }
    Save-Manifest $man
    Write-Log ("Đồng bộ session: sao chép {0}, cập nhật {1}" -f $res.copied, $res.updated)
    return $res
}

function Invoke-RemoveCopies {
    $man = Read-Manifest
    $keep = New-Object System.Collections.ArrayList
    $removed = 0; $modified = 0
    foreach ($c in $man.Copies) {
        $p = Get-DictString $c 'path'
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        if ((Get-Sha256File $p) -eq (Get-DictString $c 'hash')) { Remove-Item -LiteralPath $p -Force; $removed++ }
        else { [void]$keep.Add($c); $modified++ }
    }
    $man.Copies = $keep
    Save-Manifest $man
    Write-Log ("Gỡ session đã sao chép: xóa {0}, giữ lại {1} (đã bị sửa)" -f $removed, $modified)
    return @{ removed = $removed; kept = $modified }
}

# ---------------------------------------------------------------- Status
function Get-StatusObject {
    $st = $null; $cfgErr = $null
    try { $st = Get-ConfigState } catch { $cfgErr = $_.Exception.Message }
    $active = if ($st -and $st.Auth) { $st.Auth.Uuid } else { $null }
    $plist = New-Object System.Collections.ArrayList
    $activeMeta = $null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $recent = 0
    foreach ($p in (Get-Profiles)) {
        $m = $p.Meta
        $org = Get-DictString $m 'orgUuid'
        if (-not $org) { $org = Get-NewestOrg $p.Uuid }
        $isActive = [bool]($active -and ($active -ieq $p.Uuid))
        if ($isActive) {
            $dir = if ($script:SessionsRoot -and $org) { Join-Path (Join-Path $script:SessionsRoot $p.Uuid) $org } else { $null }
            if ($dir -and (Test-Path -LiteralPath $dir)) {
                foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter 'local_*.json' -File)) {
                    if (($now - [DateTimeOffset]::new($f.LastWriteTimeUtc).ToUnixTimeMilliseconds()) -gt 3600000) { continue }
                    $ms = Get-LastActivityMs $f.FullName
                    if ($null -eq $ms) { $ms = [DateTimeOffset]::new($f.LastWriteTimeUtc).ToUnixTimeMilliseconds() }
                    if (($now - $ms) -le 600000) { $recent++ }
                }
            }
        }
        [void]$plist.Add([ordered]@{
            uuid = $p.Uuid; label = (Get-DictString $m 'label'); email = (Get-DictString $m 'email'); displayName = (Get-DictString $m 'displayName')
            orgUuid = $org; savedAt = (Get-DictString $m 'savedAt'); hasAuth = [bool]$p.HasAuth; isActive = $isActive
            sessionCount = (Get-SessionCount $p.Uuid $org)
        })
    }
    $unsaved = $false
    if ($active) { $unsaved = -not ((Test-Path -LiteralPath (Join-Path (Get-ProfileDir $active) 'auth.bin'))) }
    $running = $false
    if (-not $NoAppControl) { $running = ((Get-ClaudeProcs).Count -gt 0) }
    $pend = Read-JsonFile (Join-Path $StoreDir 'pending-add.json')
    $man = Read-Manifest
    $s = Get-Settings
    $cli = Get-CliStatus
    $desktopInstalled = if ($NoAppControl) { [bool]($script:ConfigPath -and (Test-Path -LiteralPath $script:ConfigPath)) } else { [bool](Get-ClaudeAppId) }
    return [ordered]@{
        ok = $true; dataDir = $DataDir; storeDir = $StoreDir; loggedIn = [bool]$active; activeUuid = $active; unsavedCurrent = $unsaved
        tools = @{ desktop = $desktopInstalled; cli = [bool]$cli.installed }; cli = $cli
        usage = (Read-UsageCache)
        appRunning = $running; profiles = $plist.ToArray(); recentActive = $recent; copiedCount = $man.Copies.Count
        settings = $s; pendingAdd = $(if ($pend) { $pend } else { $null }); configError = $cfgErr
    }
}

# ---------------------------------------------------------------- Switch / PrepareAdd
function Invoke-Switch([string]$target) {
    if (-not $target -or $target -notmatch $script:GuidRx) { throw 'Thiếu mã tài khoản cần chuyển sang.' }
    # a. kiem tra truoc khi dong app
    $tgt = Read-AuthBin $target
    $st = Get-ConfigState
    Test-ConfigEditable $st.Info.Text
    if ($st.Auth -and ($st.Auth.Uuid -ieq $target)) { Write-Step 'done' 'ok' 'Tài khoản này đang được dùng rồi, không cần chuyển.'; return }
    $settings = Get-Settings

    # b. dong app
    Write-Step 'close' 'running' 'Đang đóng Claude…'
    try { Stop-ClaudeApp } catch { Write-Step 'close' 'error' $_.Exception.Message; [void](Start-ClaudeApp); throw }
    Write-Step 'close' 'done' 'Đã đóng Claude.'

    # c. sao luu
    Write-Step 'backup' 'running' 'Đang sao lưu…'
    $bk = $null
    try { $bk = New-Backup } catch { Write-Step 'backup' 'error' 'Không sao lưu được.'; [void](Start-ClaudeApp); throw 'Không sao lưu được cấu hình nên dừng lại. Chưa có gì bị thay đổi.' }

    $warn = $null
    try {
        # d. luu profile hien tai
        $st = Get-ConfigState
        if ($st.Auth) { [void](Save-ProfileFromState $st) } else { Write-Log 'Trạng thái hiện tại chưa đăng nhập: không ghi đè profile.' }
        Write-Step 'backup' 'done' 'Đã sao lưu cấu hình và đăng nhập.'
        if ($FailAt -eq 'afterBackup') { throw 'Lỗi giả lập sau bước sao lưu.' }

        # e. dong bo session
        if ($settings.syncSessions) {
            Write-Step 'sync' 'running' 'Đang đồng bộ session…'
            try { $r = Invoke-SyncSessions; Write-Step 'sync' 'done' ('Đã đồng bộ session (thêm {0}, cập nhật {1}).' -f $r.copied, $r.updated) }
            catch { Write-Log 'Đồng bộ session lỗi (bỏ qua).'; Write-Step 'sync' 'warn' 'Chưa đồng bộ được session, bỏ qua bước này.'; $warn = 'Chưa đồng bộ được session.' }
        } else { Write-Step 'sync' 'skipped' 'Đồng bộ session đang tắt.' }

        # f. ghi dang nhap dich vao config.json
        Write-Step 'switch' 'running' 'Đang đổi tài khoản…'
        $st = Get-ConfigState
        Test-ConfigEditable $st.Info.Text
        $new = $st.Info.Text
        if ($tgt.Auth.Tc) { $new = Set-KeyText $new $script:KeyTc $tgt.Auth.Tc }
        else { $new = Remove-KeyText $new $script:KeyTc }
        $new = Set-KeyText $new $script:KeyTc2 $tgt.Auth.Tc2
        $new = Set-KeyText $new $script:KeyUuid $tgt.Auth.Uuid
        Assert-NewConfig $st $new $tgt.Auth $true
        Write-ConfigText $st $new
        if ($FailAt -eq 'afterConfig') { throw 'Lỗi giả lập sau khi ghi config.' }

        # g. cookie
        if ($tgt.Cookies) { Write-FileAtomic $script:CookiesPath $tgt.Cookies }
        elseif (Test-Path -LiteralPath $script:CookiesPath) { Remove-Item -LiteralPath $script:CookiesPath -Force; Write-Log 'Profile chưa có cookie: đã xóa cookie của account cũ.' }
        if (Test-Path -LiteralPath $script:JournalPath) { Remove-Item -LiteralPath $script:JournalPath -Force }
        if ($FailAt -eq 'afterCookies') { throw 'Lỗi giả lập sau khi ghi cookie.' }
        Write-Step 'switch' 'done' 'Đã đổi tài khoản.'
    } catch {
        $why = $_.Exception.Message
        Write-Log ('LỖI sau bước sao lưu: ' + $why)
        $restored = $true
        try { Restore-Backup $bk } catch { $restored = $false; Write-Log 'Khôi phục từ bản sao lưu bị lỗi!' }
        $opened = Start-ClaudeApp
        $msg = if ($restored) { "Không đổi được tài khoản ($why) Đã khôi phục lại cấu hình và đăng nhập như trước, " + $(if ($opened) { 'Claude đã được mở lại.' } else { 'hãy tự mở lại Claude.' }) }
               else { "Không đổi được tài khoản ($why) VÀ khôi phục tự động cũng lỗi. Bản sao lưu nằm ở: " + $bk.Dir }
        Write-Step 'switch' 'error' $msg
        throw $msg
    }

    # h. mo lai app
    Write-Step 'open' 'running' 'Đang mở lại Claude…'
    if (Start-ClaudeApp) { Write-Step 'open' 'done' 'Đã mở lại Claude.' }
    else { Write-Step 'open' 'warn' 'Chưa tự mở được Claude, hãy mở bằng tay.'; $warn = 'Hãy tự mở lại Claude.' }
    Write-Step 'done' 'ok' $(if ($warn) { 'Đã chuyển tài khoản. ' + $warn } else { 'Đã chuyển tài khoản xong.' })
}

function Invoke-PrepareAdd {
    $st = Get-ConfigState
    if (-not $st.Auth) { throw 'Claude chưa đăng nhập account nào để lưu lại. Hãy đăng nhập account đầu tiên trước.' }
    Test-ConfigEditable $st.Info.Text
    foreach ($k in @($script:KeyTc2, $script:KeyUuid)) { if ((Get-KeyCount $st.Info.Text $k) -ne 1) { throw "config.json thiếu khóa '$k' nên chưa thể thêm account." } }
    $prev = $st.Auth.Uuid

    Write-Step 'close' 'running' 'Đang đóng Claude…'
    try { Stop-ClaudeApp } catch { Write-Step 'close' 'error' $_.Exception.Message; [void](Start-ClaudeApp); throw }
    Write-Step 'close' 'done' 'Đã đóng Claude.'

    Write-Step 'backup' 'running' 'Đang sao lưu…'
    $bk = $null
    try { $bk = New-Backup } catch { Write-Step 'backup' 'error' 'Không sao lưu được.'; [void](Start-ClaudeApp); throw 'Không sao lưu được cấu hình nên dừng lại. Chưa có gì bị thay đổi.' }
    try {
        $st = Get-ConfigState
        if (-not $st.Auth -or -not (Save-ProfileFromState $st)) { throw 'Không lưu được account hiện tại nên không dám gỡ đăng nhập.' }
        [void](Read-AuthBin $st.Auth.Uuid)     # chac chan giai ma duoc
        Write-Step 'backup' 'done' 'Đã sao lưu và lưu account hiện tại.'
        if ($FailAt -eq 'afterBackup') { throw 'Lỗi giả lập sau bước sao lưu.' }

        Write-Step 'switch' 'running' 'Đang chuẩn bị màn hình đăng nhập…'
        $new = $st.Info.Text
        foreach ($k in $script:KeyNames) { $new = Remove-KeyText $new $k }
        Assert-NewConfig $st $new $null $false
        Write-ConfigText $st $new
        if (Test-Path -LiteralPath $script:CookiesPath) { Remove-Item -LiteralPath $script:CookiesPath -Force }
        if (Test-Path -LiteralPath $script:JournalPath) { Remove-Item -LiteralPath $script:JournalPath -Force }
        Write-JsonFile (Join-Path $StoreDir 'pending-add.json') ([ordered]@{ previousAccount = $prev; startedAt = (Get-Date).ToString('o') })
        Write-Step 'switch' 'done' 'Đã chuẩn bị màn hình đăng nhập.'
    } catch {
        $why = $_.Exception.Message
        Write-Log ('LỖI PrepareAdd: ' + $why)
        $restored = $true
        try { Restore-Backup $bk } catch { $restored = $false }
        $opened = Start-ClaudeApp
        $msg = if ($restored) { "Không thêm được account ($why) Đã khôi phục lại như trước, " + $(if ($opened) { 'Claude đã được mở lại.' } else { 'hãy tự mở lại Claude.' }) }
               else { "Không thêm được account ($why) VÀ khôi phục tự động cũng lỗi. Bản sao lưu nằm ở: " + $bk.Dir }
        Write-Step 'switch' 'error' $msg
        throw $msg
    }
    Write-Step 'open' 'running' 'Đang mở lại Claude…'
    if (Start-ClaudeApp) { Write-Step 'open' 'done' 'Claude đã mở ở màn hình đăng nhập.' } else { Write-Step 'open' 'warn' 'Hãy tự mở lại Claude.' }
    Write-Step 'done' 'ok' 'Claude đã mở ở màn hình đăng nhập. Hãy đăng nhập account thứ hai.'
}

function Invoke-CheckConfig {
    $info = Read-TextInfo $script:ConfigPath
    $dict = $null; $parsed = $true
    try { $dict = $script:Ser.DeserializeObject($info.Text) } catch { $parsed = $false }
    $keys = [ordered]@{}
    foreach ($k in $script:KeyNames) {
        $n = Get-KeyCount $info.Text $k
        $rx = [regex]::Matches($info.Text, '("' + [regex]::Escape($k) + '"\s*:\s*)' + $script:ScalarRx).Count
        $len = 0; $isStr = $false
        if ($parsed -and (Test-DictHas $dict $k)) { $v = Get-DictString $dict $k; if ($v) { $isStr = $true; $len = $v.Length } }
        $keys[$k] = [ordered]@{ occurrences = $n; regexMatches = $rx; isNonEmptyString = $isStr; valueLength = $len }
    }
    return [ordered]@{ ok = $true; parsed = $parsed; bom = ($info.Pre.Length -gt 0); keys = $keys }
}

# ---------------------------------------------------------------- main
. (Join-Path $PSScriptRoot 'ClaudeSwitch.Cli.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSwitch.Usage.ps1')
$exitCode = 0
try {
    if ($Action -ne 'CheckConfig') { Ensure-Dir $StoreDir; Write-Log ("== Action: {0}" -f $Action) }
    switch ($Action) {
        'Status' { Emit (Get-StatusObject) }
        'Save' {
            $st = Get-ConfigState
            if (-not $st.Auth) {
                Write-Step 'save' 'skipped' 'Claude chưa đăng nhập nên không lưu gì (giữ nguyên profile đã lưu).'
                Emit ([ordered]@{ ok = $false; saved = $false; reason = 'loggedOut' })
                $exitCode = 3
            } else {
                [void](Save-ProfileFromState $st)
                Write-Step 'save' 'ok' 'Đã lưu đăng nhập hiện tại.'
                Emit ([ordered]@{ ok = $true; saved = $true; uuid = $st.Auth.Uuid })
            }
        }
        'Switch'     { Invoke-Switch $TargetAccount }
        'PrepareAdd' { Invoke-PrepareAdd }
        'SyncSessions' {
            $r = Invoke-SyncSessions
            Write-Step 'sync' 'ok' ('Đã đồng bộ session (thêm {0}, cập nhật {1}).' -f $r.copied, $r.updated)
            Emit ([ordered]@{ ok = $true; copied = $r.copied; updated = $r.updated })
        }
        'RemoveCopies' {
            $r = Invoke-RemoveCopies
            Write-Step 'remove' 'ok' ('Đã gỡ {0} session đã sao chép, giữ lại {1} (đã bị sửa).' -f $r.removed, $r.kept)
            Emit ([ordered]@{ ok = $true; removed = $r.removed; kept = $r.kept })
        }
        'SetLabel' {
            if (-not $TargetAccount -or $TargetAccount -notmatch $script:GuidRx) { throw 'Thiếu mã tài khoản.' }
            $mp = Join-Path (Get-ProfileDir $TargetAccount) 'meta.json'
            $m = Read-JsonFile $mp
            if (-not $m) { throw 'Chưa có profile cho tài khoản này.' }
            $l = ([regex]::Replace([string]$Label, '[\x00-\x1f]', '')).Trim()
            if ($l.Length -gt 30) { $l = $l.Substring(0, 30) }
            if (-not $l) { throw 'Tên không được để trống.' }
            $m['label'] = $l
            Write-JsonFile $mp $m
            Write-Step 'label' 'ok' 'Đã đổi tên.'
        }
        'CheckConfig' { Emit (Invoke-CheckConfig) }
        'RefreshUsage' { Emit (Invoke-RefreshUsage ([bool]$ForceUsage)) }
        'CliSave' { Invoke-CliLocked { Save-CliProfile (Get-CliLiveState) }; Emit @{ok=$true} }
        'CliSwitch' { Invoke-CliLocked { Invoke-CliSwitch $TargetAccount }; Emit @{ok=$true} }
        'CliLogin' { Invoke-CliLocked { Invoke-CliLogin }; Emit @{ok=$true} }
        'CliFinishLogin' { Invoke-CliLocked { Complete-CliLogin }; Emit @{ok=$true} }
        'CliOpen' { [void](Start-CliHost 'open'); Emit @{ok=$true} }
        'CliSetLabel' {
            Invoke-CliLocked {
                if ($TargetAccount -notmatch $script:GuidRx) { throw 'Mã account CLI không hợp lệ.' }
                $path=Join-Path (Get-CliProfileDir $TargetAccount) 'meta.json'
                $meta=Read-JsonFile $path
                $clean=([regex]::Replace([string]$Label,'[\x00-\x1f]','')).Trim()
                if (-not $meta -or -not $clean) { throw 'Tên account CLI không hợp lệ.' }
                if ($clean.Length -gt 30) { $clean=$clean.Substring(0,30) }
                $meta['label']=$clean; Write-JsonFile $path $meta
            }
            Emit @{ok=$true}
        }
    }
} catch {
    $m = $_.Exception.Message
    Write-Step 'done' 'error' $m
    try { Emit ([ordered]@{ok=$false;message=$m}) } catch {}
    $exitCode = 1
}
if ($exitCode -eq 0 -and $Action -in @('Switch', 'PrepareAdd')) { }
exit $exitCode
