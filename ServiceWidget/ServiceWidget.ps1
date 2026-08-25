#requires -Version 5.1
<#
    Small always-on-top widget showing red/green status lights for a list of
    Windows services. Click the green light to start/restart a service,
    click the red light to stop it.

    Service list  : services.json  (edit this to add/remove services)
    Window position: position.json (auto-saved on close/move)
#>

$ScriptDir    = $PSScriptRoot
$ConfigPath   = Join-Path $ScriptDir 'services.json'
$PositionPath = Join-Path $ScriptDir 'position.json'
$LogPath      = Join-Path $ScriptDir 'diag.log'
$RefreshMs    = 4000

# Plain file I/O only - no WPF dependency - so this works even if assembly
# loading itself is what's failing. Since the script always ends up running
# hidden, this log is the only way to see what happened.
function Write-Diag($msg) {
    try { Add-Content -Path $LogPath -Value "$(Get-Date -Format 'u') $msg" -ErrorAction SilentlyContinue } catch { }
}

trap {
    Write-Diag "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show("Service Widget hit an unexpected error and is closing:`n$($_.Exception.Message)`n`nDetails were logged to:`n$LogPath", 'Service Widget - Error', 'OK', 'Error') | Out-Null
    } catch { }
    break
}

Write-Diag "=== Script starting. PID=$PID  PSVersion=$($PSVersionTable.PSVersion)  Is64BitProcess=$([Environment]::Is64BitProcess) ==="

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Write-Diag "WPF assemblies loaded OK"

# Force software rendering. On some remote/VDI/GPU-less sessions, WPF's default
# hardware-accelerated pipeline reports the window as loaded/visible/rendered
# (that's just window-manager bookkeeping) but never actually presents a frame
# to the real display, so nothing appears on screen. This bypasses that pipeline.
[System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
Write-Diag "Forced ProcessRenderMode=SoftwareOnly"

# ---------- always run elevated ----------
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Diag "IsElevated=$IsElevated"

if (-not $IsElevated) {
    if (-not $PSCommandPath) {
        Write-Diag "No PSCommandPath - cannot self-relaunch. Aborting."
        [System.Windows.MessageBox]::Show("This script needs to be run from a .ps1 file (not pasted/selected) so it can relaunch itself elevated.", 'Service Widget', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        Write-Diag "Relaunching elevated: powershell.exe -File `"$PSCommandPath`""
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`""
        ) | Out-Null
        Write-Diag "Relaunch Start-Process call returned without throwing. Non-elevated instance exiting now."
    } catch {
        Write-Diag "Relaunch FAILED: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show("Elevation was cancelled or failed, so the widget can't start:`n$($_.Exception.Message)", 'Service Widget', 'OK', 'Warning') | Out-Null
    }
    return
}

Write-Diag "Running elevated. Continuing to build UI."

# ---------- config ----------
if (-not (Test-Path $ConfigPath)) {
    @{ services = @('Spooler', 'wuauserv') } | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
}
try {
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $ServiceNames = @($config.services)
} catch {
    [System.Windows.MessageBox]::Show("Could not read services.json:`n$($_.Exception.Message)", 'Service Widget', 'OK', 'Error') | Out-Null
    $ServiceNames = @()
}

# ---------- xaml shell ----------
# NOTE: no AllowsTransparency/transparent background here - layered/transparent
# windows frequently fail to render over RDP/Citrix/VDI display drivers, which
# shows up as "the process runs but no window ever appears". Solid background instead.
[xml]$xamlDoc = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Service Widget" Width="230" Background="#2B2B2B"
        WindowStyle="None"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="Height">
    <Border x:Name="Chrome" BorderBrush="#444444" BorderThickness="1" Padding="10">
        <StackPanel>
            <Grid x:Name="TitleBar" Margin="0,0,0,6">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Services" Foreground="#DDDDDD" FontWeight="Bold" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="CloseButton" Grid.Column="1" Text="&#x2715;" Foreground="#AAAAAA" FontSize="12" Cursor="Hand" VerticalAlignment="Center" Padding="8,0,0,0"/>
            </Grid>
            <StackPanel x:Name="ServicesPanel"/>
        </StackPanel>
    </Border>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xamlDoc)
$window = [Windows.Markup.XamlReader]::Load($reader)
Write-Diag "XAML window object created OK"

$Chrome        = $window.FindName('Chrome')
$CloseButton   = $window.FindName('CloseButton')
$ServicesPanel = $window.FindName('ServicesPanel')

# ---------- window position ----------
$wa = [System.Windows.SystemParameters]::WorkArea
Write-Diag "SystemParameters: WorkArea=$wa  VirtualScreen=($([System.Windows.SystemParameters]::VirtualScreenLeft),$([System.Windows.SystemParameters]::VirtualScreenTop)) size $($([System.Windows.SystemParameters]::VirtualScreenWidth))x$($([System.Windows.SystemParameters]::VirtualScreenHeight))  PrimaryScreen=$($([System.Windows.SystemParameters]::PrimaryScreenWidth))x$($([System.Windows.SystemParameters]::PrimaryScreenHeight))"
$window.Left = $wa.Right - 260
$window.Top  = $wa.Top + 20
if (Test-Path $PositionPath) {
    try {
        $pos = Get-Content -Path $PositionPath -Raw | ConvertFrom-Json
        if ($pos.Left -ne $null) { $window.Left = [double]$pos.Left }
        if ($pos.Top  -ne $null) { $window.Top  = [double]$pos.Top }
    } catch { }
}
Write-Diag "Planned window position: Left=$($window.Left) Top=$($window.Top)"

$window.Add_Loaded({ Write-Diag "Window Loaded event: ActualWidth=$($window.ActualWidth) ActualHeight=$($window.ActualHeight) Left=$($window.Left) Top=$($window.Top) Visibility=$($window.Visibility) WindowState=$($window.WindowState) IsVisible=$($window.IsVisible)" })
$window.Add_ContentRendered({ Write-Diag "Window ContentRendered event fired - it should be painting on screen now." })

$Chrome.Add_MouseLeftButtonDown({ $window.DragMove() })
$CloseButton.Add_MouseLeftButtonUp({ $window.Close() })

$window.Add_Closing({
    $pos = @{ Left = $window.Left; Top = $window.Top }
    $pos | ConvertTo-Json | Set-Content -Path $PositionPath -Encoding UTF8
})

# ---------- helpers ----------
$RunningBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(46, 204, 113))
$StoppedBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(231, 76, 60))
$DimGray      = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(90, 90, 90))
$StrokeBrush  = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(34, 34, 34))

function New-Ellipse {
    $e = New-Object System.Windows.Shapes.Ellipse
    $e.Width = 14
    $e.Height = 14
    $e.Margin = '4,0,0,0'
    $e.Stroke = $StrokeBrush
    $e.StrokeThickness = 0.6
    $e.Cursor = 'Hand'
    return $e
}

function Show-Err($msg) {
    [System.Windows.MessageBox]::Show($msg, 'Service Widget', 'OK', 'Error') | Out-Null
}

function Update-Row($row) {
    $svc = $null
    try { $svc = Get-Service -Name $row.Name -ErrorAction Stop } catch { $svc = $null }

    if (-not $svc) {
        $row.Label.Text = "$($row.Name) (not found)"
        $row.Green.Fill = $DimGray
        $row.Red.Fill   = $DimGray
        $row.Status = 'Unknown'
        return
    }

    $row.Status = $svc.Status.ToString()
    switch ($svc.Status) {
        'Running' {
            $row.Green.Fill = $RunningBrush
            $row.Red.Fill   = $DimGray
        }
        'Stopped' {
            $row.Green.Fill = $DimGray
            $row.Red.Fill   = $StoppedBrush
        }
        default {
            $row.Green.Fill = $DimGray
            $row.Red.Fill   = $DimGray
        }
    }
    $row.Label.Text = $svc.DisplayName
    $row.Green.ToolTip = "Start / Restart '$($svc.DisplayName)'  (currently: $($svc.Status))"
    $row.Red.ToolTip   = "Stop '$($svc.DisplayName)'  (currently: $($svc.Status))"
}

# ---------- build rows ----------
$Rows = @()

foreach ($name in $ServiceNames) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,3,0,3'
    foreach ($w in @('*', 'Auto', 'Auto')) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($w -eq '*') { $cd.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
        else { $cd.Width = [System.Windows.GridLength]::Auto }
        [void]$grid.ColumnDefinitions.Add($cd)
    }

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $name
    $label.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(238, 238, 238))
    $label.FontSize = 12
    $label.VerticalAlignment = 'Center'
    $label.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($label, 0)

    $redEllipse = New-Ellipse
    [System.Windows.Controls.Grid]::SetColumn($redEllipse, 1)

    $greenEllipse = New-Ellipse
    [System.Windows.Controls.Grid]::SetColumn($greenEllipse, 2)

    [void]$grid.Children.Add($label)
    [void]$grid.Children.Add($redEllipse)
    [void]$grid.Children.Add($greenEllipse)
    [void]$ServicesPanel.Children.Add($grid)

    $row = [PSCustomObject]@{
        Name   = $name
        Label  = $label
        Red    = $redEllipse
        Green  = $greenEllipse
        Status = 'Unknown'
    }
    $Rows += $row

    $redEllipse.Tag = $row
    $greenEllipse.Tag = $row
}

foreach ($row in $Rows) {
    $row.Red.Add_MouseLeftButtonUp({
        param($s, $e)
        $r = $s.Tag
        try { Stop-Service -Name $r.Name -Force -ErrorAction Stop }
        catch { Show-Err "Could not stop '$($r.Name)':`n$($_.Exception.Message)" }
        Update-Row $r
    })
    $row.Green.Add_MouseLeftButtonUp({
        param($s, $e)
        $r = $s.Tag
        try {
            $current = Get-Service -Name $r.Name -ErrorAction Stop
            if ($current.Status -eq 'Running') { Restart-Service -Name $r.Name -Force -ErrorAction Stop }
            else { Start-Service -Name $r.Name -ErrorAction Stop }
        } catch {
            Show-Err "Could not start/restart '$($r.Name)':`n$($_.Exception.Message)"
        }
        Update-Row $r
    })
    Update-Row $row
}

# ---------- polling timer ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($RefreshMs)
$timer.Add_Tick({ foreach ($row in $Rows) { Update-Row $row } })
$timer.Start()

Write-Diag "Calling ShowDialog() now..."
[void]$window.ShowDialog()
Write-Diag "ShowDialog() returned - window was closed."
