<#
.SYNOPSIS
一次清理体检报告中的放心清项目，以及用户点名的确认项目。
.DESCRIPTION
只按本脚本的固定表选择处理器，不使用报告中的路径或命令。
先执行普通权限项目，再为其余项目请求一次管理员权限；拒绝授权只跳过这些项目。
空间收益按 C 盘清理前后的可用空间变化估算。演练只显示计划，不调用处理器或写文件。
.PARAMETER Include
仅接受本报告中需要单独确认、且用户已点名的项目编号。
.PARAMETER ResultPath
新结果文件的路径；省略时在共享日志目录生成唯一名称，绝不覆盖已有文件。
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Public')]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ReportPath,
    [Parameter(ParameterSetName = 'Public')][string[]]$Include = @(),
    [ValidateSet('Quick', 'Full')][string]$Mode = 'Quick',
    [ValidateRange(1, 600)][int]$CacheBudgetSeconds = 15,
    [string]$ResultPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Admin', DontShow = $true)][string]$LogDirectory,
    [Parameter(Mandatory = $true, ParameterSetName = 'Admin', DontShow = $true)][switch]$AdminPhase,
    [Parameter(Mandatory = $true, ParameterSetName = 'Admin', DontShow = $true)][string[]]$AdminItemIds,
    [Parameter(Mandatory = $true, ParameterSetName = 'Admin', DontShow = $true)][string]$OriginalUserSid,
    [Parameter(Mandatory = $true, ParameterSetName = 'Admin', DontShow = $true)][string]$OriginalUserProfile,
    [Parameter(Mandatory = $true, ParameterSetName = 'Admin', DontShow = $true)][guid]$RequestId = [guid]::Empty
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw '此脚本仅支持 Windows；请在 Windows 电脑上运行。'
}
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-CleanProperty {
    param($InputObject, [string]$Name, $Default = $null)
    if ($null -ne $InputObject) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($Name)) { return ,($InputObject[$Name]) }
        }
        else {
            $property = $InputObject.PSObject.Properties[$Name]
            if ($null -ne $property) { return ,($property.Value) }
        }
    }
    return ,$Default
}

function Get-CleanItemDefinition {
    param([string]$Id)
    # 固定选择器、权限和后果确认；报告里的 NeedsAdmin、Paths、Detail 均不能覆盖。
    $table = @{
        'cache:UserTemp' = @('safe', 'clean-cache.ps1', 'UserTemp', $false, '系统临时文件')
        'cache:WindowsTemp' = @('safe', 'clean-cache.ps1', 'WindowsTemp', $true, '系统临时文件（公共）')
        'cache:ThumbnailCache' = @('safe', 'clean-cache.ps1', 'ThumbnailCache', $false, '图片缩略图缓存')
        'cache:BrowserCache' = @('safe', 'clean-cache.ps1', 'BrowserCache', $false, '浏览器缓存')
        'cache:InetCache' = @('safe', 'clean-cache.ps1', 'InetCache', $false, '上网临时文件')
        'cache:AppCache' = @('safe', 'clean-cache.ps1', 'AppCache', $false, '软件缓存')
        'cache:ShaderCache' = @('safe', 'clean-cache.ps1', 'ShaderCache', $false, '显卡缓存')
        'system:UpdateCache' = @('safe', 'clean-system.ps1', 'UpdateCache', $true, '系统更新缓存')
        'system:DeliveryOptimization' = @('safe', 'clean-system.ps1', 'DeliveryOptimization', $true, '更新共享缓存')
        # 现有系统处理器对所有这些动作都要求管理员权限，包括回收站和崩溃报告。
        'system:CrashDumps' = @('safe', 'clean-system.ps1', 'CrashDumps', $true, '错误报告')
        'system:RecycleBin' = @('confirm', 'clean-system.ps1', 'RecycleBin', $true, '回收站')
        'system:Hibernate' = @('confirm', 'clean-system.ps1', 'Hibernate', $true, '休眠文件')
        'system:WindowsOld' = @('confirm', 'clean-system.ps1', 'WindowsOld', $true, '旧系统文件')
    }
    # 比较大小写，未来编号不能意外匹配到已有动作。
    $key = @($table.Keys | Where-Object { $_ -ceq $Id })
    if ($key.Count -eq 0) { return $null }
    $entry = $table[$Id]
    $parameters = @{}
    if ($entry[1] -eq 'clean-cache.ps1') { $parameters.Category = $entry[2] }
    else { $parameters.Action = $entry[2] }
    if ($entry[2] -in @('CrashDumps', 'RecycleBin', 'Hibernate', 'WindowsOld')) {
        $parameters.AcknowledgeIrreversible = $true
    }
    # 用户选择清理休眠文件即关闭休眠（也会关闭快速启动、混合睡眠）。
    if ($entry[2] -eq 'Hibernate') { $parameters.Mode = 'Off' }
    return [pscustomobject]@{ Id = $Id; Group = $entry[0]; HandlerScript = $entry[1]
        Parameters = $parameters; NeedsAdmin = [bool]$entry[3]; Title = $entry[4] }
}

function Assert-CleanReport {
    param($Report, $Context, [string[]]$Include = @(), [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    if ((Get-CleanProperty $Report 'Schema') -cne 'pc-care/checkup/1') {
        throw '体检报告版本不支持，请重新体检。'
    }
    $sid = Get-CleanProperty (Get-CleanProperty $Report 'User') 'Sid'
    $original = Get-CleanProperty $Context 'OriginalUserSid' ''
    if ($sid -isnot [string] -or [string]::IsNullOrWhiteSpace($original) -or $sid -ine $original) {
        throw '这份体检报告属于其他账户，请用当前账户重新体检。'
    }
    if ((Get-CleanProperty $Context 'OriginalUserVerified' $false) -ne $true -or
        (Get-CleanProperty $Context 'CurrentUserSid' '') -ine $original -or
        [string]::IsNullOrWhiteSpace((Get-CleanProperty $Context 'OriginalUserProfile' ''))) {
        throw '无法确认当前账户，请使用体检时的同一账户。'
    }
    $value = Get-CleanProperty $Report 'GeneratedAt'
    $generated = [DateTimeOffset]::MinValue
    if ($value -is [DateTime] -or $value -is [DateTimeOffset]) { $generated = [DateTimeOffset]$value }
    elseif ($value -isnot [string] -or -not [DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$generated)) { throw '体检报告时间无效，请重新体检。' }
    if ($generated -gt $Now) { throw '体检报告时间晚于当前时间，请重新体检。' }
    if (($Now - $generated).TotalHours -gt 24) { throw '体检报告已超过 24 小时，请重新体检。' }
    $items = Get-CleanProperty $Report 'Items'
    if ($null -eq $items -or $items -isnot [System.Collections.IList]) { throw '体检报告缺少有效的项目清单，请重新体检。' }
    $byId = @{}
    foreach ($item in $items) {
        $id = Get-CleanProperty $item 'Id'
        if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id) -or $byId.ContainsKey($id)) {
            throw '体检报告含空白或重复的项目编号，请重新体检。'
        }
        $byId[$id] = $item
        $definition = Get-CleanItemDefinition $id
        if ($null -ne $definition -and (Get-CleanProperty $item 'Group') -cne $definition.Group) {
            throw '体检报告的项目分类不正确，请重新体检。'
        }
    }
    $seen = @{}
    foreach ($id in $Include) {
        if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id) -or
            -not $byId.ContainsKey($id) -or
            (Get-CleanProperty $byId[$id] 'Id') -cne $id -or (Get-CleanProperty $byId[$id] 'Group') -cne 'confirm') {
            throw '额外选择只能填写本次报告中需要单独确认的项目编号，且不能重复。'
        }
        $seen[$id] = $true
    }
}

function New-CleanPlan {
    param($Report, $Context, [string[]]$Include = @(), [string]$ScriptsRoot,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    Assert-CleanReport $Report $Context $Include $Now
    $selected = @(); $unselected = @(); $ignored = @()
    foreach ($item in (Get-CleanProperty $Report 'Items')) {
        $definition = Get-CleanItemDefinition $item.Id
        if ($null -eq $definition) {
            $ignored += [pscustomobject]@{ Id = $item.Id; Reason = '此项目不属于本次清理范围，已忽略' }
            continue
        }
        $definition | Add-Member -NotePropertyName HandlerPath -NotePropertyValue (Join-Path $ScriptsRoot $definition.HandlerScript)
        if ($definition.Group -eq 'safe' -or $definition.Id -cin $Include) { $selected += $definition }
        else { $unselected += $definition }
    }
    return [pscustomobject]@{ Selected = @($selected); Unselected = @($unselected); Ignored = @($ignored) }
}

function Select-CleanAdminItems {
    param([object[]]$Selected, [string[]]$Ids)
    if (@($Ids).Count -eq 0 -or @($Ids | Select-Object -Unique).Count -ne @($Ids).Count) {
        throw '管理员清理清单为空或有重复项目。'
    }
    foreach ($id in $Ids) {
        $matches = @($Selected | Where-Object { $_.Id -ceq $id -and $_.NeedsAdmin })
        if ($matches.Count -ne 1) { throw '管理员清理清单含无效项目，请重新清理。' }
        $matches[0]
    }
}

function Split-CleanPhases {
    param([object[]]$Items)
    return [pscustomobject]@{ User = @($Items | Where-Object { -not $_.NeedsAdmin })
        Admin = @($Items | Where-Object { $_.NeedsAdmin }) }
}

function New-CleanItemResult {
    param($Item, [string]$Status, [string]$Reason = '', $FreedBytes = $null, $FreeBefore = $null,
        $FreeAfter = $null, [long]$TotalMs = 0)
    return [pscustomobject]@{ Id = $Item.Id; Title = $Item.Title; Status = $Status; Reason = $Reason
        FreedBytes = $FreedBytes; FreedBytesIsEstimate = $true; FreeBefore = $FreeBefore; FreeAfter = $FreeAfter
        Timings = @{ TotalMs = $TotalMs } }
}

function Get-CleanPlainReason {
    param([string]$Text)
    # 底层详细信息留给原有审计日志；用户只看到可理解的说明。
    if ($Text -match '恢复.*失败|未.*恢复|服务恢复') { return '系统更新服务未完全恢复，需要检查系统更新是否正常' }
    if ($Text -match '正在被使用|正在使用|正由.*使用|被占用|占用|共享冲突|sharing violation|being used|in use') { return '有文件正在被使用，已跳过' }
    if ($Text -match '待重启|待重新启动|需要重新启动|重新启动|待完成') { return '系统需要重启，请重启后再清理' }
    if ($Text -match '维护进程|更新活动|更新.*运行|更新.*空闲|安装.*运行|安装标记|正在工作|BITS|更新标记|更新状态') {
        return '系统正在更新，或暂时无法确认更新是否结束，已跳过'
    }
    if ($Text -match '快速清理时间预算') { return '快速清理已到时间预算，剩余内容已保留；可稍后继续或使用完整模式' }
    if ($Text -match '请.*退出|进程查询|查询.*进程|正在运行|检测到.*进程') { return '相关软件尚未退出，或无法确认是否退出，已跳过' }
    if ($Text -match '最近|时间晚于|年龄|未达到|too recent') { return '最近使用过的文件已保留' }
    if ($Text -match '不存在|无需清理') { return '这些文件已经不存在，无需清理' }
    if ($Text -match '此系统没有|未安装|not available') { return '这台电脑暂时不支持自动清理此项' }
    if ($Text -match '后台运行|显示界面') { return '系统清理仍可能在进行，请稍后重新体检' }
    if ($Text -match '管理员|权限|拒绝访问|Access.*denied') { return '没有足够的权限，已跳过' }
    return '部分文件暂时无法安全清理，已保留'
}

function Get-CleanOutcome {
    param([object[]]$Records, [bool]$Failed = $false)
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $states = @(); $exists = @(); $progress = $false; $skips = $false; $lockedCount = 0; $hasError = $Failed
    foreach ($record in $Records) {
        if ($record -is [Management.Automation.ErrorRecord]) {
            $hasError = $true; $reasons.Add((Get-CleanPlainReason $record.Exception.Message)); continue
        }
        if ($record -is [Management.Automation.WarningRecord]) {
            $text = $record.Message
            # 旧处理器的后果告知不是执行失败或跳过。
            if ($text -match '^错误报告和崩溃转储将永久删除|^回收站中的文件将永久删除|^以前的 Windows 安装将被删除|^Off 会禁用|^优先使用') { continue }
            if ($text -match '后台运行|显示界面') { $states += 'partial' }
            $skips = $true; $reasons.Add((Get-CleanPlainReason $text)); continue
        }
        $state = Get-CleanProperty $record 'Result' ''
        if ($state -in @('done', 'partial', 'skipped', 'failed')) { $states += $state }
        if ($state -eq 'done' -or (Get-CleanProperty $record 'DeletedCount' 0) -gt 0) { $progress = $true }
        $exist = Get-CleanProperty $record 'Exists'
        if ($exist -is [bool]) { $exists += $exist }
        $skipItems = Get-CleanProperty $record 'SkippedItems' @()
        $texts = @()
        foreach ($skip in $skipItems) {
            $text = [string](Get-CleanProperty $skip 'Reason' '')
            if ($text -match '正在被使用|正在使用|正由.*使用|被占用|占用|共享冲突|sharing violation|being used|in use') { $lockedCount++ }
            $texts += $text
        }
        # SkippedReasons 是 SkippedItems 的去重摘要，不能再计一次文件数。
        if ($skipItems.Count -eq 0) { $texts += (Get-CleanProperty $record 'SkippedReasons' @()) }
        if ((Get-CleanProperty $record 'SkippedCount' 0) -gt 0) { $skips = $true }
        foreach ($text in $texts) { $skips = $true; $reasons.Add((Get-CleanPlainReason ([string]$text))) }
        if ((Get-CleanProperty $record 'IsComplete' $true) -eq $false) { $skips = $true }
    }
    if ($lockedCount -gt 0) {
        while ($reasons.Remove('有文件正在被使用，已跳过')) { }
        $reasons.Add(('有 {0} 个文件正在被使用，已跳过' -f $lockedCount))
    }
    $status = 'Done'
    if ($hasError -or 'failed' -in $states) { $status = 'Failed'; $reasons.Add('此项未能完成，请稍后重新清理；详细记录已保留') }
    elseif ('partial' -in $states -or ($progress -and ($skips -or 'skipped' -in $states))) { $status = 'Partial' }
    elseif ($skips -or 'skipped' -in $states -or ($exists.Count -gt 0 -and $true -notin $exists)) { $status = 'Skipped' }
    if ($status -ne 'Done' -and $reasons.Count -eq 0) {
        $reason = '部分文件暂时无法安全清理，已保留'
        if ($exists.Count -gt 0 -and $true -notin $exists) { $reason = '这些文件已经不存在，无需清理' }
        $reasons.Add($reason)
    }
    $reasonText = ''
    if ($status -ne 'Done') { $reasonText = @($reasons.ToArray() | Select-Object -Unique) -join '；' }
    return [pscustomobject]@{ Status = $status; Reason = $reasonText }
}

function Get-CleanFreeBytes {
    try {
        $free = (Get-PSDrive -Name C -PSProvider FileSystem -ErrorAction Stop).Free
        if ($null -ne $free) { return [long]$free }
    }
    catch { }
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($null -ne $disk.FreeSpace) { return [long]$disk.FreeSpace }
    }
    catch { }
    return $null
}

function Get-CleanDelta {
    param($Before, $After)
    if ($null -eq $Before -or $null -eq $After) { return $null }
    # 保留负值，不把其他程序占用空间的影响伪装成零。
    return ([long]$After - [long]$Before)
}

function Invoke-CleanItem {
    param($Item, $Context)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $records = New-Object 'System.Collections.Generic.List[object]'
    $before = Get-CleanFreeBytes
    $parameters = @{}
    foreach ($key in $Item.Parameters.Keys) { $parameters[$key] = $Item.Parameters[$key] }
    if ($Item.HandlerScript -eq 'clean-system.ps1') {
        $parameters.OriginalUserSid = $Context.OriginalUserSid
        $parameters.OriginalUserProfile = $Context.OriginalUserProfile
    }
    $failed = $false
    $previousLog = [Environment]::GetEnvironmentVariable('CLEANER_LOG_PATH')
    try {
        # 旧处理器会重新载入 common.ps1；同进程调用也必须保留已解析的日志位置。
        [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', $Context.LogPath)
        $handler = $Item.HandlerPath
        # 捕获错误与警告供普通中文汇总；隐藏旧处理器面向维护者的主机输出。
        & $handler @parameters -Confirm:$false -WhatIf:$false 2>&1 3>&1 4>$null 5>$null 6>$null | ForEach-Object { $records.Add($_) }
    }
    catch { $failed = $true; $records.Add($_) }
    finally {
        # PowerShell 7.5/.NET distinguishes an absent variable from an empty one.
        if ($null -eq $previousLog) { [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', [NullString]::Value) }
        else { [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', $previousLog) }
    }
    $after = Get-CleanFreeBytes
    $outcome = Get-CleanOutcome $records.ToArray() $failed
    New-CleanItemResult $Item $outcome.Status $outcome.Reason (Get-CleanDelta $before $after) $before $after $watch.ElapsedMilliseconds
}

function Invoke-CleanItems {
    param([object[]]$Items, $Context)
    foreach ($item in $Items) {
        Write-Host ('正在清理：' + $item.Title)
        try { Invoke-CleanItem $item $Context }
        catch { New-CleanItemResult $item 'Failed' '此项未能完成，请稍后重新清理；详细记录已保留' }
    }
}

function Assert-CleanInputFile {
    param($File)
    if ((Get-CleanProperty $File 'PSIsContainer' $true) -or
        (Get-CleanProperty (Get-CleanProperty $File 'PSProvider') 'Name' '') -ne 'FileSystem') {
        throw '请选择普通的体检报告文件。'
    }
    if (((Get-CleanProperty $File 'Attributes' 0) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw '报告文件是一个链接，请重新体检并使用新报告。'
    }
}

function Read-CleanJsonFile {
    param([string]$Path)
    try {
        $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        Assert-CleanInputFile $file
        $check = Test-CleanerPathChain -LiteralPath $file.FullName
        if (-not $check.IsSafe) { throw '文件路径无法安全读取。' }
        $value = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject]@{ Path = $file.FullName; Value = $value }
    }
    catch { throw '无法安全读取报告文件，请重新体检并使用新报告。' }
}

function Get-CleanNewFilePath {
    param([string]$Path, $Context)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($fullPath -notmatch '^[A-Za-z]:\\' -or $fullPath.Substring(2).Contains(':')) {
        throw '结果只接受本地盘符上的普通文件路径，不接受网络路径、提供程序路径或备用数据流。'
    }
    $check = Test-CleanerPathChain -LiteralPath $fullPath -AllowMissing
    if (-not $check.IsSafe) { throw ('结果路径不安全：' + $check.Reason) }
    $forbidden = Get-CleanerForbiddenReason -LiteralPath $fullPath -Context $Context
    if ($forbidden) { throw ('结果路径不安全：' + $forbidden) }
    if (Test-Path -LiteralPath $fullPath) { throw ('结果路径已存在，拒绝覆盖：' + $fullPath) }
    return $fullPath
}

function New-CleanResultFile {
    param([string]$Path, $Context)
    $guards = New-Object 'System.Collections.Generic.List[object]'
    try {
        $directory = [IO.Path]::GetDirectoryName($Path)
        $missing = New-Object 'System.Collections.Generic.Stack[string]'
        $candidate = $directory
        while (-not [IO.Directory]::Exists($candidate)) {
            $missing.Push($candidate); $candidate = [IO.Path]::GetDirectoryName($candidate)
            if (-not $candidate) { throw '找不到结果目录的本地祖先。' }
        }
        while ($missing.Count -gt 0) {
            $next = $missing.Pop()
            $guards.Add((Open-CleanerParentGuards -LiteralPath $next))
            [void][IO.Directory]::CreateDirectory($next)
            $check = Test-CleanerPathChain -LiteralPath $next
            if (-not $check.IsSafe) { throw $check.Reason }
        }
        $guards.Add((Open-CleanerParentGuards -LiteralPath $Path))
        $checkedPath = Get-CleanNewFilePath $Path $Context
        # 执行前占用新文件，避免清理之后才发现路径冲突；CreateNew 防止竞态覆盖。
        $stream = [IO.File]::Open($checkedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        return [pscustomobject]@{ Stream = $stream; Guards = $guards }
    }
    catch {
        foreach ($group in $guards) { foreach ($handle in $group.Handles) { $handle.Dispose() } }
        throw
    }
}

function Get-CleanCurrentSid {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return $identity.User.Value }
    finally { $identity.Dispose() }
}

function ConvertTo-CleanLiteral {
    param([string]$Text)
    return ("'" + $Text.Replace("'", "''") + "'")
}

function New-CleanAdminCommand {
    param([string]$ScriptPath, [string]$ReportPath, [object[]]$Items, [string]$ResultPath,
        $Context, [guid]$RequestId)
    # EncodedCommand 保留数组、空格、中文、引号及尾部反斜线；不把报告内容拼成代码。
    $ids = @($Items | ForEach-Object { ConvertTo-CleanLiteral $_.Id }) -join ','
    $command = '& ' + (ConvertTo-CleanLiteral $ScriptPath) + ' -AdminPhase -ReportPath ' + (ConvertTo-CleanLiteral $ReportPath)
    $command += ' -AdminItemIds @(' + $ids + ') -ResultPath ' + (ConvertTo-CleanLiteral $ResultPath)
    $command += ' -LogDirectory ' + (ConvertTo-CleanLiteral (Split-Path -Path $Context.LogPath -Parent))
    $command += ' -Mode ' + (ConvertTo-CleanLiteral (Get-CleanProperty $Context 'CleanMode' 'Quick'))
    $command += ' -CacheBudgetSeconds ' + [string](Get-CleanProperty $Context 'CleanCacheBudgetSeconds' 15)
    $command += ' -OriginalUserSid ' + (ConvertTo-CleanLiteral $Context.OriginalUserSid)
    $command += ' -OriginalUserProfile ' + (ConvertTo-CleanLiteral $Context.OriginalUserProfile)
    $command += ' -RequestId ' + (ConvertTo-CleanLiteral $RequestId.ToString()) + ' -Confirm:$false -WhatIf:$false'
    return ('$ErrorActionPreference = ''Stop''; try { ' + $command + '; exit 0 } catch { exit 1 }')
}

function Get-CleanElevationArguments {
    param([string]$Command)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    # 仅为本次子进程设置执行策略，不修改当前用户或整台电脑的策略。
    return @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
}

function Start-CleanAdminProcess {
    param([string]$Command)
    $executable = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { $executable = Join-Path $PSHOME 'powershell.exe' }
    $arguments = @(Get-CleanElevationArguments $Command)
    $process = Start-Process -FilePath $executable -ArgumentList $arguments `
        -Verb RunAs -Wait -PassThru -ErrorAction Stop
    try { return [int]$process.ExitCode }
    finally { $process.Dispose() }
}

function Merge-CleanAdminResult {
    param([object[]]$Items, $ChildResult, [string]$ExpectedSid, [guid]$RequestId,
        [int]$ExitCode = 0, [bool]$LaunchFailed = $false)
    $reason = '管理员清理步骤未正常完成，无法确认这些项目的清理结果'
    if ($LaunchFailed) { $reason = '没有获得管理员权限，已跳过' }
    $valid = -not $LaunchFailed -and $ExitCode -eq 0
    if ($valid) {
        $original = Get-CleanProperty $ChildResult 'OriginalUserSid' ''
        $current = Get-CleanProperty $ChildResult 'CurrentUserSid' ''
        $isAdmin = Get-CleanProperty $ChildResult 'IsAdmin' $false
        $valid = (Get-CleanProperty $ChildResult 'Schema') -ceq 'pc-care/clean/1' -and
            (Get-CleanProperty $ChildResult 'Phase') -ceq 'Admin' -and
            (Get-CleanProperty $ChildResult 'RequestId') -eq $RequestId.ToString() -and
            $isAdmin -is [bool] -and $isAdmin -and $original -is [string] -and $current -is [string] -and
            $original -ieq $ExpectedSid -and $current -ieq $ExpectedSid
        if (($original -is [string] -and $original -ne '' -and $original -ine $ExpectedSid) -or
            ($current -is [string] -and $current -ne '' -and $current -ine $ExpectedSid)) {
            $valid = $false; $reason = '没有获得原账户的管理员权限，已跳过'
        }
    }
    $byId = @{}
    if ($valid) {
        $rows = Get-CleanProperty $ChildResult 'Items'
        if ($null -eq $rows -or $rows -isnot [System.Collections.IList] -or $rows.Count -ne @($Items).Count) { $valid = $false }
        else {
            foreach ($row in $rows) {
                $id = Get-CleanProperty $row 'Id' ''
                $status = Get-CleanProperty $row 'Status'
                $message = Get-CleanProperty $row 'Reason'
                if ($id -isnot [string] -or $byId.ContainsKey($id) -or
                    @($Items | Where-Object { $_.Id -ceq $id }).Count -ne 1 -or
                    $status -cnotin @('Done', 'Partial', 'Skipped', 'Failed') -or $message -isnot [string] -or
                    ($status -ne 'Done' -and [string]::IsNullOrWhiteSpace($message))) { $valid = $false; break }
                foreach ($name in @('FreedBytes', 'FreeBefore', 'FreeAfter')) {
                    $number = Get-CleanProperty $row $name
                    if ($null -eq $row.PSObject.Properties[$name] -and $row -isnot [System.Collections.IDictionary]) { $valid = $false }
                    if ($row -is [System.Collections.IDictionary] -and -not $row.Contains($name)) { $valid = $false }
                    if ($null -ne $number -and $number -isnot [long] -and $number -isnot [int]) { $valid = $false }
                }
                $elapsed = Get-CleanProperty (Get-CleanProperty $row 'Timings') 'TotalMs'
                if (($elapsed -isnot [long] -and $elapsed -isnot [int]) -or $elapsed -lt 0) { $valid = $false }
                $byId[$id] = $row
            }
        }
    }
    foreach ($item in $Items) {
        if (-not $valid) { New-CleanItemResult $item 'Skipped' $reason; continue }
        $row = $byId[$item.Id]
        # 标题和编号仍来自本地计划，仅合并允许的结果字段。
        New-CleanItemResult $item $row.Status $row.Reason (Get-CleanProperty $row 'FreedBytes') `
            (Get-CleanProperty $row 'FreeBefore') (Get-CleanProperty $row 'FreeAfter') $row.Timings.TotalMs
    }
}

function Invoke-CleanElevatedPhase {
    param([object[]]$Items, $Context, [string]$ScriptPath, [string]$ReportPath, [string]$ChildPath, [guid]$RequestId)
    $child = $null; $exitCode = 1; $launchFailed = $false
    try {
        $command = New-CleanAdminCommand $ScriptPath $ReportPath $Items $ChildPath $Context $RequestId
        $exitCode = Start-CleanAdminProcess $command
    }
    catch { $launchFailed = $true }
    if (-not $launchFailed -and $exitCode -eq 0) {
        try { $child = (Read-CleanJsonFile $ChildPath).Value }
        catch { $child = $null } # 授权后结果缺失，不能误称没有获得权限，也不能重新执行。
    }
    Merge-CleanAdminResult $Items $child $Context.OriginalUserSid $RequestId $exitCode $launchFailed
}

function Invoke-CleanPhases {
    param([object[]]$Items, $Context, [string]$ScriptPath, [string]$ReportPath, [string]$ChildPath,
        [guid]$RequestId, [bool]$AdminPhase = $false)
    $phases = Split-CleanPhases $Items
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $rows = @(Invoke-CleanItems $phases.User $Context)
    $userMs = $watch.ElapsedMilliseconds
    $watch.Restart()
    if ($phases.Admin.Count -gt 0) {
        if ($Context.IsAdmin) { $rows += @(Invoke-CleanItems $phases.Admin $Context) }
        elseif ($AdminPhase) {
            $rows += @(foreach ($item in $phases.Admin) { New-CleanItemResult $item 'Skipped' '没有获得管理员权限，已跳过' })
        }
        else { $rows += @(Invoke-CleanElevatedPhase $phases.Admin $Context $ScriptPath $ReportPath $ChildPath $RequestId) }
    }
    return [pscustomobject]@{ Items = @($rows); Steps = @{ UserMs = $userMs; AdminMs = $watch.ElapsedMilliseconds } }
}

function Write-CleanResultJson {
    param($File, $Result)
    $writer = [IO.StreamWriter]::new($File.Stream, [Text.UTF8Encoding]::new($true), 1024, $true)
    try { $writer.Write(($Result | ConvertTo-Json -Depth 8)); $writer.Flush() }
    finally { $writer.Dispose() }
}

function Close-CleanResultFile {
    param($File)
    try { $File.Stream.Dispose() }
    finally { foreach ($group in $File.Guards) { foreach ($handle in $group.Handles) { $handle.Dispose() } } }
}

function Format-CleanSummary {
    param($Result)
    $freed = $Result.FreedBytes
    $text = '清理已结束，腾出的空间暂时无法测量'
    if ($null -ne $freed) {
        if ($freed -lt 0) { $text = '清理期间 C 盘可用空间减少约 {0:N1} GB（其他程序也可能在写入）' -f (-$freed / 1GB) }
        else { $text = '已腾出约 {0:N1} GB（估算）' -f ($freed / 1GB) }
    }
    foreach ($row in $Result.Items) {
        if ($row.Status -eq 'Done') { continue }
        $label = '未清理'
        if ($row.Status -eq 'Partial') { $label = '部分清理' }
        if ($row.Status -eq 'Failed') { $label = '未完成' }
        $text += '；' + $row.Title + $label + '：' + $row.Reason
    }
    return $text
}

function Get-CleanFailureDiagnostics {
    param([string]$Stage, [string]$RequestedPath, $Failure)
    $final = $null
    $exception = $Failure.Exception
    while ($null -ne $exception) {
        if ($exception.Data.Contains('RequestedPath')) { $RequestedPath = $exception.Data['RequestedPath'] }
        if ($exception.Data.Contains('FinalPath')) { $final = $exception.Data['FinalPath'] }
        $exception = $exception.InnerException
    }
    return @{ Stage = $Stage; RequestedPath = $RequestedPath; FinalPath = $final; Reason = $Failure.Exception.Message }
}

function Invoke-CleanCommand {
    param([string]$ReportPath, [string[]]$Include = @(), [string]$ResultPath,
        [bool]$AdminPhase = $false, [string[]]$AdminItemIds = @(), [string]$OriginalUserSid,
        [string]$OriginalUserProfile, [guid]$RequestId = [guid]::Empty, [string]$LogDirectory,
        [ValidateSet('Quick', 'Full')][string]$Mode = 'Quick', [ValidateRange(1, 600)][int]$CacheBudgetSeconds = 15,
        [bool]$WhatIfRun = $false, [string]$ScriptsRoot, [string]$ScriptPath, $Cmdlet)
    if ($AdminPhase -and (Get-CleanCurrentSid) -ine $OriginalUserSid) {
        # 必须先于上下文、报告、日志及结果文件的任何访问；父进程将非零退出映射为跳过。
        throw '没有获得原账户的管理员权限，已跳过。'
    }
    try {
        $contextArgs = @{}
        if ($LogDirectory) { $contextArgs.LogDirectory = $LogDirectory }
        if ($AdminPhase) { $contextArgs.OriginalUserSid = $OriginalUserSid; $contextArgs.OriginalUserProfile = $OriginalUserProfile }
        $context = Get-CleanerContext @contextArgs
    }
    catch { throw '无法确认当前账户，请使用体检时的同一账户。' }
    $inputFile = Read-CleanJsonFile $ReportPath
    if ($AdminPhase) {
        $Include = @(foreach ($id in $AdminItemIds) {
            $definition = Get-CleanItemDefinition $id
            if ($null -ne $definition -and $definition.Group -eq 'confirm') { $id }
        })
    }
    $plan = New-CleanPlan $inputFile.Value $context $Include $ScriptsRoot
    $context | Add-Member -NotePropertyName CleanMode -NotePropertyValue $Mode -Force
    $context | Add-Member -NotePropertyName CleanCacheBudgetSeconds -NotePropertyValue $CacheBudgetSeconds -Force
    foreach ($item in $plan.Selected) {
        if ($item.HandlerScript -eq 'clean-cache.ps1') {
            $item.Parameters.TimeBudgetSeconds = 0
            if ($Mode -eq 'Quick') { $item.Parameters.TimeBudgetSeconds = $CacheBudgetSeconds }
        }
    }
    if ($AdminPhase) {
        $plan.Selected = @(Select-CleanAdminItems $plan.Selected $AdminItemIds)
        $plan.Unselected = @(); $plan.Ignored = @()
    }
    if ($WhatIfRun) {
        if ($Mode -eq 'Quick') { Write-Host ('快速清理：每个缓存项目最多处理约 {0} 秒，到安全检查点后保存部分结果；系统工具耗时另计。' -f $CacheBudgetSeconds) }
        else { Write-Host '完整清理：缓存项目不设时间预算；安全规则与快速模式相同。' }
        foreach ($item in $plan.Selected) {
            $suffix = '使用当前权限'
            if ($item.NeedsAdmin -and -not $context.IsAdmin) { $suffix = '需要弹出管理员权限确认' }
            Write-Host ('计划清理：{0}（{1}）' -f $item.Title, $suffix)
        }
        foreach ($item in $plan.Unselected) { Write-Host ($item.Title + '未清理：你没有选择') }
        Write-Host '演练结束，未执行清理，也未写入文件或日志。'
        return
    }
    if (-not $Cmdlet.ShouldProcess('本次体检中已选择的清理项目', '清理并保存结果')) { return }
    $logDirectory = Split-Path -Path $context.LogPath -Parent
    if ([string]::IsNullOrWhiteSpace($logDirectory)) { throw '无法确定清理记录的保存位置。' }
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { $ResultPath = Join-Path $logDirectory ('clean-' + [guid]::NewGuid().ToString('N') + '.json') }
    try {
        $resultPathFull = Get-CleanNewFilePath $ResultPath $context
        $file = New-CleanResultFile $resultPathFull $context
    }
    catch {
        $reason = '无法创建新的清理结果文件，请选择可写入且尚不存在的文件路径。'
        $diagnostics = Get-CleanFailureDiagnostics 'Clean/ResultFile' $ResultPath $_
        # 结果位置本身不可写时，诊断只能通过标准输出交给代理，不再尝试其他写入。
        $failure = @{ Schema = 'pc-care/clean/1'; Status = 'Failed'; Reason = $reason; Diagnostics = $diagnostics }
        Write-Output (ConvertTo-Json -InputObject $failure -Depth 8 -Compress)
        Write-Output 'RESULT: 未保存'
        throw $reason
    }
    $started = [DateTimeOffset]::Now
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $before = Get-CleanFreeBytes
    $rows = @(); $steps = @{}; $diagnostics = $null; $stage = 'Clean/StartLog'
    try {
        try {
            Write-CleanerLog -Action 'Clean/Start' -Path $inputFile.Path -Result 'Started' -Context $context `
                -Message ('清理项目：' + (@($plan.Selected | ForEach-Object { $_.Id }) -join '、')) -Confirm:$false -ErrorAction Stop | Out-Null
            $stage = 'Clean/Execute'
            $childPath = Join-Path $logDirectory ('clean-admin-' + [guid]::NewGuid().ToString('N') + '.json')
            $phaseResult = Invoke-CleanPhases $plan.Selected $context $ScriptPath $inputFile.Path $childPath ([guid]::NewGuid()) $AdminPhase
            $rows = @($phaseResult.Items); $steps = $phaseResult.Steps
        }
        catch {
            $diagnostics = Get-CleanFailureDiagnostics $stage $context.LogPath $_
            $rows = @(foreach ($item in $plan.Selected) { New-CleanItemResult $item 'Failed' '清理记录无法完整保存，已停止；请稍后重新体检' })
        }
        $rows += @(foreach ($item in $plan.Unselected) { New-CleanItemResult $item 'Skipped' '你没有选择' 0 })
        $after = Get-CleanFreeBytes
        $phase = 'Public'
        if ($AdminPhase) { $phase = 'Admin' }
        $result = [ordered]@{ Schema = 'pc-care/clean/1'; GeneratedAt = [DateTimeOffset]::Now.ToString('o')
            StartedAt = $started.ToString('o'); ReportPath = $inputFile.Path; Phase = $phase; RequestId = $RequestId.ToString()
            Mode = $Mode; CacheBudgetSeconds = $(if ($Mode -eq 'Quick') { $CacheBudgetSeconds } else { 0 })
            OriginalUserSid = $context.OriginalUserSid; CurrentUserSid = $context.CurrentUserSid; IsAdmin = [bool]$context.IsAdmin
            Items = @($rows); Ignored = @($plan.Ignored); FreedBytes = Get-CleanDelta $before $after; FreedBytesIsEstimate = $true
            FreedBytesNote = '按 C 盘可用空间变化估算，后台活动可能影响数值；负值表示可用空间减少。'
            FreeBefore = $before; FreeAfter = $after; Timings = @{ TotalMs = $watch.ElapsedMilliseconds; Steps = $steps } }
        if ($null -ne $diagnostics) { $result.Diagnostics = $diagnostics }
        Write-CleanResultJson $file $result
    }
    finally { Close-CleanResultFile $file }
    try {
        Write-CleanerAudit -Action 'Clean/End' -Path $inputFile.Path -Result 'Finished' -Context $context `
            -Message ('清理结果：' + $resultPathFull) -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch { Write-Warning '清理结果已保存，但部分清理记录未能写入。' }
    Write-Host (Format-CleanSummary $result)
    Write-Output ('RESULT: ' + $resultPathFull)
}

Invoke-CleanCommand -ReportPath $ReportPath -Include $Include -ResultPath $ResultPath -AdminPhase ([bool]$AdminPhase) `
    -Mode $Mode -CacheBudgetSeconds $CacheBudgetSeconds `
    -LogDirectory $LogDirectory -AdminItemIds $AdminItemIds -OriginalUserSid $OriginalUserSid -OriginalUserProfile $OriginalUserProfile -RequestId $RequestId `
    -WhatIfRun ([bool]$WhatIfPreference) -ScriptsRoot $PSScriptRoot -ScriptPath $PSCommandPath -Cmdlet $PSCmdlet
