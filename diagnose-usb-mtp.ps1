<#
.SYNOPSIS
    USB / MTP 被禁用根因诊断脚本（只读，不修改系统）。

.DESCRIPTION
    逐层排除式诊断：从"传统禁用 U 盘"的 Windows 策略，一直查到内核设备类过滤驱动，
    最终定位是否为第三方 DLP（数据防泄漏）设备控制在内核层拦截 USB/MTP。

    本脚本全部为只读查询，不需要管理员权限即可运行大部分检查；
    个别项（如启用 WUDF 日志）需要管理员，脚本会跳过并提示。

.NOTES
    适用：Windows 10/11。配套文档见同目录 README.md。
#>

$ErrorActionPreference = 'SilentlyContinue'

# 确保中文在任意控制台都能正确显示（避免代码页非 UTF-8 时输出乱码）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; chcp 65001 > $null } catch {}

function Section($t) { Write-Host "`n========== $t ==========" -ForegroundColor Cyan }

# 已知设备类 GUID 速查
$ClassGuids = @{
    '{eec5ad98-8080-425f-922a-dabf3de3f69a}' = 'WPD (便携设备/MTP)'
    '{36fc9e60-c465-11cf-8056-444553540000}' = 'USB (USB 控制器/集线器)'
    '{88bae032-5a81-49f0-bc3d-a4ff138216d6}' = 'USBDevice (USB 设备)'
    '{4d36e967-e325-11ce-bfc1-08002be10318}' = 'DiskDrive (磁盘驱动器)'
    '{71a27cdd-812a-11d0-bec7-08002be2092f}' = 'Volume (卷)'
}

Section '1. Kernel DMA Protection 策略（防 Thunderbolt/USB4 DMA 攻击，与普通 U 盘无关）'
$dma = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Kernel DMA Protection' -Name DeviceEnumerationPolicy
if ($dma) { "DeviceEnumerationPolicy = $($dma.DeviceEnumerationPolicy)  (0=允许全部, 1=仅已有驱动, 2=阻止全部)" }
else { '未配置（默认允许）' }

Section '2. 传统"禁用 USB 存储"相关 Windows 策略'
$usbstor = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name Start).Start
"USBSTOR\Start = $usbstor  (3=正常按需启动, 4=被禁用)"
foreach ($k in @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions',
    'HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Device Control')) {
    "{0,-75} : {1}" -f $k, $(if (Test-Path $k) { '存在(需细查)' } else { '不存在' })
}

Section '3. Microsoft Defender 设备控制状态'
$mp = Get-MpComputerStatus
if ($mp) { "DeviceControlState = $($mp.DeviceControlState)" } else { 'Defender 不可用' }

Section '4. Device Guard / VBS / HVCI / WDAC 状态'
$dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard
if ($dg) {
    "VBS 状态(2=运行)              : $($dg.VirtualizationBasedSecurityStatus)"
    "已配置安全服务(1=CG,2=HVCI)   : $($dg.SecurityServicesConfigured -join ',')"
    "运行中安全服务               : $($dg.SecurityServicesRunning -join ',')"
    "WDAC 内核强制(2=强制)        : $($dg.CodeIntegrityPolicyEnforcementStatus)"
    "WDAC 用户态强制(0=未强制)    : $($dg.UsermodeCodeIntegrityPolicyEnforcementStatus)"
}

Section '5. 当前有问题的便携设备(WPD)及错误码'
Get-PnpDevice -Class WPD -PresentOnly | Where-Object { $_.Status -ne 'OK' } |
    Select-Object Status, ConfigManagerErrorCode, FriendlyName, InstanceId |
    Format-Table -AutoSize

Section '6. 关键：设备类的过滤驱动 (UpperFilters / LowerFilters)'
Write-Host '第三方 DLP/设备控制通常在这里挂内核过滤驱动来拦截设备启动' -ForegroundColor Yellow
foreach ($g in $ClassGuids.Keys) {
    $p = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$g"
    if (Test-Path $p) {
        $up = (Get-ItemProperty $p).UpperFilters -join ','
        $lo = (Get-ItemProperty $p).LowerFilters -join ','
        "{0}`n  类名        : {1}`n  UpperFilters: {2}`n  LowerFilters: {3}" -f $g, $ClassGuids[$g], $up, $lo
    }
}

Section '7. 第三方 DLP / 端点安全代理（Trellix / McAfee 等）'
$svc = Get-Service | Where-Object {
    $_.Name -match 'Mfe|McAfee|DLP|hdlp|Trellix|epsec|mvision' -or
    $_.DisplayName -match 'McAfee|Trellix|Data Loss|Device Control'
}
if ($svc) { $svc | Select-Object Status, Name, DisplayName | Format-Table -AutoSize }
else { '未发现 DLP/端点安全代理' }

Write-Host "`n--- DLP 内核驱动（hdlp* / mfe*）---" -ForegroundColor Yellow
Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match 'hdlp|mfe|dlp|trellix' } |
    Select-Object State, Name, DisplayName | Format-Table -AutoSize

Section '诊断结论提示'
Write-Host @'
判读要点：
  - 若第 1/2/3 项全部为默认/不存在，但 MTP/USB 仍被禁 → 不是 Windows 自带策略。
  - 若第 6 项里 WPD/USB 类的 Upper/LowerFilters 出现 hdlpdbk（或其它非 Windows 过滤器），
    且第 7 项存在 Trellix/McAfee DLP → 几乎可断定是企业 DLP 设备控制在内核层拦截。
  - 设备管理器错误码 10 + ProblemStatus 0xC0000001 + 用户态驱动加载成功，
    说明失败发生在内核 START_DEVICE 阶段（被下层过滤驱动拒绝），而非签名/代码完整性问题。
'@ -ForegroundColor Green
