#requires -Version 5.1
<#
  Chay toan bo bai kiem tra cua Claude Switch tren du lieu GIA (khong dong vao Claude that).
  Cach chay:  powershell -NoProfile -ExecutionPolicy Bypass -File Tests\Run-Tests.ps1 [-Scratch <thu muc tam>] [-Only <tu khoa>]
#>
param(
    [string]$Scratch,
    [string]$Only,
    [switch]$SkipGui
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $Scratch) { $Scratch = Join-Path ([IO.Path]::GetTempPath()) 'ClaudeSwitchTests' }
$Root   = Split-Path -Parent $PSScriptRoot
$Engine = Join-Path $Root 'ClaudeSwitch.Engine.ps1'
$Gui    = Join-Path $Root 'ClaudeSwitch.ps1'
New-Item -ItemType Directory -Force $Scratch | Out-Null
$Scratch = (Resolve-Path $Scratch).Path
$Utf8 = New-Object Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web.Extensions

$script:Pass = 0; $script:Fail = 0; $script:Failed = New-Object System.Collections.ArrayList
function Assert([bool]$cond, [string]$name) {
    if ($cond) { $script:Pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $script:Fail++; [void]$script:Failed.Add($name); Write-Host "  [FAIL] $name" -ForegroundColor Red }
}
function Section([string]$t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Want([string]$k) { return (-not $Only) -or ($k -like "*$Only*") }

# ---------------------------------------------------------------- du lieu gia
$A = @{ Uuid = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; Org = 'a0a0a0a0-1111-4111-8111-a0a0a0a0a0a0'; Org2 = 'b0b0b0b0-2222-4222-8222-b0b0b0b0b0b0'
        Email = 'an@example.test'; Name = 'Hà An'; Tc = 'FAKETOK-TC-A-q1w2e3+/r4t5=='; Tc2 = 'FAKETOK-TC2-A-z9x8c7+/v6b5=='; Seed = 11 }
$B = @{ Uuid = 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'; Org = 'b0b0b0b0-2222-4222-8222-b0b0b0b0b0b0'
        Email = 'binh@example.test'; Name = 'Bình Nguyễn'; Tc = 'FAKETOK-TC-B-m3n4b5+/v6c7=='; Tc2 = 'FAKETOK-TC2-B-l1k2j3+/h4g5=='; Seed = 22 }

function Build-Config($acct, [switch]$NoKeys, [switch]$Dup, [string]$Tc2Override, [switch]$EmptyTokens) {
    $auth = ''
    if (-not $NoKeys) {
        $tc = $acct.Tc; $tc2 = $acct.Tc2
        if ($Tc2Override) { $tc2 = $Tc2Override }
        if ($EmptyTokens) { $tc = ''; $tc2 = '' }
        $auth = '  "oauth:tokenCache": "' + $tc + '",' + "`r`n" + '  "oauth:tokenCacheV2": "' + $tc2 + '",' + "`r`n" + '  "lastKnownAccountUuid": "' + $acct.Uuid + '",' + "`r`n"
    }
    $dupLine = ''
    if ($Dup) { $dupLine = '  "nestedAuth": { "oauth:tokenCache": "FAKETOK-DUP" },' + "`r`n" }
    return ('{' + "`r`n" +
        '  "theme": "dark",' + "`r`n" +
        '  "bigInt": 9007199254740993,' + "`r`n" +
        '  "huge": 12345678901234567890,' + "`r`n" +
        '  "unicode": "Tiếng Việt ✓ 😀 \u00e9 \"trích dẫn\" back\\slash",' + "`r`n" +
        '  "window": { "bounds": { "x": -8, "y": 0, "w": 1280.5 }, "tabs": [1, 2, { "k": null }], "flag": true },' + "`r`n" +
        $dupLine + $auth +
        '  "tail": "end",' + "`r`n" +
        '  "arr": []' + "`r`n" + '}')
}
function New-CookieBytes($acct) {
    $r = New-Object Random($acct.Seed)
    $b = New-Object byte[] 3000
    $r.NextBytes($b)
    return , $b
}
function Hex([byte[]]$b) { $h = [Security.Cryptography.SHA256]::Create(); try { ([BitConverter]::ToString($h.ComputeHash($b))).Replace('-', '') } finally { $h.Dispose() } }
function FileHash([string]$p) { if (Test-Path -LiteralPath $p) { return (Hex ([IO.File]::ReadAllBytes($p))) } else { return 'MISSING' } }
function MaskedHash([string]$p) {
    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    $t = [regex]::Replace($t, '("(?:oauth:tokenCache|oauth:tokenCacheV2|lastKnownAccountUuid)"\s*:\s*)"(?:[^"\\]|\\.)*"', '$1"@"')
    return (Hex $Utf8.GetBytes($t))
}
function OtherJson([string]$p) {
    $o = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($k in 'oauth:tokenCache', 'oauth:tokenCacheV2', 'lastKnownAccountUuid') { $o.PSObject.Properties.Remove($k) }
    return ($o | ConvertTo-Json -Depth 30 -Compress)
}
function CfgHas([string]$p, $acct) {
    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    return $t.Contains('"oauth:tokenCache": "' + $acct.Tc + '"') -and $t.Contains('"oauth:tokenCacheV2": "' + $acct.Tc2 + '"') -and $t.Contains('"lastKnownAccountUuid": "' + $acct.Uuid + '"')
}

function New-Env([string]$name) {
    $r = Join-Path $Scratch $name
    if (Test-Path $r) { Remove-Item -Recurse -Force $r }
    New-Item -ItemType Directory -Force (Join-Path $r 'data\Network') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $r 'data\claude-code-sessions') | Out-Null
    return @{ Root = $r; Data = (Join-Path $r 'data'); Store = (Join-Path $r 'store'); Cj = (Join-Path $r 'claude.json'); N = 0
              Config = (Join-Path $r 'data\config.json'); Cookies = (Join-Path $r 'data\Network\Cookies'); Journal = (Join-Path $r 'data\Network\Cookies-journal') }
}
function Set-Current($t, $acct, [switch]$Bom, [string]$Tc2Override) {
    $text = Build-Config $acct -Tc2Override $Tc2Override
    [IO.File]::WriteAllText($t.Config, $text, (New-Object Text.UTF8Encoding([bool]$Bom)))
    [IO.File]::WriteAllBytes($t.Cookies, (New-CookieBytes $acct))
    $cj = '{ "numStartups": 3, "oauthAccount": { "accountUuid": "' + $acct.Uuid + '", "emailAddress": "' + $acct.Email + '", "displayName": "' + $acct.Name + '", "organizationUuid": "' + $acct.Org + '", "organizationName": "Org ' + $acct.Name + '" } }'
    [IO.File]::WriteAllText($t.Cj, $cj, $Utf8)
}
function Run-Engine($t, [string[]]$extra) {
    $t.N++
    $prog = Join-Path $t.Root ("progress-{0:000}.jsonl" -f $t.N)
    $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Engine, '-DataDir', $t.Data, '-StoreDir', $t.Store, '-ClaudeJson', $t.Cj, '-NoAppControl', '-ProgressFile', $prog) + $extra
    & powershell.exe @al 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $lines = @(); if (Test-Path $prog) { $lines = @(Get-Content $prog -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }) }
    return @{ Code = $code; Lines = $lines; Progress = $prog }
}
function Save-Acct($t, $acct) { Set-Current $t $acct; $r = Run-Engine $t @('-Action', 'Save'); if ($r.Code -ne 0) { throw "Save $($acct.Name) loi" } }
function Init-Two($t) { Save-Acct $t $A; Save-Acct $t $B }   # ket thuc: dang dung B
function Switch-To($t, $acct, [string[]]$more) { return (Run-Engine $t (@('-Action', 'Switch', '-TargetAccount', $acct.Uuid) + $more)) }
function Last-Msg($r) { if ($r.Lines.Count) { return [string]$r.Lines[-1].message } else { return '' } }
function Get-Status($t) {
    $out = Join-Path $t.Root 'status.json'
    $r = Run-Engine $t @('-Action', 'Status', '-OutFile', $out)
    return (Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function New-Session($t, $acct, $org, [string]$id, [double]$act, [string]$title, [string]$body = '') {
    $d = Join-Path $t.Data ("claude-code-sessions\{0}\{1}" -f $acct.Uuid, $org)
    New-Item -ItemType Directory -Force $d | Out-Null
    $j = '{ "sessionId": "local_' + $id + '", "cliSessionId": "cli-' + $id + '", "cwd": "C:\\Dự án\\' + $id + '", "lastActivityAt": ' + [string]$act + ', "isArchived": false, "title": "' + $title + '"' + $body + ' }'
    $p = Join-Path $d ("local_{0}.json" -f $id)
    [IO.File]::WriteAllText($p, $j, $Utf8)
    return $p
}
function SessDir($t, $acct, $org) { return (Join-Path $t.Data ("claude-code-sessions\{0}\{1}" -f $acct.Uuid, $org)) }

# ================================================================ V2-only login regression
if (Want 'v2login') {
    Section 'V2-only: nhận đăng nhập, lưu và chuyển account'
    $t = New-Env 'v2login'
    Save-Acct $t $A
    $null = Run-Engine $t @('-Action', 'PrepareAdd')
    Set-Current $t $B
    $v2Text = [regex]::Replace((Build-Config $B), '(?m)^  "oauth:tokenCache":.*\r?\n', '')
    [IO.File]::WriteAllText($t.Config, $v2Text, $Utf8)
    $cfgHash = FileHash $t.Config
    $st = Get-Status $t
    Assert ($st.loggedIn -and $st.activeUuid -eq $B.Uuid -and $st.unsavedCurrent) 'Status nhận account B chỉ có token V2'

    # Execute the actual GUI detector without opening a window.
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Gui, [ref]$tokens, [ref]$parseErrors)
    Assert (@($parseErrors).Count -eq 0) 'GUI sửa đổi không có lỗi cú pháp'
    $detector = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-LoginUuid' }, $true)
    . ([scriptblock]::Create($detector.Extent.Text))
    $ConfigPath = $t.Config; $Utf8NoBom = $Utf8
    Assert ((Read-LoginUuid) -eq $B.Uuid) 'Bộ nhận đăng nhập GUI nhận V2-only'
    [IO.File]::WriteAllText($t.Config, $v2Text.Substring(0, $v2Text.Length - 1), $Utf8)
    Assert ($null -eq (Read-LoginUuid)) 'GUI đợi khi Claude chưa ghi xong JSON'
    [IO.File]::WriteAllText($t.Config, $v2Text.Replace($B.Tc2, ''), $Utf8)
    Assert ($null -eq (Read-LoginUuid)) 'GUI từ chối V2 rỗng'
    $r = Run-Engine $t @('-Action', 'Save')
    Assert ($r.Code -eq 3) 'Engine từ chối lưu V2 rỗng'
    [IO.File]::WriteAllText($t.Config, $v2Text, $Utf8)
    $r = Run-Engine $t @('-Action', 'Save')
    $st = Get-Status $t
    Assert ($r.Code -eq 0 -and $st.profiles.Count -eq 2 -and -not $st.pendingAdd) 'Lưu profile B V2-only và hoàn tất pending-add'
    Assert ((FileHash $t.Config) -eq $cfgHash) 'Nhận/lưu account không sửa config đang dùng'
    $r = Switch-To $t $A
    Assert ($r.Code -eq 0 -and (CfgHas $t.Config $A)) 'Chuyển từ V2-only sang profile cũ có hai token'
    $r = Switch-To $t $B
    $d = Get-Content $t.Config -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($r.Code -eq 0 -and $d.lastKnownAccountUuid -eq $B.Uuid -and $d.'oauth:tokenCacheV2' -eq $B.Tc2 -and -not $d.PSObject.Properties['oauth:tokenCache']) 'Chuyển về B: khôi phục V2, gỡ token cũ của A'
    Assert ((FileHash $t.Cookies) -eq (Hex (New-CookieBytes $B))) 'Cookie B khôi phục đúng'
    $other = OtherJson $t.Config
    $r = Run-Engine $t @('-Action', 'PrepareAdd')
    Assert ($r.Code -eq 0 -and (OtherJson $t.Config) -eq $other) 'PrepareAdd hỗ trợ account chỉ có V2, giữ cấu hình khác'
    $r = Switch-To $t $B
    Assert ($r.Code -eq 0 -and (Get-Status $t).activeUuid -eq $B.Uuid) 'Hủy thêm account khôi phục được profile V2-only'
}

# ================================================================ 1. vong tron save/switch
if (Want 'roundtrip') {
    Section '1. Save / Switch vòng tròn, byte còn lại giữ nguyên'
    $t = New-Env 't1'
    Init-Two $t
    Assert ((Test-Path (Join-Path $t.Store "profiles\$($A.Uuid)\auth.bin")) -and (Test-Path (Join-Path $t.Store "profiles\$($B.Uuid)\meta.json"))) 'Save tạo auth.bin + meta.json cho 2 profile'
    $meta = Get-Content (Join-Path $t.Store "profiles\$($B.Uuid)\meta.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($meta.email -eq $B.Email -and $meta.displayName -eq $B.Name -and $meta.orgUuid -eq $B.Org -and $meta.label) 'meta.json có label/email/displayName/orgUuid'
    $h0 = MaskedHash $t.Config
    $o0 = OtherJson $t.Config
    $raw0 = [IO.File]::ReadAllBytes($t.Config)
    Assert (-not ($raw0[0] -eq 0xEF)) 'config gốc không BOM'
    [IO.File]::WriteAllBytes($t.Journal, [byte[]]@())
    for ($i = 1; $i -le 2; $i++) {
        $r = Switch-To $t $A
        Assert ($r.Code -eq 0) "vòng $i : chuyển sang A thành công (exit 0)"
        Assert (CfgHas $t.Config $A) "vòng $i : 3 giá trị đăng nhập = của A"
        Assert ((FileHash $t.Cookies) -eq (Hex (New-CookieBytes $A))) "vòng $i : Cookies = của A (từng byte)"
        Assert ((MaskedHash $t.Config) -eq $h0 -and (OtherJson $t.Config) -eq $o0) "vòng $i : hash config (đã che 3 giá trị) giống hệt bản gốc"
        Assert (-not (Test-Path $t.Journal)) "vòng $i : Cookies-journal đã bị xóa"
        $r = Switch-To $t $B
        Assert ($r.Code -eq 0 -and (CfgHas $t.Config $B) -and ((FileHash $t.Cookies) -eq (Hex (New-CookieBytes $B))) -and ((MaskedHash $t.Config) -eq $h0)) "vòng $i : quay lại B đúng từng byte"
    }
    $steps = @($r.Lines | Where-Object { $_.state -eq 'done' } | ForEach-Object { $_.step })
    Assert (($steps -join ',') -eq 'close,backup,sync,switch,open' -and $r.Lines[-1].step -eq 'done' -and $r.Lines[-1].state -eq 'ok') "tiến trình ghi đủ bước: $($steps -join ',')"
    $rawN = [IO.File]::ReadAllBytes($t.Config)
    Assert (-not ($rawN[0] -eq 0xEF -and $rawN[1] -eq 0xBB)) 'không thêm BOM vào config'
    $r = Switch-To $t $B
    Assert ($r.Code -eq 0 -and (Last-Msg $r) -match 'đang được dùng') 'chuyển sang account đang dùng: báo đã dùng, exit 0'

    # token tu lam moi duoc luu truoc khi chuyen
    $null = Switch-To $t $A
    [IO.File]::WriteAllText($t.Config, (Build-Config $A -Tc2Override 'FAKETOK-TC2-A-REFRESHED'), $Utf8)
    $null = Switch-To $t $B
    $null = Switch-To $t $A
    Assert ((Get-Content $t.Config -Raw -Encoding UTF8).Contains('FAKETOK-TC2-A-REFRESHED')) 'token đã tự làm mới được lưu trước khi chuyển và trả lại đúng'

    # BOM duoc giu
    $t = New-Env 't1bom'
    Save-Acct $t $A
    Set-Current $t $B -Bom
    $null = Run-Engine $t @('-Action', 'Save')
    $r = Switch-To $t $A
    $rb = [IO.File]::ReadAllBytes($t.Config)
    Assert ($r.Code -eq 0 -and $rb[0] -eq 0xEF -and $rb[1] -eq 0xBB -and $rb[2] -eq 0xBF -and (CfgHas $t.Config $A)) 'config có BOM thì giữ BOM sau khi chuyển'

    # chen khoa khi config thieu
    $t = New-Env 't1ins'
    Init-Two $t
    [IO.File]::WriteAllText($t.Config, '{}', $Utf8)
    $r = Switch-To $t $A
    $txt = Get-Content $t.Config -Raw -Encoding UTF8
    $ok = $false; try { $o = $txt | ConvertFrom-Json; $ok = ($o.'oauth:tokenCache' -eq $A.Tc -and $o.lastKnownAccountUuid -eq $A.Uuid) } catch {}
    Assert ($r.Code -eq 0 -and $ok) 'config "{}" : chèn đủ 3 khóa sau dấu {'
    [IO.File]::WriteAllText($t.Config, "{`r`n  `"x`": 1`r`n}", $Utf8)
    $r = Switch-To $t $B
    $o = (Get-Content $t.Config -Raw -Encoding UTF8) | ConvertFrom-Json
    Assert ($r.Code -eq 0 -and $o.x -eq 1 -and $o.lastKnownAccountUuid -eq $B.Uuid) 'config thiếu khóa nhưng có khóa khác: chèn đúng, giữ khóa cũ'
}

# ================================================================ 2. dang xuat khong ghi de
if (Want 'loggedout') {
    Section '2. Trạng thái đã đăng xuất không ghi đè profile'
    $t = New-Env 't2'
    Init-Two $t
    $ha = FileHash (Join-Path $t.Store "profiles\$($A.Uuid)\auth.bin"); $hb = FileHash (Join-Path $t.Store "profiles\$($B.Uuid)\auth.bin")
    [IO.File]::WriteAllText($t.Config, (Build-Config $B -NoKeys), $Utf8)
    $r = Run-Engine $t @('-Action', 'Save')
    Assert ($r.Code -ne 0) "Save khi đã đăng xuất trả exit khác 0 (=$($r.Code))"
    Assert ((FileHash (Join-Path $t.Store "profiles\$($A.Uuid)\auth.bin")) -eq $ha -and (FileHash (Join-Path $t.Store "profiles\$($B.Uuid)\auth.bin")) -eq $hb) 'auth.bin của cả hai profile không đổi'
    [IO.File]::WriteAllText($t.Config, (Build-Config $B -EmptyTokens), $Utf8)
    $r = Run-Engine $t @('-Action', 'Save')
    Assert ($r.Code -ne 0 -and (FileHash (Join-Path $t.Store "profiles\$($B.Uuid)\auth.bin")) -eq $hb) 'token rỗng cũng không ghi đè'
    # Switch tu trang thai dang xuat van chay duoc (dung cho "Huy")
    [IO.File]::WriteAllText($t.Config, (Build-Config $B -NoKeys), $Utf8)
    $o0 = OtherJson $t.Config
    $r = Switch-To $t $A
    Assert ($r.Code -eq 0 -and (CfgHas $t.Config $A) -and (OtherJson $t.Config) -eq $o0) 'Switch từ trạng thái đăng xuất: khôi phục account, khóa khác nguyên vẹn'
    Assert ((FileHash (Join-Path $t.Store "profiles\$($B.Uuid)\auth.bin")) -eq $hb) 'Switch từ trạng thái đăng xuất cũng không ghi đè profile B'
}

# ================================================================ 3. khoa trung / auth.bin hong
if (Want 'abort') {
    Section '3. Khóa trùng và auth.bin hỏng: dừng, không đổi gì'
    $t = New-Env 't3'
    Init-Two $t
    [IO.File]::WriteAllText($t.Config, (Build-Config $B -Dup), $Utf8)
    $hc = FileHash $t.Config; $hk = FileHash $t.Cookies; $ha = FileHash (Join-Path $t.Store "profiles\$($A.Uuid)\auth.bin"); $hb = FileHash (Join-Path $t.Store "profiles\$($B.Uuid)\auth.bin")
    $bkBefore = if (Test-Path (Join-Path $t.Store 'backups')) { @(Get-ChildItem (Join-Path $t.Store 'backups')).Count } else { 0 }
    $r = Switch-To $t $A
    Assert ($r.Code -ne 0) 'config có khóa trùng: Switch thất bại (exit khác 0)'
    Assert ((FileHash $t.Config) -eq $hc -and (FileHash $t.Cookies) -eq $hk) 'khóa trùng: config + Cookies không đổi một byte'
    $bkAfter = if (Test-Path (Join-Path $t.Store 'backups')) { @(Get-ChildItem (Join-Path $t.Store 'backups')).Count } else { 0 }
    Assert ($bkAfter -eq $bkBefore -and (FileHash (Join-Path $t.Store "profiles\$($A.Uuid)\auth.bin")) -eq $ha -and (FileHash (Join-Path $t.Store "profiles\$($B.Uuid)\auth.bin")) -eq $hb) 'khóa trùng: không tạo backup, profile không đổi'
    Assert ((Last-Msg $r) -match 'nhiều lần|xuất hiện') "thông báo rõ ràng: $(Last-Msg $r)"
    $r = Run-Engine $t @('-Action', 'PrepareAdd')
    Assert ($r.Code -ne 0 -and (FileHash $t.Config) -eq $hc) 'PrepareAdd với khóa trùng cũng dừng, không đổi gì'

    $t = New-Env 't3b'
    Init-Two $t
    $ap = Join-Path $t.Store "profiles\$($A.Uuid)\auth.bin"
    $bytes = [IO.File]::ReadAllBytes($ap)
    for ($i = 20; $i -lt 60; $i++) { $bytes[$i] = $bytes[$i] -bxor 0xFF }
    [IO.File]::WriteAllBytes($ap, $bytes)
    $hc = FileHash $t.Config; $hk = FileHash $t.Cookies
    $r = Switch-To $t $A
    Assert ($r.Code -ne 0 -and (Last-Msg $r) -match 'hỏng|giải mã') "auth.bin hỏng: Switch dừng - $(Last-Msg $r)"
    Assert ((FileHash $t.Config) -eq $hc -and (FileHash $t.Cookies) -eq $hk -and -not (Test-Path (Join-Path $t.Store 'backups'))) 'auth.bin hỏng: config/Cookies không đổi, chưa tạo backup'
    [IO.File]::WriteAllBytes($ap, [byte[]]@(1, 2, 3))
    $r = Switch-To $t $A
    Assert ($r.Code -ne 0 -and (FileHash $t.Config) -eq $hc) 'auth.bin bị cắt cụt: cũng dừng an toàn'
}

# ================================================================ 4. loi sau backup -> khoi phuc
if (Want 'inject') {
    Section '4. Lỗi giả lập sau khi sao lưu: khôi phục config + cookie'
    foreach ($fp in 'afterBackup', 'afterConfig', 'afterCookies') {
        $t = New-Env ("t4$fp")
        Init-Two $t
        [IO.File]::WriteAllBytes($t.Journal, [byte[]]@(7, 7, 7))
        $hc = FileHash $t.Config; $hk = FileHash $t.Cookies; $hj = FileHash $t.Journal
        $r = Switch-To $t $A @('-FailAt', $fp)
        Assert ($r.Code -ne 0) "$fp : exit khác 0"
        Assert ((FileHash $t.Config) -eq $hc -and (FileHash $t.Cookies) -eq $hk -and (FileHash $t.Journal) -eq $hj) "$fp : config, Cookies, journal được khôi phục đúng từng byte"
        Assert ((Last-Msg $r) -match 'khôi phục') "$fp : thông báo tiếng Việt nói đã khôi phục"
        Assert (-not (Test-Path ($t.Config + '.cs-tmp'))) "$fp : không để lại file tạm"
        $r2 = Switch-To $t $A
        Assert ($r2.Code -eq 0 -and (CfgHas $t.Config $A)) "$fp : lần sau vẫn chuyển được bình thường"
    }
}

# ================================================================ 5. dong bo session
if (Want 'sync') {
    Section '5. Đồng bộ session'
    $t = New-Env 't5'
    Set-Current $t $A
    $s1 = New-Session $t $A $A.Org 's1' 1000 'Phiên một'
    $s2 = New-Session $t $A $A.Org 's2' 2000 'Phiên hai'
    $s4a = New-Session $t $A $A.Org 's4' 3000 'cũ' ', "marker": "A-OLD"'
    New-Item -ItemType Directory -Force (Join-Path (SessDir $t $A $A.Org) 'waiting-input') | Out-Null
    [IO.File]::WriteAllText((Join-Path (SessDir $t $A $A.Org) 'waiting-input\w1.json'), '{"w":1}', $Utf8)
    [IO.File]::WriteAllText((Join-Path (SessDir $t $A $A.Org) 'scheduled-tasks.json'), '{"tasks":[]}', $Utf8)
    New-Item -ItemType Directory -Force (SessDir $t $A $A.Org2) | Out-Null    # thu muc org gan nhu rong cua A
    $null = Run-Engine $t @('-Action', 'Save')
    Set-Current $t $B
    $s3 = New-Session $t $B $B.Org 's3' 5000 'Phiên ba'
    $s4b = New-Session $t $B $B.Org 's4' 6000 'mới' ', "marker": "B-NEW"'
    [IO.File]::WriteAllText((Join-Path (SessDir $t $B $B.Org) 'scheduled-tasks.json'), '{"tasks":["b"]}', $Utf8)
    $null = Run-Engine $t @('-Action', 'Save')
    $st = Get-Status $t
    $pa = $st.profiles | Where-Object { $_.uuid -eq $A.Uuid }
    Assert ($pa.orgUuid -eq $A.Org -and $pa.sessionCount -eq 3) "đếm session đúng org của A (org=$($pa.orgUuid.Substring(0,4)).., count=$($pa.sessionCount))"

    $r = Run-Engine $t @('-Action', 'SyncSessions')
    Assert ($r.Code -eq 0) 'SyncSessions exit 0'
    $aDir = SessDir $t $A $A.Org; $bDir = SessDir $t $B $B.Org
    Assert ((FileHash "$aDir\local_s3.json") -eq (FileHash $s3)) 'B->A: local_s3.json sao chép từng byte'
    Assert ((FileHash "$bDir\local_s1.json") -eq (FileHash $s1) -and (FileHash "$bDir\local_s2.json") -eq (FileHash $s2)) 'A->B: s1, s2 sao chép từng byte'
    Assert (-not (Test-Path "$bDir\waiting-input") -and (Get-Content "$bDir\scheduled-tasks.json" -Raw) -eq '{"tasks":["b"]}' -and -not (Test-Path "$aDir\waiting-input\..\local_w1.json")) 'waiting-input và scheduled-tasks KHÔNG bị sao chép/ghi đè'
    Assert ((Get-Content "$aDir\local_s4.json" -Raw -Encoding UTF8) -match 'B-NEW') 'newer-wins: bản s4 mới hơn (B) ghi đè bản cũ (A)'
    $bk = @(Get-ChildItem (Join-Path $t.Store 'session-backups') -Recurse -Filter 'local_s4.json')
    Assert ($bk.Count -eq 1 -and (Get-Content $bk[0].FullName -Raw -Encoding UTF8) -match 'A-OLD') 'bản s4 bị ghi đè đã được sao lưu trước'
    Assert (-not (Test-Path (Join-Path (SessDir $t $A $A.Org2) 'local_s3.json'))) 'không ghi nhầm vào thư mục org gần-rỗng của A'

    # xoa -> khong tao lai
    Remove-Item "$bDir\local_s2.json"
    $r = Run-Engine $t @('-Action', 'SyncSessions')
    Assert (-not (Test-Path "$bDir\local_s2.json") -and (Test-Path "$aDir\local_s2.json")) 'session người dùng đã xóa không bị tạo lại, bản bên kia không bị xóa'

    # chay lai: on dinh
    $h = FileHash "$aDir\local_s1.json"
    $r = Run-Engine $t @('-Action', 'SyncSessions')
    Assert ((FileHash "$aDir\local_s1.json") -eq $h -and (Get-ChildItem $aDir -Filter 'local_*.json').Count -eq 4) 'chạy lại đồng bộ: kết quả ổn định'

    # go ban sao chep: chi go ban chua sua
    [IO.File]::AppendAllText("$aDir\local_s3.json", ' ', $Utf8)    # nguoi dung sua ban sao A/s3
    $r = Run-Engine $t @('-Action', 'RemoveCopies', '-OutFile', (Join-Path $t.Root 'rm.json'))
    $rm = Get-Content (Join-Path $t.Root 'rm.json') -Raw | ConvertFrom-Json
    Assert ($r.Code -eq 0 -and $rm.removed -eq 1 -and $rm.kept -eq 1) "RemoveCopies: xóa $($rm.removed), giữ $($rm.kept) bản đã sửa"
    Assert (-not (Test-Path "$bDir\local_s1.json") -and (Test-Path "$aDir\local_s3.json") -and (Test-Path "$aDir\local_s1.json") -and (Test-Path $s3)) 'chỉ bản chưa sửa bị gỡ; bản gốc và bản đã sửa còn nguyên'
    $null = Run-Engine $t @('-Action', 'SyncSessions')
    Assert (-not (Test-Path "$bDir\local_s1.json")) 'sau khi gỡ, đồng bộ không tạo lại bản đã gỡ'

    # tat dong bo qua settings
    $t = New-Env 't5b'
    Init-Two $t
    $null = New-Session $t $A $A.Org 'x1' 100 'x'
    [IO.File]::WriteAllText((Join-Path $t.Store 'settings.json'), '{"syncSessions":false}', $Utf8)
    $r = Switch-To $t $A
    Assert ($r.Code -eq 0 -and -not (Test-Path (Join-Path (SessDir $t $B $B.Org) 'local_x1.json')) -and (@($r.Lines | Where-Object { $_.step -eq 'sync' -and $_.state -eq 'skipped' }).Count -eq 1)) 'syncSessions=false: Switch bỏ qua đồng bộ'
    $t = New-Env 't5c'
    Init-Two $t
    $null = New-Session $t $B $B.Org 'y1' 100 'y'
    $r = Switch-To $t $A
    Assert ($r.Code -eq 0 -and (Test-Path (Join-Path (SessDir $t $A $A.Org) 'local_y1.json'))) 'Switch (mặc định bật) tự đồng bộ session sang account kia'
}

# ================================================================ 6. PrepareAdd
if (Want 'prepareadd') {
    Section '6. PrepareAdd và bắt account mới'
    $t = New-Env 't6'
    Save-Acct $t $A
    [IO.File]::WriteAllBytes($t.Journal, [byte[]]@(1))
    $o0 = OtherJson $t.Config
    $r = Run-Engine $t @('-Action', 'PrepareAdd')
    $txt = Get-Content $t.Config -Raw -Encoding UTF8
    $ok = $false; try { $null = $txt | ConvertFrom-Json; $ok = $true } catch {}
    Assert ($r.Code -eq 0 -and $ok) 'PrepareAdd thành công, config vẫn là JSON hợp lệ'
    Assert (-not $txt.Contains('oauth:tokenCache') -and -not $txt.Contains('lastKnownAccountUuid')) 'đã gỡ cả 3 khóa đăng nhập'
    Assert ((OtherJson $t.Config) -eq $o0) 'các khóa khác giữ nguyên'
    Assert (-not (Test-Path $t.Cookies) -and -not (Test-Path $t.Journal)) 'Cookies + journal đã bị xóa'
    Assert ((Test-Path (Join-Path $t.Store 'pending-add.json')) -and (Test-Path (Join-Path $t.Store "profiles\$($A.Uuid)\auth.bin")) -and @(Get-ChildItem (Join-Path $t.Store 'backups')).Count -ge 1) 'có pending-add, profile A còn, có backup'
    $st = Get-Status $t
    Assert ((-not $st.loggedIn) -and $st.pendingAdd.previousAccount -eq $A.Uuid) 'Status: chưa đăng nhập, nhớ account trước đó'
    # nguoi dung dang nhap B
    Set-Current $t $B
    $r = Run-Engine $t @('-Action', 'Save')
    $st = Get-Status $t
    Assert ($r.Code -eq 0 -and $st.profiles.Count -eq 2 -and ($st.profiles | Where-Object { $_.uuid -eq $B.Uuid }).isActive -and $null -eq $st.pendingAdd) 'đăng nhập B được bắt: tạo profile B, xóa pending-add'
    $r = Switch-To $t $A
    Assert ($r.Code -eq 0 -and (CfgHas $t.Config $A) -and (FileHash $t.Cookies) -eq (Hex (New-CookieBytes $A))) 'sau đó chuyển về A bình thường (cookie A còn nguyên)'

    # Huy: quay lai account cu tu trang thai da bi go
    $t = New-Env 't6b'
    Save-Acct $t $A
    $null = Run-Engine $t @('-Action', 'PrepareAdd')
    $r = Switch-To $t $A
    Assert ($r.Code -eq 0 -and (CfgHas $t.Config $A) -and (FileHash $t.Cookies) -eq (Hex (New-CookieBytes $A))) 'Hủy: Switch về account đã lưu khôi phục đủ config + cookie'

    # PrepareAdd khi chua dang nhap
    $t = New-Env 't6c'
    [IO.File]::WriteAllText($t.Config, (Build-Config $A -NoKeys), $Utf8)
    $hc = FileHash $t.Config
    $r = Run-Engine $t @('-Action', 'PrepareAdd')
    Assert ($r.Code -ne 0 -and (FileHash $t.Config) -eq $hc) 'PrepareAdd khi chưa đăng nhập: từ chối, không đổi gì'
    # loi trong PrepareAdd -> khoi phuc
    $t = New-Env 't6d'
    Save-Acct $t $A
    $hc = FileHash $t.Config; $hk = FileHash $t.Cookies
    $r = Run-Engine $t @('-Action', 'PrepareAdd', '-FailAt', 'afterBackup')
    Assert ($r.Code -ne 0 -and (FileHash $t.Config) -eq $hc -and (FileHash $t.Cookies) -eq $hk) 'lỗi giữa chừng trong PrepareAdd: khôi phục nguyên trạng'
    # SetLabel giu qua lan save lai
    $r = Run-Engine $t @('-Action', 'SetLabel', '-TargetAccount', $A.Uuid, '-Label', 'Account công việc')
    $null = Run-Engine $t @('-Action', 'Save')
    $m = Get-Content (Join-Path $t.Store "profiles\$($A.Uuid)\meta.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($m.label -eq 'Account công việc') 'nhãn người dùng đặt được giữ khi lưu lại'
}

# ================================================================ 7. don backup
if (Want 'prune') {
    Section '7. Dọn backup, giữ 10 bản mới nhất'
    $t = New-Env 't7'
    Init-Two $t
    $bdir = Join-Path $t.Store 'backups'
    New-Item -ItemType Directory -Force $bdir | Out-Null
    for ($i = 1; $i -le 12; $i++) { New-Item -ItemType Directory -Force (Join-Path $bdir ("20200101-000000-{0:000}" -f $i)) | Out-Null }
    $r = Switch-To $t $A
    $dirs = @(Get-ChildItem $bdir -Directory | Sort-Object Name)
    Assert ($dirs.Count -eq 10) "sau 1 lần chuyển: còn đúng 10 backup (=$($dirs.Count))"
    Assert ($dirs[-1].Name -notlike '2020*' -and (Test-Path (Join-Path $dirs[-1].FullName 'config.json')) -and -not (Test-Path (Join-Path $bdir '20200101-000000-001'))) 'bản mới nhất còn, bản cũ nhất bị xóa'
    $cur = $A
    for ($i = 0; $i -lt 12; $i++) { if ($i % 2 -eq 0) { $null = Switch-To $t $B } else { $null = Switch-To $t $A } }
    Assert (@(Get-ChildItem $bdir -Directory).Count -eq 10) 'sau 12 lần chuyển nữa vẫn đúng 10 backup'
}

# ================================================================ 8. ro ri bi mat
if (Want 'leak') {
    Section '8. Không lộ token / auth.bin không chứa chữ rõ'
    $t = New-Env 't8'
    Init-Two $t
    $null = Switch-To $t $A
    $null = Switch-To $t $B @('-FailAt', 'afterConfig')
    $null = Run-Engine $t @('-Action', 'PrepareAdd')
    Set-Current $t $A
    $null = Run-Engine $t @('-Action', 'Save')
    $null = Run-Engine $t @('-Action', 'Status', '-OutFile', (Join-Path $t.Root 'st.json'))
    $files = @()
    $files += Get-ChildItem (Join-Path $t.Store 'logs') -File -ErrorAction SilentlyContinue
    $files += Get-ChildItem (Join-Path $t.Store 'profiles') -Recurse -Filter 'meta.json'
    $files += Get-ChildItem $t.Root -Filter 'progress-*.jsonl'
    $files += Get-ChildItem $t.Store -File -Filter '*.json' -ErrorAction SilentlyContinue
    $files += Get-Item (Join-Path $t.Root 'st.json')
    $bad = @($files | Where-Object { (Get-Content $_.FullName -Raw -Encoding UTF8) -match 'FAKETOK|FAKECOOKIE' })
    Assert ($files.Count -ge 8 -and $bad.Count -eq 0) "không file log/meta/progress/status nào chứa token (đã quét $($files.Count) file)"
    $authOk = $true
    foreach ($f in Get-ChildItem (Join-Path $t.Store 'profiles') -Recurse -Filter 'auth.bin') {
        $ab = [IO.File]::ReadAllBytes($f.FullName)
        $asc = [Text.Encoding]::ASCII.GetString($ab); $u16 = [Text.Encoding]::Unicode.GetString($ab)
        if ($asc -match 'FAKETOK|tokenCache|lastKnown' -or $u16 -match 'FAKETOK|tokenCache') { $authOk = $false }
        if ($ab.Length -lt 3000) { $authOk = $false }
    }
    Assert $authOk 'auth.bin đã mã hóa DPAPI: không có chữ rõ của token/khóa, kích thước gồm cả cookie'
    $dec = $false
    try {
        $ab = [IO.File]::ReadAllBytes((Join-Path $t.Store "profiles\$($A.Uuid)\auth.bin"))
        $p = [Security.Cryptography.ProtectedData]::Unprotect($ab, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $dec = ($Utf8.GetString($p) -match 'FAKETOK-TC-A')
    } catch {}
    Assert $dec 'giải mã DPAPI (CurrentUser) ra đúng dữ liệu đã lưu'
}

# ================================================================ 9. config that (chi doc)
if (Want 'real') {
    Section '9. Kiểm tra config.json THẬT (chỉ đọc, trong bộ nhớ, chỉ in boolean)'
    $realData = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Directory -Filter 'claude_*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $realData) { Write-Host '  (không thấy thư mục dữ liệu thật, bỏ qua)' -ForegroundColor Yellow }
    else {
        $out = Join-Path $Scratch 'real-check.json'
        $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Engine, '-Action', 'CheckConfig', '-DataDir', $realData.FullName, '-StoreDir', (Join-Path $Scratch 'real-store-unused'), '-OutFile', $out)
        & powershell.exe @al 2>&1 | Out-Null
        $c = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($LASTEXITCODE -eq 0 -and $c.parsed) 'config thật parse được'
        foreach ($k in 'oauth:tokenCache', 'oauth:tokenCacheV2', 'lastKnownAccountUuid') {
            $e = $c.keys.$k
            Write-Host ("    {0}: occurrences={1}, regexMatches={2}, nonEmptyString={3}, length={4}" -f $k, $e.occurrences, $e.regexMatches, $e.isNonEmptyString, $e.valueLength)
            if ($k -eq 'oauth:tokenCache' -and $e.occurrences -eq 0) {
                Assert ($c.keys.'oauth:tokenCacheV2'.isNonEmptyString) 'Claude dùng V2-only: khóa token cũ không bắt buộc'
            } else {
                Assert ($e.occurrences -eq 1 -and $e.regexMatches -eq 1 -and $e.isNonEmptyString) "khóa $k xuất hiện đúng 1 lần và regex khớp"
            }
        }
        Assert (-not (Test-Path (Join-Path $Scratch 'real-store-unused'))) 'không tạo gì trong StoreDir khi kiểm tra'
    }
}

# ================================================================ 10. cai dat
if (Want 'install') {
    Section '10. Cài đặt / gỡ cài đặt (thư mục tạm)'
    $ti = Join-Path ([IO.Path]::GetTempPath()) 'cs-inst-test'   # đường dẫn ngắn: shortcut (COM) giới hạn 260 ký tự
    if (Test-Path $ti) { Remove-Item -Recurse -Force $ti }
    $desk = Join-Path $ti 'Desktop'; $store = Join-Path $ti 'Store'; $inst = Join-Path $store 'app'
    New-Item -ItemType Directory -Force $desk, $store | Out-Null
    $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'Install.ps1'), '-InstallDir', $inst, '-DesktopDir', $desk, '-NoLaunch')
    & powershell.exe @al 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Install.ps1 exit 0'
    $must = 'ClaudeSwitch.ps1', 'ClaudeSwitch.Engine.ps1', 'ClaudeSwitch.bat', 'Uninstall.ps1', 'README.md'
    Assert (@($must | Where-Object { -not (Test-Path (Join-Path $inst $_)) }).Count -eq 0) 'đã chép đủ file vào thư mục cài đặt'
    $lnk = Join-Path $desk 'Claude Switch.lnk'
    Assert (Test-Path $lnk) 'có shortcut "Claude Switch" trên Desktop'
    if (Test-Path $lnk) {
        $sh = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        Assert ($sh.Hotkey -match '(?i)ctrl' -and $sh.Hotkey -match '(?i)alt' -and $sh.Hotkey -match '\+C$') "phím tắt = $($sh.Hotkey)"
        Assert ($sh.Arguments -like "*$inst*ClaudeSwitch.ps1*" -and $sh.Arguments -match 'Hidden') 'shortcut trỏ đúng vào bản đã cài, chạy ẩn'
    }
    # chay lai (nang cap) khong loi
    & powershell.exe @al 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'cài đè lần 2 vẫn OK'
    New-Item -ItemType Directory -Force (Join-Path $store 'profiles\x') | Out-Null
    [IO.File]::WriteAllText((Join-Path $store 'profiles\x\meta.json'), '{}')
    $ul = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $inst 'Uninstall.ps1'), '-InstallDir', $inst, '-DesktopDir', $desk, '-StoreDir', $store)
    & powershell.exe @ul 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0 -and -not (Test-Path $lnk) -and -not (Test-Path $inst)) 'Uninstall xóa shortcut + thư mục app'
    Assert (Test-Path (Join-Path $store 'profiles\x\meta.json')) 'Uninstall mặc định GIỮ profile'
    & powershell.exe @al 2>&1 | Out-Null
    & powershell.exe @ul '-RemoveProfiles' 2>&1 | Out-Null
    Assert (-not (Test-Path (Join-Path $store 'profiles'))) 'Uninstall -RemoveProfiles xóa cả profile'
    Remove-Item -Recurse -Force $ti -ErrorAction SilentlyContinue
    $bat = Get-ChildItem $Root -Filter *.bat
    $nonAscii = @($bat | Where-Object { @([IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 }).Count -gt 0 })
    Assert ($bat.Count -ge 2 -and $nonAscii.Count -eq 0) ".bat chỉ chứa ASCII ($($bat.Name -join ', '))"
    $ps = Get-ChildItem $Root -Recurse -Filter *.ps1
    $noBom = @($ps | Where-Object { $bb = [IO.File]::ReadAllBytes($_.FullName); -not ($bb[0] -eq 0xEF -and $bb[1] -eq 0xBB -and $bb[2] -eq 0xBF) })
    Assert ($noBom.Count -eq 0) "mọi .ps1 là UTF-8 có BOM ($($ps.Count) file)"
}

# ================================================================ 11. giao dien
if ((Want 'gui') -and -not $SkipGui) {
    Section '11. Giao diện: dựng thử, vẽ PNG, chạy thử vòng lặp'
    $err = $null; $tk = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Gui, [ref]$tk, [ref]$err)
    Assert (@($err).Count -eq 0) 'ClaudeSwitch.ps1 không có lỗi cú pháp'
    $t = New-Env 't11'
    Init-Two $t
    foreach ($theme in 'light', 'dark') {
        foreach ($state in 'two', 'one', 'switching', 'error', 'success', 'confirm', 'adding') {
            $png = Join-Path $Scratch ("preview-{0}-{1}.png" -f $state, $theme)
            if (Test-Path $png) { Remove-Item $png }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $Gui -RenderPreview $png -PreviewState $state -PreviewTheme $theme -DataDir $t.Data -StoreDir $t.Store -ClaudeJson $t.Cj -NoAppControl 2>&1 | Out-Null
            Assert ((Test-Path $png) -and (Get-Item $png).Length -gt 5000) "render $state / $theme -> $(Split-Path -Leaf $png)"
        }
    }
    # chay that: tu dong chuyen account bang -AutoSwitch (khong dong Claude, du lieu gia)
    $t = New-Env 't11b'
    Init-Two $t
    $snap = Join-Path $Scratch 'gui-live-after-switch.png'
    $mut = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $Gui, '-DataDir', $t.Data, '-StoreDir', $t.Store, '-ClaudeJson', $t.Cj, '-NoAppControl', '-AutoSwitch', $A.Uuid, '-ExitAfter', '25', '-SnapshotOnExit', $snap)
    $p = Start-Process powershell.exe -ArgumentList $mut -PassThru -WindowStyle Hidden
    $done = $p.WaitForExit(60000)
    if (-not $done) { try { $p.Kill() } catch {} }
    Assert ($done -and $p.ExitCode -eq 0) "GUI tự thoát sạch sau ExitAfter (exit=$($p.ExitCode))"
    Assert ((CfgHas $t.Config $A) -and (FileHash $t.Cookies) -eq (Hex (New-CookieBytes $A))) 'GUI chạy engine nền: đã chuyển sang A (config + cookie) trên dữ liệu giả'
    Assert ((Test-Path $snap) -and (Get-Item $snap).Length -gt 5000) 'GUI chụp được trạng thái cuối sau khi chuyển'

    # bam that nut tren giao dien (qua Click event + hop xac nhan), khong di duong tat
    function Get-GuiErrors($t) { return @(Get-ChildItem (Join-Path $t.Store 'logs') -Filter 'gui-*.log' -ErrorAction SilentlyContinue | Select-String -Pattern 'Lỗi giao diện|lỗi:' -Encoding UTF8) }
    function Start-ClickGui($t, [int]$secs) {
        $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $Gui, '-DataDir', $t.Data, '-StoreDir', $t.Store, '-ClaudeJson', $t.Cj, '-NoAppControl', '-AutoClick', '-ExitAfter', [string]$secs)
        return (Start-Process powershell.exe -ArgumentList $al -PassThru -WindowStyle Hidden)
    }
    $t = New-Env 't11c'
    Init-Two $t
    $p = Start-ClickGui $t 20
    $done = $p.WaitForExit(60000); if (-not $done) { try { $p.Kill() } catch {} }
    Assert ($done -and (CfgHas $t.Config $A)) 'Bấm nút "Chuyển sang" rồi xác nhận: đã chuyển account'
    Assert ((Get-GuiErrors $t).Count -eq 0) 'Bấm nút "Chuyển sang": log giao diện không có lỗi'

    $t = New-Env 't11d'
    Save-Acct $t $A
    $p = Start-ClickGui $t 35
    $end = (Get-Date).AddSeconds(20); $cleared = $false
    while ((Get-Date) -lt $end -and -not $cleared) { Start-Sleep -Milliseconds 500; $cleared = -not ([IO.File]::ReadAllText($t.Config).Contains('oauth:tokenCache')) }
    Assert $cleared 'Bấm nút "Thêm account thứ hai" rồi xác nhận: đã mở màn hình đăng nhập (gỡ khóa)'
    $v2Login = [regex]::Replace((Build-Config $B), '(?m)^  "oauth:tokenCache":.*\r?\n', '')
    [IO.File]::WriteAllText($t.Config, $v2Login, $Utf8)
    $bin = Join-Path $t.Store "profiles\$($B.Uuid)\auth.bin"
    $end = (Get-Date).AddSeconds(25); while ((Get-Date) -lt $end -and -not (Test-Path $bin)) { Start-Sleep -Milliseconds 500 }
    Assert (Test-Path $bin) 'GUI tự nhận account mới chỉ có token V2 và lưu profile'
    $done = $p.WaitForExit(60000); if (-not $done) { try { $p.Kill() } catch {} }
    Assert ((Get-GuiErrors $t).Count -eq 0) 'Luồng thêm account: log giao diện không có lỗi'

    $guiText = [IO.File]::ReadAllText($Gui, [Text.Encoding]::UTF8)
    Assert (-not [regex]::IsMatch($guiText, '\$S\b')) 'Biến trạng thái không còn trùng tên với tham số $s của sự kiện'
}

Write-Host ""
Write-Host ("KẾT QUẢ: {0} đạt, {1} lỗi" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { $script:Failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red } }
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
