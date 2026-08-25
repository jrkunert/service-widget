<#
    Run this once, from a normal PowerShell prompt:

        .\CreateShortcut.ps1

    It creates a "Service Widget" shortcut on your Desktop and copies it into
    your Startup folder so the widget launches automatically at logon.
    Launching the shortcut runs ServiceWidget.ps1, which elevates itself via a
    UAC prompt and then hides its console.

    (This does not use .vbs / Windows Script Host, since that's blocked here.)
#>

$ScriptDir = $PSScriptRoot
$psScript  = Join-Path $ScriptDir 'ServiceWidget.ps1'
$powershellExe = (Get-Command powershell.exe).Source

$shell = New-Object -ComObject WScript.Shell

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop 'Service Widget.lnk'

$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath = $powershellExe
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$psScript`""
$shortcut.WorkingDirectory = $ScriptDir
$shortcut.IconLocation = "$powershellExe,0"
$shortcut.Save()
Write-Host "Created desktop shortcut: $lnkPath"

$startup = [Environment]::GetFolderPath('Startup')
$startupLnk = Join-Path $startup 'Service Widget.lnk'
Copy-Item -Path $lnkPath -Destination $startupLnk -Force
Write-Host "Added to Startup folder (auto-launch at logon): $startupLnk"
Write-Host ""
Write-Host "Note: since the widget always self-elevates, you'll see one UAC prompt each time it starts (including at every logon)."
