\# Parental Time Manager



Windows 11 parental screen-time manager.



\## Requirements



\- Windows 11

\- Windows PowerShell 5.1

\- Administrator account

\- Local Windows user accounts



\## Installation



1\. Extract the project folder.

2\. Open PowerShell as Administrator.

3\. Navigate to the project directory.

4\. Run:



&#x20;  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Install.ps1



5\. Open the desktop shortcut.

6\. Select a child account.

7\. Configure the daily allowance.



\## Default allowance



90 minutes per day.



\## Administrator controls



\- Grant extra time.

\- Suspend restrictions.

\- Restore restrictions.

\- Reset usage.



\## DEBUG locations:
C:\\ProgramData\\ParentalTimeManager\\Logs\\Monitor.log
## Uninstallation



Run:



powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Uninstall.ps1



\## Data location



C:\\ProgramData\\ParentalTimeManager



\## Logs



C:\\ProgramData\\ParentalTimeManager\\Logs



\## Important



This is a prototype. Test all enforcement,

recovery and security features before relying

on it for parental control.

