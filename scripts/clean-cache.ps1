<#
.SYNOPSIS
清理第 1 层可再生缓存，并汇总释放量和跳过项。
.DESCRIPTION
请先关闭有关应用。所有文件删除均交给 common.ps1 的 Remove-SafeItem，
由共享库检查白名单、重解析点、文件年龄和占用情况。浏览器运行时跳过其缓存，
仅按白名单处理各浏览器缓存，不处理用户数据。应用仍运行或进程查询失败时跳过该应用。
开发缓存实际执行时才查询缓存路径，全部通过 DevCache 安全校验后才使用官方命令清理，
不直接删除 .m2 或 .gradle。检测到安装、更新活动或待重启标志时跳过 WindowsTemp。
开发工具命令不支持统一的文件年龄筛选，可能清理最近使用的缓存；需要保留
近期开发缓存时，请不要选择 DevCache。其释放量使用系统卷空闲空间变化估算，
可能受其他进程影响。文件删除量采用共享库报告的值。
支持 Windows PowerShell 5.1 和 PowerShell 7。-WhatIf 不启动任何开发工具、不删除或写日志；
仅报告计划查询和清理的命令，缓存路径标为待解析。实际执行期间持有缓存祖先的
防替换句柄；缓存根不锁定，以允许官方工具删除根目录，仍有根及子项并发替换风险。
.PARAMETER Category
可多选 UserTemp、WindowsTemp、ThumbnailCache、BrowserCache、AppCache、ShaderCache、InetCache、SystemLogs、DevCache；默认全部。
.PARAMETER MinAgeHours
文件最短未修改时间（小时），默认 24，范围 0..876000。仅作用于 Remove-SafeItem；
SystemLogs 至少保留 168 小时内的文件；开发工具的官方缓存清理命令不支持此限制。
.EXAMPLE
.\clean-cache.ps1 -Category UserTemp,ThumbnailCache -MinAgeHours 48 -WhatIf
演练清理至少 48 小时未修改的用户临时文件和缩略图缓存。
.EXAMPLE
.\clean-cache.ps1 -Category BrowserCache,DevCache
关闭浏览器后清理浏览器缓存，并调用可用开发工具的官方缓存清理命令。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()]
    [ValidateSet('UserTemp', 'WindowsTemp', 'ThumbnailCache', 'BrowserCache', 'AppCache', 'ShaderCache', 'InetCache', 'SystemLogs', 'DevCache')]
    [string[]]$Category = @('UserTemp', 'WindowsTemp', 'ThumbnailCache', 'BrowserCache', 'AppCache', 'ShaderCache', 'InetCache', 'SystemLogs', 'DevCache'),

    [ValidateRange(0, 876000)]
    [double]$MinAgeHours = 24,

    # Zero preserves the unbounded legacy handler; clean.ps1 selects a budget.
    [ValidateRange(0, 3600)][int]$TimeBudgetSeconds = 0
)

if ($env:OS -ne 'Windows_NT') {
    throw '此脚本仅支持 Windows；请勿在其他操作系统上运行。'
}

. (Join-Path $PSScriptRoot "common.ps1")

# 共享接口未限定返回对象的字段名；兼容常见命名，缺少安全结论时拒绝继续。
function Get-CacheResultField {
    param($InputObject, [string[]]$Names, $Default = $null)
    if ($null -ne $InputObject) {
        foreach ($name in $Names) {
            if ($InputObject -is [hashtable]) {
                if ($InputObject.ContainsKey($name)) { return ,($InputObject[$name]) }
            }
            elseif ($InputObject -is [System.Collections.IDictionary]) {
                if ($InputObject.Contains($name)) { return ,($InputObject[$name]) }
            }
            else {
                $property = $InputObject.PSObject.Properties[$name]
                # 保留集合自身，避免单元素 pkgs_dirs 数组被管道解包成字符串。
                if ($null -ne $property) { return ,($property.Value) }
            }
        }
    }
    return ,$Default
}

$script:CacheCleanerCmdlet = $PSCmdlet
$script:CacheCleanerContext = Get-CleanerContext
$script:CacheCleanerSummary = [ordered]@{}
$script:CacheCleanerBlockedApps = @{}
$script:CacheCleanerDeadlineUtc = $null
if ($TimeBudgetSeconds -gt 0) { $script:CacheCleanerDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeBudgetSeconds) }
$script:CacheCleanerBudgetReported = @{}
$script:CacheCleanerLogPath = Get-CacheResultField $script:CacheCleanerContext @('LogPath', 'LogFilePath') '共享日志'
$cacheUserProfile = Get-CacheResultField $script:CacheCleanerContext @('OriginalUserProfile', 'UserProfile', 'UserProfilePath', 'OriginalProfilePath')
if ([string]::IsNullOrWhiteSpace([string]$cacheUserProfile)) {
    throw '共享上下文未提供原用户目录；为避免误清管理员账户，已停止。'
}
$cacheLocalAppData = Get-CacheResultField $script:CacheCleanerContext @('LocalAppData')
if ([string]::IsNullOrWhiteSpace([string]$cacheLocalAppData)) {
    throw '共享上下文未提供原用户已解析的 LocalAppData；为避免清理错误目录，已停止。'
}
$cacheUserTemp = Get-CacheResultField $script:CacheCleanerContext @('OriginalTempPath', 'UserTempPath', 'TempPath')
if ([string]::IsNullOrWhiteSpace([string]$cacheUserTemp)) {
    # 只有当前账户就是原账户时才使用进程的 TEMP，支持用户自定义临时目录。
    if ([string]::Equals([string]$cacheUserProfile, [string]$env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $cacheUserTemp = $env:TEMP
    }
    else { $cacheUserTemp = Join-Path $cacheLocalAppData 'Temp' }
}
$cacheSystemRoot = $env:SystemRoot
if ([string]::IsNullOrWhiteSpace($cacheSystemRoot)) {
    throw '无法确定 Windows 系统目录。'
}

foreach ($name in @($Category | Select-Object -Unique)) {
    $script:CacheCleanerSummary[$name] = [pscustomobject][ordered]@{
        Category = $name
        Result = 'skipped'
        FreedBytesEstimate = [long]0
        SkippedReasons = @()
        FreedBytes = [long]0
        EstimatedFreedBytes = [long]0
        Measurement = 'Remove-SafeItem'
        ProcessedCount = 0
        SkippedCount = 0
        WhatIf = [bool]$WhatIfPreference
        SkippedItems = New-Object 'System.Collections.Generic.List[object]'
    }
}

function Write-CacheAudit {
    param([string]$Action, [string]$Path, [string]$Result, [long]$Bytes = 0)
    # 日志本身也是写操作；WhatIf 下不得初始化或追加日志文件。
    if ($WhatIfPreference) { return }
    if ($script:CacheCleanerCmdlet.ShouldProcess([string]$script:CacheCleanerLogPath, '写入缓存清理日志')) {
        Write-CleanerLog -Action $Action -Path $Path -Result $Result -Bytes $Bytes | Out-Null
    }
}

function Add-CacheSkip {
    param([string]$Name, [string]$Path, [string]$Reason, [switch]$Quiet)
    $row = $script:CacheCleanerSummary[$Name]
    $row.SkippedItems.Add([pscustomobject]@{ Path = $Path; Reason = $Reason })
    $row.SkippedCount++
    if (-not $Quiet) { Write-Warning ('[{0}] 跳过 {1}：{2}' -f $Name, $Path, $Reason) }
    Write-CacheAudit -Action ('CacheSkip/' + $Name) -Path $Path -Result ('跳过：' + $Reason)
}

function Remove-CacheTarget {
    param([string]$Name, [string]$LiteralPath, [string[]]$ProcessNames = @(), [string]$App)
    if (Test-CacheTimeBudget -Name $Name -LiteralPath $LiteralPath) { return }
    $effectiveMinAgeHours = $MinAgeHours
    if ($Name -eq 'SystemLogs') { $effectiveMinAgeHours = [Math]::Max([double]168, $MinAgeHours) }
    try {
        if (-not (Test-Path -LiteralPath $LiteralPath -ErrorAction Stop)) {
            Add-CacheSkip $Name $LiteralPath '路径不存在'
            return
        }
        $safe = Test-SafeTarget -LiteralPath $LiteralPath -Category $Name -Context $script:CacheCleanerContext -ErrorAction Stop
        if (-not $safe.IsSafe) { Add-CacheSkip $Name $LiteralPath $safe.Reason; return }
        if (-not $script:CacheCleanerCmdlet.ShouldProcess($LiteralPath, ('清理 {0}；保留最近 {1} 小时修改的文件' -f $Name, $effectiveMinAgeHours))) {
            Add-CacheSkip $Name $LiteralPath 'WhatIf 演练或用户未确认'
            return
        }
        # 确认后再检查应用状态；不终止进程，状态变化时保留该应用余下的目标。
        if ($ProcessNames.Count -gt 0 -and -not (Test-CacheAppStopped $Name $ProcessNames $LiteralPath $App)) { return }
        $budgetArguments = @{}
        $deadline = $ExecutionContext.SessionState.PSVariable.GetValue('script:CacheCleanerDeadlineUtc')
        if ($null -ne $deadline) { $budgetArguments.DeadlineUtc = $deadline }
        $results = @(Remove-SafeItem -LiteralPath $LiteralPath -Category $Name -MinAgeHours $effectiveMinAgeHours -Context $script:CacheCleanerContext -Confirm:$false -ErrorAction Stop @budgetArguments)
        if ($results.Count -eq 0) {
            Add-CacheSkip $Name $LiteralPath '共享删除函数未返回结果，释放量未知；请检查共享日志'
            return
        }
        foreach ($result in $results) {
            $bytes = Get-CacheResultField $result @('FreedBytes', 'BytesFreed', 'ReleasedBytes', 'Bytes') 0
            $safeBytes = [Math]::Max([long]0, [long]$bytes)
            $script:CacheCleanerSummary[$Name].FreedBytes += $safeBytes
            $skipped = Get-CacheResultField $result @('SkippedItems', 'Skipped', 'SkippedPaths') @()
            foreach ($item in @($skipped)) {
                if ($null -eq $item) { continue }
                $skipPath = Get-CacheResultField $item @('Path', 'LiteralPath') $LiteralPath
                $reason = Get-CacheResultField $item @('Reason', 'Message') ([string]$item)
                if ($item -is [string]) {
                    $skipPath = $item
                    $reason = '共享库跳过；原因详见共享日志'
                }
                Add-CacheSkip $Name ([string]$skipPath) ([string]$reason)
            }
            if ((Get-CacheResultField $result @('DeletedCount') 0) -gt 0 -or
                (Get-CacheResultField $result @('IsComplete') ($skipped.Count -eq 0))) {
                $script:CacheCleanerSummary[$Name].Result = 'done'
            }
            Write-CacheAudit -Action ('CacheRemove/' + $Name) -Path $LiteralPath -Result '已处理；详细跳过项见共享删除结果' -Bytes $safeBytes
        }
        $script:CacheCleanerSummary[$Name].ProcessedCount++
    }
    catch {
        Add-CacheSkip $Name $LiteralPath $_.Exception.Message
    }
}

function Test-CacheTimeBudget {
    param([string]$Name, [string]$LiteralPath)
    $deadline = $ExecutionContext.SessionState.PSVariable.GetValue('script:CacheCleanerDeadlineUtc')
    if ($null -eq $deadline -or [DateTime]::UtcNow -lt $deadline) { return $false }
    if (-not $script:CacheCleanerBudgetReported.ContainsKey($Name)) {
        $script:CacheCleanerBudgetReported[$Name] = $true
        Add-CacheSkip $Name $LiteralPath '已达到快速清理时间预算，剩余内容保留；可稍后继续或使用完整模式。' -Quiet
    }
    return $true
}

function Remove-CacheDirectoryChildren {
    param([string]$Name, [string]$LiteralPath, [string]$Filter)
    try {
        if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container -ErrorAction Stop)) {
            Add-CacheSkip $Name $LiteralPath '目录不存在'
            return
        }
        if ([string]::IsNullOrWhiteSpace($Filter)) {
            # 临时目录在枚举前也使用共享校验，不重复实现安全规则。
            $safe = Test-SafeTarget -LiteralPath $LiteralPath -Category $Name -ErrorAction Stop
            $allowed = $false
            if ($safe -is [bool]) { $allowed = $safe }
            else { $allowed = (Get-CacheResultField $safe @('IsSafe', 'Safe', 'Allowed', 'Success') $false) -eq $true }
            if (-not $allowed) {
                $reason = Get-CacheResultField $safe @('Reason', 'Message') '共享路径校验未通过'
                Add-CacheSkip $Name $LiteralPath ([string]$reason)
                return
            }
            # One shared traversal preserves the actual whitelist root. The old
            # per-child calls treated every temporary subdirectory as a root,
            # repeatedly validating it and retaining thousands of empty roots.
            Remove-CacheTarget $Name $LiteralPath
            return
        }
        # 缩略图白名单可以仅允许匹配文件，不要求 Explorer 父目录可被删除。
        $arguments = @{ LiteralPath = $LiteralPath; Force = $true; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($Filter)) {
            $arguments['Filter'] = $Filter
            $arguments['File'] = $true
        }
        # 不递归枚举；每个子项由 Remove-SafeItem 再次校验后处理。
        foreach ($item in @(Get-ChildItem @arguments)) {
            if (Test-CacheTimeBudget -Name $Name -LiteralPath $LiteralPath) { break }
            Remove-CacheTarget $Name $item.FullName
        }
    }
    catch {
        Add-CacheSkip $Name $LiteralPath $_.Exception.Message
    }
}

function Test-CacheAppStopped {
    param([string]$Name, [string[]]$ProcessNames, [string]$Target, [string]$App)
    if ([string]::IsNullOrWhiteSpace($App)) { $App = $ProcessNames -join '/' }
    $key = $Name + '/' + $App
    if ($script:CacheCleanerBlockedApps.ContainsKey($key)) {
        Add-CacheSkip $Name $Target $script:CacheCleanerBlockedApps[$key]
        return $false
    }
    $reason = $null
    try {
        # 查询所有进程以区分“不存在”和“查询失败”；查询失败同样跳过。
        $running = @(Get-Process -ErrorAction Stop | Where-Object { $ProcessNames -contains $_.ProcessName })
        if ($running.Count -gt 0) {
            $reason = '检测到 {0} 进程（{1}）；请完全退出应用（含后台进程）后重试' -f $App, (($running | Select-Object -ExpandProperty ProcessName -Unique) -join '、')
        }
    }
    catch { $reason = '无法可靠查询 ' + $App + ' 的进程，保留该应用缓存：' + $_.Exception.Message }
    if ($null -ne $reason) {
        $script:CacheCleanerBlockedApps[$key] = $reason
        Add-CacheSkip $Name $Target $reason
        return $false
    }
    return $true
}

function Get-CacheWindowsTempActivity {
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    try {
        $processNames = @('msiexec', 'TrustedInstaller', 'TiWorker', 'wuauclt', 'usoclient')
        foreach ($process in @(Get-Process -ErrorAction Stop)) {
            if ($processNames -contains $process.ProcessName) {
                $reasons.Add('安装/更新进程正在运行：' + $process.ProcessName)
            }
        }
        $pendingKeys = @(
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress'
        )
        foreach ($key in $pendingKeys) {
            if (Test-Path -LiteralPath $key -ErrorAction Stop) {
                $reasons.Add('存在安装/更新待完成或待重启标志：' + $key)
            }
        }
        $sessionManager = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        foreach ($name in @('PendingFileRenameOperations', 'PendingFileRenameOperations2')) {
            $pending = Get-CacheResultField $sessionManager @($name)
            if (@($pending | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
                $reasons.Add('存在待重启文件操作：' + $name)
            }
        }
    }
    catch {
        # 无法完整查询时也不清理，避免把“未知”当作“空闲”。
        $reasons.Add('无法可靠检测安装/更新活动：' + $_.Exception.Message)
    }
    return [pscustomobject]@{ IsBusy = ($reasons.Count -gt 0); Reasons = $reasons.ToArray() }
}

function Resolve-CacheTargetPaths {
    param([string]$Name, [string]$Pattern)
    $expanded = Expand-CleanerPath -Pattern $Pattern -Context $script:CacheCleanerContext
    if ($expanded -notmatch '[*?]') { return $expanded }
    $segments = $expanded.Split([char]'\')
    $wildcards = @($segments | Where-Object { $_ -match '[*?]' })
    if ($wildcards.Count -ne 1 -or $wildcards[0] -ne '*') { throw '缓存路径只允许一个完整路径段的 * 通配符。' }
    $index = [Array]::IndexOf($segments, '*')
    $parent = $segments[0..($index - 1)] -join '\'
    $suffix = $segments[($index + 1)..($segments.Count - 1)] -join '\'
    $check = Test-CleanerPathChain -LiteralPath $parent -AllowMissing
    if (-not $check.IsSafe) { throw $check.Reason }
    if (-not $check.Exists) { Add-CacheSkip $Name $parent '通配目标的父目录不存在'; return }
    # 与浏览器 profile 相同，只枚举一个路径段；共享枚举器保护祖先且不递归。
    foreach ($child in @(Get-CleanerChildren -LiteralPath $parent)) {
        if (-not $child.PSIsContainer) { continue }
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-CacheSkip $Name $child.FullName '重解析点，拒绝跟随'
            continue
        }
        Join-Path $child.FullName $suffix
    }
}

function Clear-CacheWhitelistCategory {
    param([string]$Name)
    foreach ($entry in (Get-CleanerTargets).Categories[$Name].Targets) {
        try {
            $processNames = @()
            if ($entry.ContainsKey('ProcessNames')) { $processNames = @($entry['ProcessNames']) }
            if ($processNames.Count -gt 0 -and -not (Test-CacheAppStopped $Name $processNames $entry.Path $entry['App'])) { continue }
            foreach ($path in @(Resolve-CacheTargetPaths -Name $Name -Pattern $entry.Path)) {
                Remove-CacheTarget -Name $Name -LiteralPath $path -ProcessNames $processNames -App $entry['App']
            }
        }
        catch { Add-CacheSkip $Name $entry.Path $_.Exception.Message }
    }
}

function Clear-CacheBrowsers {
    Clear-CacheWhitelistCategory 'BrowserCache'
}

function Get-CacheSystemFreeBytes {
    try {
        $root = [System.IO.Path]::GetPathRoot($cacheSystemRoot)
        $drive = New-Object System.IO.DriveInfo -ArgumentList $root
        return [long]$drive.AvailableFreeSpace
    }
    catch { return $null }
}

function Invoke-CachePathQuery {
    [CmdletBinding()]
    param([string]$FilePath, [string[]]$ArgumentList)
    $fixedQueries = @('config get cache', 'cache dir', 'info --json', 'nuget locals all --list --force-english-output', 'store path', 'env GOCACHE', 'env GOMODCACHE')
    if ($null -eq $ArgumentList -or $fixedQueries -notcontains ($ArgumentList -join ' ') -or
        @($ArgumentList | Where-Object { $_ -match '\s' }).Count -gt 0) {
        throw '只允许固定的开发缓存路径查询；拒绝其他参数。'
    }
    $description = '查询开发缓存路径：' + $FilePath + ' ' + ($ArgumentList -join ' ')
    # 查询也可能初始化用户文件或写工具日志；演练绝不启动进程，防止调用方绕过。
    if ($WhatIfPreference) { throw ('WhatIf：' + $description + '；路径待解析，未启动工具。') }
    $results = @(Invoke-External -FilePath $FilePath -ArgumentList $ArgumentList -Description $description `
        -Context $script:CacheCleanerContext -Confirm:$false -ErrorAction Stop)
    if ($results.Count -ne 1) { throw '缓存路径查询未返回唯一的外部命令结果。' }
    $result = $results[0]
    $exitCode = Get-CacheResultField $result @('ExitCode')
    $skipped = Get-CacheResultField $result @('Skipped', 'WasWhatIf') $false
    if ($skipped -or $null -eq $exitCode -or [int]$exitCode -ne 0) {
        throw '缓存路径查询未成功执行，不能确定清理范围。'
    }
    $outputText = Get-CacheResultField $result @('StandardOutput', 'StdOut', 'Output')
    if ([string]::IsNullOrWhiteSpace([string]$outputText)) { throw '缓存路径查询输出为空，不能确定清理范围。' }
    return [string]$outputText
}

function Get-CacheDeveloperPath {
    param([ValidateSet('npm', 'pip', 'conda', 'dotnet', 'yarn', 'pnpm', 'go')][string]$Name, [string]$FilePath)
    $paths = New-Object 'System.Collections.Generic.List[string]'
    switch ($Name) {
        { $_ -in @('npm', 'pip', 'yarn', 'pnpm') } {
            $queryArguments = @('config', 'get', 'cache')
            if ($Name -in @('pip', 'yarn')) { $queryArguments = @('cache', 'dir') }
            if ($Name -eq 'pnpm') { $queryArguments = @('store', 'path') }
            $text = Invoke-CachePathQuery -FilePath $FilePath -ArgumentList $queryArguments
            $lines = @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($lines.Count -ne 1) { throw ($Name + ' 未返回唯一的缓存目录；拒绝猜测路径。') }
            $paths.Add($lines[0])
        }
        'go' {
            foreach ($variable in @('GOCACHE', 'GOMODCACHE')) {
                $text = Invoke-CachePathQuery -FilePath $FilePath -ArgumentList @('env', $variable)
                $lines = @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($lines.Count -ne 1) { throw ('go env ' + $variable + ' 未返回唯一缓存目录；拒绝猜测路径。') }
                $paths.Add($lines[0])
            }
        }
        'conda' {
            $text = Invoke-CachePathQuery -FilePath $FilePath -ArgumentList @('info', '--json')
            $info = ConvertFrom-Json -InputObject $text -ErrorAction Stop
            $packageDirectories = Get-CacheResultField $info @('pkgs_dirs')
            if ($null -eq $packageDirectories -or $packageDirectories -is [string] -or
                $packageDirectories -isnot [System.Collections.IEnumerable] -or @($packageDirectories).Count -eq 0) {
                throw 'conda info --json 未返回完整的 pkgs_dirs 数组；拒绝清理。'
            }
            foreach ($directory in $packageDirectories) {
                if ($directory -isnot [string] -or [string]::IsNullOrWhiteSpace($directory)) {
                    throw 'conda pkgs_dirs 包含无效目录；拒绝清理。'
                }
                $paths.Add($directory)
            }
        }
        'dotnet' {
            # 固定英文标签，且要求四类路径齐全；不按“看起来像路径”的片段猜测。
            $text = Invoke-CachePathQuery -FilePath $FilePath -ArgumentList @('nuget', 'locals', 'all', '--list', '--force-english-output')
            $locations = @{}
            $kinds = @('http-cache', 'global-packages', 'temp', 'plugins-cache')
            foreach ($line in @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                $locationMatch = [regex]::Match($line, '^\s*(?<Kind>http-cache|global-packages|temp|plugins-cache)\s*:\s*(?<Path>.+)$')
                if (-not $locationMatch.Success) { throw 'dotnet NuGet 路径列表包含无法识别的输出；拒绝清理。' }
                $kind = $locationMatch.Groups['Kind'].Value
                if ($locations.ContainsKey($kind)) { throw ('dotnet NuGet 路径列表重复：' + $kind) }
                $locations[$kind] = $locationMatch.Groups['Path'].Value
            }
            foreach ($kind in $kinds) {
                if (-not $locations.ContainsKey($kind)) { throw ('dotnet NuGet 路径列表缺少：' + $kind) }
                $paths.Add($locations[$kind])
            }
            # 同时核对影响清理位置的显式环境配置，防止配置与查询结果不一致时漏检。
            foreach ($variable in @('NUGET_PACKAGES', 'NUGET_HTTP_CACHE_PATH', 'NUGET_PLUGINS_CACHE_PATH', 'NUGET_SCRATCH')) {
                $configured = [Environment]::GetEnvironmentVariable($variable)
                if (-not [string]::IsNullOrWhiteSpace($configured)) { $paths.Add($configured) }
            }
        }
    }
    return $paths.ToArray()
}

function Assert-CacheDeveloperTarget {
    param([string]$Name, [string[]]$Paths)
    if ($null -eq $Paths -or $Paths.Count -eq 0) { throw ($Name + ' 未解析出任何缓存路径。') }
    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $Paths) {
        try {
            # 某些可选缓存根尚未创建；仍核实所有已有祖先、禁止区和固定白名单。
            $safe = Test-SafeTarget -LiteralPath $path -Category DevCache -Context $script:CacheCleanerContext -AllowMissing -ErrorAction Stop
            $allowed = $false
            if ($safe -is [bool]) { $allowed = $safe }
            else { $allowed = (Get-CacheResultField $safe @('IsSafe', 'Safe', 'Allowed', 'Success') $false) -eq $true }
            if (-not $allowed) {
                $reason = Get-CacheResultField $safe @('Reason', 'Message') '共享路径校验未通过'
                $failures.Add($path + '：' + [string]$reason)
            }
        }
        catch { $failures.Add($path + '：' + $_.Exception.Message) }
    }
    if ($failures.Count -gt 0) {
        throw ($Name + ' 的缓存路径未全部通过 DevCache 安全校验，跳过整个工具：' + ($failures.ToArray() -join '；'))
    }
}

function Clear-CacheDeveloperTools {
    $script:CacheCleanerSummary['DevCache'].Measurement = 'SystemVolumeFreeSpaceEstimate'
    $tools = @(
        @{ Name = 'npm'; Query = 'config get cache'; Arguments = @('cache', 'clean', '--force') },
        @{ Name = 'pip'; Query = 'cache dir'; Arguments = @('cache', 'purge') },
        @{ Name = 'conda'; Query = 'info --json'; Arguments = @('clean', '--tarballs', '--packages', '-y') },
        @{ Name = 'dotnet'; Query = 'nuget locals all --list --force-english-output'; Arguments = @('nuget', 'locals', 'all', '--clear') },
        @{ Name = 'yarn'; Query = 'cache dir'; Arguments = @('cache', 'clean') },
        @{ Name = 'pnpm'; Query = 'store path'; Arguments = @('store', 'prune') },
        @{ Name = 'go'; Query = 'env GOCACHE / go env GOMODCACHE'; Arguments = @('clean', '-cache'); AdditionalArguments = @('clean', '-modcache') }
    )
    # 必须先于工具发现、身份核实和路径解析返回；只描述计划，不启动查询或清理。
    if ($WhatIfPreference) {
        foreach ($tool in $tools) {
            $plannedArguments = $tool['Arguments'] -join ' '
            if ($tool['Name'] -eq 'npm') { $plannedArguments = '--cache <待解析> ' + $plannedArguments }
            if ($tool['Name'] -eq 'pip') { $plannedArguments = '--cache-dir <待解析> ' + $plannedArguments }
            if ($tool.ContainsKey('AdditionalArguments')) { $plannedArguments += '；' + $tool['Name'] + ' ' + ($tool['AdditionalArguments'] -join ' ') }
            Write-Information ('[{0}] WhatIf：将查询 {0} {1}；缓存路径待解析。通过身份及路径校验后将执行 {0} {2}（不按年龄筛选）；本次不启动工具。' -f $tool['Name'], $tool['Query'], $plannedArguments) -InformationAction Continue
            Add-CacheSkip 'DevCache' $tool['Name'] 'WhatIf 演练；工具可用性及缓存路径待解析，未执行查询或清理'
        }
        return
    }
    # 官方命令使用当前进程身份和工具配置，不能替另一个用户清理缓存。
    $originalSid = Get-CacheResultField $script:CacheCleanerContext @('OriginalUserSid', 'OriginalUserSID', 'UserSid', 'UserSID', 'Sid')
    try {
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sameProfile = [string]::Equals(
            [System.IO.Path]::GetFullPath($cacheUserProfile).TrimEnd('\'),
            [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'),
            [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $sameProfile -or (-not [string]::IsNullOrWhiteSpace([string]$originalSid) -and [string]$originalSid -ne $currentSid)) {
            Add-CacheSkip 'DevCache' $cacheUserProfile '当前进程并非原用户身份；请在原用户的普通终端中调用开发工具清理'
            return
        }
    }
    catch {
        Add-CacheSkip 'DevCache' $cacheUserProfile ('无法核实原用户身份：' + $_.Exception.Message)
        return
    }

    Write-Warning 'DevCache 使用工具官方命令，MinAgeHours 不适用，可能清理最近生成的缓存；实际路径必须全部通过 DevCache 安全校验。'
    foreach ($tool in $tools) {
        $pathGuards = New-Object 'System.Collections.Generic.List[object]'
        try {
            $commands = @(Get-Command -Name $tool.Name -CommandType Application -ErrorAction SilentlyContinue)
            if ($commands.Count -eq 0) {
                Add-CacheSkip 'DevCache' $tool.Name '工具未安装' -Quiet
                continue
            }
            $exe = $commands[0].Source
            $paths = @(Get-CacheDeveloperPath -Name $tool['Name'] -FilePath $exe | Select-Object -Unique)
            foreach ($path in $paths) {
                Write-Information ('[{0}] 已解析实际缓存路径：{1}' -f $tool['Name'], $path) -InformationAction Continue
            }
            Assert-CacheDeveloperTarget -Name $tool['Name'] -Paths $paths
            foreach ($path in $paths) {
                # 不共享 DELETE 的根句柄会阻止 dotnet 等工具删除缓存根，因此只锁祖先。
                # 规范化去掉尾部分隔符，确保不会意外把根当作父目录锁定；不创建虚拟子项。
                # 任一祖先不存在或获取失败即跳过整个工具；共享函数自行释放本次部分获取的句柄。
                $guardPath = ConvertTo-CleanerCanonicalPath -LiteralPath $path
                $pathGuards.Add((Open-CleanerParentGuards -LiteralPath $guardPath))
            }
            # 获取全部句柄后重查，覆盖初次校验与获取句柄之间的替换窗口。
            Assert-CacheDeveloperTarget -Name $tool['Name'] -Paths $paths
            $cleanArguments = $tool['Arguments']
            # CLI 参数固定已验证的 npm/pip 缓存根，优先于环境变量或配置文件。
            if ($tool['Name'] -eq 'npm') { $cleanArguments = @('--cache', $paths[0], 'cache', 'clean', '--force') }
            if ($tool['Name'] -eq 'pip') { $cleanArguments = @('--cache-dir', $paths[0], 'cache', 'purge') }
            $description = $tool['Name'] + ' ' + ($cleanArguments -join ' ')
            if ($tool.ContainsKey('AdditionalArguments')) { $description += '；' + $tool['Name'] + ' ' + ($tool['AdditionalArguments'] -join ' ') }
            if (-not $script:CacheCleanerCmdlet.ShouldProcess($exe, ('执行官方开发缓存清理（不按年龄筛选）：' + $description))) {
                Add-CacheSkip 'DevCache' $description 'WhatIf 演练或用户未确认'
                continue
            }
            if ($tool['Name'] -in @('conda', 'dotnet', 'yarn', 'pnpm', 'go')) {
                # 这些清理命令依赖工具配置；确认后再查询，配置变化即拒绝执行。
                $currentPaths = @(Get-CacheDeveloperPath -Name $tool['Name'] -FilePath $exe | Select-Object -Unique)
                Assert-CacheDeveloperTarget -Name $tool['Name'] -Paths $currentPaths
                if (@(Compare-Object -ReferenceObject $paths -DifferenceObject $currentPaths).Count -gt 0) {
                    throw '确认期间缓存配置发生变化；请重新运行以检查新的清理范围。'
                }
            }
            $commandsToRun = @(@{ Arguments = $cleanArguments })
            if ($tool.ContainsKey('AdditionalArguments')) { $commandsToRun += @{ Arguments = $tool['AdditionalArguments'] } }
            foreach ($commandToRun in $commandsToRun) {
                $cleanArguments = $commandToRun.Arguments
                $description = $tool['Name'] + ' ' + ($cleanArguments -join ' ')
                # 祖先句柄保持到工具结束及后置校验完成；根和子项仍可能被并发替换。
                Assert-CacheDeveloperTarget -Name $tool['Name'] -Paths $paths
                $before = Get-CacheSystemFreeBytes
                try {
                    $results = @(Invoke-External -FilePath $exe -ArgumentList $cleanArguments -Description $description `
                        -Context $script:CacheCleanerContext -Confirm:$false -ErrorAction Stop)
                }
                finally {
                    # 成功、非零退出或抛错均重查根及祖先的重解析点；允许工具正常删除缓存根。
                    try { Assert-CacheDeveloperTarget -Name $tool['Name'] -Paths $paths }
                    catch { throw ('工具运行后路径安全校验失败：' + $_.Exception.Message) }
                }
                $after = Get-CacheSystemFreeBytes
                $estimated = [long]0
                if ($null -ne $before -and $null -ne $after) {
                    $estimated = [Math]::Max([long]0, ([long]$after - [long]$before))
                    $script:CacheCleanerSummary['DevCache'].EstimatedFreedBytes += $estimated
                }
                # 共享包装器负责检查退出码；若返回退出码，也显式保留失败信息。
                $exitCode = $null
                foreach ($result in $results) {
                    $code = Get-CacheResultField $result @('ExitCode')
                    if ($null -ne $code) { $exitCode = $code }
                }
                if ($null -ne $exitCode -and [int]$exitCode -ne 0) {
                    throw ('官方命令失败，退出码 ' + $exitCode)
                }
                $script:CacheCleanerSummary['DevCache'].ProcessedCount++
                $script:CacheCleanerSummary['DevCache'].Result = 'done'
                Write-CacheAudit -Action 'CacheCommand/DevCache' -Path $exe -Result ('已执行 ' + $description + '；Bytes 为系统卷空闲变化估算') -Bytes $estimated
            }
        }
        catch {
            Add-CacheSkip 'DevCache' $tool.Name $_.Exception.Message
        }
        finally {
            foreach ($guards in $pathGuards) {
                foreach ($guard in $guards.Handles) { $guard.Dispose() }
            }
        }
    }
}

foreach ($name in $script:CacheCleanerSummary.Keys) {
    switch ($name) {
        'UserTemp' {
            Remove-CacheDirectoryChildren $name $cacheUserTemp
        }
        'WindowsTemp' {
            $windowsTempPath = Join-Path $cacheSystemRoot 'Temp'
            $activity = Get-CacheWindowsTempActivity
            if ($activity.IsBusy) {
                Add-CacheSkip $name $windowsTempPath ($activity.Reasons -join '；')
                break
            }
            Remove-CacheDirectoryChildren $name $windowsTempPath
        }
        'ThumbnailCache' {
            Remove-CacheDirectoryChildren $name (Join-Path $cacheLocalAppData 'Microsoft\Windows\Explorer') 'thumbcache_*.db'
        }
        'BrowserCache' { Clear-CacheBrowsers }
        { $_ -in @('AppCache', 'ShaderCache', 'InetCache') } { Clear-CacheWhitelistCategory $name }
        'SystemLogs' {
            try { Assert-Admin -Context $script:CacheCleanerContext -ErrorAction Stop }
            catch { Add-CacheSkip $name $cacheSystemRoot ('系统日志清理需要管理员权限，已跳过整个类别：' + $_.Exception.Message); break }
            Clear-CacheWhitelistCategory $name
        }
        'DevCache' { Clear-CacheDeveloperTools }
    }
}

foreach ($row in $script:CacheCleanerSummary.Values) {
    $summaryBytes = $row.FreedBytes
    if ($row.Category -eq 'DevCache') {
        $releaseText = '系统卷空闲变化估算 {0:N0} 字节（非工具精确释放量）' -f $row.EstimatedFreedBytes
        $summaryBytes = $row.EstimatedFreedBytes
    }
    else { $releaseText = '共享库报告释放 {0:N0} 字节' -f $row.FreedBytes }
    Write-Host ('[{0}] {1}；已处理 {2} 项；跳过 {3} 项。' -f $row.Category, $releaseText, $row.ProcessedCount, $row.SkippedCount)
    $summaryText = $releaseText + '；跳过项：' + (ConvertTo-Json -InputObject @($row.SkippedItems.ToArray()) -Compress -Depth 4)
    Write-CacheAudit -Action ('CacheSummary/' + $row.Category) -Path $row.Category -Result $summaryText -Bytes $summaryBytes
    $row.FreedBytesEstimate = [long]$summaryBytes
    $row.SkippedReasons = @($row.SkippedItems.ToArray() | ForEach-Object { $_.Reason } | Select-Object -Unique)
    if (-not $row.WhatIf -and $row.SkippedCount -eq 0) { $row.Result = 'done' }
    if ($row.Result -eq 'done' -and $row.SkippedCount -gt 0) { $row.Result = 'partial' }
    # 保留原字段，每个类别仍只输出一个结构化对象，供后续编排器读取。
    Write-Output $row
}
if ($WhatIfPreference) {
    Write-Host 'WhatIf 演练结束：DevCache 路径待解析；未启动开发工具查询或清理，也未写入日志。'
}
else { Write-Host ('日志位置：{0}' -f $script:CacheCleanerLogPath) }
