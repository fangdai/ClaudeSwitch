#requires -Version 5.1
<#
  Claude Switch - giao diện WPF.
  Chạy ẩn (xem ClaudeSwitch.bat). Mọi việc nặng do ClaudeSwitch.Engine.ps1 làm ở tiến trình riêng,
  giao diện chỉ đọc file tiến trình bằng DispatcherTimer nên không bao giờ bị đơ.
#>
param(
    [string]$DataDir,
    [string]$StoreDir,
    [string]$ClaudeJson,
    [string]$CliPath,
    [string]$CliConfigDir,
    [string]$CliConfigFile,
    [switch]$NoAppControl,
    [string]$RenderPreview,        # vẽ cửa sổ ra PNG rồi thoát
    [string]$PreviewState = 'two', # two | one | switching | error | success | confirm | adding
    [string]$PreviewTheme,         # light | dark (mặc định theo Windows)
    [int]$ExitAfter = 0,           # (kiểm thử) tự thoát sau N giây
    [string]$AutoSwitch,           # (kiểm thử) tự chuyển sang account này, bỏ qua hộp xác nhận
    [switch]$AutoClick,            # (kiểm thử) bấm thật nút chính của thẻ account rồi bấm xác nhận
    [string]$SnapshotOnExit        # (kiểm thử) chụp cửa sổ ra PNG trước khi thoát
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not $StoreDir)   { $StoreDir = Join-Path $env:LOCALAPPDATA 'ClaudeSwitch' }
if (-not $ClaudeJson) { $ClaudeJson = Join-Path $env:USERPROFILE '.claude.json' }
if (-not $DataDir) {
    $c = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Directory -Filter 'claude_*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $DataDir = $c.FullName }
}
$Engine = Join-Path $PSScriptRoot 'ClaudeSwitch.Engine.ps1'
$ConfigPath = if ($DataDir) { Join-Path $DataDir 'config.json' } else { '' }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$IsPreview = [bool]$RenderPreview

# ---------------------------------------------------------------- trạng thái chung (không dùng $script: để tránh lỗi phạm vi trong handler)
$AppState = @{
    Status = $null; Mode = 'accounts'; Busy = $false; Flow = ''; Jobs = (New-Object System.Collections.ArrayList)
    StepUi = @{}; StepOrder = @(); Primary = $null; ProgPrimary = $null; ProgSecondary = $null
    PrevUuid = $null; TargetUuid = $null; ConfirmKind = ''; ConfirmArg = ''; Exiting = $false
    StatusBusy = $false; SavedOnce = $false; Loading = $false; AddTimer = $null; NewUuid = $null; AutoDone = $false
    Dark = $false; ActiveTool = 'desktop'; CliSavedOnce = $false; CliFinishedId = $null
    Usage = $null; UsageBusy = $false; NextUsageCheck = [DateTimeOffset]::MinValue
}

function Gui-Log([string]$m) {
    try {
        $d = Join-Path $StoreDir 'logs'; if (-not (Test-Path -LiteralPath $d)) { [void][IO.Directory]::CreateDirectory($d) }
        [IO.File]::AppendAllText((Join-Path $d ('gui-{0:yyyyMMdd}.log' -f (Get-Date))), ('{0:HH:mm:ss} {1}' -f (Get-Date), $m) + "`r`n", $Utf8NoBom)
    } catch {}
}

# ---------------------------------------------------------------- giao diện sáng / tối
$PalLight = @{
    Bg = '#F3F2F0'; Card = '#FFFFFF'; CardBorder = '#E6E3DF'; Text = '#1F1E1D'; SubText = '#6E6A66'; Muted = '#C9C5C0'
    Accent = '#C2562F'; AccentHover = '#A94724'; AccentSoft = '#F8E6DE'; OnAccent = '#FFFFFF'
    Danger = '#B42318'; DangerSoft = '#FDE8E6'; Hover = '#ECE9E5'; Track = '#E6E3DF'
}
$PalDark = @{
    Bg = '#1C1B1A'; Card = '#292826'; CardBorder = '#3A3835'; Text = '#F3F1EE'; SubText = '#A8A29B'; Muted = '#5A5651'
    Accent = '#E0764C'; AccentHover = '#EA8A64'; AccentSoft = '#43291F'; OnAccent = '#1C1B1A'
    Danger = '#FF8A7A'; DangerSoft = '#4A2420'; Hover = '#34322F'; Track = '#3A3835'
}
function New-Brush([string]$hex) {
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
    $b.Freeze(); return $b
}
function Test-DarkTheme {
    try { return ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { return $false }
}

# ---------------------------------------------------------------- XAML cửa sổ
$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Switch" SizeToContent="WidthAndHeight" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Bg}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource OnAccent}"/>
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource AccentHover}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource CardBorder}" BorderThickness="1" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource SubText}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="28"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MenuBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SwitchBox" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="38" Height="22" VerticalAlignment="Center">
                <Border x:Name="track" CornerRadius="11" Background="{DynamicResource Muted}"/>
                <Ellipse x:Name="thumb" Width="16" Height="16" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Grid>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid x:Name="Root" Width="460" Background="{DynamicResource Bg}">
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel Margin="20,18,20,14">
      <Grid Margin="2,0,0,16">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Width="36" Height="36" CornerRadius="18" Background="{DynamicResource Accent}" VerticalAlignment="Center">
          <TextBlock Text="C" Foreground="{DynamicResource OnAccent}" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
        </Border>
        <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="Claude Switch" FontSize="19" FontWeight="SemiBold" Foreground="{DynamicResource Text}"/>
          <TextBlock Text="Chuyển account Claude Desktop và CLI" FontSize="12" Foreground="{DynamicResource SubText}"/>
        </StackPanel>
      </Grid>
      <Grid x:Name="ToolTabs" Margin="0,0,0,12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Button x:Name="DesktopTab" Style="{StaticResource Ghost}" Content="Desktop" Margin="0,0,6,0" Visibility="Collapsed"/>
        <Button x:Name="CliTab" Grid.Column="1" Style="{StaticResource Ghost}" Content="CLI" Margin="0,0,6,0" Visibility="Collapsed"/>
        <Button x:Name="ScanBtn" Grid.Column="2" Style="{StaticResource Ghost}" Content="Quét lại"/>
      </Grid>
      <TextBlock x:Name="NoToolsText" Text="Chưa tìm thấy Claude Desktop hoặc Claude CLI. Cài một ứng dụng rồi bấm Quét lại." TextWrapping="Wrap" Foreground="{DynamicResource SubText}" Margin="4,0,4,14" Visibility="Collapsed"/>
      <Grid x:Name="UsageControls" Margin="2,0,0,12" Visibility="Collapsed">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="UsageUpdated" Text="Usage tài khoản" Foreground="{DynamicResource SubText}" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,8,0"/>
        <Button x:Name="UsageRefreshBtn" Grid.Column="1" Style="{StaticResource Ghost}" Content="Cập nhật usage" FontSize="12" Padding="12,8"/>
      </Grid>
      <StackPanel x:Name="Cards"/>
      <StackPanel x:Name="CliPanel" Visibility="Collapsed">
        <TextBlock x:Name="CliInfo" TextWrapping="Wrap" Foreground="{DynamicResource SubText}" Margin="4,0,4,12"/>
        <StackPanel x:Name="CliCards"/>
        <Button x:Name="CliLoginBtn" Style="{StaticResource Primary}" Content="Đăng nhập CLI" Margin="0,0,0,8"/>
        <Button x:Name="CliOpenBtn" Style="{StaticResource Ghost}" Content="Mở Claude CLI" Margin="0,0,0,12"/>
      </StackPanel>
      <Border x:Name="PanelProgress" Visibility="Collapsed" Background="{DynamicResource Card}" BorderBrush="{DynamicResource CardBorder}" BorderThickness="1" CornerRadius="14" Padding="18" Margin="0,0,0,12">
        <StackPanel>
          <TextBlock x:Name="ProgTitle" FontSize="17" FontWeight="SemiBold" Foreground="{DynamicResource Text}" TextWrapping="Wrap" Margin="0,0,0,14"/>
          <StackPanel x:Name="StepsPanel"/>
          <Grid Height="6" Margin="0,6,0,0">
            <Border Background="{DynamicResource Track}" CornerRadius="3"/>
            <Border x:Name="BarFill" Background="{DynamicResource Accent}" CornerRadius="3" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="ProgMsg" Margin="0,12,0,0" Foreground="{DynamicResource SubText}" TextWrapping="Wrap"/>
          <StackPanel x:Name="ProgButtons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="BtnSecondary" Style="{StaticResource Ghost}" Margin="0,0,8,0" Visibility="Collapsed"/>
            <Button x:Name="BtnPrimary" Style="{StaticResource Primary}" Visibility="Collapsed"/>
          </StackPanel>
        </StackPanel>
      </Border>
      <TextBlock x:Name="Toast" Foreground="{DynamicResource SubText}" TextWrapping="Wrap" FontSize="12" Margin="4,0,4,8" Visibility="Collapsed"/>
      <StackPanel x:Name="DesktopFooter">
      <Grid Margin="2,4,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <CheckBox x:Name="SyncChk" Style="{StaticResource SwitchBox}" Content="Hiện session ở cả 2 account" IsChecked="True"/>
        <Button x:Name="MoreBtn" Grid.Column="1" Style="{StaticResource IconBtn}" Content="&#xE712;" ToolTip="Thêm tùy chọn"/>
      </Grid>
      <Button x:Name="SyncNowBtn" Style="{StaticResource Ghost}" Content="Đồng bộ session ngay" Margin="2,10,0,0" HorizontalAlignment="Stretch" IsEnabled="False" ToolTip="Cập nhật session mới nhất giữa hai account"/>
      </StackPanel>
    </StackPanel>
    </ScrollViewer>
    <Popup x:Name="MorePopup" PlacementTarget="{Binding ElementName=MoreBtn}" Placement="Top" HorizontalOffset="-196" VerticalOffset="-4" StaysOpen="False" AllowsTransparency="True" PopupAnimation="Fade">
      <Border Width="230" Margin="6" Background="{DynamicResource Card}" BorderBrush="{DynamicResource CardBorder}" BorderThickness="1" CornerRadius="10" Padding="4">
        <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.25"/></Border.Effect>
        <StackPanel>
          <Button x:Name="MenuBackups" Style="{StaticResource MenuBtn}" Content="Mở thư mục sao lưu"/>
          <Button x:Name="MenuRemove" Style="{StaticResource MenuBtn}" Content="Gỡ session đã sao chép"/>
          <Button x:Name="MenuLog" Style="{StaticResource MenuBtn}" Content="Xem log"/>
          <Button x:Name="MenuConfirm" Style="{StaticResource MenuBtn}" Content="Bật lại hộp xác nhận" Visibility="Collapsed"/>
        </StackPanel>
      </Border>
    </Popup>
    <Grid x:Name="Overlay" Visibility="Collapsed">
      <Rectangle Fill="#99000000"/>
      <Border Width="380" VerticalAlignment="Center" HorizontalAlignment="Center" Background="{DynamicResource Card}" BorderBrush="{DynamicResource CardBorder}" BorderThickness="1" CornerRadius="14" Padding="20">
        <StackPanel>
          <TextBlock x:Name="ConfirmTitle" FontSize="17" FontWeight="SemiBold" Foreground="{DynamicResource Text}" TextWrapping="Wrap"/>
          <TextBlock x:Name="ConfirmBody" Margin="0,8,0,0" Foreground="{DynamicResource Text}" TextWrapping="Wrap"/>
          <TextBlock x:Name="ConfirmExtra" Margin="0,6,0,0" Foreground="{DynamicResource Accent}" FontWeight="SemiBold" TextWrapping="Wrap" Visibility="Collapsed"/>
          <CheckBox x:Name="SkipChk" Style="{StaticResource SwitchBox}" Content="Không hỏi lại" Margin="0,16,0,0"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
            <Button x:Name="ConfirmCancel" Style="{StaticResource Ghost}" Content="Hủy" Margin="0,0,8,0"/>
            <Button x:Name="ConfirmOk" Style="{StaticResource Primary}" Content="Tiếp tục"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($MainXaml)
$win.MaxHeight = [Math]::Max(400, [Windows.SystemParameters]::WorkArea.Height - 48)
$Cards = $win.FindName('Cards'); $PanelProgress = $win.FindName('PanelProgress'); $ProgTitle = $win.FindName('ProgTitle')
$StepsPanel = $win.FindName('StepsPanel'); $BarFill = $win.FindName('BarFill'); $ProgMsg = $win.FindName('ProgMsg')
$BtnPrimary = $win.FindName('BtnPrimary'); $BtnSecondary = $win.FindName('BtnSecondary'); $Toast = $win.FindName('Toast')
$SyncChk = $win.FindName('SyncChk'); $MoreBtn = $win.FindName('MoreBtn'); $MorePopup = $win.FindName('MorePopup')
$SyncNowBtn = $win.FindName('SyncNowBtn')
$Overlay = $win.FindName('Overlay'); $ConfirmTitle = $win.FindName('ConfirmTitle'); $ConfirmBody = $win.FindName('ConfirmBody')
$ConfirmExtra = $win.FindName('ConfirmExtra'); $SkipChk = $win.FindName('SkipChk'); $ConfirmOk = $win.FindName('ConfirmOk'); $ConfirmCancel = $win.FindName('ConfirmCancel')
$Root = $win.FindName('Root')
foreach ($name in @('ToolTabs','DesktopTab','CliTab','ScanBtn','NoToolsText','CliPanel','CliInfo','CliCards','CliLoginBtn','CliOpenBtn','DesktopFooter','UsageControls','UsageUpdated','UsageRefreshBtn')) { Set-Variable -Name $name -Value $win.FindName($name) }

function Set-Theme([bool]$dark) {
    $AppState.Dark = $dark
    $pal = if ($dark) { $PalDark } else { $PalLight }
    foreach ($k in $pal.Keys) { $win.Resources[$k] = [Windows.Media.SolidColorBrush](New-Brush $pal[$k]) }
}
function Res([string]$k) { return $win.Resources[$k] }

# ---------------------------------------------------------------- biểu tượng
function New-AppIcon {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::Transparent)
    $br = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#C2562F'))
    $g.FillEllipse($br, 0, 0, 31, 31)
    $f = New-Object Drawing.Font('Segoe UI', 17, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString('C', $f, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, 0, 32, 33), $sf)
    $g.Dispose()
    $h = $bmp.GetHicon()
    return @{ Icon = [Drawing.Icon]::FromHandle($h); Handle = $h }
}
$AppIcon = New-AppIcon
try { $win.Icon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($AppIcon.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()) } catch {}

# ---------------------------------------------------------------- cài đặt của giao diện
function Get-GuiSettings {
    $s = @{ syncSessions = $true; skipConfirm = $false; hintShown = $false }
    try {
        $p = Join-Path $StoreDir 'settings.json'
        if (Test-Path -LiteralPath $p) {
            $o = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($null -ne $o.$k) { $s[$k] = [bool]$o.$k } }
        }
    } catch {}
    return $s
}
function Set-GuiSetting([string]$k, [bool]$v) {
    $s = Get-GuiSettings; $s[$k] = $v
    try {
        if (-not (Test-Path -LiteralPath $StoreDir)) { [void][IO.Directory]::CreateDirectory($StoreDir) }
        [IO.File]::WriteAllText((Join-Path $StoreDir 'settings.json'), ($s | ConvertTo-Json -Compress), $Utf8NoBom)
    } catch { Gui-Log 'Không ghi được settings.json' }
}

# ---------------------------------------------------------------- chạy engine ở tiến trình riêng
function Quote-Arg([string]$a) { if ($a -eq '' -or $a -match '[\s"]') { return '"' + $a.Replace('"', '') + '"' } else { return $a } }

function Start-EngineJob([string[]]$engineArgs, [scriptblock]$onLine, [scriptblock]$onDone) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dir = Join-Path $StoreDir 'run'
    if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $prog = Join-Path $dir ($id + '.jsonl'); $out = Join-Path $dir ($id + '.out.json')
    $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $Engine, '-DataDir', $DataDir, '-StoreDir', $StoreDir, '-ClaudeJson', $ClaudeJson, '-ProgressFile', $prog, '-OutFile', $out)
    if ($NoAppControl) { $al += '-NoAppControl' }
    if ($CliPath) { $al += @('-CliPath',$CliPath) }
    if ($CliConfigDir) { $al += @('-CliConfigDir',$CliConfigDir) }
    if ($CliConfigFile) { $al += @('-CliConfigFile',$CliConfigFile) }
    $al += $engineArgs
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = (($al | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WindowStyle = 'Hidden'
    $psi.RedirectStandardError=$true; $psi.RedirectStandardOutput=$true
    $proc = [Diagnostics.Process]::Start($psi)
    $job = @{ Proc = $proc; Prog = $prog; Out = $out; Pos = 0; OnLine = $onLine; OnDone = $onDone; Lines = (New-Object System.Collections.ArrayList); Exit = $null; Stderr=$proc.StandardError.ReadToEndAsync(); Stdout=$proc.StandardOutput.ReadToEndAsync() }
    [void]$AppState.Jobs.Add($job)
    $description = $engineArgs -join ' '
    if ($DataDir) { $description=$description.Replace($DataDir,'<data>') }
    Gui-Log ('engine start: ' + $description)
    return $job
}

function Read-JobLines($job) {
    if (-not (Test-Path -LiteralPath $job.Prog)) { return @() }
    $text = ''
    try {
        $fs = New-Object IO.FileStream($job.Prog, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $sr = New-Object IO.StreamReader($fs, $Utf8NoBom); $text = $sr.ReadToEnd() } finally { $fs.Dispose() }
    } catch { return @() }
    $parts = $text -split "`n"
    $complete = if ($text.EndsWith("`n")) { $parts.Count } else { $parts.Count - 1 }
    $new = @()
    while ($job.Pos -lt $complete) {
        $ln = $parts[$job.Pos].Trim(); $job.Pos++
        if ($ln) { try { $new += , ($ln | ConvertFrom-Json) } catch {} }
    }
    return $new
}

function Pump-Jobs {
    foreach ($job in @($AppState.Jobs.ToArray())) {
        try {
            $exited = $job.Proc.HasExited
            foreach ($l in (Read-JobLines $job)) {
                [void]$job.Lines.Add($l)
                if ($job.OnLine) { try { & $job.OnLine $job $l } catch { Gui-Log ('OnLine lỗi: ' + $_.Exception.Message) } }
            }
            if ($exited) {
                $job.Exit = $job.Proc.ExitCode
                [void]$AppState.Jobs.Remove($job)
                if ($job.Exit -ne 0) { Gui-Log ('engine exit {0}: {1}' -f $job.Exit,(Read-EngineError $job)) }
                if ($job.OnDone) { try { & $job.OnDone $job } catch { Gui-Log ('OnDone lỗi: ' + $_.Exception.Message) } }
                $job.Proc.Dispose()
            }
        } catch { Gui-Log ('Pump lỗi: ' + $_.Exception.Message); [void]$AppState.Jobs.Remove($job) }
    }
}

# ---------------------------------------------------------------- dựng thẻ
$CardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="{DynamicResource Card}" BorderBrush="{DynamicResource CardBorder}" BorderThickness="1" CornerRadius="14" Padding="16" Margin="0,0,0,12">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="46"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Border Width="44" Height="44" CornerRadius="22" Background="{DynamicResource AccentSoft}" HorizontalAlignment="Left">
        <TextBlock x:Name="Initial" FontSize="19" FontWeight="SemiBold" Foreground="{DynamicResource Accent}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="12,0,8,0" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="LabelText" FontSize="16" FontWeight="SemiBold" Foreground="{DynamicResource Text}" TextTrimming="CharacterEllipsis" MaxWidth="190" VerticalAlignment="Center"/>
          <TextBox x:Name="LabelEdit" Visibility="Collapsed" FontSize="15" FontWeight="SemiBold" MaxLength="30" Width="170" Padding="4,2" Background="{DynamicResource Hover}" Foreground="{DynamicResource Text}" BorderBrush="{DynamicResource Accent}" BorderThickness="1" CaretBrush="{DynamicResource Text}"/>
          <Button x:Name="EditBtn" Style="{StaticResource IconBtn}" Content="&#xE70F;" Margin="4,0,0,0" Width="24" Height="24" FontSize="12" ToolTip="Đổi tên"/>
        </StackPanel>
        <TextBlock x:Name="EmailText" FontSize="12" Foreground="{DynamicResource SubText}" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
      </StackPanel>
      <Border x:Name="Badge" Grid.Column="2" Background="{DynamicResource AccentSoft}" CornerRadius="10" Padding="10,3" VerticalAlignment="Top" Visibility="Collapsed">
        <TextBlock Text="Đang dùng" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/>
      </Border>
    </Grid>
    <TextBlock x:Name="SessText" FontSize="12" Foreground="{DynamicResource SubText}" Margin="2,12,0,0"/>
    <StackPanel x:Name="UsageSlot" Margin="2,10,2,0"/>
    <Button x:Name="SwitchBtn" Style="{StaticResource Primary}" Margin="0,12,0,0" Visibility="Collapsed"/>
  </StackPanel>
</Border>
'@

$EmptyXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="{DynamicResource Card}" BorderBrush="{DynamicResource Muted}" BorderThickness="1.5" CornerRadius="14" Padding="18" Margin="0,0,0,12">
  <StackPanel>
    <TextBlock Text="Thêm account thứ hai" FontSize="17" FontWeight="SemiBold" Foreground="{DynamicResource Text}"/>
    <TextBlock Text="Làm một lần, sau này chuyển qua lại chỉ cần một cú nhấp." FontSize="12" Foreground="{DynamicResource SubText}" Margin="0,2,0,12" TextWrapping="Wrap"/>
    <StackPanel x:Name="Steps"/>
    <Button x:Name="AddBtn" Style="{StaticResource Primary}" Content="Thêm account thứ hai" Margin="0,6,0,0"/>
  </StackPanel>
</Border>
'@

$StepRowXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,9">
  <Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border x:Name="Num" Width="22" Height="22" CornerRadius="11" Background="{DynamicResource AccentSoft}" HorizontalAlignment="Left" VerticalAlignment="Top">
    <TextBlock x:Name="NumText" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource Accent}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
  <TextBlock x:Name="StepText" Grid.Column="1" TextWrapping="Wrap" Foreground="{DynamicResource Text}" VerticalAlignment="Center" LineHeight="18"/>
</Grid>
'@

$ProgRowXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,10">
  <Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border x:Name="Circle" Width="22" Height="22" CornerRadius="11" BorderThickness="1.5" BorderBrush="{DynamicResource Muted}" Background="Transparent" HorizontalAlignment="Left">
    <TextBlock x:Name="Glyph" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="White"/>
  </Border>
  <TextBlock x:Name="Label" Grid.Column="1" VerticalAlignment="Center" Foreground="{DynamicResource SubText}" FontSize="14"/>
</Grid>
'@

# thẻ được parse riêng nên phải dùng DynamicResource để tìm style của cửa sổ
$CardXaml = $CardXaml.Replace('StaticResource', 'DynamicResource')
$EmptyXaml = $EmptyXaml.Replace('StaticResource', 'DynamicResource')

function New-AccountCard($p) {
    $card = [Windows.Markup.XamlReader]::Parse($CardXaml)
    $label = [string]$p.label; if (-not $label) { $label = [string]$p.email }; if (-not $label) { $label = 'Account' }
    $card.FindName('Initial').Text = $label.Substring(0, 1).ToUpper()
    $card.FindName('LabelText').Text = $label
    $email = [string]$p.email; if (-not $email) { $email = [string]$p.displayName }; if (-not $email) { $email = 'Chưa có email' }
    $card.FindName('EmailText').Text = $email
    $n = [int]$p.sessionCount
    $card.FindName('SessText').Text = if ($n -gt 0) { "$n session Claude Code" } else { 'Chưa có session Claude Code' }
    Add-UsageToCard $card ([string]$p.uuid)
    $edit = $card.FindName('EditBtn'); $edit.Tag = @{ Card = $card; Uuid = [string]$p.uuid }
    $edit.Add_Click({ param($s, $e) Begin-EditLabel $s.Tag.Card $s.Tag.Uuid })
    $le = $card.FindName('LabelEdit'); $le.Tag = @{ Card = $card; Uuid = [string]$p.uuid; Done = $false }
    $le.Add_KeyDown({ param($s, $e)
        if ($e.Key -eq 'Return') { $e.Handled = $true; Commit-EditLabel $s $true }
        elseif ($e.Key -eq 'Escape') { $e.Handled = $true; Commit-EditLabel $s $false } })
    $le.Add_LostFocus({ param($s, $e) Commit-EditLabel $s $true })
    if ($p.isActive) {
        $card.FindName('Badge').Visibility = 'Visible'
        $card.BorderBrush = (Res 'Accent'); $card.BorderThickness = New-Object Windows.Thickness 1.5
    } elseif ($p.hasAuth) {
        $b = $card.FindName('SwitchBtn')
        $tb = New-Object Windows.Controls.TextBlock; $tb.Text = "Chuyển sang $label"; $tb.TextTrimming = 'CharacterEllipsis'
        $b.Content = $tb; $b.Visibility = 'Visible'; $b.Tag = [string]$p.uuid
        $b.Add_Click({ param($s, $e) Begin-Switch ([string]$s.Tag) })
        $AppState.TestBtn = $b
        if (-not $AppState.Primary) { $AppState.Primary = { Begin-Switch ([string]$AppState.PrimaryArg) }; $AppState.PrimaryArg = [string]$p.uuid }
    }
    return $card
}

function New-EmptyCard {
    $card = [Windows.Markup.XamlReader]::Parse($EmptyXaml)
    $steps = $card.FindName('Steps')
    $texts = @('Claude đóng lại rồi tự mở lên ở màn hình đăng nhập.', 'Bạn đăng nhập bằng account Claude còn lại của mình.', 'Claude Switch tự nhận ra và lưu lại. Xong!')
    for ($i = 0; $i -lt 3; $i++) {
        $r = [Windows.Markup.XamlReader]::Parse($StepRowXaml)
        $r.FindName('NumText').Text = [string]($i + 1)
        $r.FindName('StepText').Text = $texts[$i]
        [void]$steps.Children.Add($r)
    }
    $btn = $card.FindName('AddBtn')
    $btn.Add_Click({ param($s, $e) Begin-Add })
    $AppState.TestBtn = $btn
    if (-not $AppState.Primary) { $AppState.Primary = { Begin-Add } }
    return $card
}

function New-NoLoginCard {
    $card = [Windows.Markup.XamlReader]::Parse($EmptyXaml)
    $card.Child.Children[0].Text = 'Chưa thấy account nào đang đăng nhập'
    $card.Child.Children[1].Text = 'Hãy mở Claude, đăng nhập một lần rồi quay lại đây.'
    $steps = $card.FindName('Steps')
    $texts = @('Mở ứng dụng Claude và đăng nhập account đầu tiên.', 'Quay lại Claude Switch, bấm "Kiểm tra lại".', 'Sau đó thêm account thứ hai ngay tại đây.')
    for ($i = 0; $i -lt 3; $i++) {
        $r = [Windows.Markup.XamlReader]::Parse($StepRowXaml)
        $r.FindName('NumText').Text = [string]($i + 1); $r.FindName('StepText').Text = $texts[$i]
        [void]$steps.Children.Add($r)
    }
    $btn = $card.FindName('AddBtn'); $btn.Content = 'Kiểm tra lại'
    $btn.Add_Click({ param($s, $e) Refresh-Status })
    $AppState.Primary = { Refresh-Status }
    return $card
}

function New-PendingCard {
    $card = [Windows.Markup.XamlReader]::Parse($EmptyXaml)
    $card.Child.Children[0].Text = 'Đang thêm account thứ hai'
    $card.Child.Children[1].Text = 'Lần trước bạn chưa đăng nhập xong account thứ hai.'
    $card.FindName('Steps').Visibility = 'Collapsed'
    $btn = $card.FindName('AddBtn'); $btn.Content = 'Tiếp tục chờ đăng nhập'
    $btn.Add_Click({ param($s, $e) Enter-WaitLogin })
    $AppState.Primary = { Enter-WaitLogin }
    $cancel = New-Object Windows.Controls.Button
    $cancel.Style = $win.FindResource('Ghost'); $cancel.Content = 'Hủy, quay lại account cũ'; $cancel.Margin = New-Object Windows.Thickness 0, 8, 0, 0
    $cancel.Add_Click({ param($s, $e) Cancel-Add })
    [void]$card.Child.Children.Add($cancel)
    return $card
}

function Render-Accounts {
    if ($AppState.ActiveTool -eq 'cli') { Render-CliAccounts; return }
    $Cards.Children.Clear()
    $AppState.Primary = $null
    $st = $AppState.Status
    $profiles = @(); if ($st) { $profiles = @($st.profiles) }
    if ($st -and $st.pendingAdd -and -not $st.loggedIn -and $profiles.Count -ge 1) {
        foreach ($p in $profiles) { [void]$Cards.Children.Add((New-AccountCard $p)) }
        $AppState.Primary = $null
        [void]$Cards.Children.Add((New-PendingCard))
    } elseif ($profiles.Count -eq 0) {
        [void]$Cards.Children.Add((New-NoLoginCard))
    } else {
        foreach ($p in $profiles) { [void]$Cards.Children.Add((New-AccountCard $p)) }
        if ($profiles.Count -eq 1) { [void]$Cards.Children.Add((New-EmptyCard)) }
    }
    if ($st -and $st.configError) {
        $Toast.Text = [string]$st.configError; $Toast.Visibility = 'Visible'
    }
    Update-SyncButton
}

# ---------------------------------------------------------------- đổi tên
function Begin-EditLabel($card, [string]$uuid) {
    $lt = $card.FindName('LabelText'); $le = $card.FindName('LabelEdit')
    $le.Text = $lt.Text; $le.Tag.Done = $false
    $lt.Visibility = 'Collapsed'; $le.Visibility = 'Visible'
    [void]$le.Focus(); $le.SelectAll()
}
function Commit-EditLabel($le, [bool]$save) {
    if ($le.Tag.Done) { return }
    $le.Tag.Done = $true
    $card = $le.Tag.Card; $lt = $card.FindName('LabelText')
    $new = ([string]$le.Text).Trim()
    $le.Visibility = 'Collapsed'; $lt.Visibility = 'Visible'
    if ($save -and $new -and $new -ne $lt.Text) {
        $lt.Text = $new; $card.FindName('Initial').Text = $new.Substring(0, 1).ToUpper()
        foreach ($p in @($AppState.Status.profiles)) { if ($p.uuid -eq $le.Tag.Uuid) { $p.label = $new } }
        [void](Start-EngineJob @('-Action', 'SetLabel', '-TargetAccount', $le.Tag.Uuid, '-Label', $new.Replace('"', '')) $null { param($job) Refresh-Status })
    }
}

# ---------------------------------------------------------------- panel tiến trình
$SwitchSteps = @(@('close', 'Đóng Claude'), @('backup', 'Sao lưu'), @('sync', 'Đồng bộ session'), @('switch', 'Đổi tài khoản'), @('open', 'Mở lại Claude'))
$AddSteps = @(@('close', 'Đóng Claude'), @('backup', 'Sao lưu'), @('switch', 'Chuẩn bị màn hình đăng nhập'), @('open', 'Mở lại Claude'), @('login', 'Bạn đăng nhập account thứ hai'))
$BarWidth = 382

function Show-ProgressPanel([string]$title, $steps) {
    $AppState.Mode = 'progress'
    Update-DetectedTools
    Update-SyncButton
    $Cards.Children.Clear(); $Toast.Visibility = 'Collapsed'
    $PanelProgress.Visibility = 'Visible'
    $ProgTitle.Text = $title; $ProgTitle.Foreground = (Res 'Text'); $ProgMsg.Text = ''
    $StepsPanel.Children.Clear(); $AppState.StepUi = @{}; $AppState.StepOrder = @()
    foreach ($st in $steps) {
        $row = [Windows.Markup.XamlReader]::Parse($ProgRowXaml)
        $row.FindName('Label').Text = $st[1]
        [void]$StepsPanel.Children.Add($row)
        $AppState.StepUi[$st[0]] = @{ Circle = $row.FindName('Circle'); Glyph = $row.FindName('Glyph'); Label = $row.FindName('Label'); State = 'pending' }
        $AppState.StepOrder += $st[0]
    }
    $BarFill.Width = 0
    $BtnPrimary.Visibility = 'Collapsed'; $BtnSecondary.Visibility = 'Collapsed'
    $AppState.ProgPrimary = $null; $AppState.ProgSecondary = $null; $AppState.Primary = $null
}

function Set-Step([string]$id, [string]$state) {
    if (-not $AppState.StepUi.ContainsKey($id)) { return }
    $u = $AppState.StepUi[$id]; $u.State = $state
    $u.Circle.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $u.Circle.Opacity = 1
    $u.Glyph.FontFamily = New-Object Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'; $u.Glyph.FontSize = 13
    $u.Label.FontWeight = 'Normal'
    switch ($state) {
        'pending' { $u.Circle.Background = [Windows.Media.Brushes]::Transparent; $u.Circle.BorderBrush = (Res 'Muted'); $u.Glyph.Text = ''; $u.Label.Foreground = (Res 'SubText') }
        'running' {
            $u.Circle.Background = (Res 'Accent'); $u.Circle.BorderBrush = (Res 'Accent')
            $u.Glyph.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI'; $u.Glyph.FontSize = 9; $u.Glyph.Text = [string][char]0x25CF; $u.Glyph.Foreground = (Res 'OnAccent')
            $u.Label.Foreground = (Res 'Text'); $u.Label.FontWeight = 'SemiBold'
            $an = New-Object Windows.Media.Animation.DoubleAnimation 1.0, 0.45, (New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(700)))
            $an.AutoReverse = $true; $an.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $u.Circle.BeginAnimation([Windows.UIElement]::OpacityProperty, $an)
        }
        'done' { $u.Circle.Background = (Res 'Accent'); $u.Circle.BorderBrush = (Res 'Accent'); $u.Glyph.Text = [string][char]0xE73E; $u.Glyph.Foreground = (Res 'OnAccent'); $u.Label.Foreground = (Res 'Text') }
        'skipped' { $u.Circle.Background = [Windows.Media.Brushes]::Transparent; $u.Circle.BorderBrush = (Res 'Muted'); $u.Glyph.Text = [string][char]0x2013; $u.Glyph.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI'; $u.Glyph.Foreground = (Res 'SubText'); $u.Label.Foreground = (Res 'SubText') }
        'warn' { $u.Circle.Background = (Res 'Accent'); $u.Circle.BorderBrush = (Res 'Accent'); $u.Glyph.Text = '!'; $u.Glyph.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI'; $u.Glyph.FontSize = 12; $u.Glyph.Foreground = (Res 'OnAccent'); $u.Label.Foreground = (Res 'Text') }
        'error' { $u.Circle.Background = (Res 'Danger'); $u.Circle.BorderBrush = (Res 'Danger'); $u.Glyph.Text = [string][char]0xE711; $u.Glyph.Foreground = (Res 'Bg'); $u.Label.Foreground = (Res 'Danger'); $u.Label.FontWeight = 'SemiBold' }
    }
    $total = [Math]::Max(1, $AppState.StepOrder.Count); $done = 0
    foreach ($k in $AppState.StepOrder) { if (@('done', 'skipped', 'warn') -contains $AppState.StepUi[$k].State) { $done++ } }
    $BarFill.Width = [double]($BarWidth * $done / $total)
}

function Set-ProgressEnd([string]$kind, [string]$title, [string]$msg, [string]$primaryText, [scriptblock]$primaryAction, [string]$secText, [scriptblock]$secAction) {
    $ProgTitle.Text = $title
    $ProgTitle.Foreground = if ($kind -eq 'error') { Res 'Danger' } else { Res 'Text' }
    $ProgMsg.Text = $msg
    $ProgMsg.Foreground = if ($kind -eq 'error') { Res 'Text' } else { Res 'SubText' }
    $AppState.ProgPrimary = $primaryAction; $AppState.ProgSecondary = $secAction
    if ($primaryText) { $BtnPrimary.Content = $primaryText; $BtnPrimary.Visibility = 'Visible' } else { $BtnPrimary.Visibility = 'Collapsed' }
    if ($secText) { $BtnSecondary.Content = $secText; $BtnSecondary.Visibility = 'Visible' } else { $BtnSecondary.Visibility = 'Collapsed' }
    $AppState.Primary = $primaryAction
}

function Show-Accounts {
    $AppState.Mode = 'accounts'; $AppState.Busy = $false
    if ($AppState.AddTimer) { $AppState.AddTimer.Stop() }
    $PanelProgress.Visibility = 'Collapsed'
    $Toast.Visibility = 'Collapsed'
    Render-Accounts
    Refresh-Status
}

function Show-Toast([string]$msg) {
    $Toast.Text = $msg; $Toast.Visibility = 'Visible'
    if ($AppState.ToastTimer) { $AppState.ToastTimer.Stop(); $AppState.ToastTimer.Start() }
}

function Update-SyncButton {
    $profiles = @($AppState.Status.profiles | Where-Object { $_.hasAuth })
    $SyncNowBtn.IsEnabled = ($AppState.ActiveTool -eq 'desktop' -and $AppState.Mode -eq 'accounts' -and -not $AppState.Busy -and $profiles.Count -ge 2)
}

function Start-SessionSync {
    if ($AppState.Busy -or $AppState.Mode -ne 'accounts') { return }
    if (@($AppState.Status.profiles | Where-Object { $_.hasAuth }).Count -lt 2) {
        Show-Toast 'Hãy thêm đủ 2 account trước khi đồng bộ session.'
        return
    }
    $AppState.Busy = $true
    Update-SyncButton
    $SyncNowBtn.Content = 'Đang đồng bộ…'
    $SyncChk.IsEnabled = $false
    Show-Toast 'Đang đồng bộ session giữa 2 account…'
    try {
        [void](Start-EngineJob @('-Action', 'SyncSessions') $null { param($job) Finish-SessionSync $job })
    } catch {
        Finish-SessionSync @{ Exit = 1; Out = ''; Lines = @() }
    }
}

function Finish-SessionSync($job) {
    try {
        if ($job.Exit -ne 0) { throw (Get-FailMessage $job) }
        $result = [IO.File]::ReadAllText($job.Out, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if (-not $result.ok) { throw 'Chưa nhận được kết quả đồng bộ.' }
        Show-Toast ('Đã đồng bộ: thêm {0}, cập nhật {1} session. Mở lại Claude để thấy đủ.' -f $result.copied, $result.updated)
    } catch {
        Show-Toast ('Chưa đồng bộ được session. ' + $_.Exception.Message)
    } finally {
        $AppState.Busy = $false
        $SyncNowBtn.Content = 'Đồng bộ session ngay'
        $SyncChk.IsEnabled = $true
        Update-SyncButton
        Refresh-Status
    }
}

# ---------------------------------------------------------------- xác nhận
function Get-Label([string]$uuid) {
    foreach ($p in @($AppState.Status.profiles)) { if ($p.uuid -eq $uuid) { if ($p.label) { return [string]$p.label } else { return [string]$p.email } } }
    return 'account này'
}

function Show-Confirm([string]$kind, [string]$arg, [string]$title) {
    $AppState.ConfirmKind = $kind; $AppState.ConfirmArg = $arg
    $ConfirmTitle.Text = $title
    $ConfirmBody.Text = 'Claude sẽ đóng và mở lại. Việc đang chạy sẽ bị dừng.'
    $n = 0; if ($AppState.Status) { $n = [int]$AppState.Status.recentActive }
    if ($n -gt 0) { $ConfirmExtra.Text = "Hiện có $n session đã hoạt động trong 10 phút qua."; $ConfirmExtra.Visibility = 'Visible' } else { $ConfirmExtra.Visibility = 'Collapsed' }
    $SkipChk.IsChecked = $false
    $Overlay.Visibility = 'Visible'
    $AppState.PrimaryBeforeConfirm = $AppState.Primary
    $AppState.Primary = { Do-ConfirmOk }
}
function Hide-Confirm { $Overlay.Visibility = 'Collapsed'; $AppState.Primary = $AppState.PrimaryBeforeConfirm }
function Do-ConfirmOk {
    if ($SkipChk.IsChecked) { Set-GuiSetting 'skipConfirm' $true }
    $kind = $AppState.ConfirmKind; $arg = $AppState.ConfirmArg
    Hide-Confirm
    if ($kind -eq 'switch') { Start-Switch $arg } elseif ($kind -eq 'add') { Start-Add }
}

function Begin-Switch([string]$uuid) {
    if ($AppState.Busy -or $Overlay.Visibility -eq 'Visible') { return }
    $label = Get-Label $uuid
    if ((Get-GuiSettings).skipConfirm) { Start-Switch $uuid } else { Show-Confirm 'switch' $uuid "Chuyển sang $label?" }
}
function Begin-Add {
    if ($AppState.Busy -or $Overlay.Visibility -eq 'Visible') { return }
    if ((Get-GuiSettings).skipConfirm) { Start-Add } else { Show-Confirm 'add' '' 'Thêm account thứ hai?' }
}

# ---------------------------------------------------------------- chuyển account
function Handle-ProgressLine($job, $l) {
    if ($AppState.StepUi.ContainsKey([string]$l.step)) {
        Set-Step ([string]$l.step) ([string]$l.state)
        if ($l.state -eq 'running') { $ProgMsg.Text = [string]$l.message }
    }
}
function Get-FailMessage($job) {
    $msg = ''
    foreach ($l in $job.Lines) { if ($l.state -eq 'error') { $msg = [string]$l.message } }
    if (-not $msg -and $job.Prog -and (Test-Path -LiteralPath $job.Prog)) {
        try {
            foreach($line in [IO.File]::ReadAllLines($job.Prog,[Text.Encoding]::UTF8)) {
                $record=$line|ConvertFrom-Json -ErrorAction Stop
                if($record.state -eq 'error'){$msg=[string]$record.message}
            }
        } catch {}
    }
    if (-not $msg -and $job.Out -and (Test-Path -LiteralPath $job.Out)) {
        try { $result=[IO.File]::ReadAllText($job.Out,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop; if($result.ok -eq $false -and $result.message){$msg=[string]$result.message} } catch {}
    }
    if (-not $msg) {
        $details=Read-EngineError $job
        $msg='Tiến trình xử lý dừng với mã '+[string]$job.Exit+'.'
        if($details){$msg+=' '+$details}else{$msg+=' Chưa ghi được thông tin lỗi; hãy thử lại hoặc xem log.'}
    }
    foreach ($k in $AppState.StepOrder) { if ($AppState.StepUi[$k].State -eq 'running') { Set-Step $k 'error'; break } }
    return $msg
}

function Read-EngineError($job) {
    $text=''
    if($job.Stderr -and $job.Stderr.IsCompleted){try{$text=[string]$job.Stderr.GetAwaiter().GetResult()}catch{}}
    $text=[regex]::Replace($text,'(?i)(Bearer\s+)[^\s"'']+','$1[ẩn]')
    $text=[regex]::Replace($text,'(?i)sk-[a-z0-9_-]+','[ẩn]')
    $text=[regex]::Replace($text,'(?i)("(?:accessToken|refreshToken|oauth:tokenCache(?:V2)?|tokenCache(?:V2)?|password|apiKey)"\s*:\s*)"(?:[^"\\]|\\.)*"','$1"[ẩn]"')
    $text=$text.Trim()
    if($text.Length -gt 1800){$text=$text.Substring(0,1800)+'…'}
    return $text
}

function Start-Switch([string]$uuid) {
    $AppState.Busy = $true; $AppState.Flow = 'switch'
    $AppState.PrevUuid = if ($AppState.Status) { [string]$AppState.Status.activeUuid } else { $null }
    $AppState.TargetUuid = $uuid
    $label = Get-Label $uuid
    Show-ProgressPanel "Đang chuyển sang $label" $SwitchSteps
    $ProgMsg.Text = 'Vui lòng đợi vài giây, đừng tắt máy.'
    [void](Start-EngineJob @('-Action', 'Switch', '-TargetAccount', $uuid) { param($job, $l) Handle-ProgressLine $job $l } { param($job) Finish-Switch $job })
}

function Finish-Switch($job) {
    $label = Get-Label $AppState.TargetUuid
    if ($job.Exit -eq 0) {
        foreach ($k in $AppState.StepOrder) { if ($AppState.StepUi[$k].State -eq 'pending' -or $AppState.StepUi[$k].State -eq 'running') { Set-Step $k 'done' } }
        $last = ''; foreach ($l in $job.Lines) { if ($l.step -eq 'done') { $last = [string]$l.message } }
        $prev = $AppState.PrevUuid
        $secText = $null; $secAct = $null
        if ($prev) { $secText = 'Quay lại account trước'; $secAct = { $AppState.Busy = $false; Show-Accounts; Begin-Switch ([string]$AppState.PrevBack) } }
        $AppState.PrevBack = $AppState.PrevUuid
        Set-ProgressEnd 'ok' "Đã chuyển sang $label" ($last + ' Session Claude Code hiện ở cả 2 account.') 'Xong' { Show-Accounts } $secText $secAct
        if ((Get-GuiSettings).syncSessions -eq $false) { $ProgMsg.Text = $last }
    } else {
        $msg = Get-FailMessage $job
        Set-ProgressEnd 'error' 'Chưa chuyển được account' $msg 'Đóng' { Show-Accounts } $null $null
    }
    $AppState.Busy = $false
    Refresh-Status
}

# ---------------------------------------------------------------- thêm account thứ hai
function Start-Add {
    $AppState.Busy = $true; $AppState.Flow = 'add'
    $AppState.PrevUuid = if ($AppState.Status) { [string]$AppState.Status.activeUuid } else { $null }
    Show-ProgressPanel 'Đang chuẩn bị thêm account' $AddSteps
    $ProgMsg.Text = 'Claude sẽ đóng rồi mở lại ở màn hình đăng nhập.'
    [void](Start-EngineJob @('-Action', 'PrepareAdd') { param($job, $l) Handle-ProgressLine $job $l } { param($job) Finish-PrepareAdd $job })
}
function Finish-PrepareAdd($job) {
    if ($job.Exit -eq 0) {
        foreach ($k in @('close', 'backup', 'switch', 'open')) { if ($AppState.StepUi[$k].State -ne 'warn') { Set-Step $k 'done' } }
        Enter-WaitLogin
    } else {
        $msg = Get-FailMessage $job
        Set-ProgressEnd 'error' 'Chưa thêm được account' $msg 'Đóng' { Show-Accounts } $null $null
        $AppState.Busy = $false
    }
    Refresh-Status
}
function Enter-WaitLogin {
    $AppState.Busy = $true; $AppState.Flow = 'add'; $AppState.NewUuid = $null
    if ($AppState.Mode -ne 'progress' -or $AppState.StepOrder.Count -ne 5) {
        if (-not $AppState.PrevUuid -and $AppState.Status -and $AppState.Status.pendingAdd) { $AppState.PrevUuid = [string]$AppState.Status.pendingAdd.previousAccount }
        Show-ProgressPanel 'Đang thêm account thứ hai' $AddSteps
        foreach ($k in @('close', 'backup', 'switch', 'open')) { Set-Step $k 'done' }
    }
    $ProgTitle.Text = 'Hãy đăng nhập account thứ hai'
    $ProgMsg.Text = 'Trong cửa sổ Claude vừa mở, đăng nhập bằng account còn lại. Claude Switch sẽ tự nhận ra và lưu lại.'
    Set-Step 'login' 'running'
    Set-ProgressEnd 'wait' 'Hãy đăng nhập account thứ hai' $ProgMsg.Text $null $null 'Hủy, quay lại account cũ' { Cancel-Add }
    $ProgTitle.Foreground = (Res 'Text')
    if ($AppState.AddTimer) { $AppState.AddTimer.Start() }
}
function Cancel-Add {
    if ($AppState.AddTimer) { $AppState.AddTimer.Stop() }
    $prev = $AppState.PrevUuid
    if (-not $prev -and $AppState.Status -and $AppState.Status.pendingAdd) { $prev = [string]$AppState.Status.pendingAdd.previousAccount }
    if (-not $prev) { Show-Accounts; return }
    $AppState.PrevUuid = $null
    Start-Switch $prev
    $ProgTitle.Text = 'Đang quay lại account cũ'
}

function Read-LoginUuid {
    try {
        if (-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath)) { return $null }
        $fs = New-Object IO.FileStream($ConfigPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $sr = New-Object IO.StreamReader($fs, $Utf8NoBom); $t = $sr.ReadToEnd() } finally { $fs.Dispose() }
        $d = $t | ConvertFrom-Json -ErrorAction Stop
        $u = $d.lastKnownAccountUuid
        if ($u -isnot [string] -or $u -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $null }
        if ($d.'oauth:tokenCacheV2' -isnot [string] -or -not $d.'oauth:tokenCacheV2') { return $null }
        $legacy = $d.PSObject.Properties['oauth:tokenCache']
        if ($legacy -and ($legacy.Value -isnot [string] -or -not $legacy.Value)) { return $null }
        return $u
    } catch { return $null }
}
function Check-NewLogin {
    if ($AppState.Mode -ne 'progress' -or $AppState.Flow -ne 'add' -or $AppState.NewUuid) { return }
    $u = Read-LoginUuid
    if (-not $u) { return }
    if ($AppState.PrevUuid -and $u -ieq $AppState.PrevUuid) { $ProgMsg.Text = 'Đây vẫn là account cũ. Hãy đăng nhập account còn lại (khác account này).'; return }
    $AppState.NewUuid = $u
    $AppState.AddTimer.Stop()
    $ProgMsg.Text = 'Đã thấy account mới, đang lưu lại…'
    $AppState.SaveDelay = 0
    $AppState.SaveTimer.Start()
}
function Save-NewAccount {
    [void](Start-EngineJob @('-Action', 'Save') $null { param($job)
        Set-Step 'login' 'done'
        if ($job.Exit -eq 0) {
            Refresh-Status
            $AppState.Busy = $false
            Set-ProgressEnd 'ok' 'Đã thêm account thứ hai' 'Từ giờ bạn chuyển qua lại giữa 2 account chỉ với một cú nhấp.' 'Xong' { Show-Accounts } $null $null
        } else {
            $AppState.Busy = $false
            Set-ProgressEnd 'error' 'Chưa lưu được account mới' 'Claude Switch chưa lưu được account vừa đăng nhập. Hãy thử lại bằng cách mở lại công cụ.' 'Đóng' { Show-Accounts } $null $null
        }
    })
}

# ---------------------------------------------------------------- làm mới trạng thái / khay hệ thống
function Refresh-Status {
    if ($AppState.StatusBusy) { return }
    $AppState.StatusBusy = $true
    [void](Start-EngineJob @('-Action', 'Status') $null { param($job)
        $AppState.StatusBusy = $false
        $st = $null
        try { if ($job.Exit -eq 0 -and (Test-Path -LiteralPath $job.Out)) { $st = [IO.File]::ReadAllText($job.Out, [Text.Encoding]::UTF8) | ConvertFrom-Json } } catch {}
        if (-not $st) { return }
        $AppState.Status = $st
        $AppState.Usage = $st.usage
        Update-DetectedTools
        if ($st.tools.desktop -and $st.unsavedCurrent -and -not $AppState.SavedOnce) {
            $AppState.SavedOnce = $true
            [void](Start-EngineJob @('-Action', 'Save') $null { param($j2) Refresh-Status })
        }
        if ($st.cli.installed -and $st.cli.unsavedCurrent -and -not $AppState.CliSavedOnce) {
            $AppState.CliSavedOnce=$true
            [void](Start-EngineJob @('-Action','CliSave') $null { param($job) Refresh-Status })
        }
        if ($st.cli.pendingLogin.state -eq 'ready' -and -not $AppState.Busy -and $AppState.CliFinishedId -ne $st.cli.pendingLogin.id) {
            $AppState.CliFinishedId=$st.cli.pendingLogin.id
            Start-CliAction 'CliFinishLogin'
        }
        $AppState.Loading = $true
        $SyncChk.IsChecked = [bool]$st.settings.syncSessions
        $AppState.Loading = $false
        $MenuConfirm.Visibility = if ((Get-GuiSettings).skipConfirm) { 'Visible' } else { 'Collapsed' }
        if ($AppState.Mode -eq 'accounts') { Render-Accounts }
        Update-UsageControls
        if (-not $NoAppControl -and -not $AppState.Busy -and [DateTimeOffset]::UtcNow -ge $AppState.NextUsageCheck) { Start-UsageRefresh }
        Update-Tray
        if ($AutoSwitch -and -not $AppState.AutoDone -and $st.profiles.Count -ge 2) { $AppState.AutoDone = $true; Start-Switch $AutoSwitch }
        if ($AutoClick -and -not $AppState.AutoDone -and -not $st.unsavedCurrent -and $AppState.TestBtn) {
            $AppState.AutoDone = $true
            $clickEvt = New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            $AppState.TestBtn.RaiseEvent($clickEvt)
            $ConfirmOk.RaiseEvent($clickEvt)
        }
    })
}

$MenuConfirm = $win.FindName('MenuConfirm')
$notify = $null
function Update-Tray {
    if (-not $notify) { return }
    $name = 'chưa đăng nhập'
    if ($AppState.Status -and $AppState.Status.activeUuid) { $name = Get-Label ([string]$AppState.Status.activeUuid) }
    if ($AppState.ActiveTool -eq 'cli') {
        $name='CLI chưa đăng nhập'
        foreach($p in @($AppState.Status.cli.profiles)){if($p.isActive){$name='CLI: '+[string]$p.label;break}}
    }
    $t = "Claude Switch - $name"
    if ($t.Length -gt 62) { $t = $t.Substring(0, 62) }
    $notify.Text = $t
}
function Build-TrayMenu {
    $menu.Items.Clear()
    $cur = 'chưa đăng nhập'; if ($AppState.Status -and $AppState.Status.activeUuid) { $cur = Get-Label ([string]$AppState.Status.activeUuid) }
    if ($AppState.Status.tools.desktop) {
        $h = New-Object Windows.Forms.ToolStripMenuItem ("Desktop: $cur"); $h.Enabled = $false
        [void]$menu.Items.Add($h)
    }
    if ($AppState.Status.tools.desktop) {
        foreach ($p in @($AppState.Status.profiles)) {
            if (-not $p.isActive -and $p.hasAuth) {
                $it = New-Object Windows.Forms.ToolStripMenuItem ("Chuyển sang " + $(if ($p.label) { $p.label } else { $p.email }))
                $it.Tag = [string]$p.uuid
                $it.Add_Click({ param($s, $e) Show-MainWindow; Begin-Switch ([string]$s.Tag) })
                [void]$menu.Items.Add($it)
            }
        }
    }
    if ($AppState.Status.cli.installed) {
        $cliName='chưa đăng nhập'
        foreach($p in @($AppState.Status.cli.profiles)){if($p.isActive){$cliName=[string]$p.label;break}}
        $heading=New-Object Windows.Forms.ToolStripMenuItem ('CLI: '+$cliName);$heading.Enabled=$false
        [void]$menu.Items.Add($heading)
        foreach($p in @($AppState.Status.cli.profiles)){
            if(-not $p.isActive -and $p.hasAuth){
                $item=New-Object Windows.Forms.ToolStripMenuItem ('Chuyển CLI sang '+[string]$p.label)
                $item.Tag=[string]$p.uuid
                $item.Add_Click({param($sender,$event) Show-MainWindow; Select-ClaudeTool 'cli'; Start-CliAction 'CliSwitch' ([string]$sender.Tag)})
                [void]$menu.Items.Add($item)
            }
        }
    }
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $open = New-Object Windows.Forms.ToolStripMenuItem 'Mở Claude Switch'
    $open.Add_Click({ Show-MainWindow })
    [void]$menu.Items.Add($open)
    $quit = New-Object Windows.Forms.ToolStripMenuItem 'Thoát'
    $quit.Add_Click({ Exit-App })
    [void]$menu.Items.Add($quit)
}

function Update-Chrome {
    try {
        $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
        if ($h -ne [IntPtr]::Zero) { $v = [int]$AppState.Dark; [void][CsDwm.Native]::DwmSetWindowAttribute($h, 20, [ref]$v, 4) }
    } catch {}
}
function Show-MainWindow {
    try {
        Set-Theme (Test-DarkTheme)
        if (-not $win.IsVisible) { $win.Show() }
        if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }
        Update-Chrome
        [void]$win.Activate(); $win.Topmost = $true; $win.Topmost = $false
        if ($AppState.Mode -eq 'accounts') { Refresh-Status }
    } catch { Gui-Log ('Show lỗi: ' + $_.Exception.Message) }
}
function Exit-App {
    $AppState.Exiting = $true
    try { if ($notify) { $notify.Visible = $false; $notify.Dispose() } } catch {}
    try { if ($AppState.Mutex) { $AppState.Mutex.ReleaseMutex(); $AppState.Mutex.Dispose() } } catch {}
    try { [Windows.Application]::Current.Shutdown() } catch {}
}

# ---------------------------------------------------------------- render PNG
function Save-WindowPng($path) {
    if (-not ($Root.IsLoaded -and $Root.ActualHeight -gt 0)) {
        $Root.Measure((New-Object Windows.Size 460, ([double]::PositiveInfinity)))
        $Root.Arrange((New-Object Windows.Rect 0, 0, $Root.DesiredSize.Width, $Root.DesiredSize.Height))
        $Root.UpdateLayout()
    }
    $dw = if ($Root.ActualWidth -gt 0) { $Root.ActualWidth } else { $Root.DesiredSize.Width }
    $dh = if ($Root.ActualHeight -gt 0) { $Root.ActualHeight } else { $Root.DesiredSize.Height }
    $scale = 2.0
    $w = [int]($dw * $scale); $h = [int]($dh * $scale)
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap $w, $h, (96 * $scale), (96 * $scale), ([Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($Root)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $dir = Split-Path -Parent $path; if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $fs = [IO.File]::Create($path); try { $enc.Save($fs) } finally { $fs.Dispose() }
}

function Set-PreviewData([string]$state) {
    $a = [pscustomobject]@{ uuid = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; label = 'Hà An'; email = 'ha.an@example.com'; displayName = 'Hà An'; sessionCount = 65; isActive = $false; hasAuth = $true }
    $b = [pscustomobject]@{ uuid = 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'; label = 'Bình Nguyễn'; email = 'binh.nguyen@example.com'; displayName = 'Bình Nguyễn'; sessionCount = 12; isActive = $true; hasAuth = $true }
    $AppState.Status = [pscustomobject]@{ profiles = @($a, $b); activeUuid = $b.uuid; recentActive = 0; loggedIn = $true; pendingAdd = $null; configError = $null; settings = [pscustomobject]@{ syncSessions = $true } }
    $AppState.Usage = @{ accounts = @{} }
    foreach ($profile in @($a, $b)) {
        $AppState.Usage.accounts[$profile.uuid] = [pscustomobject]@{
            state = 'ok'; updatedAt = [DateTimeOffset]::UtcNow.ToString('o'); message = ''
            windows = @(
                [pscustomobject]@{label='5 giờ';usedPercent=$(if($profile.uuid -eq $a.uuid){25}else{62});resetsAt=[DateTimeOffset]::UtcNow.AddHours(2).ToString('o')},
                [pscustomobject]@{label='7 ngày';usedPercent=$(if($profile.uuid -eq $a.uuid){100}else{48});resetsAt=[DateTimeOffset]::UtcNow.AddDays(3).ToString('o')}
            )
        }
    }
    $AppState.Status | Add-Member tools ([pscustomobject]@{desktop=$true;cli=$true})
    $AppState.Status | Add-Member cli ([pscustomobject]@{installed=$true;loggedIn=$true;activeUuid=$b.uuid;profiles=@($a,$b);authOverrides=@();runningCount=0;pendingLogin=$null})
    if ($state -eq 'cli-only') { $AppState.Status.tools.desktop=$false }
    if ($state -eq 'desktop-only') { $AppState.Status.tools.cli=$false }
    if ($state -eq 'none') { $AppState.Status.tools.desktop=$false; $AppState.Status.tools.cli=$false }
    if ($state -in @('cli','cli-only')) { $AppState.ActiveTool='cli' }
    Update-DetectedTools
    $AppState.Loading = $true; $SyncChk.IsChecked = $true; $AppState.Loading = $false
    switch ($state) {
        'one' { $AppState.Status.profiles = @($b); Render-Accounts }
        'switching' {
            $AppState.PrevUuid = $b.uuid; $AppState.TargetUuid = $a.uuid
            Show-ProgressPanel 'Đang chuyển sang Hà An' $SwitchSteps
            Set-Step 'close' 'done'; Set-Step 'backup' 'done'; Set-Step 'sync' 'running'
            $ProgMsg.Text = 'Đang đồng bộ session…'
        }
        'error' {
            Show-ProgressPanel 'Đang chuyển sang Hà An' $SwitchSteps
            Set-Step 'close' 'done'; Set-Step 'backup' 'done'; Set-Step 'sync' 'done'; Set-Step 'switch' 'error'
            Set-ProgressEnd 'error' 'Chưa chuyển được account' 'Không đổi được tài khoản (Không ghi được config.json). Đã khôi phục lại cấu hình và đăng nhập như trước, Claude đã được mở lại.' 'Đóng' {} $null $null
        }
        'success' {
            Show-ProgressPanel 'Đang chuyển sang Hà An' $SwitchSteps
            foreach ($k in $AppState.StepOrder) { Set-Step $k 'done' }
            Set-ProgressEnd 'ok' 'Đã chuyển sang Hà An' 'Đã chuyển tài khoản xong. Session Claude Code hiện ở cả 2 account.' 'Xong' {} 'Quay lại account trước' {}
        }
        'adding' {
            Show-ProgressPanel 'Đang thêm account thứ hai' $AddSteps
            foreach ($k in @('close', 'backup', 'switch', 'open')) { Set-Step $k 'done' }
            Set-Step 'login' 'running'
            Set-ProgressEnd 'wait' 'Hãy đăng nhập account thứ hai' 'Trong cửa sổ Claude vừa mở, đăng nhập bằng account còn lại. Claude Switch sẽ tự nhận ra và lưu lại.' $null $null 'Hủy, quay lại account cũ' {}
        }
        'confirm' { $AppState.Status.recentActive = 2; Render-Accounts; Show-Confirm 'switch' $a.uuid 'Chuyển sang Hà An?' }
        default { Render-Accounts }
    }
}

. (Join-Path $PSScriptRoot 'ClaudeSwitch.CliUI.ps1')
. (Join-Path $PSScriptRoot 'ClaudeSwitch.UsageUI.ps1')

# ---------------------------------------------------------------- sự kiện cửa sổ
$DesktopTab.Add_Click({ Select-ClaudeTool 'desktop' })
$CliTab.Add_Click({ Select-ClaudeTool 'cli' })
$ScanBtn.Add_Click({ Refresh-Status })
$UsageRefreshBtn.Add_Click({ Start-UsageRefresh -Force })
$CliLoginBtn.Add_Click({
    $pending=$AppState.Status.cli.pendingLogin
    if ($pending.state -eq 'ready') { Start-CliAction 'CliFinishLogin' } else { Start-CliAction 'CliLogin' }
})
$CliOpenBtn.Add_Click({ Start-CliAction 'CliOpen' })
$ConfirmOk.Add_Click({ Do-ConfirmOk })
$ConfirmCancel.Add_Click({ Hide-Confirm })
$BtnPrimary.Add_Click({ if ($AppState.ProgPrimary) { & $AppState.ProgPrimary } })
$BtnSecondary.Add_Click({ if ($AppState.ProgSecondary) { & $AppState.ProgSecondary } })
$MoreBtn.Add_Click({ $MorePopup.IsOpen = -not $MorePopup.IsOpen })
$win.FindName('MenuBackups').Add_Click({
    $MorePopup.IsOpen = $false
    $d = Join-Path $StoreDir 'backups'; if (-not (Test-Path -LiteralPath $d)) { [void][IO.Directory]::CreateDirectory($d) }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $d + '"')
})
$win.FindName('MenuRemove').Add_Click({
    $MorePopup.IsOpen = $false
    Show-Toast 'Đang gỡ session đã sao chép…'
    [void](Start-EngineJob @('-Action', 'RemoveCopies') $null { param($job)
        $m = 'Không gỡ được session đã sao chép.'
        try { $o = [IO.File]::ReadAllText($job.Out, [Text.Encoding]::UTF8) | ConvertFrom-Json; $m = "Đã gỡ $($o.removed) session đã sao chép" + $(if ($o.kept -gt 0) { ", giữ lại $($o.kept) bản bạn đã sửa." } else { '.' }) } catch {}
        Show-Toast $m
        Refresh-Status
    })
})
$win.FindName('MenuLog').Add_Click({
    $MorePopup.IsOpen = $false
    $d = Join-Path $StoreDir 'logs'
    $f = $null; if (Test-Path -LiteralPath $d) { $f = Get-ChildItem -LiteralPath $d -Filter 'claude-switch-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    if ($f) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $f.FullName + '"') } else { Show-Toast 'Chưa có log nào.' }
})
$MenuConfirm.Add_Click({ $MorePopup.IsOpen = $false; Set-GuiSetting 'skipConfirm' $false; $MenuConfirm.Visibility = 'Collapsed'; Show-Toast 'Đã bật lại hộp xác nhận.' })
$SyncNowBtn.Add_Click({ Start-SessionSync })
$SyncChk.Add_Click({
    if ($AppState.Loading) { return }
    $on = [bool]$SyncChk.IsChecked
    Set-GuiSetting 'syncSessions' $on
    if ($on) {
        Start-SessionSync
    } else { Show-Toast 'Đã tắt. Các session đã sao chép trước đó vẫn còn; dùng "Gỡ session đã sao chép" nếu muốn bỏ.' }
})

$win.Add_PreviewKeyDown({ param($s, $e)
    if ($e.OriginalSource -is [Windows.Controls.TextBox]) { return }
    if ($e.Key -eq 'Escape') {
        $e.Handled = $true
        if ($Overlay.Visibility -eq 'Visible') { Hide-Confirm }
        elseif ($MorePopup.IsOpen) { $MorePopup.IsOpen = $false }
        else { $win.Hide() }
    } elseif ($e.Key -eq 'Return') {
        if ($e.OriginalSource -is [Windows.Controls.TextBox]) { return }
        if ($AppState.Primary) { $e.Handled = $true; & $AppState.Primary }
    }
})

# ================================================================ chế độ vẽ PNG
if ($IsPreview) {
    $dark = if ($PreviewTheme) { $PreviewTheme -eq 'dark' } else { Test-DarkTheme }
    Set-Theme $dark
    Set-PreviewData $PreviewState
    Save-WindowPng $RenderPreview
    exit 0
}

# ================================================================ chạy thật
Add-Type -Namespace CsDwm -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);'

# một bản duy nhất
$sha = [Security.Cryptography.SHA1]::Create()
$hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($StoreDir.ToLowerInvariant()))).Replace('-', '')).Substring(0, 10)
$createdNew = $false
$AppState.Mutex = New-Object Threading.Mutex($true, "Local\ClaudeSwitch.$hash", [ref]$createdNew)
$showEvt = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, "Local\ClaudeSwitch.Show.$hash")
if (-not $createdNew) {
    [void]$showEvt.Set()
    exit 0
}

# dọn file chạy cũ
try { Get-ChildItem -LiteralPath (Join-Path $StoreDir 'run') -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}

$app = New-Object Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$app.Add_DispatcherUnhandledException({ param($s, $e) Gui-Log ('Lỗi giao diện: ' + $e.Exception.Message); $e.Handled = $true })

$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.Font = New-Object Drawing.Font('Segoe UI', 9.5)
$notify = New-Object Windows.Forms.NotifyIcon
$notify.Icon = $AppIcon.Icon
$notify.Text = 'Claude Switch'
$notify.ContextMenuStrip = $menu
$menu.Add_Opening({ Build-TrayMenu })
$notify.Add_MouseClick({ param($s, $e) if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-MainWindow } })
$notify.Visible = $true

$win.Add_Closing({ param($s, $e)
    if ($AppState.Exiting) { return }
    $e.Cancel = $true
    $win.Hide()
    if (-not (Get-GuiSettings).hintShown) {
        Set-GuiSetting 'hintShown' $true
        $notify.ShowBalloonTip(5000, 'Claude Switch vẫn đang chạy', 'Bấm vào biểu tượng ở khay hệ thống để mở lại, bấm chuột phải để chuyển account hoặc thoát.', [Windows.Forms.ToolTipIcon]::Info)
    }
})
$win.Add_SourceInitialized({ Update-Chrome })

# vòng lặp nền: đọc tiến trình engine + nhận tín hiệu "hiện cửa sổ" từ bản chạy thứ hai
$pump = New-Object Windows.Threading.DispatcherTimer
$pump.Interval = [TimeSpan]::FromMilliseconds(250)
$pump.Add_Tick({
    try {
        Pump-Jobs
        if ($showEvt.WaitOne(0)) { Show-MainWindow }
    } catch { Gui-Log ('Tick lỗi: ' + $_.Exception.Message) }
})
$pump.Start()

$cliPoll = New-Object Windows.Threading.DispatcherTimer
$cliPoll.Interval = [TimeSpan]::FromSeconds(5)
$cliPoll.Add_Tick({ if (-not $AppState.Busy -and ($AppState.ActiveTool -eq 'cli' -or $AppState.Status.cli.pendingLogin)) { Refresh-Status } })
$cliPoll.Start()

$usagePoll = New-Object Windows.Threading.DispatcherTimer
$usagePoll.Interval = [TimeSpan]::FromMinutes(2)
$usagePoll.Add_Tick({ if (-not $AppState.Busy -and -not $NoAppControl) { Start-UsageRefresh } })
$usagePoll.Start()

$AppState.AddTimer = New-Object Windows.Threading.DispatcherTimer
$AppState.AddTimer.Interval = [TimeSpan]::FromSeconds(2)
$AppState.AddTimer.Add_Tick({ try { Check-NewLogin } catch { Gui-Log ('Check lỗi: ' + $_.Exception.Message) } })

$AppState.SaveTimer = New-Object Windows.Threading.DispatcherTimer
$AppState.SaveTimer.Interval = [TimeSpan]::FromSeconds(4)   # đợi Claude ghi xong cookie/token
$AppState.SaveTimer.Add_Tick({ $AppState.SaveTimer.Stop(); Save-NewAccount })

$AppState.ToastTimer = New-Object Windows.Threading.DispatcherTimer
$AppState.ToastTimer.Interval = [TimeSpan]::FromSeconds(7)
$AppState.ToastTimer.Add_Tick({ $AppState.ToastTimer.Stop(); if ($AppState.Mode -eq 'accounts') { $Toast.Visibility = 'Collapsed' } })

if ($ExitAfter -gt 0) {
    $quit = New-Object Windows.Threading.DispatcherTimer
    $quit.Interval = [TimeSpan]::FromSeconds($ExitAfter)
    $quit.Add_Tick({ $quit.Stop()
        try { if ($SnapshotOnExit) { Save-WindowPng $SnapshotOnExit } } catch { Gui-Log ('Snapshot lỗi: ' + $_.Exception.Message) }
        Exit-App })
    $quit.Start()
}

Gui-Log 'GUI khởi động'
Show-MainWindow
try { $app.Run() | Out-Null } finally {
    try { $notify.Visible = $false; $notify.Dispose() } catch {}
    try { $AppState.Mutex.Dispose() } catch {}
}
exit 0
