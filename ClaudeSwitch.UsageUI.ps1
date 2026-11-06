#requires -Version 5.1
function Update-UsageControls {
    $count = @($AppState.Status.profiles).Count + @($AppState.Status.cli.profiles).Count
    $UsageControls.Visibility = if ($count -gt 0 -and $AppState.Mode -eq 'accounts') { 'Visible' } else { 'Collapsed' }
    $UsageRefreshBtn.IsEnabled = (-not $AppState.UsageBusy -and -not $AppState.Busy)
    $UsageRefreshBtn.Content = if ($AppState.UsageBusy) { 'Đang cập nhật…' } else { 'Cập nhật usage' }
    $UsageUpdated.Text = 'Giới hạn đã dùng của từng account'
}

function Find-UsageRecord([string]$uuid) {
    $accounts = $AppState.Usage.accounts
    if ($accounts -is [System.Collections.IDictionary]) { return $accounts[$uuid] }
    if ($accounts) { return $accounts.PSObject.Properties[$uuid].Value }
    return $null
}

function New-UsageText([string]$text) {
    $block = New-Object Windows.Controls.TextBlock
    $block.Text = $text
    $block.FontSize = 11
    $block.Foreground = Res 'SubText'
    $block.TextWrapping = 'Wrap'
    return $block
}

function Add-UsageToCard($card, [string]$uuid) {
    $slot = $card.FindName('UsageSlot')
    $record = Find-UsageRecord $uuid
    if (-not $record) { [void]$slot.Children.Add((New-UsageText 'Usage chưa được cập nhật.')); return }
    foreach ($window in @($record.windows)) {
        if ($null -eq $window.usedPercent) { continue }
        $row = New-Object Windows.Controls.Grid
        [void]$row.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
        $right = New-Object Windows.Controls.ColumnDefinition
        $right.Width = [Windows.GridLength]::Auto
        [void]$row.ColumnDefinitions.Add($right)
        $label = New-UsageText ([string]$window.label)
        $percent = New-UsageText ('Đã dùng {0:0.#}%' -f [double]$window.usedPercent)
        [Windows.Controls.Grid]::SetColumn($percent, 1)
        [void]$row.Children.Add($label); [void]$row.Children.Add($percent)
        [void]$slot.Children.Add($row)
        $bar = New-Object Windows.Controls.ProgressBar
        $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = [double]$window.usedPercent
        $bar.Height = 5; $bar.BorderThickness = New-Object Windows.Thickness 0
        $bar.Background = Res 'Track'
        $bar.Foreground = if ($bar.Value -ge 90) { Res 'Danger' } else { Res 'Accent' }
        $bar.Margin = New-Object Windows.Thickness 0,4,0,3
        [void]$slot.Children.Add($bar)
        if ($window.resetsAt) {
            $time = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse([string]$window.resetsAt, [ref]$time)) {
                $reset = New-UsageText ('Reset {0:HH:mm · dd/MM}' -f $time.ToLocalTime())
                $reset.Margin = New-Object Windows.Thickness 0,0,0,8
                [void]$slot.Children.Add($reset)
            }
        }
    }
    if ($record.updatedAt) {
        $time = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$record.updatedAt, [ref]$time)) {
            $prefix = if ($record.state -eq 'ok') { 'Cập nhật' } else { 'Dữ liệu lưu lúc' }
            [void]$slot.Children.Add((New-UsageText ('{0} {1:HH:mm · dd/MM}' -f $prefix, $time.ToLocalTime())))
        }
    }
    if ($record.message) { [void]$slot.Children.Add((New-UsageText ([string]$record.message))) }
}

function Start-UsageRefresh([switch]$Force) {
    if ($AppState.UsageBusy -or $AppState.Busy -or -not $AppState.Status) { return }
    $AppState.UsageBusy = $true
    $AppState.NextUsageCheck = [DateTimeOffset]::UtcNow.AddMinutes(2)
    Update-UsageControls
    $arguments = @('-Action', 'RefreshUsage')
    if ($Force) { $arguments += '-ForceUsage' }
    try {
        [void](Start-EngineJob $arguments $null { param($job)
            $AppState.UsageBusy = $false
            if ($job.Exit -eq 0) {
                try { $AppState.Usage = [IO.File]::ReadAllText($job.Out, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch {}
            } else { Show-Toast (Get-FailMessage $job) }
            if ($AppState.Mode -eq 'accounts') { Render-Accounts }
            Update-UsageControls
        })
    } catch {
        $AppState.UsageBusy = $false
        Update-UsageControls
        Show-Toast 'Chưa cập nhật được usage. Hãy thử lại.'
    }
}
