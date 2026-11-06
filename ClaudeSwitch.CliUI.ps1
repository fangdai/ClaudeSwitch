#requires -Version 5.1
function Update-DetectedTools {
    $tools=$AppState.Status.tools
    if (-not $tools) { return }
    if ($AppState.ActiveTool -eq 'desktop' -and -not $tools.desktop -and $tools.cli) { $AppState.ActiveTool='cli' }
    if ($AppState.ActiveTool -eq 'cli' -and -not $tools.cli -and $tools.desktop) { $AppState.ActiveTool='desktop' }
    $DesktopTab.Visibility=if($tools.desktop){'Visible'}else{'Collapsed'}
    $CliTab.Visibility=if($tools.cli){'Visible'}else{'Collapsed'}
    $ToolTabs.ColumnDefinitions[0].Width=if($tools.desktop){[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}else{[Windows.GridLength]::new(0)}
    $ToolTabs.ColumnDefinitions[1].Width=if($tools.cli){[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}else{[Windows.GridLength]::new(0)}
    $NoToolsText.Visibility=if(-not $tools.desktop -and -not $tools.cli){'Visible'}else{'Collapsed'}
    $isDesktop=$tools.desktop -and $AppState.ActiveTool -eq 'desktop'
    $Cards.Visibility=if($isDesktop){'Visible'}else{'Collapsed'}
    $DesktopFooter.Visibility=if($isDesktop){'Visible'}else{'Collapsed'}
    $CliPanel.Visibility=if($tools.cli -and $AppState.ActiveTool -eq 'cli'){'Visible'}else{'Collapsed'}
    $DesktopTab.IsEnabled=-not $AppState.Busy
    $CliTab.IsEnabled=-not $AppState.Busy
    $ScanBtn.IsEnabled=-not $AppState.Busy
    $DesktopTab.Background=if($isDesktop){Res 'AccentSoft'}else{[Windows.Media.Brushes]::Transparent}
    $CliTab.Background=if($AppState.ActiveTool -eq 'cli'){Res 'AccentSoft'}else{[Windows.Media.Brushes]::Transparent}
    if (-not $isDesktop) { $PanelProgress.Visibility='Collapsed' }
    Update-SyncButton
    Update-UsageControls
}

function Select-ClaudeTool([string]$tool) {
    if ($AppState.Busy) { return }
    $AppState.ActiveTool=$tool
    $AppState.Mode='accounts'
    $AppState.Primary=$null
    $Toast.Visibility='Collapsed'
    Update-DetectedTools
    Render-Accounts
    Update-Tray
    Refresh-Status
}

function Render-CliAccounts {
    $CliCards.Children.Clear()
    $AppState.Primary=$null
    $cli=$AppState.Status.cli
    $overridden=@($cli.authOverrides).Count -gt 0
    $message='Account CLI được quản lý riêng. Hãy thoát các phiên CLI đang chạy trước khi chuyển.'
    if (-not $cli.loggedIn) { $message='Đã tìm thấy Claude CLI. Đăng nhập để lưu account đầu tiên.' }
    if ($cli.runningCount -gt 0) { $message='Có phiên Claude CLI đang chạy. Thoát CLI trước khi chuyển account; công cụ sẽ giữ nguyên phiên đang mở.' }
    if ($overridden) { $message='CLI đang dùng cấu hình đăng nhập bên ngoài: '+($cli.authOverrides -join ', ')+'. Bỏ cấu hình ghi đè để chuyển account đăng nhập tại đây.' }
    if ($cli.pendingLogin.state -eq 'waiting') { $message='Đang chờ bạn đăng nhập trong trình duyệt/cửa sổ CLI. Account hiện tại vẫn được giữ nguyên.' }
    if ($cli.pendingLogin.state -eq 'failed') { $message='Chưa hoàn tất đăng nhập CLI. Bấm bên dưới để mở lại.' }
    $CliInfo.Text=$message
    foreach ($profile in @($cli.profiles)) {
        if (-not $profile.uuid) { continue }
        $card=[Windows.Markup.XamlReader]::Parse($CardXaml)
        $label=[string]$profile.label; if(-not $label){$label='Account CLI'}
        $card.FindName('Initial').Text=$label.Substring(0,1).ToUpper()
        $card.FindName('LabelText').Text=$label
        $card.FindName('EmailText').Text=[string]$profile.email
        $card.FindName('SessText').Text='Claude Code CLI'
        Add-UsageToCard $card ([string]$profile.uuid)
        $card.FindName('EditBtn').Visibility='Collapsed'
        if($profile.isActive){
            $card.FindName('Badge').Visibility='Visible'
            $card.BorderBrush=Res 'Accent'
            $card.BorderThickness=New-Object Windows.Thickness 1.5
        }elseif($profile.hasAuth){
            $button=$card.FindName('SwitchBtn')
            $text=New-Object Windows.Controls.TextBlock
            $text.Text='Chuyển CLI sang '+$label; $text.TextTrimming='CharacterEllipsis'
            $button.Content=$text; $button.Visibility='Visible'; $button.Tag=[string]$profile.uuid
            $button.IsEnabled=(-not $AppState.Busy -and -not $overridden)
            $button.Add_Click({param($sender,$event) Start-CliAction 'CliSwitch' ([string]$sender.Tag)})
        }
        [void]$CliCards.Children.Add($card)
    }
    $CliLoginBtn.Content=if(@($cli.profiles).Count -gt 0){'Thêm account CLI'}else{'Đăng nhập CLI'}
    if($cli.pendingLogin.state -eq 'ready'){$CliLoginBtn.Content='Hoàn tất đăng nhập CLI'}
    if($cli.pendingLogin.state -eq 'waiting'){$CliLoginBtn.Content='Đang chờ đăng nhập CLI…'}
    $CliLoginBtn.IsEnabled=(-not $AppState.Busy -and -not $overridden -and $cli.pendingLogin.state -ne 'waiting')
    $CliOpenBtn.IsEnabled=(-not $AppState.Busy)
}

function Start-CliAction([string]$action,[string]$uuid='') {
    if($AppState.Busy){return}
    $AppState.Busy=$true
    Update-DetectedTools
    if($AppState.ActiveTool -eq 'cli'){Render-CliAccounts}
    Show-Toast 'Đang cập nhật Claude CLI…'
    $arguments=@('-Action',$action)
    if($uuid){$arguments+=@('-TargetAccount',$uuid)}
    try {
        [void](Start-EngineJob $arguments $null {param($job)
            $AppState.Busy=$false
            if($job.Exit -eq 0){
                $message='Đã cập nhật CLI. Mở phiên CLI mới để dùng account đã chọn.'
                foreach($line in $job.Lines){if($line.state -eq 'ok'){$message=[string]$line.message}}
                Show-Toast $message
            }else{Show-Toast (Get-FailMessage $job)}
            Update-DetectedTools
            if($AppState.ActiveTool -eq 'cli'){Render-CliAccounts}
            Refresh-Status
        })
    }catch{
        $AppState.Busy=$false
        Show-Toast 'Chưa khởi chạy được thao tác CLI. Hãy thử lại.'
        Update-DetectedTools
        if($AppState.ActiveTool -eq 'cli'){Render-CliAccounts}
    }
}
