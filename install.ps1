# ============================================================
# Parental Time Manager
# Install.ps1
# Version 1.1.0 (With Power-Unrestricted Settings & Process Termination)
# ============================================================

$ErrorActionPreference = "Stop"

# Require administrator privileges.
$Principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    exit
}

$TaskName = "ParentalTimeManager"
$LogonTaskName = "ParentalTimeManager_Logon"
$Root = "$env:ProgramData\ParentalTimeManager"
$LogsDir = Join-Path $Root "Logs"

Write-Host "Installing Parental Time Manager..." -ForegroundColor Cyan

# ------------------------------------------------------------
# 0. Pre-Flight: Stop running tasks and kill active background instances
# ------------------------------------------------------------
Write-Host "Stopping any active monitoring tasks and background processes..."
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
} catch {}

# Find and terminate any active PowerShell processes running TimeMonitor.ps1 from ProgramData
Get-CimInstance Win32_Process -Filter "Name LIKE '%powershell%'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*$Root\TimeMonitor.ps1*" -or $_.CommandLine -like "*TimeMonitor.ps1*"
} | ForEach-Object {
    Write-Host "Terminating active process ID: $($_.ProcessId)" -ForegroundColor Yellow
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# Brief pause to release file locks
Start-Sleep -Seconds 1

# ------------------------------------------------------------
# 1. Create directories
# ------------------------------------------------------------

if (-not (Test-Path $Root)) {
    New-Item -Path $Root -ItemType Directory -Force | Out-Null
}

if (-not (Test-Path $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

# ------------------------------------------------------------
# 2. Secure folder permissions with NTFS (Language-Agnostic using SIDs)
# SYSTEM (*S-1-5-18), Administrators (*S-1-5-32-544), Users (*S-1-5-32-545)
# ------------------------------------------------------------

Write-Host "Securing installation directory permissions..."
& icacls.exe $Root /inheritance:d /q
& icacls.exe $Root /grant "*S-1-5-18:(OI)(CI)F" /q
& icacls.exe $Root /grant "*S-1-5-32-544:(OI)(CI)F" /q
& icacls.exe $Root /grant "*S-1-5-32-545:(OI)(CI)RX" /q

# ------------------------------------------------------------
# 3. Copy scripts if running from source deployment folder
# ------------------------------------------------------------

$SourceDir = $PSScriptRoot

if ($SourceDir -and (Test-Path "$SourceDir\TimeMonitor.ps1")) {
    Copy-Item "$SourceDir\TimeMonitor.ps1" "$Root\" -Force
    Copy-Item "$SourceDir\ParentalTimeManager.ps1" "$Root\" -Force
       Write-Host "Copied script files to $Root"
} else {
    Write-Host "Warning: Source scripts not found in `$PSScriptRoot. Ensure TimeMonitor.ps1, ParentalTimeManager.ps1 are present." -ForegroundColor Yellow
}

# ------------------------------------------------------------
# 4. Initialize default Settings.json if missing
# ------------------------------------------------------------

$SettingsFile = Join-Path $Root "Settings.json"

if (-not (Test-Path $SettingsFile)) {
    $DefaultSettings = [PSCustomObject]@{
        DefaultDailyLimitMinutes = 90
        Users = @()
    }

    $DefaultSettings | ConvertTo-Json -Depth 10 |
        Set-Content $SettingsFile -Encoding UTF8

    Write-Host "Initialized default Settings.json"
}

# ------------------------------------------------------------
# 5. Initialize default Usage.json if missing
# ------------------------------------------------------------

$UsageFile = Join-Path $Root "Usage.json"

if (-not (Test-Path $UsageFile)) {
    $DefaultUsage = [PSCustomObject]@{
        Date = (Get-Date -Format "yyyy-MM-dd")
        Users = @()
    }

    $DefaultUsage | ConvertTo-Json -Depth 10 |
        Set-Content $UsageFile -Encoding UTF8

    Write-Host "Initialized default Usage.json"
}

# ------------------------------------------------------------
# 6. Create Public Desktop Shortcut for Dashboard
# ------------------------------------------------------------

try {
    $WScriptShell = New-Object -ComObject WScript.Shell
    $ShortcutPath = Join-Path $env:PUBLIC "Desktop\Parental Time Manager.lnk"
    $Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = "powershell.exe"
    $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Root\ParentalTimeManager.ps1`""
    $Shortcut.Description = "Parental Time Manager Dashboard"
    $Shortcut.WorkingDirectory = $Root
    $Shortcut.Save()

    Write-Host "Created public desktop shortcut."
}
catch {
    Write-Host "Warning: Could not create desktop shortcut. You can run ParentalTimeManager.ps1 manually from $Root." -ForegroundColor Yellow
}
# ------------------------------------------------------------
# 7. Register Scheduled Task for Background Monitor (SYSTEM)
# ------------------------------------------------------------

Write-Host "Registering background monitoring task..."

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$Root\TimeMonitor.ps1"""
$Trigger = New-ScheduledTaskTrigger -AtStartup
$PrincipalTask = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Configure task settings to allow running on battery and prevent stopping on power loss
$SettingsTask = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 365) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$SettingsTask.DisallowStartIfOnBatteries = $false
$SettingsTask.StopIfGoingOnBatteries = $false

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $PrincipalTask -Settings $SettingsTask -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

Write-Host "`nInstallation and update completed successfully!" -ForegroundColor Green