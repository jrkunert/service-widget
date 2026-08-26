#requires -Version 5.1
<#
    Small always-on-top widget showing red/green status lights for a list of
    Windows services. Click the green light to start/restart a service,
    click the red light to stop it.

    Built on Windows Forms (GDI), not WPF: on this org's VDI image, WPF's
    DirectX/DXGI present pipeline never actually hands frames to the desktop
    compositor - the window is created, reports ContentRendered, and shows up
    in Alt-Tab, but nothing ever paints on screen (confirmed even with WPF's
    software-rendering fallback forced on). Plain WinForms/GDI rendering does
    not depend on that pipeline and paints correctly in the same session.

    Service list  : services.json  (edit this to add/remove services)
    Window position: position.json (auto-saved on close/move)
#>

$ScriptDir    = $PSScriptRoot
$ConfigPath   = Join-Path $ScriptDir 'services.json'
$PositionPath = Join-Path $ScriptDir 'position.json'
$LogPath      = Join-Path $ScriptDir 'diag.log'
$RefreshMs    = 4000

# Plain file I/O only - no GUI dependency - so this works even if assembly
# loading itself is what's failing. Since the script always ends up running
# hidden, this log is the only way to see what happened.
function Write-Diag($msg) {
    try { Add-Content -Path $LogPath -Value "$(Get-Date -Format 'u') $msg" -ErrorAction SilentlyContinue } catch { }
}

trap {
    Write-Diag "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show("Service Widget hit an unexpected error and is closing:`n$($_.Exception.Message)`n`nDetails were logged to:`n$LogPath", 'Service Widget - Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
    break
}

Write-Diag "=== Script starting. PID=$PID  PSVersion=$($PSVersionTable.PSVersion)  Is64BitProcess=$([Environment]::Is64BitProcess) ==="

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Write-Diag "WinForms assemblies loaded OK"

# ---------- always run elevated ----------
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Diag "IsElevated=$IsElevated"

if (-not $IsElevated) {
    if (-not $PSCommandPath) {
        Write-Diag "No PSCommandPath - cannot self-relaunch. Aborting."
        [System.Windows.Forms.MessageBox]::Show("This script needs to be run from a .ps1 file (not pasted/selected) so it can relaunch itself elevated.", 'Service Widget', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
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
        [System.Windows.Forms.MessageBox]::Show("Elevation was cancelled or failed, so the widget can't start:`n$($_.Exception.Message)", 'Service Widget', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
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
    [System.Windows.Forms.MessageBox]::Show("Could not read services.json:`n$($_.Exception.Message)", 'Service Widget', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    $ServiceNames = @()
}

function Show-Err($msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, 'Service Widget', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

# ---------- layout constants ----------
$WidgetWidth  = 230
$Padding      = 10
$HeaderHeight = 42
$RowHeight    = 24

$BackColor    = [System.Drawing.Color]::FromArgb(211, 211, 211)
$BorderColor  = [System.Drawing.Color]::FromArgb(150, 150, 150)
$TitleColor   = [System.Drawing.Color]::FromArgb(30, 30, 30)
$CloseColor   = [System.Drawing.Color]::FromArgb(90, 90, 90)
$LabelColor   = [System.Drawing.Color]::FromArgb(30, 30, 30)
$LinkColor    = [System.Drawing.Color]::FromArgb(0, 102, 204)
$RunningColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
$StoppedColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
$DimColor     = [System.Drawing.Color]::FromArgb(90, 90, 90)

# ---------- form shell ----------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Service Widget'
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'Manual'
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.BackColor       = $BackColor
$form.Width           = $WidgetWidth
$form.Height          = $HeaderHeight + ($ServiceNames.Count * $RowHeight) + $Padding + 6

$form.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen($BorderColor)
    $e.Graphics.DrawRectangle($pen, 0, 0, $form.Width - 1, $form.Height - 1)
    $pen.Dispose()
})

# ---------- window position (WinForms Screen API handles multi-monitor better than WPF's SystemParameters) ----------
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
Write-Diag "Screen: PrimaryScreen.WorkingArea=$wa  AllScreens=$([System.Windows.Forms.Screen]::AllScreens.Count)"
$form.Left = $wa.Right - $WidgetWidth - 30
$form.Top  = $wa.Top + 20
if (Test-Path $PositionPath) {
    try {
        $pos = Get-Content -Path $PositionPath -Raw | ConvertFrom-Json
        if ($null -ne $pos.Left) { $form.Left = [int]$pos.Left }
        if ($null -ne $pos.Top)  { $form.Top  = [int]$pos.Top }
    } catch { }
}
Write-Diag "Planned window position: Left=$($form.Left) Top=$($form.Top)"

$form.Add_Shown({ Write-Diag "Form Shown event fired: Bounds=$($form.Bounds) Visible=$($form.Visible)" })
$form.Add_FormClosing({
    $pos = @{ Left = $form.Left; Top = $form.Top }
    $pos | ConvertTo-Json | Set-Content -Path $PositionPath -Encoding UTF8
})

# ---------- title bar (drag + close) ----------
$script:Dragging  = $false
$script:DragStart = New-Object System.Drawing.Point 0, 0

$dragDown = {
    param($s, $e)
    $script:Dragging  = $true
    $script:DragStart = New-Object System.Drawing.Point($e.X, $e.Y)
}
$dragMove = {
    param($s, $e)
    if ($script:Dragging) {
        $form.Left += $e.X - $script:DragStart.X
        $form.Top  += $e.Y - $script:DragStart.Y
    }
}
$dragUp = { $script:Dragging = $false }

$titleBar = New-Object System.Windows.Forms.Panel
$titleBar.Height    = $HeaderHeight
$titleBar.Dock      = 'Top'
$titleBar.BackColor = $BackColor
$form.Controls.Add($titleBar)
$titleBar.Add_MouseDown($dragDown)
$titleBar.Add_MouseMove($dragMove)
$titleBar.Add_MouseUp($dragUp)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text      = 'Services'
$titleLabel.ForeColor = $TitleColor
$titleLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize  = $true
$titleLabel.Location  = New-Object System.Drawing.Point($Padding, 6)
$titleBar.Controls.Add($titleLabel)
$titleLabel.Add_MouseDown($dragDown)
$titleLabel.Add_MouseMove($dragMove)
$titleLabel.Add_MouseUp($dragUp)

$closeLabel = New-Object System.Windows.Forms.Label
$closeLabel.Text      = [char]0x2715
$closeLabel.ForeColor = $CloseColor
$closeLabel.AutoSize  = $true
$closeLabel.Cursor    = [System.Windows.Forms.Cursors]::Hand
$closeLabel.Location  = New-Object System.Drawing.Point(($WidgetWidth - 24), 6)
$titleBar.Controls.Add($closeLabel)
$closeLabel.Add_Click({ $form.Close() })

$editLabel = New-Object System.Windows.Forms.Label
$editLabel.Text      = 'Edit List'
$editLabel.ForeColor = $LinkColor
$editLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Underline)
$editLabel.AutoSize  = $true
$editLabel.Cursor    = [System.Windows.Forms.Cursors]::Hand
$editLabel.Location  = New-Object System.Drawing.Point($Padding, 24)
$titleBar.Controls.Add($editLabel)
$editLabel.Add_Click({
    try { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$ConfigPath`"" }
    catch { Show-Err "Could not open services.json:`n$($_.Exception.Message)" }
})

# ---------- helpers ----------
function New-Light {
    $p = New-Object System.Windows.Forms.Panel
    $p.Width     = 14
    $p.Height    = 14
    $p.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $p.BackColor = $BackColor
    $p | Add-Member -NotePropertyName LedColor -NotePropertyValue $DimColor
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $bezel = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 40, 40))
        $g.FillEllipse($bezel, 0, 0, $s.Width, $s.Height)
        $bezel.Dispose()

        $inner = New-Object System.Drawing.Rectangle(1, 1, ($s.Width - 3), ($s.Height - 3))
        $path  = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddEllipse($inner)
        $glossBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
        $glossBrush.CenterPoint  = New-Object System.Drawing.PointF(($inner.X + $inner.Width * 0.32), ($inner.Y + $inner.Height * 0.3))
        $glossBrush.CenterColor  = [System.Drawing.Color]::FromArgb(255, 255, 255)
        $glossBrush.SurroundColors = @($s.LedColor)
        $g.FillPath($glossBrush, $path)
        $glossBrush.Dispose()
        $path.Dispose()
    })
    return $p
}

function Update-Row($row) {
    $svc = $null
    try { $svc = Get-Service -Name $row.Name -ErrorAction Stop } catch { $svc = $null }

    if (-not $svc) {
        $row.Label.Text = "$($row.Name) (not found)"
        $row.Green.LedColor = $DimColor
        $row.Red.LedColor   = $DimColor
        $row.Green.Invalidate()
        $row.Red.Invalidate()
        $row.Status = 'Unknown'
        return
    }

    $row.Status = $svc.Status.ToString()
    switch ($svc.Status) {
        'Running' {
            $row.Green.LedColor = $RunningColor
            $row.Red.LedColor   = $DimColor
        }
        'Stopped' {
            $row.Green.LedColor = $DimColor
            $row.Red.LedColor   = $StoppedColor
        }
        default {
            $row.Green.LedColor = $DimColor
            $row.Red.LedColor   = $DimColor
        }
    }
    $row.Green.Invalidate()
    $row.Red.Invalidate()
    $row.Label.Text = $svc.DisplayName
    $toolTip = $row.ToolTip
    $toolTip.SetToolTip($row.Green, "Start / Restart '$($svc.DisplayName)'  (currently: $($svc.Status))")
    $toolTip.SetToolTip($row.Red,   "Stop '$($svc.DisplayName)'  (currently: $($svc.Status))")
}

# ---------- build rows ----------
$Rows = @()
$sharedToolTip = New-Object System.Windows.Forms.ToolTip
$y = $HeaderHeight + 6

foreach ($name in $ServiceNames) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text          = $name
    $label.ForeColor     = $LabelColor
    $label.AutoSize      = $false
    $label.Width         = $WidgetWidth - $Padding - 44
    $label.Height        = 18
    $label.AutoEllipsis  = $true
    $label.Location      = New-Object System.Drawing.Point($Padding, ($y + 1))
    $form.Controls.Add($label)

    $redEllipse = New-Light
    $redEllipse.Location = New-Object System.Drawing.Point(($WidgetWidth - $Padding - 32), $y)
    $form.Controls.Add($redEllipse)

    $greenEllipse = New-Light
    $greenEllipse.Location = New-Object System.Drawing.Point(($WidgetWidth - $Padding - 14), $y)
    $form.Controls.Add($greenEllipse)

    $row = [PSCustomObject]@{
        Name    = $name
        Label   = $label
        Red     = $redEllipse
        Green   = $greenEllipse
        Status  = 'Unknown'
        ToolTip = $sharedToolTip
    }
    $Rows += $row

    $redEllipse.Tag   = $row
    $greenEllipse.Tag = $row

    $y += $RowHeight
}
$form.Height = $y + $Padding

foreach ($row in $Rows) {
    $row.Red.Add_Click({
        param($s, $e)
        $r = $s.Tag
        try { Stop-Service -Name $r.Name -Force -ErrorAction Stop }
        catch { Show-Err "Could not stop '$($r.Name)':`n$($_.Exception.Message)" }
        Update-Row $r
    })
    $row.Green.Add_Click({
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
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $RefreshMs
$timer.Add_Tick({ foreach ($row in $Rows) { Update-Row $row } })
$timer.Start()

Write-Diag "Calling Application.Run() now..."
[System.Windows.Forms.Application]::Run($form)
Write-Diag "Application.Run() returned - window was closed."
