# ============================================================
# Parental Time Manager
# ParentalTimeManager.ps1
# Version 1.0.3 (Mutex-Protected Edition)
# ============================================================

$ErrorActionPreference = "Stop"

$Root = "$env:ProgramData\ParentalTimeManager"
$SettingsFile = Join-Path $Root "Settings.json"
$UsageFile = Join-Path $Root "Usage.json"
$MutexName = "Global\ParentalTimeManager_FileMutex"

# Require administrator.
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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Read-Settings {
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $LockAcquired = $false
    try {
        $LockAcquired = $Mutex.WaitOne(5000)
        if (Test-Path $SettingsFile) {
            $Content = Get-Content $SettingsFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($Content) -and -not $Content.Contains("`0")) {
                return $Content | ConvertFrom-Json
            }
        }
        return [PSCustomObject]@{ DefaultDailyLimitMinutes = 90; Users = @() }
    }
    finally {
        if ($LockAcquired) { $Mutex.ReleaseMutex() }
        $Mutex.Dispose()
    }
}

function Read-Usage {
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $LockAcquired = $false
    try {
        $LockAcquired = $Mutex.WaitOne(5000)
        if (Test-Path $UsageFile) {
            $Content = Get-Content $UsageFile -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($Content) -and -not $Content.Contains("`0")) {
                return $Content | ConvertFrom-Json
            }
        }
        return [PSCustomObject]@{ Date = (Get-Date -Format "yyyy-MM-dd"); Users = @() }
    }
    finally {
        if ($LockAcquired) { $Mutex.ReleaseMutex() }
        $Mutex.Dispose()
    }
}

function Save-Json {
    param($Path, $Data)
    $Temp = "$Path.tmp"
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $LockAcquired = $false
    try {
        $LockAcquired = $Mutex.WaitOne(5000)
        if (-not $LockAcquired) {
            throw "Timeout acquiring file lock for saving json."
        }
        $Data | ConvertTo-Json -Depth 10 | Set-Content $Temp -Encoding UTF8 -Force
        Move-Item $Temp $Path -Force
    }
    finally {
        if ($LockAcquired) { $Mutex.ReleaseMutex() }
        $Mutex.Dispose()
    }
}

function Get-UsageRow {
    param($Data, $User)

    $Row = $Data.Users | Where-Object { $_.User -ieq $User } | Select-Object -First 1
    if (-not $Row) {
        $Row = [PSCustomObject]@{
            User = $User
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

function Refresh-Status {
    if (-not $userBox.SelectedItem) { return }

    $Settings = Read-Settings
    $Usage = Read-Usage
    $User = [string]$userBox.SelectedItem

    $Config = $Settings.Users | Where-Object { $_.User -ieq $User } | Select-Object -First 1
    $Row = Get-UsageRow $Usage $User

    if ($Config) {
        $BaseLimit = [int]$Config.DailyLimitMinutes
        $Enabled = [bool]$Config.Enabled
    }
    else {
        $BaseLimit = [int]$Settings.DefaultDailyLimitMinutes
        $Enabled = $false
    }

    $ExtraMinutes = [math]::Floor($Row.ExtraSeconds / 60)
    $TotalLimit = $BaseLimit + $ExtraMinutes
    $UsedMinutes = [math]::Floor($Row.UsedSeconds / 60)
    $RemainingMinutes = [math]::Max(0, $TotalLimit - $UsedMinutes)

    $limitBox.Value = [decimal]$BaseLimit

    $statusLabel.Text = @"
Selected user: $User
Monitoring enabled: $Enabled

Base daily allowance: $BaseLimit minutes
Extra time granted: $ExtraMinutes minutes (Total: $TotalLimit min)
Used today: $UsedMinutes minutes
Remaining: $RemainingMinutes minutes

Override expiry: $($Row.OverrideUntil)
"@
}

# ------------------------------------------------------------
# Main window
# ------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Parental Time Manager"
$form.Size = New-Object System.Drawing.Size(560, 640)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

function Add-Label {
    param($Text, $Top)
    $Label = New-Object System.Windows.Forms.Label
    $Label.Text = $Text
    $Label.Location = New-Object System.Drawing.Point(25, $Top)
    $Label.Size = New-Object System.Drawing.Size(470, 25)
    $form.Controls.Add($Label)
}

Add-Label "PARENTAL TIME MANAGER" 20
Add-Label "Select local Windows user:" 65

$userBox = New-Object System.Windows.Forms.ComboBox
$userBox.Location = New-Object System.Drawing.Point(25, 95)
$userBox.Size = New-Object System.Drawing.Size(470, 30)
$userBox.DropDownStyle = "DropDownList"

$Accounts = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" |
    Where-Object { -not $_.Disabled } |
    Sort-Object Name

foreach ($Account in $Accounts) {
    [void]$userBox.Items.Add($Account.Name)
}
$form.Controls.Add($userBox)

Add-Label "Daily allowance (minutes):" 145

$limitBox = New-Object System.Windows.Forms.NumericUpDown
$limitBox.Location = New-Object System.Drawing.Point(25, 175)
$limitBox.Size = New-Object System.Drawing.Size(120, 30)
$limitBox.Minimum = 1
$limitBox.Maximum = 1440
$limitBox.Value = 90
$form.Controls.Add($limitBox)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Save allowance"
$saveButton.Location = New-Object System.Drawing.Point(170, 175)
$saveButton.Size = New-Object System.Drawing.Size(150, 32)
$form.Controls.Add($saveButton)

$saveButton.Add_Click({
    if (-not $userBox.SelectedItem) { return }

    $Settings = Read-Settings
    $User = [string]$userBox.SelectedItem

    $Existing = @(
        $Settings.Users | Where-Object { $_.User -ine $User }
    )

    $Entry = [PSCustomObject]@{
        User = $User
        Enabled = $true
        DailyLimitMinutes = [int]$limitBox.Value
    }

    $Settings.Users = @($Existing) + @($Entry)
    Save-Json $SettingsFile $Settings

    [System.Windows.Forms.MessageBox]::Show("Allowance saved successfully.", "Parental Time Manager", 0, 64)
    Refresh-Status
})

Add-Label "Grant additional time:" 225

$extraBox = New-Object System.Windows.Forms.NumericUpDown
$extraBox.Location = New-Object System.Drawing.Point(25, 255)
$extraBox.Size = New-Object System.Drawing.Size(120, 30)
$extraBox.Minimum = 1
$extraBox.Maximum = 1440
$extraBox.Value = 30
$form.Controls.Add($extraBox)

$extraButton = New-Object System.Windows.Forms.Button
$extraButton.Text = "Grant extra minutes"
$extraButton.Location = New-Object System.Drawing.Point(170, 255)
$extraButton.Size = New-Object System.Drawing.Size(180, 32)
$form.Controls.Add($extraButton)

$extraButton.Add_Click({
    if (-not $userBox.SelectedItem) { return }

    $Confirm = [System.Windows.Forms.MessageBox]::Show(
        "Grant $($extraBox.Value) extra minutes?",
        "Administrator confirmation",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($Confirm -ne "Yes") { return }

    $Usage = Read-Usage
    $Row = Get-UsageRow $Usage ([string]$userBox.SelectedItem)

    $Row.ExtraSeconds = [int]$Row.ExtraSeconds + ([int]$extraBox.Value * 60)

    Save-Json $UsageFile $Usage
    Refresh-Status
    [System.Windows.Forms.MessageBox]::Show("Extra time granted.", "Success", 0, 64)
})

Add-Label "Temporary restriction suspension:" 305

$suspendBox = New-Object System.Windows.Forms.NumericUpDown
$suspendBox.Location = New-Object System.Drawing.Point(25, 335)
$suspendBox.Size = New-Object System.Drawing.Size(120, 30)
$suspendBox.Minimum = 1
$suspendBox.Maximum = 1440
$suspendBox.Value = 60
$form.Controls.Add($suspendBox)

$suspendButton = New-Object System.Windows.Forms.Button
$suspendButton.Text = "Suspend restrictions"
$suspendButton.Location = New-Object System.Drawing.Point(170, 335)
$suspendButton.Size = New-Object System.Drawing.Size(180, 32)
$form.Controls.Add($suspendButton)

$suspendButton.Add_Click({
    if (-not $userBox.SelectedItem) { return }

    $Confirm = [System.Windows.Forms.MessageBox]::Show(
        "Suspend restrictions for $($suspendBox.Value) minutes?",
        "Administrator confirmation",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($Confirm -ne "Yes") { return }

    $Usage = Read-Usage
    $Row = Get-UsageRow $Usage ([string]$userBox.SelectedItem)

    $Row.OverrideUntil = (Get-Date).AddMinutes([int]$suspendBox.Value).ToString("o")

    Save-Json $UsageFile $Usage
    Refresh-Status
    [System.Windows.Forms.MessageBox]::Show("Restrictions suspended temporarily.", "Success", 0, 64)
})

$resumeButton = New-Object System.Windows.Forms.Button
$resumeButton.Text = "Restore restrictions now"
$resumeButton.Location = New-Object System.Drawing.Point(25, 385)
$resumeButton.Size = New-Object System.Drawing.Size(325, 32)
$form.Controls.Add($resumeButton)

$resumeButton.Add_Click({
    if (-not $userBox.SelectedItem) { return }

    $Usage = Read-Usage
    $Row = Get-UsageRow $Usage ([string]$userBox.SelectedItem)

    $Row.OverrideUntil = ""

    Save-Json $UsageFile $Usage
    Refresh-Status
    [System.Windows.Forms.MessageBox]::Show("Restrictions restored.", "Success", 0, 64)
})

$resetButton = New-Object System.Windows.Forms.Button
$resetButton.Text = "Reset today's usage"
$resetButton.Location = New-Object System.Drawing.Point(25, 430)
$resetButton.Size = New-Object System.Drawing.Size(325, 32)
$form.Controls.Add($resetButton)

$resetButton.Add_Click({
    if (-not $userBox.SelectedItem) { return }

    $Confirm = [System.Windows.Forms.MessageBox]::Show(
        "Reset usage for today?",
        "Administrator confirmation",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($Confirm -ne "Yes") { return }

    $Usage = Read-Usage
    $Row = Get-UsageRow $Usage ([string]$userBox.SelectedItem)

    $Row.UsedSeconds = 0
    $Row.ExtraSeconds = 0
    $Row.Warn10Sent = $false
    $Row.Warn5Sent = $false

    Save-Json $UsageFile $Usage
    Refresh-Status
    [System.Windows.Forms.MessageBox]::Show("Daily usage has been reset.", "Success", 0, 64)
})

Add-Label "DAILY STATUS" 480

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(25, 510)
$statusLabel.Size = New-Object System.Drawing.Size(490, 100)
$statusLabel.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($statusLabel)

$userBox.Add_SelectedIndexChanged({
    Refresh-Status
})

if ($userBox.Items.Count -gt 0) {
    $userBox.SelectedIndex = 0
}

[void]$form.ShowDialog()