<#
.SYNOPSIS
    手机文件管理器（ADB 版）—— 在 MTP 被企业 DLP 封锁时，用 ADB 通道实现手机⇄电脑文件传输。

.DESCRIPTION
    MTP(WPD 设备类) 被 hdlpdbk 在内核层拦截，但 ADB 走的是独立的
    "Android ADB Interface"(WinUSB) USB 通道，通常不在 DLP 的 WPD 过滤范围内。
    本工具把 adb push / pull / ls 封装成图形界面：
      - 打开后直接浏览手机里的文件和文件夹（树状路径 + 文件列表）
      - 从资源管理器把文件/文件夹拖进窗口 = 上传到手机 (adb push)
      - 把列表里的手机文件/文件夹拖到资源管理器/桌面 = 复制到电脑 (adb pull)
      - 另提供 上传 / 下载 / 新建文件夹 / 删除 / 刷新 按钮

.NOTES
    前提：手机已开启「开发者选项 → USB 调试」，并在弹窗里点「允许」此电脑。
    需以 STA 模式运行（拖放/剪贴板要求）。请用同目录的 .bat 启动，或：
        powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\MtpAdbFileManager.ps1
#>
param(
    [string]$Adb,                     # 可手动指定 adb.exe 路径
    [string]$StartDir = '/sdcard'     # 启动时默认进入的手机目录
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 隐藏控制台启动时，未捕获异常会让程序静默退出 —— 用 MessageBox 弹出来便于排查
trap {
    try {
        [System.Windows.Forms.MessageBox]::Show(
            ($_.Exception.Message + "`n`n" + $_.ScriptStackTrace),
            "程序出错", 'OK', 'Error') | Out-Null
    }
    catch {}
    break
}

# ============================================================================
#  一、adb 定位与调用层
# ============================================================================

function Resolve-AdbPath {
    param([string]$Hint)
    $candidates = @()
    if ($Hint) { $candidates += $Hint }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += @(
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:ProgramFiles\platform-tools\adb.exe",
        "${env:ProgramFiles(x86)}\platform-tools\adb.exe"
    )
    # scrcpy(winget) 自带的 adb
    $wingetRoot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $wingetRoot) {
        $candidates += (Get-ChildItem -Path $wingetRoot -Recurse -Filter adb.exe -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }
    return $null
}

$script:AdbPath = Resolve-AdbPath -Hint $Adb
if (-not $script:AdbPath) {
    [System.Windows.Forms.MessageBox]::Show(
        "未找到 adb.exe。`n请安装 Android Platform-Tools 或 scrcpy，或用 -Adb 参数指定 adb.exe 路径。",
        "缺少 adb", 'OK', 'Error') | Out-Null
    return
}

function Quote-Arg([string]$s) { '"' + ($s -replace '"', '\"') + '"' }

# 把 host 端路径里的反斜杠保留、双引号转义，用于 push/pull 的本地参数
function Quote-Local([string]$s) { Quote-Arg $s }

# 设备端 shell 单引号转义：' -> '\''
function Quote-RemoteShell([string]$s) { "'" + ($s -replace "'", "'\''") + "'" }

# 同步执行一条 adb 命令，捕获 stdout/stderr（带超时，避免设备离线时卡死）
function Invoke-Adb {
    param([string]$Arguments, [int]$TimeoutMs = 60000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:AdbPath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $soTask = $p.StandardOutput.ReadToEndAsync()
    $seTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch {}
        return [pscustomobject]@{ ExitCode = -999; StdOut = $soTask.Result; StdErr = "命令超时（${TimeoutMs}ms）。设备可能离线。" }
    }
    [void]$p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $soTask.Result; StdErr = $seTask.Result }
}

# 返回设备列表：@( @{Serial;State;Model} )
function Get-AdbDevices {
    $r = Invoke-Adb "devices -l" 15000
    $list = @()
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        if ($line -match '^(\S+)\s+(device|unauthorized|offline|no permissions)\b(.*)$') {
            $serial = $matches[1]
            $state = $matches[2]
            $rest = $matches[3]
            if ($serial -eq 'List') { continue }
            $model = ''
            if ($rest -match 'model:(\S+)') { $model = $matches[1] -replace '_', ' ' }
            $list += [pscustomobject]@{ Serial = $serial; State = $state; Model = $model }
        }
    }
    return $list
}

# ============================================================================
#  二、远程目录列举
# ============================================================================

function Format-Size {
    param([Nullable[Int64]]$Bytes)
    if ($null -eq $Bytes) { return '' }
    if ($Bytes -lt 1024) { return "$Bytes B" }
    $u = 'KB', 'MB', 'GB', 'TB'; $i = -1; $v = [double]$Bytes
    do { $v /= 1024; $i++ } while ($v -ge 1024 -and $i -lt 3)
    return ('{0:N1} {1}' -f $v, $u[$i])
}

function Join-RemotePath {
    param([string]$Dir, [string]$Name)
    if ($Dir -eq '/') { return "/$Name" }
    return ($Dir.TrimEnd('/')) + '/' + $Name
}

function Get-ParentPath {
    param([string]$Dir)
    $d = $Dir.TrimEnd('/')
    if (-not $d) { return '/' }
    $idx = $d.LastIndexOf('/')
    if ($idx -le 0) { return '/' }
    return $d.Substring(0, $idx)
}

# 在手机上权威判断某路径是否为目录（不依赖 ls 解析），返回 $true/$false
function Test-RemoteIsDir {
    param([string]$Serial, [string]$Path)
    $q = Quote-RemoteShell $Path
    $r = Invoke-Adb ("-s " + (Quote-Arg $Serial) + " shell " + (Quote-Arg "[ -d $q ] && echo __ISDIR__")) 15000
    return ($r.StdOut -match '__ISDIR__')
}

# 列出远程目录，返回 @( @{Name;IsDir;IsLink;Size;Modified} )，目录在前
function Get-RemoteListing {
    param([string]$Serial, [string]$Dir)
    $qDir = Quote-RemoteShell $Dir

    # 1) 权威的名字 + 类型（-1ap：一行一个、含隐藏、目录带尾斜杠；能正确处理含空格的名字）
    $rNames = Invoke-Adb ("-s " + (Quote-Arg $Serial) + " shell " + (Quote-Arg "ls -1ap $qDir"))
    $items = @{}
    $order = New-Object System.Collections.Generic.List[object]
    $errText = ''
    foreach ($raw in ($rNames.StdOut -split "`r?`n")) {
        $n = $raw.TrimEnd("`r")
        if (-not $n) { continue }
        if ($n -match 'No such file or directory|Permission denied|Not a directory') { $errText = $n; continue }
        if ($n -eq './' -or $n -eq '../' -or $n -eq '.' -or $n -eq '..') { continue }
        $isDir = $n.EndsWith('/')
        $name = if ($isDir) { $n.Substring(0, $n.Length - 1) } else { $n }
        if (-not $name) { continue }
        $obj = [pscustomobject]@{ Name = $name; IsDir = $isDir; IsLink = $false; Size = $null; Modified = '' }
        if (-not $items.ContainsKey($name)) {
            $items[$name] = $obj
            $order.Add($obj)
        }
    }
    if ($rNames.StdErr -and $order.Count -eq 0 -and -not $errText) {
        $errText = ($rNames.StdErr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
    }

    # 2) 用 ls -al 补充 类型(权威靠权限位 d) / 大小 / 修改时间
    #    （toybox: drwx... 2 owner group SIZE YYYY-MM-DD HH:MM[:SS] name；兼容秒/时区/链接）
    $rDetail = Invoke-Adb ("-s " + (Quote-Arg $Serial) + " shell " + (Quote-Arg "ls -al $qDir"))
    foreach ($raw in ($rDetail.StdOut -split "`r?`n")) {
        $line = $raw.TrimEnd("`r")
        if ($line -match '^([bcdlpso\-][rwxsStT\-]{9})[\.\+@]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:\s+[+\-]\d{4})?)\s+(.+)$') {
            $perm = $matches[1]; $size = [int64]$matches[2]; $modified = $matches[3]; $nm = $matches[4]
            $isLink = $perm[0] -eq 'l'
            if ($isLink -and $nm -match '^(.*?) -> ') { $nm = $matches[1] }
            if ($items.ContainsKey($nm)) {
                $items[$nm].Size = $size
                $items[$nm].Modified = $modified
                if ($perm[0] -eq 'd') { $items[$nm].IsDir = $true }   # 权限位 d 是目录的权威依据
                if ($isLink) { $items[$nm].IsLink = $true }
            }
        }
    }

    $result = @($order | Sort-Object @{Expression = { -not $_.IsDir } }, @{Expression = { $_.Name }; Ascending = $true })
    return [pscustomobject]@{ Items = $result; Error = $errText }
}

# ============================================================================
#  三、传输（push / pull）—— 带进度对话框，可取消，UI 不卡死
# ============================================================================

$script:TransferScript = {
    param($AdbPath, $Ops, $Queue, $State)
    foreach ($op in $Ops) {
        if ($State['Cancel']) { $Queue.Enqueue("[已取消]"); break }
        $Queue.Enqueue("==> " + $op.Desc)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $AdbPath
        $psi.Arguments = $op.Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        try { [void]$p.Start() } catch { $Queue.Enqueue("启动 adb 失败: $($_.Exception.Message)"); continue }
        $State['Proc'] = $p
        while (-not $p.StandardOutput.EndOfStream) {
            if ($State['Cancel']) { try { $p.Kill() } catch {}; break }
            $line = $p.StandardOutput.ReadLine()
            if ($null -ne $line -and $line.Trim()) { $Queue.Enqueue($line.Trim()) }
        }
        $err = $p.StandardError.ReadToEnd()
        [void]$p.WaitForExit()
        $State['Proc'] = $null
        if ($err) {
            foreach ($el in ($err -split "`r?`n")) { if ($el.Trim()) { $Queue.Enqueue($el.Trim()) } }
        }
        if ($p.ExitCode -ne 0 -and -not $State['Cancel']) { $Queue.Enqueue("[退出码 $($p.ExitCode)]") }
    }
    $Queue.Enqueue("<<DONE>>")
}

# $Ops: @( @{ Arguments=...; Desc=... } )；返回 $true=全部成功完成（未取消）
function Invoke-AdbTransfer {
    param([System.Collections.IEnumerable]$Ops, [string]$Title = "正在传输…")

    $opsArr = @($Ops)
    if ($opsArr.Count -eq 0) { return $true }

    $queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    $state = [hashtable]::Synchronized(@{ Cancel = $false; Proc = $null })

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(620, 380)
    $form.StartPosition = 'CenterParent'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.FormBorderStyle = 'FixedDialog'

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "准备中…"
    $lbl.AutoEllipsis = $true
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size = New-Object System.Drawing.Size(580, 20)
    $form.Controls.Add($lbl)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 30
    $bar.Location = New-Object System.Drawing.Point(12, 36)
    $bar.Size = New-Object System.Drawing.Size(580, 18)
    $form.Controls.Add($bar)

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = 'Vertical'
    $log.Font = New-Object System.Drawing.Font('Consolas', 9)
    $log.Location = New-Object System.Drawing.Point(12, 60)
    $log.Size = New-Object System.Drawing.Size(580, 250)
    $log.Anchor = 'Top,Left,Right,Bottom'
    $form.Controls.Add($log)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "取消"
    $btn.Location = New-Object System.Drawing.Point(505, 316)
    $btn.Size = New-Object System.Drawing.Size(87, 26)
    $btn.Anchor = 'Bottom,Right'
    $form.Controls.Add($btn)

    $btn.Add_Click({
            if ($script:__transferDone) { $form.Close(); return }
            $state['Cancel'] = $true
            $p = $state['Proc']
            if ($p) { try { $p.Kill() } catch {} }
            $btn.Enabled = $false
        })

    # 中途关闭窗口：先取消后台传输，避免 EndInvoke 卡住
    $form.Add_FormClosing({
            if (-not $script:__transferDone) {
                $state['Cancel'] = $true
                $p = $state['Proc']
                if ($p) { try { $p.Kill() } catch {} }
            }
        })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:TransferScript).AddArgument($script:AdbPath).AddArgument($opsArr).AddArgument($queue).AddArgument($state)
    $handle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 120
    $timer.Add_Tick({
            while ($queue.Count -gt 0) {
                $msg = $queue.Dequeue()
                if ($msg -eq '<<DONE>>') {
                    $script:__transferDone = $true
                    continue
                }
                if ($msg -like '==> *') { $lbl.Text = $msg.Substring(4) }
                $log.AppendText($msg + "`r`n")
            }
            if ($script:__transferDone) {
                $timer.Stop()
                $bar.Style = 'Continuous'
                $bar.Value = 100
                $lbl.Text = if ($state['Cancel']) { "已取消" } else { "全部完成" }
                $btn.Text = "关闭"
                $btn.Enabled = $true
            }
        })
    $script:__transferDone = $false
    $timer.Start()

    [void]$form.ShowDialog()

    $timer.Stop(); $timer.Dispose()
    try { $ps.EndInvoke($handle) } catch {}
    $ps.Dispose(); $rs.Close(); $rs.Dispose()
    return (-not $state['Cancel'])
}

# 构造一条 push 操作（本地 -> 手机当前目录）
function New-PushOp {
    param([string]$Serial, [string]$LocalPath, [string]$RemoteDir)
    $name = Split-Path $LocalPath -Leaf
    $remoteFull = Join-RemotePath $RemoteDir $name
    [pscustomobject]@{
        Arguments = ("-s " + (Quote-Arg $Serial) + " push " + (Quote-Local $LocalPath) + " " + (Quote-Arg $remoteFull))
        Desc      = "上传: $name  ->  $RemoteDir"
    }
}

# 构造一条 pull 操作（手机 -> 本地目录）
function New-PullOp {
    param([string]$Serial, [string]$RemotePath, [string]$LocalDir)
    $name = Split-Path $RemotePath -Leaf
    [pscustomobject]@{
        Arguments = ("-s " + (Quote-Arg $Serial) + " pull " + (Quote-Arg $RemotePath) + " " + (Quote-Local $LocalDir))
        Desc      = "下载: $name  ->  $LocalDir"
    }
}

# 同步把若干远程项目拉到一个临时目录（供拖出用）。返回本地完整路径数组。
function Invoke-PullToFolder {
    param([string]$Serial, [string[]]$RemotePaths, [string]$LocalDir)
    $results = @()
    foreach ($rp in $RemotePaths) {
        $name = Split-Path $rp -Leaf
        $r = Invoke-Adb ("-s " + (Quote-Arg $Serial) + " pull " + (Quote-Arg $rp) + " " + (Quote-Local $LocalDir)) 600000
        $local = Join-Path $LocalDir $name
        if (Test-Path $local) { $results += $local }
    }
    return $results
}

# ============================================================================
#  四、主窗口
# ============================================================================

$script:CurrentSerial = $null
$script:CurrentDir = $StartDir

# 清理上次遗留的拖出临时目录
Get-ChildItem -Path $env:TEMP -Filter 'adbdrag_*' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-2) } |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

$form = New-Object System.Windows.Forms.Form
$form.Text = "手机文件管理器 (ADB) —— MTP 替代方案"
$form.Size = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(640, 400)

# --- 顶部：设备选择 + 刷新 ---
$lblDev = New-Object System.Windows.Forms.Label
$lblDev.Text = "设备:"
$lblDev.Location = New-Object System.Drawing.Point(12, 15)
$lblDev.AutoSize = $true
$form.Controls.Add($lblDev)

$cboDev = New-Object System.Windows.Forms.ComboBox
$cboDev.DropDownStyle = 'DropDownList'
$cboDev.Location = New-Object System.Drawing.Point(52, 12)
$cboDev.Size = New-Object System.Drawing.Size(320, 24)
$form.Controls.Add($cboDev)

$btnDevRefresh = New-Object System.Windows.Forms.Button
$btnDevRefresh.Text = "刷新设备"
$btnDevRefresh.Location = New-Object System.Drawing.Point(380, 11)
$btnDevRefresh.Size = New-Object System.Drawing.Size(80, 25)
$form.Controls.Add($btnDevRefresh)

# --- 第二行：地址栏 + 导航 ---
$btnUp = New-Object System.Windows.Forms.Button
$btnUp.Text = "↑ 上级"
$btnUp.Location = New-Object System.Drawing.Point(12, 45)
$btnUp.Size = New-Object System.Drawing.Size(64, 25)
$form.Controls.Add($btnUp)

$btnHome = New-Object System.Windows.Forms.Button
$btnHome.Text = "🏠"
$btnHome.Location = New-Object System.Drawing.Point(80, 45)
$btnHome.Size = New-Object System.Drawing.Size(34, 25)
$form.Controls.Add($btnHome)

$txtPath = New-Object System.Windows.Forms.TextBox
$txtPath.Location = New-Object System.Drawing.Point(118, 47)
$txtPath.Size = New-Object System.Drawing.Size(560, 23)
$txtPath.Anchor = 'Top,Left,Right'
$form.Controls.Add($txtPath)

$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = "转到"
$btnGo.Location = New-Object System.Drawing.Point(684, 45)
$btnGo.Size = New-Object System.Drawing.Size(60, 25)
$btnGo.Anchor = 'Top,Right'
$form.Controls.Add($btnGo)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = "刷新"
$btnReload.Location = New-Object System.Drawing.Point(748, 45)
$btnReload.Size = New-Object System.Drawing.Size(60, 25)
$btnReload.Anchor = 'Top,Right'
$form.Controls.Add($btnReload)

# --- 快捷目录 ---
$btnDcim = New-Object System.Windows.Forms.Button
$btnDcim.Text = "DCIM"
$btnDcim.Location = New-Object System.Drawing.Point(812, 45)
$btnDcim.Size = New-Object System.Drawing.Size(64, 25)
$btnDcim.Anchor = 'Top,Right'
$form.Controls.Add($btnDcim)

# --- 中部：文件列表 ---
$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.MultiSelect = $true
$lv.AllowDrop = $true
$lv.Location = New-Object System.Drawing.Point(12, 78)
$lv.Size = New-Object System.Drawing.Size(864, 430)
$lv.Anchor = 'Top,Left,Right,Bottom'
[void]$lv.Columns.Add("名称", 420)
[void]$lv.Columns.Add("大小", 110)
[void]$lv.Columns.Add("修改时间", 170)
[void]$lv.Columns.Add("类型", 120)
$form.Controls.Add($lv)

# 列表小图标（文件夹/文件）
$il = New-Object System.Windows.Forms.ImageList
$il.ImageSize = New-Object System.Drawing.Size(16, 16)
$bmpDir = New-Object System.Drawing.Bitmap 16, 16
$g = [System.Drawing.Graphics]::FromImage($bmpDir)
$g.FillRectangle([System.Drawing.Brushes]::Goldenrod, 1, 5, 14, 9)
$g.FillRectangle([System.Drawing.Brushes]::Khaki, 1, 3, 7, 3)
$g.DrawRectangle([System.Drawing.Pens]::DarkGoldenrod, 1, 5, 13, 8)
$g.Dispose()
$il.Images.Add('dir', $bmpDir)
$bmpFile = New-Object System.Drawing.Bitmap 16, 16
$g = [System.Drawing.Graphics]::FromImage($bmpFile)
$g.FillRectangle([System.Drawing.Brushes]::White, 3, 1, 10, 14)
$g.DrawRectangle([System.Drawing.Pens]::Gray, 3, 1, 9, 13)
$g.DrawLine([System.Drawing.Pens]::Gray, 5, 5, 11, 5)
$g.DrawLine([System.Drawing.Pens]::Gray, 5, 8, 11, 8)
$g.DrawLine([System.Drawing.Pens]::Gray, 5, 11, 9, 11)
$g.Dispose()
$il.Images.Add('file', $bmpFile)
$lv.SmallImageList = $il

# --- 底部按钮栏 ---
$btnUpFile = New-Object System.Windows.Forms.Button
$btnUpFile.Text = "上传文件"
$btnUpFile.Location = New-Object System.Drawing.Point(12, 516)
$btnUpFile.Size = New-Object System.Drawing.Size(82, 28)
$btnUpFile.Anchor = 'Bottom,Left'
$form.Controls.Add($btnUpFile)

$btnUpDir = New-Object System.Windows.Forms.Button
$btnUpDir.Text = "上传文件夹"
$btnUpDir.Location = New-Object System.Drawing.Point(98, 516)
$btnUpDir.Size = New-Object System.Drawing.Size(92, 28)
$btnUpDir.Anchor = 'Bottom,Left'
$form.Controls.Add($btnUpDir)

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = "下载到电脑"
$btnDownload.Location = New-Object System.Drawing.Point(194, 516)
$btnDownload.Size = New-Object System.Drawing.Size(92, 28)
$btnDownload.Anchor = 'Bottom,Left'
$form.Controls.Add($btnDownload)

$btnNewDir = New-Object System.Windows.Forms.Button
$btnNewDir.Text = "新建文件夹"
$btnNewDir.Location = New-Object System.Drawing.Point(290, 516)
$btnNewDir.Size = New-Object System.Drawing.Size(92, 28)
$btnNewDir.Anchor = 'Bottom,Left'
$form.Controls.Add($btnNewDir)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "删除"
$btnDelete.Location = New-Object System.Drawing.Point(386, 516)
$btnDelete.Size = New-Object System.Drawing.Size(70, 28)
$btnDelete.Anchor = 'Bottom,Left'
$form.Controls.Add($btnDelete)

$status = New-Object System.Windows.Forms.StatusStrip
$statusLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLbl.Text = "就绪"
$statusLbl.Spring = $true
$statusLbl.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusLbl)
$form.Controls.Add($status)

function Set-Status([string]$t) { $statusLbl.Text = $t; $status.Refresh() }

# ============================================================================
#  五、行为逻辑
# ============================================================================

function Get-SelectedSerial {
    if ($cboDev.SelectedItem) { return $cboDev.SelectedItem.Tag }
    return $null
}

function Get-SelectedRemoteItems {
    $sel = @()
    foreach ($it in $lv.SelectedItems) {
        $sel += [pscustomobject]@{ Name = $it.Text; IsDir = ($it.ImageKey -eq 'dir'); Tag = $it.Tag }
    }
    return $sel
}

function Refresh-Devices {
    $cboDev.Items.Clear()
    $devs = Get-AdbDevices
    foreach ($d in $devs) {
        $disp = if ($d.Model) { "$($d.Model)  [$($d.Serial)]  ($($d.State))" } else { "$($d.Serial)  ($($d.State))" }
        $entry = New-Object PSObject -Property @{ Display = $disp; Tag = $d.Serial; State = $d.State }
        $entry | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Display } -Force
        [void]$cboDev.Items.Add($entry)
    }
    if ($cboDev.Items.Count -gt 0) {
        $cboDev.SelectedIndex = 0
        Set-Status "发现 $($devs.Count) 台设备"
    }
    else {
        Set-Status "未发现设备。请插入手机、开启『USB 调试』并在手机上点『允许』。"
        $lv.Items.Clear()
    }
}

function Refresh-Listing {
    $serial = Get-SelectedSerial
    if (-not $serial) { return }
    $sel = $cboDev.SelectedItem
    if ($sel -and $sel.State -ne 'device') {
        $lv.Items.Clear()
        if ($sel.State -eq 'unauthorized') {
            Set-Status "设备未授权：请在手机屏幕上点『允许 USB 调试』，然后点『刷新设备』。"
        }
        else {
            Set-Status "设备状态: $($sel.State)，暂不可访问。"
        }
        return
    }
    Set-Status "正在读取 $script:CurrentDir …"
    $form.Cursor = 'WaitCursor'
    try {
        $res = Get-RemoteListing -Serial $serial -Dir $script:CurrentDir
    }
    finally {
        $form.Cursor = 'Default'
    }
    $txtPath.Text = $script:CurrentDir
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($it in $res.Items) {
        $row = New-Object System.Windows.Forms.ListViewItem($it.Name)
        $row.ImageKey = if ($it.IsDir) { 'dir' } else { 'file' }
        $row.Tag = Join-RemotePath $script:CurrentDir $it.Name
        [void]$row.SubItems.Add($(if ($it.IsDir) { '' } else { Format-Size $it.Size }))
        [void]$row.SubItems.Add($it.Modified)
        $type = if ($it.IsLink) { '链接' } elseif ($it.IsDir) { '文件夹' } else { '文件' }
        [void]$row.SubItems.Add($type)
        [void]$lv.Items.Add($row)
    }
    $lv.EndUpdate()
    $dirCount = @($res.Items | Where-Object { $_.IsDir }).Count
    $fileCount = $res.Items.Count - $dirCount
    if ($res.Error) {
        Set-Status "无法打开: $($res.Error)"
    }
    else {
        Set-Status "$script:CurrentDir  —  $dirCount 个文件夹, $fileCount 个文件"
    }
}

function Navigate-To([string]$dir) {
    if (-not $dir) { return }
    $script:CurrentDir = $dir
    Refresh-Listing
}

# 上传一批本地路径到当前目录
function Upload-Paths([string[]]$paths) {
    $serial = Get-SelectedSerial
    if (-not $serial) { [System.Windows.Forms.MessageBox]::Show("请先选择设备。", "提示") | Out-Null; return }
    if (-not $paths -or $paths.Count -eq 0) { return }
    $ops = @()
    foreach ($p in $paths) { $ops += New-PushOp -Serial $serial -LocalPath $p -RemoteDir $script:CurrentDir }
    [void](Invoke-AdbTransfer -Ops $ops -Title "上传到手机")
    Refresh-Listing
}

# 下载选中的远程项目到指定本地目录
function Download-Selected {
    $serial = Get-SelectedSerial
    if (-not $serial) { return }
    $sel = @(Get-SelectedRemoteItems)
    if ($sel.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("请先在列表里选择要下载的文件/文件夹。", "提示") | Out-Null; return }
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "选择保存到电脑的位置"
    if ($fbd.ShowDialog() -ne 'OK') { return }
    $dest = $fbd.SelectedPath
    $ops = @()
    foreach ($s in $sel) { $ops += New-PullOp -Serial $serial -RemotePath $s.Tag -LocalDir $dest }
    [void](Invoke-AdbTransfer -Ops $ops -Title "下载到电脑")
    Set-Status "已下载到 $dest"
}

# ---- 事件绑定 ----

$btnDevRefresh.Add_Click({ Refresh-Devices; Refresh-Listing })
$cboDev.Add_SelectedIndexChanged({
        $serial = Get-SelectedSerial
        if ($serial -ne $script:CurrentSerial) {
            $script:CurrentSerial = $serial
            $script:CurrentDir = $StartDir
        }
        Refresh-Listing
    })

$btnUp.Add_Click({ Navigate-To (Get-ParentPath $script:CurrentDir) })
$btnHome.Add_Click({ Navigate-To '/sdcard' })
$btnDcim.Add_Click({ Navigate-To '/sdcard/DCIM' })
$btnReload.Add_Click({ Refresh-Listing })
$btnGo.Add_Click({ Navigate-To ($txtPath.Text.Trim()) })
$txtPath.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Navigate-To ($txtPath.Text.Trim()) } })

# 进入选中项：是目录就导航进去（IsDir 标记或在手机上 [ -d ] 实测为真都算）
function Open-SelectedFolder {
    $serial = Get-SelectedSerial
    if (-not $serial) { return }
    $sel = @(Get-SelectedRemoteItems)
    if ($sel.Count -lt 1) { return }
    $path = $sel[0].Tag
    if ($sel[0].IsDir -or (Test-RemoteIsDir -Serial $serial -Path $path)) { Navigate-To $path }
}

# 双击文件夹 -> 直接进入（ItemActivate 比 DoubleClick 更可靠，不会被拖拽抢走）
$lv.Add_ItemActivate({ Open-SelectedFolder })
# 键盘导航：回车进入选中文件夹，退格返回上级
$lv.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true
            Open-SelectedFolder
        }
        elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Back) {
            $_.SuppressKeyPress = $true
            Navigate-To (Get-ParentPath $script:CurrentDir)
        }
    })

$btnUpFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Multiselect = $true
        $ofd.Title = "选择要上传到手机的文件"
        if ($ofd.ShowDialog() -eq 'OK') { Upload-Paths $ofd.FileNames }
    })

$btnUpDir.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "选择要上传到手机的文件夹"
        if ($fbd.ShowDialog() -eq 'OK') { Upload-Paths @($fbd.SelectedPath) }
    })

$btnDownload.Add_Click({ Download-Selected })

$btnNewDir.Add_Click({
        $serial = Get-SelectedSerial
        if (-not $serial) { return }
        $name = [Microsoft.VisualBasic.Interaction]::InputBox("新文件夹名称：", "新建文件夹", "新建文件夹")
        if (-not $name) { return }
        $remote = Join-RemotePath $script:CurrentDir $name
        $r = Invoke-Adb ("-s " + (Quote-Arg $serial) + " shell " + (Quote-Arg ("mkdir -p " + (Quote-RemoteShell $remote))))
        if ($r.ExitCode -ne 0 -and $r.StdErr) { [System.Windows.Forms.MessageBox]::Show($r.StdErr, "新建失败") | Out-Null }
        Refresh-Listing
    })

$btnDelete.Add_Click({
        $serial = Get-SelectedSerial
        if (-not $serial) { return }
        $sel = @(Get-SelectedRemoteItems)
        if ($sel.Count -eq 0) { return }
        $msg = "确定删除手机上的这 $($sel.Count) 项吗？此操作不可恢复！`n`n" + (($sel | Select-Object -First 10 | ForEach-Object { $_.Name }) -join "`n")
        if ([System.Windows.Forms.MessageBox]::Show($msg, "确认删除", 'YesNo', 'Warning') -ne 'Yes') { return }
        foreach ($s in $sel) {
            [void](Invoke-Adb ("-s " + (Quote-Arg $serial) + " shell " + (Quote-Arg ("rm -rf " + (Quote-RemoteShell $s.Tag)))))
        }
        Refresh-Listing
    })

# ---- 拖入：资源管理器 -> 列表（上传） ----
$lv.Add_DragEnter({
        if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
        else { $_.Effect = [System.Windows.Forms.DragDropEffects]::None }
    })
$lv.Add_DragDrop({
        if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            Upload-Paths ([string[]]$files)
        }
    })

# ---- 拖出：列表 -> 资源管理器/桌面（下载） ----
$lv.Add_ItemDrag({
        $serial = Get-SelectedSerial
        if (-not $serial) { return }
        $sel = @(Get-SelectedRemoteItems)
        if ($sel.Count -eq 0) { return }
        $tmp = Join-Path $env:TEMP ("adbdrag_" + ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $form.Cursor = 'WaitCursor'
        Set-Status "正在准备拖出（先拉取到临时目录）…"
        try {
            $locals = Invoke-PullToFolder -Serial $serial -RemotePaths @($sel | ForEach-Object { $_.Tag }) -LocalDir $tmp
        }
        finally { $form.Cursor = 'Default' }
        if ($locals.Count -eq 0) { Set-Status "拉取失败，无法拖出。"; return }
        $sc = New-Object System.Collections.Specialized.StringCollection
        $sc.AddRange([string[]]$locals)
        $dataObj = New-Object System.Windows.Forms.DataObject
        $dataObj.SetFileDropList($sc)
        Set-Status "拖到目标文件夹后松开即可复制到电脑。"
        [void]$lv.DoDragDrop($dataObj, [System.Windows.Forms.DragDropEffects]::Copy)
    })

# ---- 初始化 ----
$form.Add_Shown({
        Refresh-Devices
        Refresh-Listing
        $form.Activate()
    })

# InputBox 需要 VisualBasic 程序集
Add-Type -AssemblyName Microsoft.VisualBasic

# ---- 自检模式（仅诊断用：设置环境变量 ADBFM_SELFTEST=1 时运行，不弹窗）----
if ($env:ADBFM_SELFTEST -eq '1') {
    $slog = Join-Path $env:TEMP 'adbfm_selftest.txt'
    function SLog($m) { Add-Content -LiteralPath $slog -Value $m }
    Set-Content -LiteralPath $slog -Value ("SELFTEST start " + (Get-Date))
    try {
        [void]$form.Handle; [void]$lv.Handle; [void]$cboDev.Handle
        Refresh-Devices
        SLog ("devices in combo=" + $cboDev.Items.Count + " selectedSerial=" + (Get-SelectedSerial))
        $script:CurrentDir = '/sdcard'
        Refresh-Listing
        SLog ("after list /sdcard: items=" + $lv.Items.Count + " CurrentDir=" + $script:CurrentDir)
        $target = $env:ADBFM_TESTDIR; if (-not $target) { $target = 'DCIM' }
        $hit = $null
        foreach ($it in $lv.Items) { if ($it.Text -eq $target) { $hit = $it; break } }
        if (-not $hit) { SLog "TARGET '$target' NOT FOUND in list"; }
        else {
            $hit.Selected = $true; $hit.Focused = $true
            $sel = @(Get-SelectedRemoteItems)
            SLog ("selected count=" + $sel.Count + " name=" + $sel[0].Name + " IsDir=" + $sel[0].IsDir + " Tag=" + $sel[0].Tag)
            SLog "calling Open-SelectedFolder ..."
            Open-SelectedFolder
            SLog ("AFTER open: CurrentDir=" + $script:CurrentDir + " items=" + $lv.Items.Count)
        }
    }
    catch {
        SLog ("EXCEPTION: " + $_.Exception.Message + " | " + $_.ScriptStackTrace)
    }
    SLog "SELFTEST end"
    return
}

[void]$form.ShowDialog()
