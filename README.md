# USB / MTP Blocked by Enterprise Policy — Root-Cause Diagnosis

A full write-up of a real investigation: from an initial “Kernel DMA Protection” hypothesis to the actual cause — **Trellix/McAfee DLP (data-loss prevention) device control intercepting devices in the kernel**. The document records symptoms, wrong assumptions, layer-by-layer checks, decisive evidence, underlying mechanics, error-code decoding, reusable commands, and the correct remediation path.

---

## Overview and purpose

- **Purpose**: Capture the real root cause and a repeatable method for “USB / phone MTP file transfer suddenly stops working,” so similar cases can be diagnosed in minutes.
- **Host**: Windows 11 (Build 26100), enterprise domain account `YOUR_DOMAIN\YOUR_USER`, Thunderbolt/USB4 plus a full enterprise security stack (Trellix Agent, Trellix DLP Endpoint, Defender/MDE, leftover McAfee components).
- **Symptom**: Phone connected as “Transfer files (MTP)” never appears on the PC. It worked the previous week; it broke after an IT policy update. USB sticks / external disks appeared similarly restricted.
- **One-line conclusion**: **This is not Windows’ built-in “disable USB stick / DMA protection” policy.** Enterprise Trellix DLP intercepts MTP/USB devices via the kernel device-class filter driver `hdlpdbk` during **Start Device (`IRP_MN_START_DEVICE`)**, returning error 10 / `0xC0000001`.

> **Practical tool (skip the theory, just copy files):** this repo includes a GUI **Phone File Manager (ADB)** (`MtpAdbFileManager.ps1`). ADB uses a separate **Android ADB Interface (WinUSB)** USB channel that is usually outside DLP’s WPD filter. The GUI wraps `adb push/pull/ls`: browse phone folders, drag files from the PC to upload, drag phone files out to download. See **Section 12**. Double-click `启动手机文件管理器.bat` to start.

---

## Final root cause

| Dimension | Conclusion |
|---|---|
| Interceptor | **Trellix DLP Endpoint** (formerly McAfee DLP), service `TrellixDLPAgentService`, kernel filter `hdlpdbk.sys` (Host **D**LP **D**evice **B**loc**k**) |
| Where it attaches | Device class **WPD `{eec5ad98-8080-425f-922a-dabf3de3f69a}`** `LowerFilters = hdlpdbk`; USB/USBDevice classes `UpperFilters = hdlpdbk` |
| When it fails | Plug-and-play start: **`IRP_MJ_PNP / IRP_MN_START_DEVICE`** (WUDF log `(27,0)`) |
| Failure return | Lower (kernel) driver returns **`0xC0000001` = STATUS_UNSUCCESSFUL**; Device Manager **error 10 (`CM_PROB_FAILED_START`)** |
| Why user-mode looks fine | WUDF logs show user-mode MTP driver `wpdmtpdr.dll` **loaded successfully**, so this is **not** signing / code integrity / WDAC / VBS |
| Timeline | Matches an IT ePO (ePolicy Orchestrator) DLP device-control policy update that week |

---

## Background (needed to read the evidence)

### 3.1 Windows device stacks and class filter drivers

A device is served by a **stack** of drivers, roughly:

```
   App / Explorer
        │
   [UpperFilters]   ← upper filter (can be injected per device class)
        │
   Function Driver  ← the worker (MTP: wpdmtp / UMDF)
        │
   [LowerFilters]   ← lower filter (can be injected per device class)
        │
   Bus Driver       ← USB stack / usbccgp, etc.
```

- A **filter driver** sits in the stack and can watch, modify, or **block** I/O request packets (IRPs).
- Two attachment styles:
  - **Per instance**: one device (`...\Enum\...\Device Parameters`).
  - **Per class**: entire class, via `UpperFilters` / `LowerFilters` under `HKLM\SYSTEM\CurrentControlSet\Control\Class\{class-GUID}`.
- DLP / endpoint products typically use **class filters** for device control: inject a filter into `USB`, `USBDevice`, `WPD`, `DiskDrive`, so **every device of that class must pass that filter on start**.

### 3.2 Common class GUIDs

| Class GUID | Meaning |
|---|---|
| `{eec5ad98-8080-425f-922a-dabf3de3f69a}` | **WPD** — portable devices / **phone MTP/PTP** |
| `{36fc9e60-c465-11cf-8056-444553540000}` | **USB** — USB controllers / hubs |
| `{88bae032-5a81-49f0-bc3d-a4ff138216d6}` | **USBDevice** — USB devices |
| `{4d36e967-e325-11ce-bfc1-08002be10318}` | **DiskDrive** — disk bodies (USB sticks / external HDDs) |
| `{71a27cdd-812a-11d0-bec7-08002be2092f}` | **Volume** — volumes (drive letters) |

### 3.3 PnP Start Device IRP

From discovery to usable, the PnP manager sends a series of IRPs. The critical one is **`IRP_MJ_PNP`** (major `0x1B` = 27) **`IRP_MN_START_DEVICE`** (minor `0`). In the **WUDF Operational** log this is **`(27, 0)`**. If a **lower driver** completes it with failure, the device **fails to start → error 10**.

### 3.4 UMDF / WUDF (how MTP runs)

Phone MTP is a **user-mode driver** (UMDF 2.x) hosted by **`WUDFHost.exe`**. Kernel reflector **`WUDFRd.sys`** forwards requests. If a driver DLL were blocked by code integrity / signing, load would fail. Here **load succeeded, then START_DEVICE was rejected below** — that cleanly **rules out signing / WDAC / VBS** and points at a **kernel filter**.

### 3.5 Error-code cheat sheet

| Code | Meaning | In this case |
|---|---|---|
| Device Manager error 10 | `CM_PROB_FAILED_START` | Stack failed during start |
| `0xC0000001` | `STATUS_UNSUCCESSFUL` | Lower filter actively refused START_DEVICE |
| `0xC00000BB` | `STATUS_NOT_SUPPORTED` | Normal placeholder when WUDF forwards an IRP; **not an error** |
| `0xC0000120` | `STATUS_CANCELLED` | Cancelled power/wake IRP; common and harmless |

---

## Investigation (layer-by-layer exclusion)

Core idea: start with the **most likely / easiest to verify** hypotheses and disprove them until one cause remains. All checks below are read-only.

### Step 0: Challenge the initial “DMA Protection” claim

An earlier assistant claimed `Kernel DMA Protection` `DeviceEnumerationPolicy=1`. Two hard problems:

1. **Concept**: Kernel DMA Protection applies to **Thunderbolt/USB4 PCIe devices with DMA**. Ordinary USB sticks and phone MTP sit on a USB host controller and **have no DMA**. That policy does not target them.
2. **Measurement**:

```powershell
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\Kernel DMA Protection" /v DeviceEnumerationPolicy
# Observed = 0x0 (allow all), not 1
```

### Step 1: Rule out classic “disable USB storage” policy

```powershell
reg query "HKLM\SYSTEM\CurrentControlSet\Services\USBSTOR" /v Start          # = 0x3 normal (4 = disabled)
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices" /s   # key missing
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" /s # key missing
reg query "HKLM\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies" /s         # key missing
```

→ **Classic Windows policies excluded.**

### Step 2: Rule out Microsoft Defender Device Control

```powershell
Get-MpComputerStatus | Select DeviceControlState   # = Disabled
Get-MpPreference     | Select AttackSurfaceReductionRules_Ids   # empty (no ASR)
```

→ **Defender Device Control and ASR excluded.**

### Step 3: Confirm the failure is MTP and capture the error code

```powershell
Get-PnpDevice -Class WPD -PresentOnly | Where Status -ne 'OK' |
    Select Status, ConfigManagerErrorCode, FriendlyName, InstanceId
# MTP USB Device → CM_PROB_FAILED_START

pnputil /enum-devices /instanceid "USB\VID_2717&PID_FF48&MI_00\..."
# Problem Code: 10 (0x0A)  /  Problem Status: 0xC0000001  /  Driver: wpdmtp.inf
```

### Step 4: A security stack was rolled out that week (VBS/HVCI/WDAC) — verify whether it is the cause

```powershell
Get-CimInstance Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard |
  Select VirtualizationBasedSecurityStatus, SecurityServicesRunning,
         CodeIntegrityPolicyEnforcementStatus, UsermodeCodeIntegrityPolicyEnforcementStatus
# VBS=2 (running), HVCI running, WDAC kernel enforce=2, user-mode enforce=0 (important)
```

This step is easy to misread: VBS/HVCI/WDAC are on and were enabled that week. **User-mode CI enforce = 0**, so it **will not block user-mode DLLs**. Keep looking for direct evidence.

### Step 5: Decisive evidence — enable WUDF logs, reproduce, read the failure sequence

WUDF Operational logging is off by default. Enable it (admin), then re-enumerate:

```powershell
wevtutil sl "Microsoft-Windows-DriverFrameworks-UserMode/Operational" /e:true
pnputil /remove-device "<MTP instance ID>"
pnputil /scan-devices
```

Key sequence (excerpt):

```
2010  UMDF host successfully loaded MTP driver
2005  Loaded wpdmtpdr.dll / WUDFx.dll / ADVAPI32 ... all success
2006  UMDF host successfully loaded level 0 driver
2107  Error: PnP operation (27,0) completed by lower driver with 0xC0000001   ← actual failure
2103  Error: (27,0) ended with 0xC0000001
```

**Read**: user-mode drivers **all loaded** (rules out signing/WDAC/VBS/ACG). Failure is **`IRP_MN_START_DEVICE (27,0)` rejected by a kernel lower driver.** → **The culprit is a kernel filter.**

### Step 6: Identify the kernel filter (confirmation)

```powershell
# Who is attached as a class filter on WPD/USB/USBDevice?
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{eec5ad98-8080-425f-922a-dabf3de3f69a}" |
    Select UpperFilters, LowerFilters
# Result: WPD LowerFilters = hdlpdbk   ← DLP device-block filter
# USB / USBDevice UpperFilters also = hdlpdbk

# Which DLP product?
Get-Service | Where { $_.DisplayName -match 'Trellix|McAfee|Data Loss' }
# TrellixDLPAgentService (running), masvc, macmnsvc, mfemms, mfevtp ...
Get-CimInstance Win32_SystemDriver | Where Name -match 'hdlp'
# hdlpflt / hdlphook / hdlpctrl / hdlpevnt / hdlpdbk ...
```

→ **Root cause: Trellix DLP uses `hdlpdbk` for WPD/USB device control and blocks MTP at START_DEVICE.**

---

## How DLP “disables” MTP

1. IT configures **DLP Device Control / Plug-and-Play Device Rules** in ePO to **block** portable devices/MTP (and possibly USB storage).
2. Trellix Agent (`masvc`/`macmnsvc`) **pulls policy** to the machine.
3. DLP already registered kernel filter **`hdlpdbk`** on **WPD / USB / USBDevice**.
4. When MTP enumerates and reaches **`IRP_MN_START_DEVICE`**, the request hits `hdlpdbk`; policy says **deny**, so START IRP fails with **`0xC0000001`**.
5. User-mode MTP still loads, but the device **never starts → error 10**, so Explorer never shows the phone.

**Why no Windows policy keys?** This is **not** Windows policy. It is DLP’s **own kernel filter + policy engine**. It leaves traces only on class filters and DLP services — which is why **`UpperFilters` / `LowerFilters`** must be inspected.

---

## Can you locally “temporarily unblock” it?

**No clean, durable local workaround. Do not bypass it.** Reasons:

1. **Tamper protection**: `mfevtp` (Trellix Validation Trust Protection) + `mfemms` protect DLP. Ordinary admin `Stop-Service TrellixDLPAgentService` / deleting `hdlpdbk` filters is usually **denied**.
2. **Central policy restores**: Trellix Agent periodically syncs from ePO; **local edits are overwritten**.
3. **Compliance**: DLP is corporate data-loss control. Forcing a bypass is typically **logged/alerted** and is a policy violation.

> Removing WPD `LowerFilters=hdlpdbk` could theoretically start MTP, but given the three points above it is **neither durable nor compliant**. This document **does not provide bypass steps** — only the mechanism.

### Correct path: ask IT / security for a DLP exception

Send something this precise:

> Machine `YOUR_MACHINE_NAME`, user `YOUR_DOMAIN\YOUR_USER`. Trellix DLP Endpoint **Plug-and-Play / Removable Storage Device Control** is blocking phone MTP (portable device) file transfer: device `USB\VID_2717&PID_FF48&MI_00` (standard MTP, WPD class), Device Manager error 10 / `0xC0000001`, intercepted by kernel filter `hdlpdbk` at `IRP_MN_START_DEVICE`. Please add an exception for this user/machine or for MTP portable devices (or temporarily disable the matching PnP Device Rule).

---

## Tech stack / components and tools

- **OS**: Windows 11 (Build 26100), PowerShell 5.1
- **Diagnostic Windows tools**: `reg`, `pnputil`, `wevtutil`, `Get-PnpDevice` / `Get-PnpDeviceProperty`, `Get-CimInstance` (`Win32_DeviceGuard` / `Win32_SystemDriver`), `Get-MpComputerStatus` / `Get-MpPreference`, event channels `Microsoft-Windows-DriverFrameworks-UserMode/Operational`, `Microsoft-Windows-Kernel-PnP/Configuration`, `Microsoft-Windows-CodeIntegrity/Operational`
- **Security components under diagnosis**: Trellix Agent (`masvc`/`macmnsvc`/`mfemms`/`mfevtp`), **Trellix DLP Endpoint** (`TrellixDLPAgentService` + `hdlp*` kernel drivers, core `hdlpdbk`), Defender/MDE, leftover McAfee modules
- **No third-party dependencies**; admin rights only for the optional “enable WUDF logging” step

---

## How to run / use

1. Open PowerShell (most checks work without elevation).
2. Run the read-only diagnostic script:

```powershell
powershell -ExecutionPolicy Bypass -File .\diagnose-usb-mtp.ps1
```

3. Use the script’s closing hints:
   - Items 1/2/3 default or missing, but devices are still blocked → not a built-in Windows policy;
   - Item 6 shows non-Windows filters such as `hdlpdbk` on WPD/USB, and item 7 shows Trellix/McAfee DLP → treat as **enterprise DLP device control**.
4. (Optional, admin) To see the `(27,0)/0xC0000001` kernel failure sequence, enable WUDF logs and re-plug:

```powershell
wevtutil sl "Microsoft-Windows-DriverFrameworks-UserMode/Operational" /e:true
# Re-plug the phone / or pnputil /remove-device + pnputil /scan-devices
# Event Viewer → Applications and Services Logs → Microsoft → Windows → DriverFrameworks-UserMode → Operational
# Restore when done:
wevtutil sl "Microsoft-Windows-DriverFrameworks-UserMode/Operational" /e:false
```

---

## Reusable one-shot commands

```powershell
# A. Non-Windows class filters (most important)
'{eec5ad98-8080-425f-922a-dabf3de3f69a}','{36fc9e60-c465-11cf-8056-444553540000}','{88bae032-5a81-49f0-bc3d-a4ff138216d6}' |
  % { $p="HKLM:\SYSTEM\CurrentControlSet\Control\Class\$_"; "$_  U=$((gp $p).UpperFilters -join ',')  L=$((gp $p).LowerFilters -join ',')" }

# B. DLP / endpoint agents
Get-Service | ? { $_.DisplayName -match 'Trellix|McAfee|Data Loss|Device Control' } | ft Status,Name,DisplayName

# C. DLP kernel drivers
Get-CimInstance Win32_SystemDriver | ? Name -match 'hdlp|mfe' | ft State,Name,DisplayName

# D. Failing device error codes
Get-PnpDevice -Class WPD -PresentOnly | ? Status -ne 'OK' | ft Status,ConfigManagerErrorCode,FriendlyName,InstanceId
```

---

## Lessons

1. **Do not follow a “sounds expert” hypothesis**: DMA Protection sounds advanced, but the value was 0 and conceptually it does not cover ordinary USB/MTP. **Measure first.**
2. **Layered exclusion beats intuition**: Windows policy → Defender → VBS/WDAC → kernel filters, easy-to-hard.
3. **Read the error layer**: user-mode load OK + START_DEVICE fail = problem below in the kernel stack; that instantly drops a large signing/CI class of bugs.
4. **On managed PCs, “device mysteriously banned” → check class `UpperFilters`/`LowerFilters` and DLP/EDR agents**; this control is not stored in standard Windows policy keys.
5. **The fix is process (IT exception), not a local hack**: centrally managed, tamper-protected DLP is neither durable nor allowed to bypass locally.

---

## File structure

```text
.
├─ README.md                 # This document: root cause, theory, method + ADB file manager
├─ diagnose-usb-mtp.ps1      # Read-only diagnostic; replays the layered checks
├─ MtpAdbFileManager.ps1     # GUI phone file manager (WinForms + adb), two-way drag-and-drop
├─ build-exe.ps1             # Compile the .ps1 with ps2exe into 手机文件管理器.exe
├─ 启动手机文件管理器.bat      # Double-click launcher without compiling (-Sta required for drag-drop)
├─ usb cmd.txt               # ADB file-transfer command reference (push/pull/ls/mkdir/rm)
└─ usb.txt                   # Extra ADB / registry notes
```

Temporary admin scripts used during the live investigation (`mtp_fix.ps1` to reset MTP, `mtp_diag.ps1` to capture WUDF logs) lived under `%USERPROFILE%` and are not part of this repo.

---

## ADB phone file manager (MTP alternative)

MTP (WPD class) is blocked in the kernel, so this tool uses a **USB channel that is typically not blocked** — **ADB** — and wraps ADB in a GUI for Explorer-like drag-and-drop.

### 12.1 Why ADB can work when MTP cannot

| Dimension | MTP (blocked) | ADB (this tool) |
|---|---|---|
| Device class | **WPD** `{eec5ad98-...}`, `LowerFilters=hdlpdbk` | **Android ADB Interface**, WinUSB vendor interface |
| Data path | Explorer ↔ `wpdmtpdr.dll` (UMDF) | `adb.exe` daemon ↔ phone `adbd`, USB bulk endpoints |
| Hit by DLP WPD rules | **Yes** (START_DEVICE `0xC0000001`) | **Usually no** (outside WPD class filters) |
| Prerequisite | Phone set to “Transfer files (MTP)” | USB debugging enabled and this PC authorized |

> Depends on local DLP targeting **WPD/storage only**. If IT also configures USB/USBDevice `UpperFilters=hdlpdbk` to block ADB, ADB will not see a device — the tool reports “no device found,” and you still need an IT exception (Section 6). This tool does not bypass or alter any security component; it only calls standard `adb`.

### 12.2 Features

- **Device management**: auto-discover connected devices (`device` / `unauthorized` / `offline`), switch via dropdown, one-click refresh.
- **Browse**: detail list of name / size / mtime / type (folders first; folder/file icons; symlink detection).
- **Navigation**: **double-click a folder** (or select + `Enter`; `Backspace` goes up). Address bar + Go is for typed paths. Shortcuts: parent, home (`/sdcard`), DCIM, refresh.
- **Upload (PC → phone)**:
  - Drag files/folders from Explorer into the window → `adb push` into the current directory;
  - or use Upload file / Upload folder.
- **Download (phone → PC)**:
  - Drag items from the list to Explorer/desktop → `adb pull` (stage in a temp dir, then let Explorer copy);
  - or Download to PC and pick a folder.
- **File ops**: New folder (`mkdir -p`), Delete (`rm -rf`, confirm twice).
- **Transfer UX**: separate progress dialog with per-file logs, **cancel anytime** (kills adb), main window stays responsive.
- **Robustness**: spaces and non-ASCII names handled (UTF-8); commands time out so an offline device does not hang; startup errors pop a dialog.

### 12.3 Stack and dependencies

- **Windows PowerShell 5.1 + WinForms / GDI+** (inbox, **no install**). Script saved **UTF-8 with BOM** for PS 5.1 parsing.
- **adb** (Android Platform-Tools): often bundled with **scrcpy (winget)** at
  `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Genymobile.scrcpy_*\scrcpy-win64-*\adb.exe`.
  The tool probes PATH / Android SDK / scrcpy; override with `-Adb`.
- **Drag-drop / clipboard need STA**, so start with `-Sta` (the `.bat` already does).

### 12.4 How to run

**Phone (once)**: Settings → About phone → tap Build number 7 times → enable USB debugging → connect USB → tap **Allow** on “Allow USB debugging?”

Start (pick one):

```powershell
# A (recommended): compiled self-contained exe
手机文件管理器.exe

# B: no-compile launcher
启动手机文件管理器.bat

# C: command line (must use -Sta)
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\MtpAdbFileManager.ps1

# Optional: pin adb / start directory
powershell ... -File .\MtpAdbFileManager.ps1 -Adb "D:\platform-tools\adb.exe" -StartDir /sdcard/Download
```

Daily use:

1. Pick the phone in the top dropdown (status should be `device`; if `unauthorized`, allow on the phone then Refresh devices).
2. Browse: **double-click folders** (or `Enter` / `Backspace`).
3. **Upload**: drag PC files/folders into the list (or Upload file / Upload folder).
4. **Download**: drag list items to desktop/Explorer (or Download to PC).

### 12.5 Known limits

- Drag-out (phone → Explorer) **pulls to `%TEMP%\adbdrag_*` first**, then Explorer copies. Large files have a short “prepare” delay on drag start. Prefer Download to PC (progress + cancel). Temp dirs older than 2 hours are cleaned on next start.
- Progress is per-file completion, not byte percent (indeterminate busy bar). **Errors are shown in full.**
- Standard `adb` only — **no DLP/security bypass**. If ADB is also blocked, use the IT exception path in Section 6.

### 12.6 Build an exe (`build-exe.ps1`)

`手机文件管理器.exe` is a **self-contained** build of `MtpAdbFileManager.ps1` via [`ps2exe`](https://www.powershellgallery.com/packages/ps2exe) (script embedded, `-STA` for drag-drop, `-noConsole`). After editing the `.ps1`, rebuild:

```powershell
# Online compile (first run installs ps2exe for the current user)
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-exe.ps1

# If the network needs a proxy, set HTTP_PROXY/HTTPS_PROXY then add -Proxy
$env:HTTPS_PROXY = 'http://YOUR_PROXY_HOST:PORT'
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-exe.ps1 -Proxy
```

Equivalent:

```powershell
Install-Module ps2exe -Scope CurrentUser            # first time only
Invoke-ps2exe -InputFile .\MtpAdbFileManager.ps1 -OutputFile .\手机文件管理器.exe -noConsole -STA -title "手机文件管理器 (ADB)"
```

Compile itself is **offline** (inbox .NET Framework `csc.exe` at `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`). Only installing the `ps2exe` module needs network (or a proxy).
