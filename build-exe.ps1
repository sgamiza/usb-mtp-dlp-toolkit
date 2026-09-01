<#
.SYNOPSIS
    把 MtpAdbFileManager.ps1 编译打包成自包含的 exe（手机文件管理器.exe）。
.DESCRIPTION
    使用 ps2exe 模块（首次会自动从 PowerShell Gallery 安装到当前用户）。
    生成的 exe 已内嵌脚本、以 -STA 单元线程运行（拖放必需）、无控制台窗口。
    每次修改 MtpAdbFileManager.ps1 后重跑本脚本即可重新生成 exe。
.PARAMETER Proxy
    若直接联网失败，加 -Proxy 走公司代理重试。
    代理地址从环境变量 HTTPS_PROXY/HTTP_PROXY 读取，或用 -ProxyUrl 显式指定。
.PARAMETER ProxyUrl
    代理地址，形如 http://YOUR_PROXY_HOST:PORT。默认读取 HTTPS_PROXY/HTTP_PROXY 环境变量。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-exe.ps1
    $env:HTTPS_PROXY = 'http://YOUR_PROXY_HOST:PORT'
    powershell -ExecutionPolicy Bypass -File .\build-exe.ps1 -Proxy
    powershell -ExecutionPolicy Bypass -File .\build-exe.ps1 -Proxy -ProxyUrl 'http://YOUR_PROXY_HOST:PORT'
#>
param(
    [switch]$Proxy,
    [string]$ProxyUrl = $(if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { $env:HTTP_PROXY })
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($Proxy) {
    if ([string]::IsNullOrWhiteSpace($ProxyUrl)) {
        throw "已指定 -Proxy 但未提供代理地址：请设置 HTTPS_PROXY 环境变量或用 -ProxyUrl 'http://YOUR_PROXY_HOST:PORT'"
    }
    $env:HTTP_PROXY = $ProxyUrl
    $env:HTTPS_PROXY = $ProxyUrl
    Write-Host "已启用代理 $env:HTTPS_PROXY"
}

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "未检测到 ps2exe，正在安装到当前用户…"
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        $p = @{ Name = 'NuGet'; MinimumVersion = '2.8.5.201'; Force = $true; Scope = 'CurrentUser' }
        if ($Proxy) { $p['Proxy'] = $env:HTTPS_PROXY }
        Install-PackageProvider @p | Out-Null
    }
    $m = @{ Name = 'ps2exe'; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true }
    if ($Proxy) { $m['Proxy'] = $env:HTTPS_PROXY }
    Install-Module @m
}

Import-Module ps2exe

$src = Join-Path $PSScriptRoot 'MtpAdbFileManager.ps1'
$out = Join-Path $PSScriptRoot '手机文件管理器.exe'

Write-Host "正在编译: $src  ->  $out"
Invoke-ps2exe -InputFile $src -OutputFile $out -noConsole -STA `
    -title '手机文件管理器 (ADB)' `
    -description 'MTP 替代方案：用 ADB 实现手机⇄电脑文件传输' `
    -company 'test98_usb' -product '手机文件管理器(ADB)' -version '1.0.0'

if (Test-Path $out) {
    $sz = '{0:N0} KB' -f ((Get-Item $out).Length / 1KB)
    Write-Host "完成！生成 $out （$sz）。双击即可运行。" -ForegroundColor Green
}
else {
    throw "编译未生成 exe，请检查上面的错误。"
}
