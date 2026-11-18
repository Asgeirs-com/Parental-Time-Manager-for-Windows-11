# System Design Document: Parental Time Manager for Windows 11 (v1.2.0)

## 1. Executive Summary & Objectives
The **Parental Time Manager** is a lightweight, robust, native PowerShell-based background utility designed for Windows 11 (Home and Pro editions). It monitors active user sessions, tracks daily screen-time allowances, issues real-time desktop warning popups, and automatically logs off target sessions when daily time limits are exhausted. 

The system is engineered to overcome Windows Session 0 isolation constraints and bypass legacy utility blocks on Home editions by directly interfacing with native Windows Terminal Services APIs (`wtsapi32.dll`), backed by a thread-safe **Cross-Process Mutex Synchronization Model** to eliminate file lock race conditions.

---

## 2. System Architecture & Component Suite

The solution consists of 8 modular components stored securely within the system environment:

| Component | Target Path / Location | Purpose & Function |
| :--- | :--- | :--- |
| **`Install.ps1`** | Deployment script | Creates directory structures, applies strict NTFS security hardening (`icacls`), and registers background/logon scheduled tasks. |
| **`Uninstall.ps1`** | Cleanup script | Safely stops scheduled tasks, removes registration, and cleans up resources. |
| **`TimeMonitor.ps1`** | `$env:ProgramData\ParentalTimeManager\` | Core background monitoring engine running continuously under the `SYSTEM` security context. |
| **`ParentalTimeManager.ps1`** | `$env:ProgramData\ParentalTimeManager\` | Administrative GUI dashboard to manage allowances, extra time, and temporary overrides. |
| **`Settings.json`** | `$env:ProgramData\ParentalTimeManager\` | Central configuration file defining enabled monitored users and daily time limits (in minutes). |
| **`Usage.json`** | `$env:ProgramData\ParentalTimeManager\` | Atomic state tracking file storing daily usage counters (`UsedSeconds`), bonus time (`ExtraSeconds`), and warning flags. |
| **`Monitor.log` / `Notifier.log`** | Logs Directories | Rolling diagnostic logs capturing loop ticks, warnings, logoff events, and user notification startups. |

---

## 3. Core Technical Mechanics

### A. Background Execution & Privilege Level
- **Scheduled Task Configuration:** Registered as a system-level background task executing under `NT AUTHORITY\SYSTEM` with highest privileges.
- **Resilience:** Built-in exception boundaries (`try/catch` blocks around the main loops) ensure that transient errors or missing files never crash or hang the monitoring threads.

### B. Zero-Hang Native Session Detection (`wtsapi32.dll`)
To avoid WMI/CIM hangs common in background Session 0 environments, `TimeMonitor.ps1` utilizes custom C# P/Invoke signatures embedded via `Add-Type`:
- **Fast Scanning:** Queries Windows session identifiers instantly.
- **Account Filtering:** Automatically ignores system accounts (`SYSTEM`, `LOCAL SERVICE`, `NETWORK SERVICE`, `DWM-1`, `UMFD-0`, etc.) and isolates true interactive desktop user sessions.

### C. Native Inter-Session Notifications & Logoffs
Bypasses restricted or deprecated command-line binaries (`msg.exe`, `logoff.exe`) by invoking native Windows APIs directly:
- **`WTSSendMessage`:** Dispatches asynchronous, rich GUI info boxes directly to the target user's session ID with customizable timeouts.
- **`WTSLogoffSession`:** Cleanly terminates the precise interactive user session upon allowance expiration without affecting background services or other users.

### D. Concurrency & Inter-Process Synchronization (Named Mutex)
- **Problem Solved:** Prevents race conditions and `NUL` byte file corruption caused by simultaneous reads/writes between the background monitoring loop (`SYSTEM`) and the interactive administrator GUI (`ParentalTimeManager.ps1`).
- **Mechanism:** Uses a named system-wide mutex (`Global\ParentalTimeManager_FileMutex`) combined with atomic temporary file swapping (`Move-Item -Force`) to guarantee thread-safe, serialized access to `Settings.json` and `Usage.json`.

### E. User Logon Greeting  
- **Problem Solved:** Prevents issues with windows -logIn conditions such as not running on AC.
- **Mechanism:** notifications are sent using WTSSendMessage when a user sesstion with logins are detected.

---

## 4. Security & Data Protection Model

- **File System Lockdown:** Configuration and usage data residing in `$env:ProgramData\ParentalTimeManager` are locked down using Windows Access Control Lists (`icacls`). 
- **Privilege Separation:** Standard user accounts (children) hold **Read/Execute-only** rights, preventing them from modifying `Settings.json` to extend limits or tampering with `Usage.json`. Only the `SYSTEM` context and local Administrators possess write access.
