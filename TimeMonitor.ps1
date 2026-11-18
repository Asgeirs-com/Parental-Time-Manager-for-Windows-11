# ============================================================
# Parental Time Manager
# TimeMonitor.ps1
# Version 1.1.0 (Mutex-Protected with Logon Greeting)
# ============================================================

$ErrorActionPreference = "Stop"

$Root = "$env:ProgramData\ParentalTimeManager"
$SettingsFile = Join-Path $Root "Settings.json"
$UsageFile = Join-Path $Root "Usage.json"
$LogDir = Join-Path $Root "Logs"
$LogFile = Join-Path $LogDir "Monitor.log"
$MutexName = "Global\ParentalTimeManager_FileMutex"

# ENSURE LOGS DIRECTORY EXISTS FIRST
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$IntervalSeconds = 15

# ------------------------------------------------------------
# Load Native Windows Terminal Services API (Never Hangs)
# ------------------------------------------------------------
if (-not ("WtsApi" -as [type])) {
    Add-Type -TypeDefinition @'
    using System;
    using System.Runtime.InteropServices;
    using System.Collections.Generic;

    public class WtsApi {
        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSLogoffSession(IntPtr hServer, int SessionId, bool bWait);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool WTSSendMessage(
            IntPtr hServer,
            int SessionId,
            string pTitle,
            int TitleLength,
            string pMessage,
            int MessageLength,
            uint Style,
            uint Timeout,
            out uint pResponse,
            bool bWait
        );

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool WTSQuerySessionInformation(
            IntPtr hServer,
            int SessionId,
            int wtsInfoClass,
            out IntPtr ppBuffer,
            out uint pBytesReturned
        );

        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern void WTSFreeMemory(IntPtr pMemory);

        public static readonly IntPtr WTS_CURRENT_SERVER_HANDLE = IntPtr.Zero;

        public static string GetUserNameForSession(int sessionId) {
            IntPtr buffer = IntPtr.Zero;
            uint bytesReturned = 0;
							  
            if (WTSQuerySessionInformation(WTS_CURRENT_SERVER_HANDLE, sessionId, 5, out buffer, out bytesReturned)) {
                try {
                    if (buffer != IntPtr.Zero && bytesReturned > 2) {
                        return Marshal.PtrToStringUni(buffer);
                    }
                }
                finally {
                    if (buffer != IntPtr.Zero) {
                        WTSFreeMemory(buffer);
                    }
                }
            }
            return null;
        }
    }
'@ -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        Add-Content -Path $LogFile -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue
    } catch {}
}

# ------------------------------------------------------------
# Thread-safe JSON reader with Mutex & NUL-byte protection
# ------------------------------------------------------------
function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "File not found: $Path"
    }

    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $LockAcquired = $false
    try {
        $LockAcquired = $Mutex.WaitOne(5000)
        if (-not $LockAcquired) {
            throw "Timeout acquiring file lock for reading: $Path"
        }

        for ($i = 0; $i -lt 3; $i++) {
            try {
                $Content = Get-Content $Path -Raw -Encoding UTF8
                if (-not [string]::IsNullOrWhiteSpace($Content) -and -not $Content.Contains("`0")) {
                    return $Content | ConvertFrom-Json
                }
            }
            catch {
                Start-Sleep -Milliseconds 200
            }
        }
        throw "Could not read locked or corrupted file: $Path"
    }
    finally {
        if ($LockAcquired) {
            $Mutex.ReleaseMutex()
        }
        $Mutex.Dispose()
    }
}

# ------------------------------------------------------------
# Thread-safe atomic JSON writer with Mutex
# ------------------------------------------------------------
function Save-Usage {
    param($Data)
    $TempFile = "$UsageFile.tmp"
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $LockAcquired = $false
    try {
        $LockAcquired = $Mutex.WaitOne(5000)
        if (-not $LockAcquired) {
            throw "Timeout acquiring file lock for writing usage data."
        }

        $Data | ConvertTo-Json -Depth 10 | Set-Content $TempFile -Encoding UTF8 -Force
        Move-Item $TempFile $UsageFile -Force
    }
    catch {
        Write-Log "ERROR saving usage file: $($_.Exception.Message)"
    }
    finally {
        if ($LockAcquired) {
            $Mutex.ReleaseMutex()
        }
        $Mutex.Dispose()
    }
}

# ------------------------------------------------------------
# Get active Windows sessions instantly via WTS API
# ------------------------------------------------------------
function Get-ActiveUsers {
    $ActiveUsers = @()
    try {
        for ($sessionId = 0; $sessionId -lt 32; $sessionId++) {
            $Username = [WtsApi]::GetUserNameForSession($sessionId)
            if (-not [string]::IsNullOrEmpty($Username)) {
                $SystemAccounts = @("SYSTEM", "LOCAL SERVICE", "NETWORK SERVICE", "DWM-1", "UMFD-0", "ANONYMOUS LOGON")
                if ($SystemAccounts -notcontains $Username) {
                    $Existing = $ActiveUsers | Where-Object { $_.User -ieq $Username }
                    if (-not $Existing) {
                        $ActiveUsers += [PSCustomObject]@{
                            User = $Username
                            Id   = $sessionId
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Error detecting active users via WTS API: $($_.Exception.Message)"
    }
    return $ActiveUsers
}

# ------------------------------------------------------------
# Find or create user usage record
# ------------------------------------------------------------
function Get-UsageRow {
    param($Data, [string]$Username)

    $Row = $Data.Users | Where-Object { $_.User -ieq $Username } | Select-Object -First 1

    if (-not $Row) {
        $Row = [PSCustomObject]@{
            User = $Username
            UsedSeconds = 0
            ExtraSeconds = 0
            OverrideUntil = ""
            Warn10Sent = $false
            Warn5Sent = $false
        }
        $Data.Users = @($Data.Users) + @($Row)
    }

    return $Row
}

# ------------------------------------------------------------
# Send native popup warning to specific Session ID
# ------------------------------------------------------------
function Send-Warning {
    param([int]$SessionId, [string]$Message)
    try {
        [uint32]$response = 0
        $title = "Parental Time Manager"
        [WtsApi]::WTSSendMessage(
            [WtsApi]::WTS_CURRENT_SERVER_HANDLE,
            $SessionId,
            $title,
            $title.Length,
            $Message,
            $Message.Length,
            0x00000040, # MB_ICONINFORMATION | MB_OK
            30,
            [ref]$response,
            $false
        ) | Out-Null
        Write-Log "Popup message sent to session ${SessionId}"
    }
    catch {
        Write-Log "Could not send message to session ${SessionId}: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# Force logoff specific Session ID natively
# ------------------------------------------------------------
function Invoke-UserLogoff {
    param([int]$SessionId, [string]$Username)
    try {
        $success = [WtsApi]::WTSLogoffSession([WtsApi]::WTS_CURRENT_SERVER_HANDLE, $SessionId, $false)
        if ($success) {
            Write-Log "Successfully logged off $Username on session ${SessionId}"
        } else {
            Write-Log "WTSLogoffSession returned false for session ${SessionId}"
        }
    }
    catch {
        Write-Log "Logoff exception for $Username on session ${SessionId} : $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# Daily reset
# ------------------------------------------------------------
function Reset-DailyUsage {
    param($Data)
    $Today = Get-Date -Format "yyyy-MM-dd"

    if (-not $Data.Date -or $Data.Date -ne $Today) {
        Write-Log "New day detected. Resetting daily usage."
        if ($Data.Users) {
            foreach ($Row in $Data.Users) {
                $Row.UsedSeconds = 0
                $Row.ExtraSeconds = 0
                $Row.Warn10Sent = $false
                $Row.Warn5Sent = $false
            }
        }
        $Data.Date = $Today
    }
}

# ------------------------------------------------------------
# Main monitoring loop
# ------------------------------------------------------------
Write-Log "============================================"
Write-Log "Parental Time Manager monitor started (v1.1.0)."
Write-Log "============================================"

# Memory tracker for active session IDs to detect new logins/reconnections
$KnownActiveSessions = @{}

while ($true) {
    try {
        if (-not (Test-Path $SettingsFile) -or -not (Test-Path $UsageFile)) {
            Write-Log "DEBUG: Settings.json or Usage.json missing."
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        $Settings = Read-JsonFile $SettingsFile
        $Usage = Read-JsonFile $UsageFile

        Reset-DailyUsage $Usage

        $ActiveUsers = Get-ActiveUsers
        
        # Clean up tracking for sessions that have logged off
        $CurrentActiveSessionIds = @($ActiveUsers | Select-Object -ExpandProperty Id)
        foreach ($trackedSid in @($KnownActiveSessions.Keys)) {
            if ($CurrentActiveSessionIds -notcontains $trackedSid) {
                $KnownActiveSessions.Remove($trackedSid)
                Write-Log "Session ID $trackedSid logged off or terminated."
            }
        }

        if ($ActiveUsers.Count -eq 0) {
            Write-Log "DEBUG: No active user sessions found on this cycle."
        } else {
            Write-Log "DEBUG: Active users detected: $($ActiveUsers.User -join ', ')"
        }

        foreach ($ActiveUser in $ActiveUsers) {
            $Username = $ActiveUser.User
            $SessionId = $ActiveUser.Id

            $UserConfig = $Settings.Users | Where-Object { $_.Enabled -and $_.User -ieq $Username } | Select-Object -First 1
            if (-not $UserConfig) { continue }

            $Row = Get-UsageRow $Usage $Username

            # Determine if this session ID is newly discovered
            $IsNewSession = -not $KnownActiveSessions.ContainsKey($SessionId)
            if ($IsNewSession) {
                $KnownActiveSessions[$SessionId] = $Username
                Write-Log "New user session found: $Username on Session ID $SessionId"
            }

            # Increment used time on regular poll intervals
            $Row.UsedSeconds = [int]$Row.UsedSeconds + $IntervalSeconds

            $DailyLimitSeconds = ([int]$UserConfig.DailyLimitMinutes * 60) + [int]$Row.ExtraSeconds
            $RemainingSeconds = $DailyLimitSeconds - [int]$Row.UsedSeconds
            $RemainingMinutes = [Math]::Max(0, [Math]::Ceiling($RemainingSeconds / 60))

            Write-Log "User: $Username | Used: $($Row.UsedSeconds)s | Remaining: ${RemainingSeconds}s (Session ID: $SessionId)"

            # If it's a newly detected session, send the welcome time limit notification immediately
            if ($IsNewSession) {
                $GreetingMessage = "Welcome, $Username!`n`nThis session is managed by Parental Time Manager.`nDaily Limit: $($UserConfig.DailyLimitMinutes) minutes.`nRemaining Time: $RemainingMinutes minutes."
                Send-Warning -SessionId $SessionId -Message $GreetingMessage
                Write-Log "Logon greeting sent to $Username on session $SessionId (Remaining: ${RemainingMinutes}m)"
            }

            $Suspended = $false
            if ($Row.OverrideUntil -and $Row.OverrideUntil -ne "") {
                try {
                    $OverrideExpiry = [DateTimeOffset]::Parse($Row.OverrideUntil)
                    if ([DateTimeOffset]::Now -lt $OverrideExpiry) {
                        $Suspended = $true
                    } else {
                        $Row.OverrideUntil = ""
                        Write-Log "Temporary override expired for $Username"
                    }
                }
                catch {
                    $Row.OverrideUntil = ""
                    Write-Log "Invalid override timestamp for $Username"
                }
            }

            if ($Suspended) { continue }

            # 10 minute warning
            if ($RemainingSeconds -le 600 -and $RemainingSeconds -gt 300 -and -not $Row.Warn10Sent) {
                Send-Warning $SessionId "You have approximately 10 minutes of PC time remaining."
                $Row.Warn10Sent = $true
            }

            # 5 minute warning
            if ($RemainingSeconds -le 300 -and $RemainingSeconds -gt 0 -and -not $Row.Warn5Sent) {
                Send-Warning $SessionId "You have approximately 5 minutes of PC time remaining."
                $Row.Warn5Sent = $true
            }

            # Time expired -> Log off target session natively
            if ($RemainingSeconds -le 0) {
                Write-Log "Daily allowance expired for $Username"
                Send-Warning $SessionId "Your daily PC allowance has expired. You are being logged off."
                
                Start-Sleep -Seconds 5

                Invoke-UserLogoff -SessionId $SessionId -Username $Username
            }
        }

        Save-Usage $Usage
    }
    catch {
        Write-Log "CRITICAL LOOP ERROR: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $IntervalSeconds
}