# ============================================================
# Parental Time Manager
# Uninstall.ps1
# Version 1.1.0 (Complete Cleanup & Uninstallation)
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

Write-Host "Uninstalling Parental Time Manager..." -ForegroundColor Cyan

# ------------------------------------------------------------
# 1. Stop and Unregister Scheduled Tasks
# ------------------------------------------------------------
Write-Host "Stopping and removing scheduled tasks..."
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
} catch {}

try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
} catch {}

try {
    Unregister-ScheduledTask -TaskName $LogonTaskName -Confirm:$false -ErrorAction SilentlyContinue
} catch {}

# ------------------------------------------------------------
# 2. Terminate Active Background or GUI Processes
# ------------------------------------------------------------
Write-Host "Terminating active background monitoring or GUI processes..."
Get-CimInstance Win32_Process -Filter "Name LIKE '%powershell%'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*$Root\TimeMonitor.ps1*" -or 
    $_.CommandLine -like "*TimeMonitor.ps1*" -or 
    $_.CommandLine -like "*ParentalTimeManager.ps1*"
} | ForEach-Object {
    Write-Host "Terminating active process ID: $($_.ProcessId)" -ForegroundColor Yellow
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# Brief pause to release file locks and mutexes
Start-Sleep -Seconds 1

# ------------------------------------------------------------
# 3. Remove Desktop Shortcut
# ------------------------------------------------------------
$ShortcutPath = Join-Path $env:PUBLIC "Desktop\Parental Time Manager.lnk"
if (Test-Path $ShortcutPath) {
    try {
        Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue
        Write-Host "Removed public desktop shortcut."
    } catch {
        Write-Host "Warning: Could not remove desktop shortcut." -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
# 4. Remove Program Data Directory and Files
# ------------------------------------------------------------
if (Test-Path $Root) {
    Write-Host "Removing installation files and logs from $Root..."
    try {
        # Reset inheritance / permissions first in case icacls locks folder deletion
        & icacls.exe $Root /inheritance:e /q /c | Out-Null
        Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Successfully removed installation directory." -ForegroundColor Green
    } catch {
        Write-Host "Warning: Some files in $Root could not be automatically removed. A system reboot will clear them." -ForegroundColor Yellow
    }
} else {
    Write-Host "Installation directory not found. Already clean."
}

Write-Host "`nUninstallation completed successfully!" -ForegroundColor Green
Pause