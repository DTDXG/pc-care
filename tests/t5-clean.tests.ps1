Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/clean.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors.Message -join '；') }
# 仅执行函数定义；绝不执行脚本体、Windows API、真实清理或子进程。
foreach ($definition in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw ('断言失败：' + $Message) }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($null -eq $Expected) { Assert-True ($null -eq $Actual) $Message }
    else { Assert-True ($Actual -ceq $Expected) ($Message + '；实际值：' + $Actual) }
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $caught = ''
    try { & $Action | Out-Null }
    catch { $caught = $_.Exception.Message }
    Assert-True ($caught -match $Pattern) ($Message + '；实际错误：' + $caught)
    Assert-True ($caught -notmatch 'SID|reparse|junction|WinSxS|VSS') ($Message + '：错误使用普通中文')
}
$requestParameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RequestId' })[0]
Assert-Equal $requestParameter.DefaultValue.Extent.Text '[guid]::Empty' '普通调用不把未绑定的空值转成标识号'
$now = [DateTimeOffset]::Parse('2026-10-23T12:00:00Z')
$context = [pscustomobject]@{ OriginalUserSid = 'S-1-5-21-test'; CurrentUserSid = 'S-1-5-21-test'
    OriginalUserProfile = "C:\Users\张'三\"; OriginalUserVerified = $true; IsAdmin = $false; LogPath = '/fake/logs/cleaner.jsonl' }
function New-TestItem {
    param([string]$Id, [string]$Group = 'safe')
    return [pscustomobject]@{ Id = $Id; Group = $Group; Title = '不能信任的标题'; Bytes = 100; NeedsAdmin = $false
        Paths = @('C:\不可删除的用户文件'); Detail = @{ HandlerPath = '恶意脚本'; Action = 'Hibernate' } }
}
function New-TestReport {
    return [pscustomobject]@{ Schema = 'pc-care/checkup/1'; GeneratedAt = $now.AddHours(-1).ToString('o')
        User = @{ Sid = $context.OriginalUserSid; Profile = $context.OriginalUserProfile }
        Items = @((New-TestItem 'cache:UserTemp'), (New-TestItem 'cache:WindowsTemp'),
            (New-TestItem 'system:CrashDumps'), (New-TestItem 'system:RecycleBin' 'confirm'),
            (New-TestItem 'system:Hibernate' 'confirm'), (New-TestItem 'system:WindowsOld' 'confirm'),
            (New-TestItem 'future:Cleaner' 'safe'), (New-TestItem 'move:WeChat' 'move'), (New-TestItem 'info:LargeApps' 'info')) }
}
function Get-TestPlan {
    param($Report = (New-TestReport), [string[]]$Include = @())
    New-CleanPlan $Report $context $Include (Join-Path $repoRoot 'scripts') $now
}
$plan = Get-TestPlan
Assert-Equal $plan.Selected.Count 3 '全部 safe 自动选中'
Assert-Equal $plan.Unselected.Count 3 '确认项默认不执行'
Assert-Equal $plan.Ignored.Count 3 '未来编号和搬家提示项目记录为忽略'
Assert-Equal $plan.Ignored[0].Id 'future:Cleaner' '未知编号保留在忽略清单'
$report = New-TestReport; $report.Items[6].Group = 'confirm'
$futurePlan = Get-TestPlan $report @('future:Cleaner')
Assert-Equal $futurePlan.Selected.Count 3 '未来确认编号即使点名也不执行'
Assert-Equal $futurePlan.Ignored[0].Id 'future:Cleaner' '未来确认编号仍按未知项目忽略'
Assert-Equal $plan.Selected[0].Title '系统临时文件' '输出标题不信任报告内容'
Assert-Equal (Get-TestPlan (New-TestReport) @('system:RecycleBin')).Selected.Count 4 '只增加用户点名的确认项'
$json = New-TestReport | ConvertTo-Json -Depth 8 | ConvertFrom-Json
Assert-Equal (Get-TestPlan $json).Selected.Count 3 '兼容 JSON 数组和对象'
foreach ($bad in @('cache:UserTemp', 'move:WeChat', 'info:LargeApps', 'future:Cleaner', 'missing:item', '', 'SYSTEM:RecycleBin')) {
    Assert-Rejected { Get-TestPlan (New-TestReport) @($bad) } '额外选择' "拒绝无效选择 $bad"
}
Assert-Rejected { Get-TestPlan (New-TestReport) @('system:RecycleBin', 'system:RecycleBin') } '不能重复' '重复选择拒绝'
$report = New-TestReport; $report.Items = @($report.Items | Where-Object { $_.Id -ne 'system:RecycleBin' })
Assert-Rejected { Get-TestPlan $report @('system:RecycleBin') } '额外选择' '不能选择不在本报告的确认项'
$report = New-TestReport; $report.Schema = 'old/3'
Assert-Rejected { Get-TestPlan $report } '版本' '旧报告拒绝'
$report = New-TestReport; $report.User.Sid = '另一个账户'
Assert-Rejected { Get-TestPlan $report } '其他账户' '不同账户报告拒绝'
$report = New-TestReport; $report.GeneratedAt = $now.AddHours(-24).ToString('o')
Assert-Equal (Get-TestPlan $report).Selected.Count 3 '恰好 24 小时可执行'
$report.GeneratedAt = $now.AddHours(-24).AddTicks(-1).ToString('o')
Assert-Rejected { Get-TestPlan $report } '超过 24 小时' '超过一天拒绝'
$report.GeneratedAt = $now.AddSeconds(1).ToString('o')
Assert-Rejected { Get-TestPlan $report } '晚于' '未来时间拒绝'
$report.GeneratedAt = '无效时间'
Assert-Rejected { Get-TestPlan $report } '时间无效' '错误时间拒绝'
$report.GeneratedAt = $now.AddHours(-1).UtcDateTime
Assert-Equal (Get-TestPlan $report).Selected.Count 3 '兼容新版 JSON 自动转换的日期'
$report.GeneratedAt = [DateTimeOffset]::Parse('2026-10-23T18:00:00+07:00')
Assert-Equal (Get-TestPlan $report).Selected.Count 3 '保留时区偏移'
$report = New-TestReport; $report.Items = '错误清单'
Assert-Rejected { Get-TestPlan $report } '项目清单' '清单必须是数组'
$report.Items = @()
Assert-Equal (Get-TestPlan $report).Selected.Count 0 '空报告可以输出零清理结果'
$report = New-TestReport; $report.Items += $report.Items[0]
Assert-Rejected { Get-TestPlan $report } '重复' '报告内编号不能重复'
$report = New-TestReport; $report.Items[3].Group = 'safe'
Assert-Rejected { Get-TestPlan $report } '分类' '不能把回收站伪装为 safe'
$report = New-TestReport; $report.Items[0].Group = 'confirm'
Assert-Rejected { Get-TestPlan $report } '分类' '已知项目分类须与固定表一致'
$context.CurrentUserSid = '另一个账户'
Assert-Rejected { Get-TestPlan } '同一账户' '当前令牌必须与原用户一致'
$context.CurrentUserSid = $context.OriginalUserSid; $context.OriginalUserVerified = $false
Assert-Rejected { Get-TestPlan } '同一账户' '未核实身份拒绝'
$context.OriginalUserVerified = $true
$file = @{ PSIsContainer = $false; PSProvider = @{ Name = 'FileSystem' }; Attributes = [IO.FileAttributes]::Normal }
Assert-CleanInputFile $file
$file.Attributes = [IO.FileAttributes]::ReparsePoint
Assert-Rejected { Assert-CleanInputFile $file } '链接' '报告不能是链接'
$file.Attributes = [IO.FileAttributes]::Normal; $file.PSIsContainer = $true
Assert-Rejected { Assert-CleanInputFile $file } '普通' '报告不能是目录'
$file.PSIsContainer = $false; $file.PSProvider.Name = 'Registry'
Assert-Rejected { Assert-CleanInputFile $file } '普通' '报告不能是其他提供程序'

foreach ($name in @('UserTemp', 'WindowsTemp', 'ThumbnailCache', 'BrowserCache', 'InetCache', 'AppCache', 'ShaderCache')) {
    $item = Get-CleanItemDefinition ('cache:' + $name)
    Assert-Equal $item.HandlerScript 'clean-cache.ps1' "$name 缓存处理器"
    Assert-Equal $item.Parameters.Category $name "$name 明确选择器"
    Assert-Equal $item.NeedsAdmin ($name -eq 'WindowsTemp') "$name 管理员标记"
    Assert-True (-not $item.Parameters.ContainsKey('AcknowledgeIrreversible')) "$name 无额外操作"
}
foreach ($name in @('UpdateCache', 'DeliveryOptimization', 'CrashDumps', 'RecycleBin', 'Hibernate', 'WindowsOld')) {
    $item = Get-CleanItemDefinition ('system:' + $name)
    Assert-Equal $item.HandlerScript 'clean-system.ps1' "$name 系统处理器"
    Assert-Equal $item.Parameters.Action $name "$name 明确选择器"
    Assert-True $item.NeedsAdmin "$name 遵循现有系统处理器管理员要求"
    Assert-Equal $item.Parameters.ContainsKey('AcknowledgeIrreversible') ($name -in @('CrashDumps', 'RecycleBin', 'Hibernate', 'WindowsOld')) "$name 后果确认"
}
Assert-Equal (Get-CleanItemDefinition 'system:Hibernate').Parameters.Mode 'Off' '休眠文件清理显式关闭休眠'
foreach ($id in @('system:ComponentStore', 'system:ShadowStorage', 'cache:DevCache', 'cache:SystemLogs', 'CACHE:UserTemp', '../evil.ps1')) {
    Assert-Equal (Get-CleanItemDefinition $id) $null "$id 不在执行表中"
}
$plan = Get-TestPlan (New-TestReport) @('system:RecycleBin')
$split = Split-CleanPhases $plan.Selected
Assert-Equal ($split.User.Id -join ',') 'cache:UserTemp' '普通权限阶段仅用户项目'
Assert-Equal ($split.Admin.Id -join ',') 'cache:WindowsTemp,system:CrashDumps,system:RecycleBin' '管理员阶段使用固定权限而非报告标记'
Assert-Equal @(Select-CleanAdminItems $plan.Selected @('system:RecycleBin')).Count 1 '子阶段仅指定管理员项'
Assert-Rejected { Select-CleanAdminItems $plan.Selected @('cache:UserTemp') } '无效项目' '子阶段不能运行用户项'
Assert-Rejected { Select-CleanAdminItems $plan.Selected @('system:Hibernate') } '无效项目' '子阶段不能扩大确认范围'
Assert-Rejected { Select-CleanAdminItems $plan.Selected @('system:RecycleBin', 'system:RecycleBin') } '重复' '子阶段不能重复执行'

function Test-Outcome {
    param([object[]]$Records, [string]$Expected, [string]$Pattern = '')
    $outcome = Get-CleanOutcome $Records
    Assert-Equal $outcome.Status $Expected '状态映射'
    if ($Pattern) { Assert-True ($outcome.Reason -match $Pattern) '用户得到具体的普通中文原因' }
    Assert-True ($outcome.Reason -notmatch 'SID|WinSxS|VSS|junction|reparse|C:\\') '不泄漏底层术语和路径'
}
Test-Outcome @(@{ Result = 'done' }) 'Done'
Test-Outcome @(@{ Result = 'partial' }) 'Partial' '已保留'
Test-Outcome @(@{ Result = 'skipped' }) 'Skipped' '已保留'
Test-Outcome @(@{ Result = 'failed' }) 'Failed' '未能完成'
Test-Outcome @(@{ Exists = $false }) 'Skipped' '不存在'
Test-Outcome @(@{ DeletedCount = 2; SkippedItems = @(@{ Reason = '文件被占用' }) }) 'Partial' '有 1 个文件正在被使用'
Test-Outcome @(@{ IsComplete = $false; SkippedCount = 1; SkippedItems = @(@{ Reason = '重解析点，拒绝跟随' }) }) 'Skipped' '安全清理'
$locked = @(1..12 | ForEach-Object { @{ Path = "C:\\file$_"; Reason = 'The file is being used by another process' } })
Test-Outcome @(@{ Result = 'partial'; SkippedCount = 12; SkippedItems = $locked; SkippedReasons = @('being used') }) 'Partial' '有 12 个文件正在被使用'
Assert-Equal (Get-CleanOutcome @(@{ Result = 'partial'; SkippedItems = $locked })).Reason '有 12 个文件正在被使用，已跳过' '占用说明不重复列出摘要'
Test-Outcome @(@{ Result = 'skipped'; ProcessedCount = 1; SkippedItems = $locked }) 'Skipped' '有 12 个文件'
Test-Outcome @(@{ SkippedItems = @(@{ Reason = '另一个程序正在使用此文件，进程无法访问。' }, @{ Reason = '文件正由另一个进程使用。' }) }) 'Skipped' '有 2 个文件正在被使用'
Test-Outcome @([Management.Automation.WarningRecord]::new('存在维护进程：TiWorker')) 'Skipped' '系统正在更新'
Test-Outcome @([Management.Automation.WarningRecord]::new('此系统没有 Delete-DeliveryOptimizationCache。')) 'Skipped' '暂时不支持'
Test-Outcome @([Management.Automation.WarningRecord]::new('系统磁盘清理可能显示界面或继续在后台运行')) 'Partial' '仍可能在进行'
Test-Outcome @([Management.Automation.WarningRecord]::new('错误报告和崩溃转储将永久删除，可能丢失故障诊断证据。'), @{ Exists = $true }) 'Done'
Assert-Equal (Get-CleanOutcome @() $true).Status 'Failed' '终止异常映射为失败'
Assert-Equal (Get-CleanDelta 200 100) -100 '空间减少保留负值'
Assert-Equal (Get-CleanDelta $null 100) $null '未测量不冒充零'

$request = [guid]::NewGuid()
$admins = $split.Admin
$child = [pscustomobject]@{ Schema = 'pc-care/clean/1'; Phase = 'Admin'; RequestId = $request.ToString()
    IsAdmin = $true; OriginalUserSid = $context.OriginalUserSid; CurrentUserSid = $context.CurrentUserSid
    Items = @(foreach ($item in $admins) { New-CleanItemResult $item 'Done' '' 100 1000 1100 9 }) }
$merged = @(Merge-CleanAdminResult $admins $child $context.OriginalUserSid $request)
Assert-Equal ($merged.Status -join ',') 'Done,Done,Done' '合并有效管理员结果'
Assert-Equal $merged[0].FreedBytes 100 '保留管理员阶段空间估算'
$child.Items[0].Status = 'Partial'; $child.Items[0].Reason = '有 12 个文件正在被使用，已跳过'
Assert-Equal @(Merge-CleanAdminResult $admins $child $context.OriginalUserSid $request)[0].Status 'Partial' '保留子阶段部分完成'
$child.Items[0].Title = '不可信标题'
Assert-Equal @(Merge-CleanAdminResult $admins $child $context.OriginalUserSid $request)[0].Title $admins[0].Title '合并标题使用本地计划'
foreach ($case in @('throw', 'exit', 'sid', 'original', 'request', 'schema', 'phase', 'admin', 'duplicate', 'missing', 'status', 'reason', 'bytes', 'timing', 'missingbytes', 'admintext')) {
    $copy = $child | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $code = 0; $declined = $false
    switch ($case) {
        'throw' { $declined = $true }
        'exit' { $code = 1 }
        'sid' { $copy.CurrentUserSid = '其他账户' }
        'original' { $copy.OriginalUserSid = '其他账户' }
        'request' { $copy.RequestId = [guid]::NewGuid().ToString() }
        'schema' { $copy.Schema = 'unknown' }
        'phase' { $copy.Phase = 'Public' }
        'admin' { $copy.IsAdmin = $false }
        'duplicate' { $copy.Items[1].Id = $copy.Items[0].Id }
        'missing' { $copy.Items = @($copy.Items[0]) }
        'status' { $copy.Items[0].Status = 'not-a-status' }
        'reason' { $copy.Items[0].Reason = '' }
        'bytes' { $copy.Items[0].FreedBytes = '100' }
        'timing' { $copy.Items[0].Timings.TotalMs = -1 }
        'missingbytes' { $copy.Items[0].PSObject.Properties.Remove('FreedBytes') }
        'admintext' { $copy.IsAdmin = 'true' }
    }
    $merged = @(Merge-CleanAdminResult $admins $copy $context.OriginalUserSid $request $code $declined)
    Assert-Equal ($merged.Status -join ',') 'Skipped,Skipped,Skipped' "$case 不接受无效管理员结果"
    Assert-True ($merged[0].Reason -match '[\u4e00-\u9fff]') "$case 中文说明"
    if ($case -in @('throw', 'sid', 'original')) { Assert-True ($merged[0].Reason -match '没有获得.*管理员权限') "$case 权限未获得只跳过" }
    else {
        Assert-Equal $merged[0].Reason '管理员清理步骤未正常完成，无法确认这些项目的清理结果' "$case 已启动但结果无法确认"
    }
}

$missingChild = @(Merge-CleanAdminResult $admins $null $context.OriginalUserSid $request)
Assert-Equal $missingChild[0].Status 'Skipped' '子结果缺失不重试'
Assert-Equal $missingChild[0].Reason '管理员清理步骤未正常完成，无法确认这些项目的清理结果' '子结果缺失不误称未取得权限'

# 结果写入使用内存流，验证 UTF-8 JSON 和未知计量，绝不创建磁盘文件。
$memory = New-Object IO.MemoryStream
try {
    $memoryResult = @{ Schema = 'pc-care/clean/1'; Items = @((New-CleanItemResult $admins[0] 'Skipped' '没有获得管理员权限'))
        FreedBytes = $null; Ignored = @(); Timings = @{ TotalMs = 8; Steps = @{ UserMs = 1 } } }
    Write-CleanResultJson @{ Stream = $memory } $memoryResult
    Assert-True $memory.CanWrite '写入后底层流由外层负责关闭'
    $jsonText = [Text.Encoding]::UTF8.GetString($memory.ToArray()).TrimStart([char]0xFEFF)
    $decoded = $jsonText | ConvertFrom-Json
    Assert-Equal $decoded.Items[0].Reason '没有获得管理员权限' 'JSON 中文编码正确'
    Assert-Equal $decoded.Items[0].FreedBytes $null '未知字节写为 null'
    Assert-Equal $decoded.Timings.Steps.UserMs 1 '计时结构完整写入'
}
finally { $memory.Dispose() }

# 测试编码命令内的实际调用 AST，执行的目标只是本文件定义的内存假函数。
function Invoke-TestAdmin {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$AdminPhase, [string]$ReportPath, [string[]]$AdminItemIds, [string]$ResultPath,
        [string]$OriginalUserSid, [string]$OriginalUserProfile, [guid]$RequestId, [string]$LogDirectory)
    Assert-True $AdminPhase '内部管理员参数集'
    Assert-Equal $ReportPath "C:\报'告\checkup.json" '报告路径单引号不丢失'
    Assert-Equal $OriginalUserProfile $context.OriginalUserProfile '原用户目录尾部反斜线与引号保留'
    Assert-Equal $OriginalUserSid $context.OriginalUserSid '原账户明确传入'
    Assert-Equal ($AdminItemIds -join ',') ($admins.Id -join ',') '只传入已选管理员编号'
    Assert-Equal $ResultPath "C:\结'果\child.json" '子结果路径安全引用'
    Assert-True (-not $WhatIfPreference -and $ConfirmPreference -eq 'None') '已授权项目不二次交互'
}
$command = New-CleanAdminCommand 'Invoke-TestAdmin' "C:\报'告\checkup.json" $admins "C:\结'果\child.json" $context $request
$commandAst = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$errors)
Assert-Equal $errors.Count 0 '管理员命令可解析'
$calls = @($commandAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
Assert-Equal $calls.Count 1 '编码内容只调用自身脚本一次'
& ([scriptblock]::Create($calls[0].Extent.Text))
$elevationArguments = @(Get-CleanElevationArguments $command)
Assert-Equal $elevationArguments.Count 7 '提权宿主只有七个参数，不修改持久执行策略'
Assert-Equal ($elevationArguments[0..5] -join ' ') '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand' '宿主执行策略在编码命令前且仅作用于子进程'
Assert-Equal ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($elevationArguments[-1]))) $command '跨进程编码完整保留中文和引号'

# 使用假 Start-Process 验证真实适配器传入 RunAs、Wait 和完整编码命令。
& {
    function Test-Path { param($LiteralPath, $PathType); return $script:hasPwsh }
    function Start-Process {
        param($FilePath, $ArgumentList, [string]$Verb, [switch]$Wait, [switch]$PassThru, $ErrorAction)
        Assert-Equal $Verb 'RunAs' '通过系统权限确认提权'
        Assert-True ($Wait -and $PassThru) '等待一次子进程并读取退出码'
        Assert-Equal $FilePath (Join-Path $PSHOME $script:expectedHost) '支持两种 Windows 宿主'
        Assert-Equal ($ArgumentList -join ' ') ($elevationArguments -join ' ') '真实启动器使用纯函数生成的全部参数'
        Assert-Equal $ArgumentList[-2] '-EncodedCommand' '通过编码命令传递数组'
        Assert-Equal ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))) $command '子进程参数完整'
        $fakeProcess = [pscustomobject]@{ ExitCode = 0 }
        $fakeProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:disposed = $true }
        return $fakeProcess
    }
    foreach ($hostName in @('pwsh.exe', 'powershell.exe')) {
        $script:expectedHost = $hostName; $script:hasPwsh = $hostName -eq 'pwsh.exe'
        $script:disposed = $false
        Assert-Equal (Start-CleanAdminProcess $command) 0 '读取系统子进程退出码'
        Assert-True $script:disposed '释放进程对象'
    }
}

# 真实提权适配器与合并流程之间只替换系统启动和读取边界；所有事件均在内存中。
& {
    function Test-Path { param($LiteralPath, $PathType); return $true }
    function Start-Process {
        param($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru, $ErrorAction)
        $script:launchCount++
        if ($script:phaseCase -eq 'declined') { throw '用户拒绝授权' }
        if ($script:phaseCase -eq 'launch') { throw '无法启动程序' }
        $code = 0
        if ($script:phaseCase -eq 'exit') { $code = 1 }
        $process = [pscustomobject]@{ ExitCode = $code }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:phaseDisposed = $true }
        return $process
    }
    function Read-CleanJsonFile {
        param($Path)
        $script:readCount++
        if ($script:phaseCase -eq 'missing') { throw '结果缺失或无法读取' }
        return @{ Value = @{ Schema = 'invalid' } }
    }
    foreach ($case in @('declined', 'launch', 'exit', 'missing', 'invalid')) {
        $script:phaseCase = $case; $script:launchCount = 0; $script:readCount = 0; $script:phaseDisposed = $false
        $rows = @(Invoke-CleanElevatedPhase $admins $context '/fake/clean.ps1' '/fake/report.json' '/fake/child.json' $request)
        Assert-Equal $script:launchCount 1 "$case 只启动一次，不重试清理"
        $expectedReason = '管理员清理步骤未正常完成，无法确认这些项目的清理结果'
        $expectedReads = 0
        if ($case -in @('declined', 'launch')) { $expectedReason = '没有获得管理员权限，已跳过' }
        else { Assert-True $script:phaseDisposed "$case 释放已启动进程" }
        if ($case -in @('missing', 'invalid')) { $expectedReads = 1 }
        Assert-Equal $script:readCount $expectedReads "$case 只在正常退出后读取结果"
        Assert-Equal $rows.Count $admins.Count "$case 保留全部管理员项目"
        foreach ($row in $rows) {
            Assert-Equal $row.Status 'Skipped' "$case 不报告清理成功"
            Assert-Equal $row.Reason $expectedReason "$case 准确说明启动失败或结果未知"
            Assert-Equal $row.FreedBytes $null "$case 不确认腾出空间"
            Assert-Equal $row.FreeBefore $null "$case 不确认清理前空间"
            Assert-Equal $row.FreeAfter $null "$case 不确认清理后空间"
        }
    }
}

$script:events = @(); $script:measurements = 0
function Get-CleanFreeBytes { $script:measurements++; return [long](1000 + 100 * $script:measurements) }
function Invoke-TestHandler {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Category, [string]$Action, [switch]$AcknowledgeIrreversible, [string]$Mode,
        [string]$OriginalUserSid, [string]$OriginalUserProfile)
    Assert-Equal ([Environment]::GetEnvironmentVariable('CLEANER_LOG_PATH')) $context.LogPath '旧处理器继承当前进程已解析的日志路径'
    $script:events += ('handler:' + $Category + $Action)
    Write-Host '处理器的内部维护输出，不应显示给用户'
    Assert-True ($ConfirmPreference -eq 'None') '处理器不重复询问'
    Assert-True (-not $WhatIfPreference) '演练不应进入处理器'
    if ($Action) {
        Assert-Equal $OriginalUserSid $context.OriginalUserSid '系统处理器接收原用户'
        Assert-Equal $OriginalUserProfile $context.OriginalUserProfile '系统处理器接收原目录'
    }
    if ($Category -eq 'Throw') {
        [pscustomobject]@{ DeletedCount = 1; SkippedItems = @(@{ Reason = '文件占用' }) }
        throw '模拟异常，不应该泄露的 SID 和 C:\\路径'
    }
    if ($Category -eq 'Locked') { [pscustomobject]@{ Result = 'partial'; SkippedItems = $locked }; return }
    [pscustomobject]@{ Result = 'done'; FreedBytes = 99999999 }
}
$item = Get-CleanItemDefinition 'cache:UserTemp'
$item | Add-Member -NotePropertyName HandlerPath -NotePropertyValue 'Invoke-TestHandler'
$originalHandlerLog = [Environment]::GetEnvironmentVariable('CLEANER_LOG_PATH')
$captured = @(Invoke-CleanItem $item $context 6>&1)
Assert-Equal ([Environment]::GetEnvironmentVariable('CLEANER_LOG_PATH')) $originalHandlerLog '处理器成功后恢复原日志环境变量'
Assert-Equal $captured.Count 1 '旧处理器内部主机输出被隐藏，输出只剩结果对象'
$row = $captured[0]
Assert-Equal $row.Status 'Done' '内存处理器正常结果'
Assert-Equal $row.FreedBytes 100 '使用 C 盘变化而非处理器字节数'
Assert-Equal $row.FreeBefore 1100 '每项记录执行前空间'
Assert-Equal $row.FreeAfter 1200 '每项记录执行后空间'
$item.Parameters.Category = 'Locked'
$row = Invoke-CleanItem $item $context
Assert-Equal $row.Status 'Partial' '真实捕获输出并映射'
Assert-True ($row.Reason -match '有 12 个文件') '捕获文件占用数'
$item.Parameters.Category = 'Throw'
$row = Invoke-CleanItem $item $context
Assert-Equal $row.Status 'Failed' '有输出后抛错仍为失败'
Assert-Equal ([Environment]::GetEnvironmentVariable('CLEANER_LOG_PATH')) $originalHandlerLog '处理器异常后也恢复原日志环境变量'
Assert-True ($row.Reason -match '文件正在被使用' -and $row.Reason -notmatch 'SID|C:\\') '保留输出中的跳过信息，异常使用普通中文'
$systemItem = Get-CleanItemDefinition 'system:Hibernate'
$systemItem | Add-Member -NotePropertyName HandlerPath -NotePropertyValue 'Invoke-TestHandler'
Assert-Equal (Invoke-CleanItem $systemItem $context).Status 'Done' '系统处理器使用固定参数调用'
Assert-Equal $script:measurements 8 '每项执行前后都测量'

# 下面覆盖所有 Windows 和副作用边界；测试期间只有内存事件记录。
$script:testReport = New-TestReport
$script:testReport.GeneratedAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
$script:testChild = $child
function Get-CleanerContext { param([string]$OriginalUserSid, [string]$OriginalUserProfile); $script:events += 'context'; return $context }
function Get-CleanCurrentSid { $script:events += 'identity'; return $script:currentSid }
function Read-CleanJsonFile {
    param([string]$Path)
    $script:events += ('read:' + $Path)
    if ($Path -eq '/fake/report.json') { return @{ Path = $Path; Value = $script:testReport } }
    return @{ Path = $Path; Value = $script:testChild }
}
function Get-CleanNewFilePath { param($Path, $Context); $script:events += 'path'; return '/fake/result.json' }
function New-CleanResultFile { param($Path, $Context); $script:events += 'create'; return @{ Stream = 'fake' } }
function Close-CleanResultFile { param($File); $script:events += 'close' }
function Write-CleanResultJson { param($File, $Result); $script:events += 'write'; $script:written = $Result }
function Write-CleanerLog { param($Action, $Path, $Result, $Context, $Message, $Confirm, $ErrorAction); $script:events += 'log' }
function Write-CleanerAudit { param($Action, $Path, $Result, $Context, $Message, $Confirm, $ErrorAction); $script:events += 'audit' }
function Invoke-CleanItem { param($Item, $Context); $script:events += ('run:' + $Item.Id); New-CleanItemResult $Item 'Done' '' 10 100 110 1 }
function Start-CleanAdminProcess {
    param($Command)
    $script:events += 'uac'
    if ($script:decline) { throw '拒绝授权' }
    $childRequest = [regex]::Match($Command, "-RequestId '([0-9a-f-]+)'").Groups[1].Value
    $script:testChild = @{ Schema = 'pc-care/clean/1'; Phase = 'Admin'; RequestId = $childRequest
        OriginalUserSid = $context.OriginalUserSid; CurrentUserSid = $script:childSid; IsAdmin = $true
        Items = @(foreach ($admin in $script:childAdmins) { New-CleanItemResult $admin 'Done' '' 20 100 120 2 }) }
    return 0
}
$cmdletFake = New-Object psobject
$cmdletFake | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($target, $action); $script:events += 'shouldprocess'; return $true }
$mainArgs = @{ ReportPath = '/fake/report.json'; ScriptsRoot = (Join-Path $repoRoot 'scripts')
    ScriptPath = '/fake/clean.ps1'; Cmdlet = $cmdletFake }
$script:events = @(); $script:measurements = 0; $script:decline = $false
Invoke-CleanCommand @mainArgs -Include @('system:RecycleBin') -WhatIfRun $true
Assert-Equal ($script:events -join ',') 'context,read:/fake/report.json' 'WhatIf 仅只读账户和报告，无处理器、提权、结果、日志或写入'
Assert-Equal $script:measurements 0 'WhatIf 不测量执行收益'
$script:events = @(); $script:decline = $true
$output = @(Invoke-CleanCommand @mainArgs)
Assert-Equal @($script:events | Where-Object { $_ -eq 'uac' }).Count 1 '多个管理员项目只请求一次权限'
Assert-Equal @($script:events | Where-Object { $_ -like 'run:*' }).Count 1 '普通进程先清理用户项'
Assert-True ([array]::IndexOf($script:events, 'run:cache:UserTemp') -lt [array]::IndexOf($script:events, 'uac')) '普通权限阶段先于提权'
Assert-Equal ($script:written.Items.Status -join ',') 'Done,Skipped,Skipped,Skipped,Skipped,Skipped' '拒绝 UAC 不影响已完成用户项，未选项保留'
Assert-Equal $script:written.Schema 'pc-care/clean/1' '新结果架构'
Assert-Equal $script:written.Ignored.Count 3 '结果列出忽略项目'
Assert-Equal $output[-1] 'RESULT: /fake/result.json' '输出最终结果路径'
Assert-True ($script:events -contains 'create' -and $script:events -contains 'write' -and $script:events -contains 'close') '结果文件创建、写入和释放'
Assert-True ((Format-CleanSummary $script:written) -match '回收站未清理：你没有选择') '最终说明未选回收站'
$script:decline = $false; $script:childSid = $context.OriginalUserSid
$script:childAdmins = (Split-CleanPhases (Get-TestPlan (New-TestReport) @('system:RecycleBin')).Selected).Admin
$script:events = @()
Invoke-CleanCommand @mainArgs -Include @('system:RecycleBin') | Out-Null
Assert-Equal ($script:written.Items.Status -join ',') 'Done,Done,Done,Done,Skipped,Skipped' '普通父进程合并成功管理员子结果'
Assert-Equal @($script:events | Where-Object { $_ -eq 'uac' }).Count 1 '成功提权也仅启动一次'
Assert-Equal $script:written.Items[1].FreedBytes 20 '成功管理员项保留各自计量'
Assert-Equal @($script:events | Where-Object { $_ -like 'run:*' }).Count 1 '管理员项由子进程处理，父进程不重复'
$script:childSid = '其他账户'; $script:events = @()
Invoke-CleanCommand @mainArgs -Include @('system:RecycleBin') | Out-Null
Assert-Equal ($script:written.Items.Status -join ',') 'Done,Skipped,Skipped,Skipped,Skipped,Skipped' '错误账户子结果不影响已完成用户阶段'
Assert-True ($script:written.Items[1].Reason -match '没有获得原账户') '错误账户子结果说明清楚'
$context.IsAdmin = $true; $script:events = @()
Invoke-CleanCommand @mainArgs -Include @('system:RecycleBin') | Out-Null
Assert-Equal @($script:events | Where-Object { $_ -eq 'uac' }).Count 0 '同账户已提权不再启动子进程'
Assert-Equal @($script:events | Where-Object { $_ -like 'run:*' }).Count 4 '已提权进程执行全部已选项'
Assert-Equal ($script:written.Items.Status -join ',') 'Done,Done,Done,Done,Skipped,Skipped' '已提权合并未选项'
$context.IsAdmin = $false; $script:currentSid = '其他账户'; $script:events = @()
Assert-Rejected { Invoke-CleanCommand @mainArgs -AdminPhase $true -AdminItemIds @('cache:WindowsTemp') -OriginalUserSid $context.OriginalUserSid -OriginalUserProfile $context.OriginalUserProfile -RequestId $request } '原账户的管理员权限' '不同账户的子进程停止'
Assert-Equal ($script:events -join ',') 'identity' '不同账户在任何读取、日志或清理之前停止'
$script:currentSid = $context.OriginalUserSid; $context.IsAdmin = $true; $script:events = @()
Invoke-CleanCommand @mainArgs -AdminPhase $true -AdminItemIds @('system:RecycleBin') -OriginalUserSid $context.OriginalUserSid -OriginalUserProfile $context.OriginalUserProfile -RequestId $request | Out-Null
Assert-Equal ($script:written.Items.Id -join ',') 'system:RecycleBin' '子进程只执行传入管理员项目，不重复全部 safe'
Assert-Equal $script:written.RequestId $request.ToString() '子结果绑定本次请求'
Assert-Equal $script:written.Phase 'Admin' '子结果标记阶段'
Assert-Equal @($script:events | Where-Object { $_ -eq 'uac' }).Count 0 '内部阶段不递归提权'

# 结果路径不可创建时，必须在任何清理和日志之前停止。
& {
    function New-CleanResultFile { param($Path, $Context); $script:events += 'create-failed'; throw '模拟不可写目录' }
    $script:events = @()
    Assert-Rejected { Invoke-CleanCommand @mainArgs } '无法创建新的清理结果文件' '先确认结果可以保存，再开始清理'
    Assert-Equal @($script:events | Where-Object { $_ -like 'run:*' -or $_ -in @('uac', 'log', 'audit', 'write') }).Count 0 '创建结果失败没有执行清理或日志'
}

# 结果目录本身不可写时，仍经标准输出交付可解析的诊断，且绝不开始清理。
& {
    function New-CleanResultFile { param($Path, $Context); throw '模拟结果目录不可写' }
    $script:events = @(); $messages = [Collections.Generic.List[string]]::new(); $reason = ''
    try { Invoke-CleanCommand @mainArgs | ForEach-Object { $messages.Add([string]$_) } }
    catch { $reason = $_.Exception.Message }
    $failure = $messages[0] | ConvertFrom-Json
    Assert-Equal $failure.Schema 'pc-care/clean/1' '结果无法保存仍使用原版本的 JSON'
    Assert-Equal $failure.Diagnostics.Stage 'Clean/ResultFile' '结果创建失败保留阶段'
    Assert-True ($failure.Diagnostics.RequestedPath -match 'clean-.*\.json$') '结果创建失败保留请求路径'
    Assert-Equal $failure.Diagnostics.Reason '模拟结果目录不可写' '结果创建失败保留原始原因'
    Assert-Equal $messages[-1] 'RESULT: 未保存' '不能冒充结果文件已保存'
    Assert-True ($reason -match '无法创建新的清理结果文件') '用户错误仍是普通中文'
    Assert-Equal @($script:events | Where-Object { $_ -like 'run:*' -or $_ -in @('uac', 'log', 'audit', 'write') }).Count 0 '无法创建结果不执行清理'
}
# 开始日志失败时诊断进入已保留的结果文件；最终路径差异供代理排查，不出现在用户原因里。
& {
    function Write-CleanerLog {
        param($Action, $Path, $Result, $Context, $Message, $Confirm, $ErrorAction)
        $exception = [IO.IOException]::new('模拟父目录最终路径不同')
        $exception.Data['RequestedPath'] = 'C:\requested\Logs'
        $exception.Data['FinalPath'] = 'C:\redirected\Logs'
        throw $exception
    }
    $script:events = @()
    Invoke-CleanCommand @mainArgs | Out-Null
    Assert-Equal $script:written.Schema 'pc-care/clean/1' '诊断只增加字段，不改变版本'
    Assert-Equal $script:written.Diagnostics.Stage 'Clean/StartLog' '开始日志失败保留阶段'
    Assert-Equal $script:written.Diagnostics.RequestedPath 'C:\requested\Logs' '保留失败祖先的请求路径'
    Assert-Equal $script:written.Diagnostics.FinalPath 'C:\redirected\Logs' '保留句柄最终路径'
    Assert-Equal $script:written.Diagnostics.Reason '模拟父目录最终路径不同' '不吞掉开始日志异常'
    Assert-True ($script:written.Items[0].Reason -match '清理记录无法完整保存' -and $script:written.Items[0].Reason -notmatch 'C:\\') '用户原因保持普通中文'
    Assert-Equal @($script:events | Where-Object { $_ -like 'run:*' -or $_ -eq 'uac' }).Count 0 '开始日志失败绝不执行清理或提权'
    Assert-True ($script:events -contains 'write' -and $script:events -contains 'close') '开始日志失败仍写结果并释放句柄'
}

Write-Host ('PASS t5-clean: {0} assertions; AST-only loading; in-memory fakes; no script body, Windows API, cleanup or child process executed.' -f $script:assertions)
