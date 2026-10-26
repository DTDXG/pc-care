<#
.SYNOPSIS
    C 盘清理脚本共用的安全检查、统计、删除、外部命令、日志和服务恢复接口。
.DESCRIPTION
    兼容 Windows PowerShell 5.1 / PowerShell 7。点引用不创建日志、不提权、不停止服务。
    Test-SafeTarget 返回 IsSafe/Reason 对象，不能直接把该对象当布尔值使用。
    所有用户占位符基于原用户 SID/目录；提权前保存 Get-CleanerContext 的身份并传给新进程。
    同账户原身份可经参数或环境变量传入；跨账户只接受显式参数，并核实交互式会话。
    所有公开写入函数支持 -WhatIf；目录删除保留传入的根目录，不递归跟随重解析点。
.PARAMETER Context
    Get-CleanerContext 返回的上下文；省略时使用本进程已建立的上下文。
.EXAMPLE
    . (Join-Path $PSScriptRoot 'common.ps1')
    $context = Get-CleanerContext
    $check = Test-SafeTarget -LiteralPath $context.Temp -Category UserTemp
    if ($check.IsSafe) { Remove-SafeItem -LiteralPath $check.Path -Category UserTemp -WhatIf }
#>

$script:CleanerLibraryRoot = $PSScriptRoot
$script:CleanerTargets = $null
$script:CleanerContext = $null
$script:CleanerNativeType = $null

function Get-CleanerTargets {
    [CmdletBinding()]
    param()
    if ($null -eq $script:CleanerTargets) {
        $script:CleanerTargets = Import-PowerShellDataFile -LiteralPath (Join-Path $script:CleanerLibraryRoot 'targets.psd1') -ErrorAction Stop
        if ($script:CleanerTargets.SchemaVersion -ne 1) { throw '不支持的 targets.psd1 版本。' }
    }
    return $script:CleanerTargets
}

function Test-CleanerWindows {
    return ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}

function Get-CleanerNativeType {
    # Reflection.Emit 只在内存生成 P/Invoke；避免 Add-Type 在 5.1 中生成临时编译文件。
    [CmdletBinding()]
    param()
    if ($null -ne $script:CleanerNativeType) { return $script:CleanerNativeType }
    if (-not (Test-CleanerWindows)) { throw '此安全库仅支持 Windows。' }
    $existing = 'CDriveCleaner.NativeV5' -as [type]
    if ($null -ne $existing) { $script:CleanerNativeType = $existing; return $existing }
    $name = [Reflection.AssemblyName]::new('CDriveCleaner.NativeV5')
    if ($null -ne [Reflection.Emit.AssemblyBuilder].GetMethod('DefineDynamicAssembly', [type[]]@([Reflection.AssemblyName], [Reflection.Emit.AssemblyBuilderAccess]))) {
        $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    }
    else {
        $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly($name, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    }
    $module = $assembly.DefineDynamicModule('Native')
    $builder = $module.DefineType('CDriveCleaner.NativeV5', [Reflection.TypeAttributes]'Public, Abstract, Sealed')
    $definitions = @(
        @{ Name = 'GetCurrentPackageFamilyName'; Return = [int]; Parameters = [type[]]@([uint32].MakeByRefType(), [Text.StringBuilder]) }
        @{ Name = 'GetVolumeNameForVolumeMountPointW'; Return = [bool]; Parameters = [type[]]@([string], [Text.StringBuilder], [uint32]) }
        @{ Name = 'GetLongPathNameW'; Return = [uint32]; Parameters = [type[]]@([string], [Text.StringBuilder], [uint32]) }
        @{ Name = 'CreateFileW'; Return = [Microsoft.Win32.SafeHandles.SafeFileHandle]; Parameters = [type[]]@([string], [uint32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr]) }
        @{ Name = 'GetFileInformationByHandle'; Return = [bool]; Parameters = [type[]]@([Microsoft.Win32.SafeHandles.SafeFileHandle], [IntPtr]) }
        @{ Name = 'GetFileInformationByHandleEx'; Return = [bool]; Parameters = [type[]]@([Microsoft.Win32.SafeHandles.SafeFileHandle], [int], [IntPtr], [uint32]) }
        @{ Name = 'GetFinalPathNameByHandleW'; Return = [uint32]; Parameters = [type[]]@([Microsoft.Win32.SafeHandles.SafeFileHandle], [Text.StringBuilder], [uint32], [uint32]) }
        @{ Name = 'DeviceIoControl'; Return = [bool]; Parameters = [type[]]@([Microsoft.Win32.SafeHandles.SafeFileHandle], [uint32], [IntPtr], [uint32], [byte[]], [uint32], [uint32].MakeByRefType(), [IntPtr]) }
        @{ Name = 'SetFileInformationByHandle'; Return = [bool]; Parameters = [type[]]@([Microsoft.Win32.SafeHandles.SafeFileHandle], [int], [IntPtr], [uint32]) }
        @{ Name = 'SHSetKnownFolderPath'; Library = 'shell32.dll'; Return = [int]; Parameters = [type[]]@([guid].MakeByRefType(), [uint32], [IntPtr], [string]) }
        @{ Name = 'SHGetKnownFolderPath'; Library = 'shell32.dll'; Return = [int]; Parameters = [type[]]@([guid].MakeByRefType(), [uint32], [IntPtr], [IntPtr].MakeByRefType()) }
    )
    $attributeType = [Runtime.InteropServices.DllImportAttribute]
    $constructor = $attributeType.GetConstructor([type[]]@([string]))
    $fields = [Reflection.FieldInfo[]]@(
        $attributeType.GetField('EntryPoint'), $attributeType.GetField('CharSet'),
        $attributeType.GetField('CallingConvention'), $attributeType.GetField('SetLastError'), $attributeType.GetField('ExactSpelling')
    )
    foreach ($definition in $definitions) {
        $method = $builder.DefineMethod($definition['Name'], [Reflection.MethodAttributes]'Public, Static, PinvokeImpl', $definition['Return'], $definition['Parameters'])
        $values = [object[]]@($definition['Name'], [Runtime.InteropServices.CharSet]::Unicode, [Runtime.InteropServices.CallingConvention]::Winapi, $true, $true)
        $library = 'kernel32.dll'
        if ($definition.ContainsKey('Library')) { $library = $definition['Library'] }
        $attribute = [Reflection.Emit.CustomAttributeBuilder]::new($constructor, [object[]]@($library), $fields, $values)
        $method.SetCustomAttribute($attribute)
        if ($definition['Name'] -eq 'DeviceIoControl') { $null=$method.DefineParameter(5,[Reflection.ParameterAttributes]::Out,'outputBuffer') }
        $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
    }
    $script:CleanerNativeType = $builder.CreateType()
    return $script:CleanerNativeType
}

function ConvertTo-CleanerCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or $LiteralPath -ne $LiteralPath.Trim()) { throw '路径为空或首尾存在空白。' }
    $path = $LiteralPath.Replace('/', '\')
    if ($path -notmatch '^[A-Za-z]:\\') { throw '只接受本地盘符绝对路径；拒绝相对路径、UNC、设备路径和提供程序路径。' }
    if ($path.Substring(2).Contains(':') -or $path.IndexOf([char]0) -ge 0) { throw '拒绝备用数据流或 NUL 字符。' }
    if ($path -match '[<>"|?*\x00-\x1f]') { throw '路径包含通配符或非法字符。' }
    $segments = $path.Substring(3).Split([char]'\')
    foreach ($segment in $segments) {
        if ($segment -eq '.' -or $segment -eq '..') { throw '拒绝 . 或 .. 路径段。' }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) { throw '拒绝以点或空格结尾的路径段。' }
        if ($segment -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') { throw '拒绝 DOS 设备名。' }
        if ($segment -match '~[0-9]') { throw '拒绝可能的 8.3 短文件名；请传入长文件名。' }
    }
    if ($path.Substring(2).Contains('\\')) { throw '拒绝重复的路径分隔符。' }
    if (Test-CleanerWindows) { $path = [IO.Path]::GetFullPath($path) }
    if ($path.Length -gt 3) { $path = $path.TrimEnd([char]'\') }
    return $path.Substring(0, 1).ToUpperInvariant() + $path.Substring(1)
}

function Test-CleanerPathChain {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [switch]$AllowMissing)
    $path = $LiteralPath
    try {
        if (-not (Test-CleanerWindows)) { throw '仅支持 Windows 本地文件系统。' }
        $path = ConvertTo-CleanerCanonicalPath -LiteralPath $LiteralPath
        $root = [IO.Path]::GetPathRoot($path)
        $parts = @($root)
        $current = $root
        if ($path.Length -gt 3) {
            foreach ($part in $path.Substring(3).Split([char]'\')) {
                $current = [IO.Path]::Combine($current, $part)
                $parts += $current
            }
        }
        $missing = $false
        $existingParent = $null
        $attributes = $null
        foreach ($part in $parts) {
            if ($missing) { continue }
            try { $attributes = [IO.File]::GetAttributes($part) }
            catch [IO.FileNotFoundException] { if ($AllowMissing -and $part -ne $root) { $missing = $true; continue }; throw }
            catch [IO.DirectoryNotFoundException] { if ($AllowMissing -and $part -ne $root) { $missing = $true; continue }; throw }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "路径或父目录是重解析点：$part" }
            if (([int]$attributes -band 0x441000) -ne 0) { throw "路径或父目录为离线/按需召回项：$part" }
            if ($part -ne $path -and ($attributes -band [IO.FileAttributes]::Directory) -eq 0) { throw "父路径不是目录：$part" }
            $existingParent = $part
        }
        if (-not $missing) {
            $native = Get-CleanerNativeType
            $buffer = [Text.StringBuilder]::new(32768)
            $length = $native::GetLongPathNameW($path, $buffer, [uint32]$buffer.Capacity)
            if ($length -eq 0 -or $length -ge $buffer.Capacity) { throw '无法可靠解析长文件名（可能拒绝访问或超长路径）。' }
            $longPath = ConvertTo-CleanerCanonicalPath -LiteralPath $buffer.ToString()
            if (-not $longPath.Equals($path, [StringComparison]::OrdinalIgnoreCase)) { throw '路径存在短名或别名；请使用解析后的长路径。' }
        }
        if ($missing) { $attributes = $null }
        return [pscustomobject]@{ IsSafe = $true; Reason = 'OK'; Path = $path; Exists = (-not $missing); Attributes = $attributes; ExistingParent = $existingParent }
    }
    catch {
        return [pscustomobject]@{ IsSafe = $false; Reason = $_.Exception.Message; Path = $path; Exists = $false; Attributes = $null; ExistingParent = $null }
    }
}

function Expand-CleanerPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Pattern, [Parameter(Mandatory = $true)]$Context)
    $expanded = $Pattern
    foreach ($key in $Context.Variables.psbase.Keys) {
        $token = '%' + $key + '%'
        # Most rules contain one token; do not create a closure for every variable
        # on every file. Escape replacement dollars so user paths stay literal.
        if ($expanded.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $replacement = [string]$Context.Variables[$key]
        $expanded = [regex]::Replace($expanded, [regex]::Escape($token), $replacement.Replace('$', '$$'), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    if ($expanded -match '%[^%]+%') { throw "不能展开路径占位符：$Pattern" }
    return $expanded
}

function ConvertTo-CleanerPatternRegex {
    param([Parameter(Mandatory = $true)][string]$Pattern)
    return [regex]::Escape($Pattern.Replace('/', '\').TrimEnd([char]'\')).Replace('\*', '[^\\]*').Replace('\?', '[^\\]')
}

function Test-CleanerPattern {
    param([string]$Path, [string]$Pattern, [switch]$Exact)
    # Cache pure pattern compilation only, never path validation or file metadata.
    # Ordinal keys preserve case-sensitive regex source; matching retains the
    # original IgnoreCase/CultureInvariant semantics. Bound memory for long runs.
    $cache = $ExecutionContext.SessionState.PSVariable.GetValue('script:CleanerPatternCache')
    if ($null -eq $cache) {
        $cache = [Collections.Generic.Dictionary[string,regex]]::new([StringComparer]::Ordinal)
        $script:CleanerPatternCache = $cache
    }
    $key = [string][bool]$Exact + ':' + $Pattern
    $matcher = $null
    if ($cache.TryGetValue($key, [ref]$matcher)) { return $matcher.IsMatch($Path) }
    $expression = '^(?:' + (ConvertTo-CleanerPatternRegex -Pattern $Pattern) + ')'
    if ($Exact) { $expression += '$' } else { $expression += '(?:\\|$)' }
    $matcher = [regex]::new($expression, [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
    if ($cache.Count -ge 2048) { $cache.Clear() }
    $cache[$key] = $matcher
    return $matcher.IsMatch($Path)
}

function Get-CleanerRegistryValue {
    param([Microsoft.Win32.RegistryKey]$Hive, [string]$SubKey, [string]$Name)
    $key = $null
    try {
        $key = $Hive.OpenSubKey($SubKey, $false)
        if ($null -ne $key) { return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    }
    catch { return $null }
    finally { if ($null -ne $key) { $key.Dispose() } }
    return $null
}

function Test-CleanerInteractiveUser {
    # 只认可当前进程会话中的 Explorer；其他 RDP/切换用户会话不能证明发起身份。
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UserSid)
    if (-not (Test-CleanerWindows)) { return $false }
    try {
        $currentProcess = Get-Process -Id $PID -ErrorAction Stop
        $currentSessionProperty = $currentProcess.PSObject.Properties['SessionId']
        $currentSessionId = 0
        if ($null -eq $currentSessionProperty -or
            -not [int]::TryParse([string]$currentSessionProperty.Value, [ref]$currentSessionId) -or $currentSessionId -le 0) { return $false }
        foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop)) {
            $sessionProperty = $process.PSObject.Properties['SessionId']
            $sessionId = 0
            if ($null -eq $sessionProperty -or
                -not [int]::TryParse([string]$sessionProperty.Value, [ref]$sessionId) -or $sessionId -ne $currentSessionId) { continue }
            try {
                $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
                if ($null -eq $owner) { continue }
                $returnProperty = $owner.PSObject.Properties['ReturnValue']
                $sidProperty = $owner.PSObject.Properties['Sid']
                if ($null -ne $returnProperty -and $null -ne $returnProperty.Value -and [uint32]$returnProperty.Value -eq 0 -and
                    $null -ne $sidProperty -and [string]$sidProperty.Value -eq $UserSid) { return $true }
            }
            catch { continue } # 会话/进程可能在查询期间退出。
        }
    }
    catch { return $false }
    return $false
}

function Get-CleanerProfileBoundary {
    # 账户边界来自只读的机器 ProfileList；HKCU 重定向值不构成跨账户授权。
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)
    $key = $null
    $profiles = [Collections.Generic.List[object]]::new()
    $usersRoots = [Collections.Generic.List[string]]::new()
    $usersRoots.Add((ConvertTo-CleanerCanonicalPath -LiteralPath ($Context.SystemDrive + '\Users')))
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList', $false)
        if ($null -eq $key) { throw '无法读取 ProfileList，不能核实用户路径的账户边界。' }
        $rawRoot = $key.GetValue('ProfilesDirectory', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($rawRoot) { $usersRoots.Add((ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern $rawRoot -Context $Context))) }
        foreach ($sid in $key.GetSubKeyNames()) {
            if ($sid -notmatch '^S-1-') { continue }
            $profileKey = $null
            try {
                $profileKey = $key.OpenSubKey($sid, $false)
                if ($null -eq $profileKey) { throw "无法读取 ProfileList 账户：$sid" }
                $rawPath = $profileKey.GetValue('ProfileImagePath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ([string]::IsNullOrWhiteSpace([string]$rawPath)) { throw "ProfileList 账户缺少用户目录：$sid" }
                $path = ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern $rawPath -Context $Context)
                $profiles.Add([pscustomobject]@{ Sid = ($sid -replace '\.bak$', ''); Path = $path })
            }
            finally { if ($null -ne $profileKey) { $profileKey.Dispose() } }
        }
    }
    finally { if ($null -ne $key) { $key.Dispose() } }
    return [pscustomobject]@{ Profiles = $profiles.ToArray(); UsersRoots = @($usersRoots.ToArray() | Select-Object -Unique) }
}

function Get-CleanerUserPathReason {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [Parameter(Mandatory = $true)]$Context)
    $path = ConvertTo-CleanerCanonicalPath -LiteralPath $LiteralPath
    $originalProfile = ConvertTo-CleanerCanonicalPath -LiteralPath $Context.OriginalUserProfile
    $boundaryProperty = $Context.PSObject.Properties['ProfileBoundary']
    if ($null -ne $boundaryProperty -and $null -ne $boundaryProperty.Value) { $boundary = $boundaryProperty.Value }
    else { $boundary = Get-CleanerProfileBoundary -Context $Context }
    foreach ($profile in $boundary.Profiles) {
        if ($profile.Sid -ne $Context.OriginalUserSid -and (Test-CleanerPattern -Path $path -Pattern $profile.Path)) {
            return "用户路径位于其他 ProfileList 账户目录下，拒绝授权：$($profile.Path)"
        }
    }
    $usersRoots = @($boundary.UsersRoots)
    # 也拒绝未登记账户的 Users 子目录，包括其他卷或非标准位置的 Users。
    $usersMatch = [regex]::Match($path, '^(?<Root>[A-Za-z]:\\(?:[^\\]+\\)*?Users)(?:\\|$)', [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
    if ($usersMatch.Success) { $usersRoots += $usersMatch.Groups['Root'].Value }
    foreach ($root in $usersRoots) {
        if ((Test-CleanerPattern -Path $path -Pattern $root) -and
            ($originalProfile -ieq $root -or -not (Test-CleanerPattern -Path $originalProfile -Pattern $root) -or
             -not (Test-CleanerPattern -Path $path -Pattern $originalProfile))) {
            return "用户路径位于非原用户的 Users 子目录或用户目录集合根下，拒绝授权：$path"
        }
    }
    return $null
}

function Test-CleanerOriginalUserIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OriginalUserSid,
        [Parameter(Mandatory = $true)][string]$CurrentUserSid,
        [switch]$ExplicitIdentity
    )
    if ($OriginalUserSid -eq $CurrentUserSid) { return $true }
    if (-not $ExplicitIdentity) { return $false }
    return Test-CleanerInteractiveUser -UserSid $OriginalUserSid
}

function Test-CleanerPackageFamilyName {
    param([AllowEmptyString()][string]$PackageFamilyName)
    return ($PackageFamilyName -cmatch '\A[A-Za-z0-9.-]+_[A-Za-z0-9.-]+\z' -and
        -not $PackageFamilyName.Contains('..'))
}

function Get-CleanerLogBase {
    # 纯路径选择；显式 LocalCache 位置避免打包进程的 AppData 写入重定向。
    param([string]$LocalAppData, [AllowEmptyString()][string]$PackageFamilyName)
    $base = $LocalAppData.TrimEnd([char]'\')
    if (Test-CleanerPackageFamilyName $PackageFamilyName) {
        $base += '\Packages\' + $PackageFamilyName + '\LocalCache\Local'
    }
    return $base + '\CDriveCleaner\Logs'
}

function Get-CleanerPackageFamilyName {
    # API 返回错误码本身；不要读取 GetLastWin32Error。失败仅影响默认路径选择。
    $family = ''; $diagnostic = ''
    try {
        $native = Get-CleanerNativeType
        [uint32]$length = 0
        $code = $native::GetCurrentPackageFamilyName([ref]$length, $null)
        for ($attempt = 0; $code -eq 122 -and $attempt -lt 3; $attempt++) {
            if ($length -eq 0 -or $length -gt 32768) { throw '应用包名称长度无效。' }
            $buffer = [Text.StringBuilder]::new([int]$length)
            $code = $native::GetCurrentPackageFamilyName([ref]$length, $buffer)
            if ($code -eq 0) { $family = $buffer.ToString() }
        }
        if ($code -ne 0 -and $code -ne 15700) {
            throw [ComponentModel.Win32Exception]::new([int]$code)
        }
        if ($code -eq 0 -and -not (Test-CleanerPackageFamilyName $family)) {
            $family = ''; $diagnostic = '应用包名称格式无效。'
        }
    }
    catch { $family = ''; $diagnostic = $_.Exception.Message }
    return [pscustomobject]@{ FamilyName = $family; Error = $diagnostic }
}

function Set-CleanerContextLogPath {
    # Client-independent default, outside AppData package virtualization.
    # Explicit legacy locations remain supported for existing migration records.
    param($Context, [string]$LogPath)
    $diagnostic = ''
    if (-not $LogPath) { $LogPath = [Environment]::GetEnvironmentVariable('CLEANER_LOG_PATH') }
    if (-not $LogPath) {
        $base = (ConvertTo-CleanerCanonicalPath -LiteralPath $Context.OriginalUserProfile) + '\.pc-care\Logs'
        $LogPath = $base + '\cleaner-' + [guid]::NewGuid().ToString('N') + '.jsonl'
    }
    $Context.LogPath = ConvertTo-CleanerCanonicalPath -LiteralPath $LogPath
    $Context | Add-Member -NotePropertyName PackageIdentityDiagnostic -NotePropertyValue $diagnostic -Force
}

function Assert-CleanerLogDirectory {
    # Stable per-user directory, plus the two legacy shapes for existing records.
    param([string]$LogDirectory, $Context)
    try {
        $directory = ConvertTo-CleanerCanonicalPath -LiteralPath $LogDirectory
        $local = ConvertTo-CleanerCanonicalPath -LiteralPath $Context.Variables.LOCALAPPDATA
        $profile = ConvertTo-CleanerCanonicalPath -LiteralPath $Context.OriginalUserProfile
        if (-not $directory.StartsWith(($profile + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw '记录目录必须位于原账户的用户文件夹内。' }
        $plain = Get-CleanerLogBase $local ''
        $portable = $profile + '\.pc-care\Logs'
        if (-not $directory.Equals($portable, [StringComparison]::OrdinalIgnoreCase) -and
            -not $directory.Equals($plain, [StringComparison]::OrdinalIgnoreCase)) {
            $prefix = $local + '\Packages\'
            $suffix = '\LocalCache\Local\CDriveCleaner\Logs'
            if (-not $directory.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not $directory.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) -or
                $directory.Length -le ($prefix.Length + $suffix.Length)) { throw '记录目录格式不正确。' }
            $family = $directory.Substring($prefix.Length, $directory.Length - $prefix.Length - $suffix.Length)
            if (-not (Test-CleanerPackageFamilyName $family)) { throw '记录目录格式不正确。' }
        }
        $reason = Get-CleanerForbiddenReason -LiteralPath $directory -Context $Context
        if ($reason) { throw '记录目录位于受保护的位置。' }
        return $directory
    }
    catch { throw '记录目录不安全，请使用原账户的清理记录文件夹。' }
}

function Set-CleanerChildLogDirectory {
    param([string]$LogDirectory, $Context)
    $directory = Assert-CleanerLogDirectory -LogDirectory $LogDirectory -Context $Context
    # 子进程始终使用新文件，绝不沿用父进程文件或继承的 CLEANER_LOG_PATH。
    $log = $directory + '\cleaner-' + [guid]::NewGuid().ToString('N') + '.jsonl'
    $check = Test-CleanerPathChain -LiteralPath $log -AllowMissing
    if (-not $check.IsSafe) { throw '记录目录无法安全使用，请回到原账户重新运行。' }
    $Context.LogPath = $log
}

function New-CleanerPathException {
    param([string]$Reason, [string]$RequestedPath, [string]$FinalPath)
    $exception = [IO.IOException]::new($Reason)
    $exception.Data['RequestedPath'] = $RequestedPath
    $exception.Data['FinalPath'] = $FinalPath
    return $exception
}

function Get-CleanerContext {
    <#
    .SYNOPSIS
        读取原用户身份、系统目录和默认日志位置，不创建文件。
    .DESCRIPTION
        默认使用当前令牌账户，包括同账户提权。传入身份必须与 ProfileList 匹配。
        跨账户只接受显式成对参数，并要求原 SID 拥有与当前进程相同 SessionId 的 explorer；环境变量不作来源证明。
    .PARAMETER OriginalUserSid
        提权前记录的原用户 SID。别名 UserSid。
    .PARAMETER OriginalUserProfile
        提权前记录的原用户目录。别名 UserProfile。
    .PARAMETER LogPath
        可选 JSONL 日志绝对路径；默认位于原用户 LocalAppData 下。
    .PARAMETER LogDirectory
        子进程继承的记录目录；须在原用户目录内并符合普通或应用包日志目录形状，另建 JSONL 文件。
    .EXAMPLE
        $c = Get-CleanerContext -OriginalUserSid 'S-1-5-21-1-2-3-1001' -OriginalUserProfile 'C:\Users\张三'
    #>
    [CmdletBinding()]
    param(
        [Alias('UserSid')][string]$OriginalUserSid,
        [Alias('UserProfile')][string]$OriginalUserProfile,
        [string]$LogPath,
        [string]$LogDirectory
    )
    if ($PSBoundParameters.Count -eq 0 -and $null -ne $script:CleanerContext) { return $script:CleanerContext }
    if (-not (Test-CleanerWindows)) { throw '此共享库仅供 Windows 使用。' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $currentSid = $identity.User.Value
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
    # 在读取环境变量前记录来源，禁止显式参数与继承的环境变量拼成跨账户身份。
    $explicitIdentity = $PSBoundParameters.ContainsKey('OriginalUserSid') -and $PSBoundParameters.ContainsKey('OriginalUserProfile')
    $hasExplicitIdentity = $PSBoundParameters.ContainsKey('OriginalUserSid') -or $PSBoundParameters.ContainsKey('OriginalUserProfile')
    if ($hasExplicitIdentity -and (-not $explicitIdentity -or [string]::IsNullOrWhiteSpace($OriginalUserSid) -or [string]::IsNullOrWhiteSpace($OriginalUserProfile))) {
        throw '原用户 SID 和目录必须通过非空显式参数成对传入。'
    }
    if (-not $hasExplicitIdentity) {
        $OriginalUserSid = [Environment]::GetEnvironmentVariable('CLEANER_ORIGINAL_USER_SID')
        $OriginalUserProfile = [Environment]::GetEnvironmentVariable('CLEANER_ORIGINAL_USER_PROFILE')
    }
    $suppliedIdentity = (-not [string]::IsNullOrWhiteSpace($OriginalUserSid)) -or (-not [string]::IsNullOrWhiteSpace($OriginalUserProfile))
    if ($suppliedIdentity -and ([string]::IsNullOrWhiteSpace($OriginalUserSid) -or [string]::IsNullOrWhiteSpace($OriginalUserProfile))) { throw '原用户 SID 和目录必须成对传入。' }
    if (-not $OriginalUserSid) { $OriginalUserSid = $currentSid }
    [void][Security.Principal.SecurityIdentifier]::new($OriginalUserSid)
    $windows = [IO.Path]::GetDirectoryName([Environment]::SystemDirectory)
    $drive = [IO.Path]::GetPathRoot($windows).TrimEnd([char]'\')
    $registeredProfile = Get-CleanerRegistryValue -Hive ([Microsoft.Win32.Registry]::LocalMachine) -SubKey ('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $OriginalUserSid) -Name 'ProfileImagePath'
    if ($registeredProfile) { $registeredProfile = $registeredProfile.Replace('%SystemDrive%', $drive).Replace('%SYSTEMDRIVE%', $drive) }
    if (-not $OriginalUserProfile) {
        if ($registeredProfile) { $OriginalUserProfile = $registeredProfile }
        else { $OriginalUserProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile) }
    }
    $OriginalUserProfile = ConvertTo-CleanerCanonicalPath -LiteralPath $OriginalUserProfile
    if ($suppliedIdentity) {
        if (-not $registeredProfile) { throw '无法从 ProfileList 核实原用户 SID，拒绝猜测用户目录。' }
        $registeredProfile = ConvertTo-CleanerCanonicalPath -LiteralPath $registeredProfile
        if (-not $registeredProfile.Equals($OriginalUserProfile, [StringComparison]::OrdinalIgnoreCase)) { throw '原用户 SID 与目录不匹配。' }
    }
    $profileCheck = Test-CleanerPathChain -LiteralPath $OriginalUserProfile
    $verified = $profileCheck.IsSafe -and (Test-CleanerOriginalUserIdentity -OriginalUserSid $OriginalUserSid -CurrentUserSid $currentSid -ExplicitIdentity:$explicitIdentity)
    $variables = @{
        USERPROFILE = $OriginalUserProfile
        ORIGINALUSERSID = $OriginalUserSid
        LOCALAPPDATA = [IO.Path]::Combine($OriginalUserProfile, 'AppData\Local')
        APPDATA = [IO.Path]::Combine($OriginalUserProfile, 'AppData\Roaming')
        TEMP = [IO.Path]::Combine($OriginalUserProfile, 'AppData\Local\Temp')
        TMP = [IO.Path]::Combine($OriginalUserProfile, 'AppData\Local\Temp')
        HOMEDRIVE = [IO.Path]::GetPathRoot($OriginalUserProfile).TrimEnd([char]'\')
        HOMEPATH = $OriginalUserProfile.Substring(2)
        SystemRoot = $windows
        SystemDrive = $drive
        ProgramData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        ProgramFiles = $drive + '\Program Files'
        'ProgramFiles(x86)' = $drive + '\Program Files (x86)'
        ProgramW6432 = $drive + '\Program Files'
    }
    $context = [pscustomobject]@{
        OriginalUserSid = $OriginalUserSid; UserSid = $OriginalUserSid
        OriginalUserProfile = $OriginalUserProfile; UserProfile = $OriginalUserProfile
        CurrentUserSid = $currentSid; OriginalUserVerified = [bool]$verified
        IsAdministrator = $isAdmin; IsAdmin = $isAdmin
        PowerShellVersion = $PSVersionTable.PSVersion.ToString(); PSVersion = $PSVersionTable.PSVersion.ToString()
        Variables = $variables; SystemRoot = $windows; SystemDrive = $drive
        LocalAppData = $variables.LOCALAPPDATA; AppData = $variables.APPDATA; Temp = $variables.TEMP
        OriginalTempPath = $variables.TEMP; UserTempPath = $variables.TEMP; TempPath = $variables.TEMP
        LogPath = ''; SyncRoots = @(); ProtectedMachineRoots = @(($drive + '\Program Files'), ($drive + '\Program Files (x86)'))
    }
    foreach ($pair in @(@('ProgramFiles', 'ProgramFilesDir'), @('ProgramFiles(x86)', 'ProgramFilesDir (x86)'), @('ProgramW6432', 'ProgramW6432Dir'))) {
        $raw = Get-CleanerRegistryValue -Hive ([Microsoft.Win32.Registry]::LocalMachine) -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion' -Name $pair[1]
        if ($raw) {
            $variables[$pair[0]] = ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern $raw -Context $context)
            $context.ProtectedMachineRoots += $variables[$pair[0]]
        }
    }
    $context | Add-Member -NotePropertyName ProfileBoundary -NotePropertyValue (Get-CleanerProfileBoundary -Context $context)
    $shellKey = $OriginalUserSid + '\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    foreach ($pair in @(@('LOCALAPPDATA', 'Local AppData'), @('APPDATA', 'AppData'))) {
        $raw = Get-CleanerRegistryValue -Hive ([Microsoft.Win32.Registry]::Users) -SubKey $shellKey -Name $pair[1]
        if ($raw) { $variables[$pair[0]] = ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern $raw -Context $context) }
        $userPathReason = Get-CleanerUserPathReason -LiteralPath $variables[$pair[0]] -Context $context
        if ($userPathReason) { throw $userPathReason }
    }
    $standardTemp = ConvertTo-CleanerCanonicalPath -LiteralPath ([IO.Path]::Combine($variables.LOCALAPPDATA, 'Temp'))
    $variables.TEMP = $standardTemp
    $rawTemp = Get-CleanerRegistryValue -Hive ([Microsoft.Win32.Registry]::Users) -SubKey ($OriginalUserSid + '\Environment') -Name 'TEMP'
    if (-not $rawTemp -and $OriginalUserSid -eq $currentSid -and -not $isAdmin) { $rawTemp = [Environment]::GetEnvironmentVariable('TEMP') }
    if ($rawTemp) { $variables.TEMP = ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern $rawTemp -Context $context) }
    $userPathReason = Get-CleanerUserPathReason -LiteralPath $variables.TEMP -Context $context
    if ($userPathReason) { throw $userPathReason }
    $variables.TMP = $variables.TEMP
    $context.LocalAppData = $variables.LOCALAPPDATA; $context.AppData = $variables.APPDATA; $context.Temp = $variables.TEMP
    $context.OriginalTempPath = $variables.TEMP; $context.UserTempPath = $variables.TEMP; $context.TempPath = $variables.TEMP
    $customTemp = -not $variables.TEMP.Equals($standardTemp, [StringComparison]::OrdinalIgnoreCase)
    $tempReason = '仅授权原用户 LocalAppData\Temp。'
    if ($customTemp) { $tempReason = 'TEMP 指向非标准目录，需要人工确认；不自动授权该目录及其内容。' }
    $context | Add-Member -NotePropertyName StandardTempPath -NotePropertyValue $standardTemp
    $context | Add-Member -NotePropertyName UserTempRequiresManualConfirmation -NotePropertyValue $customTemp
    $context | Add-Member -NotePropertyName UserTempReason -NotePropertyValue $tempReason
    $syncRoots = [Collections.Generic.List[string]]::new()
    foreach ($name in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) {
        $raw = Get-CleanerRegistryValue -Hive ([Microsoft.Win32.Registry]::Users) -SubKey ($OriginalUserSid + '\Environment') -Name $name
        if (-not $raw -and $OriginalUserSid -eq $currentSid -and -not $isAdmin) { $raw = [Environment]::GetEnvironmentVariable($name) }
        if ($raw) { $syncRoots.Add((ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern $raw -Context $context))) }
    }
    $accounts = $null
    try {
        $accounts = [Microsoft.Win32.Registry]::Users.OpenSubKey($OriginalUserSid + '\Software\Microsoft\OneDrive\Accounts', $false)
        if ($null -ne $accounts) {
            foreach ($account in $accounts.GetSubKeyNames()) {
                $raw = Get-CleanerRegistryValue -Hive ([Microsoft.Win32.Registry]::Users) -SubKey ($OriginalUserSid + '\Software\Microsoft\OneDrive\Accounts\' + $account) -Name 'UserFolder'
                if ($raw) { $syncRoots.Add((ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern $raw -Context $context))) }
            }
        }
    }
    finally { if ($null -ne $accounts) { $accounts.Dispose() } }
    foreach ($infoPath in @([IO.Path]::Combine($variables.LOCALAPPDATA, 'Dropbox\info.json'), [IO.Path]::Combine($variables.APPDATA, 'Dropbox\info.json'))) {
        $infoCheck = Test-CleanerPathChain -LiteralPath $infoPath -AllowMissing
        if (-not $infoCheck.IsSafe) { throw "不能可靠核实 Dropbox 配置路径：$($infoCheck.Reason)" }
        if ($infoCheck.Exists) {
            try {
                $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                foreach ($property in $info.PSObject.Properties) {
                    if ($null -eq $property.Value) { continue }
                    $pathProperty = $property.Value.PSObject.Properties['path']
                    if ($null -ne $pathProperty -and $pathProperty.Value) {
                        $syncRoots.Add((ConvertTo-CleanerCanonicalPath -LiteralPath $pathProperty.Value))
                    }
                }
            }
            catch { throw "不能可靠读取原用户的 Dropbox 同步根：$($_.Exception.Message)" }
        }
    }
    $context.SyncRoots = @($syncRoots.ToArray() | Select-Object -Unique)
    if ($PSBoundParameters.ContainsKey('LogDirectory')) { Set-CleanerChildLogDirectory -LogDirectory $LogDirectory -Context $context }
    else { Set-CleanerContextLogPath -Context $context -LogPath $LogPath }
    $script:CleanerContext = $context
    return $context
}

function Get-CleanerForbiddenRules {
    param($Context)
    $targets = Get-CleanerTargets
    # Snapshot only rule inputs. A changed context or policy invalidates the
    # compiled matchers; filesystem identity and permissions are never cached.
    $sources = @($targets.ForbiddenPaths, $targets.ProtectedRoots, $Context.SyncRoots,
        $Context.ProtectedMachineRoots, $targets.SyncDirectoryNames, $targets.ForbiddenFilePatterns)
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($pair in $Context.Variables.GetEnumerator()) {
        $parts.Add([string]$pair.Key); $parts.Add([string]$pair.Value)
    }
    foreach ($source in $sources) {
        $parts.Add('GROUP:' + @($source).Count)
        foreach ($value in $source) { $parts.Add([string]$value) }
    }
    $builder = [Text.StringBuilder]::new()
    foreach ($part in $parts) { [void]$builder.Append($part.Length).Append(':').Append($part) }
    $signature = $builder.ToString()
    $property = $Context.PSObject.Properties['CompiledForbiddenRules']
    if ($null -ne $property -and $property.Value.Signature -ceq $signature) { return $property.Value }
    $rules = [Collections.Generic.List[object]]::new()
    $segments = [Collections.Generic.List[object]]::new()
    $options = [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'
    foreach ($template in $targets.ForbiddenPaths) {
        $pattern = Expand-CleanerPath -Pattern $template -Context $Context
        $rules.Add(@{ Matcher = [regex]::new(('^(?:' + (ConvertTo-CleanerPatternRegex $pattern) + ')(?:\\|$)'), $options)
            Reason = "永久禁止区：$template"; Container = $false })
    }
    foreach ($template in $targets.ProtectedRoots) {
        $pattern = Expand-CleanerPath -Pattern $template -Context $Context
        $rules.Add(@{ Matcher = [regex]::new(('^(?:' + (ConvertTo-CleanerPatternRegex $pattern) + ')$'), $options)
            Reason = "禁止整棵目录操作：$template"; Container = $true })
    }
    foreach ($syncRoot in $Context.SyncRoots) {
        $rules.Add(@{ Matcher = [regex]::new(('^(?:' + (ConvertTo-CleanerPatternRegex $syncRoot) + ')(?:\\|$)'), $options)
            Reason = "原用户的同步根：$syncRoot"; Container = $false })
    }
    foreach ($machineRoot in $Context.ProtectedMachineRoots) {
        $rules.Add(@{ Matcher = [regex]::new(('^(?:' + (ConvertTo-CleanerPatternRegex $machineRoot) + ')(?:\\|$)'), $options)
            Reason = "禁止直接处理程序安装目录：$machineRoot"; Container = $false })
    }
    foreach ($pattern in $targets.SyncDirectoryNames) {
        $segments.Add(@{ Matcher = [regex]::new(('^(?:' + (ConvertTo-CleanerPatternRegex $pattern) + ')$'), $options); Reason = '疑似同步目录：' })
    }
    foreach ($pattern in $targets.ForbiddenFilePatterns) {
        $segments.Add(@{ Matcher = [regex]::new(('^(?:' + (ConvertTo-CleanerPatternRegex $pattern) + ')$'), $options); Reason = '禁止直接处理的文件类型或用户数据：' })
    }
    $plan = [pscustomobject]@{ Signature = $signature; Rules = $rules.ToArray(); Segments = $segments.ToArray() }
    $Context | Add-Member -NotePropertyName CompiledForbiddenRules -NotePropertyValue $plan -Force
    return $plan
}

function Get-CleanerForbiddenReason {
    param([string]$LiteralPath, $Context, [string[]]$PermittedContainerRoots = @())
    if ($LiteralPath.Length -le 3) { return '禁止盘符根目录。' }
    $plan = Get-CleanerForbiddenRules -Context $Context
    foreach ($rule in $plan.Rules) {
        if ($rule.Matcher.IsMatch($LiteralPath) -and (-not $rule.Container -or $LiteralPath -notin $PermittedContainerRoots)) { return $rule.Reason }
    }
    foreach ($segment in $LiteralPath.Substring(3).Split([char]'\')) {
        foreach ($rule in $plan.Segments) {
            if ($rule.Matcher.IsMatch($segment)) { return $rule.Reason + $segment }
        }
    }
    return $null
}

function Get-CleanerKnownFolderMap {
    param($Context)
    if (-not (Test-CleanerWindows) -or $Context.OriginalUserSid -ne $Context.CurrentUserSid) {
        throw 'Known Folder 必须在已核实的原用户 Windows 会话中读取。'
    }
    $native = Get-CleanerNativeType
    $paths = @{}
    foreach ($entry in (Get-CleanerTargets).MigrationKnownFolders.GetEnumerator()) {
        $id = [guid]$entry.Value
        $pointer = [IntPtr]::Zero
        try {
            # flags=0：与 migrate.ps1 相同，不创建/重定向目录。
            $code = $native::SHGetKnownFolderPath([ref]$id, 0, [IntPtr]::Zero, [ref]$pointer)
            if ($code -lt 0) { [Runtime.InteropServices.Marshal]::ThrowExceptionForHR($code) }
            if ($pointer -eq [IntPtr]::Zero) { throw 'Known Folder 未返回路径。' }
            $paths[$entry.Key] = ConvertTo-CleanerCanonicalPath -LiteralPath ([Runtime.InteropServices.Marshal]::PtrToStringUni($pointer))
        }
        catch {
            # 单个 Known Folder 缺失/不可解析时不授权它，也不影响其他可核实的文件夹。
            continue
        }
        finally { if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer) } }
    }
    return $paths
}

function Get-CleanerWSLPath {
    param($Context)
    if (-not (Test-CleanerWindows)) { throw 'WSL 注册信息仅支持 Windows。' }
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::Users.OpenSubKey(($Context.OriginalUserSid + '\Software\Microsoft\Windows\CurrentVersion\Lxss'), $false)
        if ($null -eq $key) { return }
        foreach ($name in $key.GetSubKeyNames()) {
            $record = $null
            try {
                $record = $key.OpenSubKey($name, $false)
                if ($null -eq $record) { throw '无法读取 WSL 注册记录。' }
                $distribution = [string]$record.GetValue('DistributionName', '')
                if (-not $distribution -or $distribution -in @('docker-desktop', 'docker-desktop-data')) { continue }
                $raw = [string]$record.GetValue('BasePath', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if (-not $raw) { continue }
                $path = Expand-CleanerPath -Pattern $raw -Context $Context
                if ($path -match '^\\\\\?\\[A-Za-z]:\\') { $path = $path.Substring(4) }
                ConvertTo-CleanerCanonicalPath -LiteralPath $path
            }
            finally { if ($null -ne $record) { $record.Dispose() } }
        }
    }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Resolve-CleanerChatPaths {
    # 与 checkup Resolve-CheckupChatPaths 一致：旧微信配置是父目录，JSON 为准确数据根。
    param([string]$Value, [string[]]$Names, [bool]$IsParent)
    $path = ConvertTo-CleanerCanonicalPath -LiteralPath $Value
    if (-not $IsParent -or $path.Substring($path.LastIndexOf('\') + 1) -in $Names) { return $path }
    foreach ($name in $Names) { $path + '\' + $name }
}

function ConvertFrom-CleanerChatConfig {
    param([string]$Text, [string]$Format)
    if ($Format -eq 'Text') {
        foreach ($line in ($Text -split '[\r\n\x00]+')) {
            $value = $line.Trim().Trim([char]'"')
            if ($value -match '^[A-Za-z]:[\\/]') { $value }
        }
        return
    }
    $stack = [Collections.Generic.Stack[object]]::new()
    $stack.Push(@{ Value = (ConvertFrom-Json -InputObject $Text); Depth = 0 })
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node.Value -or $node.Depth -gt 6) { continue }
        foreach ($property in $node.Value.PSObject.Properties) {
            if ($property.Name -in @('fileSavePath','file_save_path','savePath','dataPath','data_dir','userDataPath','filePath') -and
                $property.Value -is [string]) { $property.Value }
            elseif ($property.Value -is [pscustomobject]) { $stack.Push(@{ Value = $property.Value; Depth = $node.Depth + 1 }) }
        }
    }
}

function Read-CleanerChatConfig {
    param([string]$Path)
    $chain = Test-CleanerPathChain -LiteralPath $Path
    if (-not $chain.IsSafe) { throw '聊天软件的设置文件无法安全读取。' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $buffer = New-Object byte[] 65537; $length = 0
        while ($length -lt $buffer.Length) {
            $read = $stream.Read($buffer, $length, $buffer.Length - $length)
            if ($read -eq 0) { break }; $length += $read
        }
        if ($length -gt 65536) { throw '聊天软件的设置文件过大，无法确认存储位置。' }
        if ($length -ge 2 -and $buffer[0] -eq 255 -and $buffer[1] -eq 254) { return [Text.Encoding]::Unicode.GetString($buffer, 2, $length - 2) }
        if ($length -ge 2 -and $buffer[0] -eq 254 -and $buffer[1] -eq 255) { return [Text.Encoding]::BigEndianUnicode.GetString($buffer, 2, $length - 2) }
        $text = ''
        try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $length) }
        catch { $text = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage).GetString($buffer, 0, $length) }
        return $text.TrimStart([char]0xfeff)
    }
    finally { $stream.Dispose() }
}

function Get-CleanerChatRootRecognition {
    # 仅直属、非链接目录是标记；不递归，不凭通用 filePath 键授权用户数据。
    param([string]$Path,[string]$App,[string[]]$Names,[scriptblock]$Children)
    if ($Path.Substring($Path.LastIndexOf('\')+1) -in $Names) {return 'Name'}
    foreach ($entry in (& $Children $Path)) {
        if (($entry.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {continue}
        $name=$entry.Name
        if (($App -eq 'WeChat' -and ($name -eq 'All Users' -or $name -match '^wxid_[A-Za-z0-9_-]+$')) -or
            ($App -eq 'QQ' -and ($name -eq 'nt_qq' -or $name -match '^[1-9][0-9]{4,11}$'))) {return 'Marker'}
    }
    return ''
}

function Get-CleanerChatMarkerChildren {
    param([string]$Path)
    # 包括根本身的安全校验，不沿自定义根的链接读取目标。
    $check=Test-CleanerPathChain -LiteralPath $Path
    if ($check.IsSafe -and $check.Exists) {([IO.DirectoryInfo]::new($Path)).EnumerateDirectories()}
}

function Get-CleanerChatRoots {
    param($Context, $KnownFolders,
        [scriptblock]$ReadRegistry = { param($key,$name) Get-CleanerRegistryValue -Hive ([Microsoft.Win32.Registry]::Users) -SubKey $key -Name $name },
        [scriptblock]$ReadConfig = { param($path) Read-CleanerChatConfig $path },
        [scriptblock]$Exists = { param($path) $null -ne (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue) }, [switch]$IncludeMissing,
        [scriptblock]$MarkerChildren={param($p) Get-CleanerChatMarkerChildren $p},
        $Issues=$null)
    if ($null -eq $KnownFolders) { $KnownFolders = Get-CleanerKnownFolderMap -Context $Context }
    $seen = @{}; $recognitions=@{}
    foreach ($app in @('WeChat','QQ')) {
        $definition = (Get-CleanerTargets).MoveChats[$app]
        $candidates = [Collections.Generic.List[string]]::new()
        if ($KnownFolders.ContainsKey('Documents')) {
            $names = @('Tencent Files'); if ($app -eq 'WeChat') { $names = @('WeChat Files','xwechat_files') }
            foreach ($name in $names) { $candidates.Add($KnownFolders.Documents + '\' + $name) }
        }
        $custom = [Collections.Generic.List[object]]::new()
        $value = & $ReadRegistry ($Context.OriginalUserSid + '\' + $definition.RegistryKey) $definition.RegistryName
        if ($value -is [string] -and $value) { $custom.Add(@{ Value = $value; Parent = ($app -eq 'WeChat') }) }
        foreach ($config in $definition.Configs) {
            try {
                $text = & $ReadConfig (Expand-CleanerPath -Pattern $config.Path -Context $Context)
                foreach ($value in @(ConvertFrom-CleanerChatConfig $text $config.Format)) { $custom.Add(@{ Value = $value; Parent = ($config.Format -eq 'Text') }) }
            }
            catch { } # 只采用能可靠读取的配置，和体检相同，不猜测其他路径。
        }
        foreach ($entry in $custom) {
            try {
                $expanded = Expand-CleanerPath -Pattern $entry.Value -Context $Context
                foreach ($path in @(Resolve-CleanerChatPaths $expanded $definition.Names $entry.Parent)) {
                    if ($path -in $KnownFolders.Values) {if($null -ne $Issues){$Issues.Add('找到了自定义的聊天文件位置，但无法确认，暂不搬家')};continue}
                    if (-not (Get-CleanerForbiddenReason -LiteralPath $path -Context $Context) -and
                        -not (Get-CleanerMigrationForbiddenReason -LiteralPath $path -Context $Context)) {
                        $recognition=Get-CleanerChatRootRecognition $path $app $definition.Names $MarkerChildren
                        if (-not $recognition -and $IncludeMissing) {
                            # 改名后仅以同父目录中精确的保留副本确认标记；不跟随原位置的链接。
                            $parent=$path.Substring(0,$path.LastIndexOf('\'));$leaf=$path.Substring($path.LastIndexOf('\')+1)
                            foreach ($sibling in (& $MarkerChildren $parent)) {
                                if ($sibling.Name -match ('^'+[regex]::Escape($leaf)+'\.cdrive-retained-[0-9a-f]{32}$') -and
                                    ($sibling.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                                    $recognition=Get-CleanerChatRootRecognition $sibling.FullName $app $definition.Names $MarkerChildren
                                    if ($recognition) {break}
                                }
                            }
                        }
                        if ($recognition) {$candidates.Add($path);$recognitions[$app+'|'+$path]=$recognition}
                        elseif ($null -ne $Issues) {$Issues.Add('找到了自定义的聊天文件位置，但无法确认，暂不搬家')}
                    }
                }
            }
            catch {if($null -ne $Issues){$Issues.Add('找到了自定义的聊天文件位置，但无法确认，暂不搬家')}}
        }
        foreach ($path in $candidates) {
            $key = $app + '|' + $path
            if (-not $seen.ContainsKey($key) -and ($IncludeMissing -or (& $Exists $path))) {
                $seen[$key] = $true
                [pscustomobject]@{ App = $app; Path = $path; Recognition=$(if($recognitions.ContainsKey($key)){$recognitions[$key]}else{'Default'}) }
            }
        }
    }
}

function Get-CleanerMigrationTarget {
    # 此处只派生路径数据，不创建目录、读清单内容或授权删除。
    param($Definition, $Context)
    $targets = Get-CleanerTargets
    $entries = [Collections.Generic.List[object]]::new()
    switch ($Definition['TargetSource']) {
        'KnownFolders' {
            foreach ($path in (Get-CleanerKnownFolderMap -Context $Context).Values) {
                $entries.Add(@{ Path = $path; Scope = 'Contents' })
            }
        }
        { $_ -in @('MoveChat','MoveChatBackup','MoveChatParent') } {
            foreach ($chat in @(Get-CleanerChatRoots -Context $Context -IncludeMissing)) {
                switch ($Definition['TargetSource']) {
                    'MoveChat' { $entries.Add(@{ Path = $chat.Path; Scope = 'Contents' }) }
                    'MoveChatBackup' { $entries.Add(@{ Path = $chat.Path; Scope = 'Container'; SuffixRegex = '\.cdrive-retained-[0-9a-f]{32}' }) }
                    'MoveChatParent' { $entries.Add(@{ Path = $chat.Path.Substring(0,$chat.Path.LastIndexOf('\')); Scope = 'Container' }) }
                }
            }
        }
        'ApplicationFiles' {
            $folders = Get-CleanerKnownFolderMap -Context $Context
            if (-not $folders.ContainsKey('Documents')) { throw '无法核实当前 Documents Known Folder。' }
            foreach ($entry in $Definition['Targets']) {
                $entries.Add(@{ Path = $folders.Documents + '\' + $entry['RelativePath']; Scope = $entry['Scope'] })
            }
        }
        { $_ -in @('DevCache', 'RetainedDevCache', 'DevCacheParent') } {
            # 三个联接相关类别共用这份缓存根，绝不扩大成任意 AppData 目录。
            foreach ($cache in $targets.Categories.DevCache.Targets) {
                $root = ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern $cache.Path -Context $Context)
                switch ($Definition['TargetSource']) {
                    'DevCache' { $entries.Add(@{ Path = $root; Scope = 'Contents' }) }
                    'RetainedDevCache' { $entries.Add(@{ Path = $root; Scope = 'Container'; SuffixRegex = '\.cdrive-retained-[0-9a-f]{32}' }) }
                    'DevCacheParent' { $entries.Add(@{ Path = $root.Substring(0, $root.LastIndexOf('\')); Scope = 'Container'; AllowProtectedRoot = $true }) }
                }
            }
            foreach ($entry in $Definition['Targets']) { $entries.Add($entry) }
        }
        'Configuration' {
            foreach ($entry in $Definition['Targets']) {
                $path = Expand-CleanerPath -Pattern $entry['Path'] -Context $Context
                $entries.Add(@{ Path = $path; Scope = 'File'; SuffixRegex = '(?:\.cdrive-backup-[0-9a-f]{32}|\.tmp-[0-9a-f]{32})?' })
                $entries.Add(@{ Path = $path.Substring(0, $path.LastIndexOf('\')); Scope = 'Container'; AllowProtectedRoot = $true })
            }
        }
        'AuditDirectory' {
            $log = ConvertTo-CleanerCanonicalPath -LiteralPath $Context.LogPath
            if ($log -notmatch '\.jsonl$') { throw '上下文审计日志必须是 .jsonl 文件。' }
            $directory = Assert-CleanerLogDirectory -LogDirectory ($log.Substring(0, $log.LastIndexOf('\'))) -Context $Context
            # 必须是明确的审计目录，不能把用户/AppData/盘根当审计目录泛化授权。
            $reason = Get-CleanerForbiddenReason -LiteralPath $directory -Context $Context
            if ($reason) { throw $reason }
            $entries.Add(@{ Path = $directory; Scope = 'Container' })
            $entries.Add(@{ Path = ($directory + '\move-inventory-'); Scope = 'File'; SuffixRegex = '[0-9a-f]{32}(?:-v(?:[2-9][0-9]*|1[0-9]+))?\.tsv' })
            $entries.Add(@{ Path = ($directory + '\*.json'); Scope = 'File'; SuffixRegex = '(?:\.tmp-[0-9a-f]{32}|\.lock)?' })
        }
        'RegisteredWSL' {
            foreach ($path in @(Get-CleanerWSLPath -Context $Context)) { $entries.Add(@{ Path = $path; Scope = 'Container' }) }
        }
        'DataVolume' { return } # 在 Test-SafeTarget 中按明确的非系统卷路径处理。
        default { throw '未知迁移白名单来源。' }
    }
    return $entries.ToArray()
}

function Get-CleanerMigrationForbiddenReason {
    param([string]$LiteralPath, $Context)
    foreach ($template in (Get-CleanerTargets).MigrationForbiddenPaths) {
        $pattern = $template.Replace('%VOLUME%', $LiteralPath.Substring(0, 2))
        if (Test-CleanerPattern -Path $LiteralPath -Pattern $pattern) { return "迁移禁止的系统区域：$pattern" }
    }
    if (Test-CleanerPattern -Path $LiteralPath -Pattern $Context.SystemRoot) { return '迁移不能处理 Windows 系统目录。' }
    if (Test-CleanerPattern -Path $LiteralPath -Pattern $Context.Variables.ProgramData) { return '迁移不能处理系统 ProgramData 目录。' }
    return $null
}

function Test-CleanerRetainedCache {
    # Junction 普通源必须存在；仅在改名/回滚阶段，由同根保留副本证明缺失根的用途。
    param([string]$LiteralPath, $Context)
    $parent = $LiteralPath.Substring(0, $LiteralPath.LastIndexOf('\'))
    foreach ($item in @(Get-CleanerChildren -LiteralPath $parent)) {
        if ($item.FullName -notmatch ('^(?:' + [regex]::Escape($LiteralPath) + ')\.cdrive-retained-[0-9a-f]{32}$')) { continue }
        $check = Test-SafeTarget -LiteralPath $item.FullName -Category JunctionBackup -Context $Context
        if ($check.IsSafe -and $check.Exists) { return $true }
    }
    return $false
}

function Test-CleanerRetainedChat {
    param([string]$LiteralPath,$Context)
    $parent=$LiteralPath.Substring(0,$LiteralPath.LastIndexOf('\'))
    foreach ($item in @(Get-CleanerChildren -LiteralPath $parent)) {
        if ($item.FullName -notmatch ('^'+[regex]::Escape($LiteralPath)+'\.cdrive-retained-[0-9a-f]{32}$')) {continue}
        $check=Test-SafeTarget -LiteralPath $item.FullName -Category MoveChatBackup -Context $Context
        if ($check.IsSafe -and $check.Exists) {return $true}
    }
    return $false
}

function Assert-CleanerDeletionCategory {
    param([string]$Category)
    $targets = Get-CleanerTargets
    if ($null -ne $targets['CategoryAliases'] -and $targets['CategoryAliases'].ContainsKey($Category)) { $Category = $targets['CategoryAliases'][$Category] }
    if ($targets.Categories.ContainsKey($Category) -and $targets.Categories[$Category]['MigrationOnly']) {
        throw '迁移类别不授权删除；禁止 Remove-SafeItem/Remove-CleanerLeaf 使用。'
    }
}

function Test-CleanerMigrationTarget {
    param([string]$LiteralPath, [string]$Category, $Definition, $Context, $Result)
    # 公共 -AllowMissing 不能放宽普通迁移源；只有类别规则能授权缺失路径。
    $allowMissing = [bool]$Definition['AllowMissing'] -or $Category -eq 'Junction'
    $chain = Test-CleanerPathChain -LiteralPath $LiteralPath -AllowMissing:$allowMissing
    $Result.Path = $chain.Path; $Result.NormalizedPath = $chain.Path; $Result.Exists = $chain.Exists
    if (-not $chain.IsSafe) { throw $chain.Reason }
    $path = $chain.Path
    $targets = Get-CleanerTargets
    $entryMatch = $null
    $rootPath = $null
    if ($Definition['TargetSource'] -eq 'DataVolume') {
        if ($path.Substring(0, 2) -in @($targets.CleanupDrive, $Context.SystemDrive, $Context.SystemRoot.Substring(0, 2))) {
            throw '迁移目标不能位于 C 盘或 Windows 系统卷。'
        }
        $entryMatch = @{ Scope = 'MigrationTarget' }
        $rootPath = $path
    }
    else {
        foreach ($entry in @(Get-CleanerMigrationTarget -Definition $Definition -Context $Context)) {
            $pattern = Expand-CleanerPath -Pattern $entry['Path'] -Context $Context
            $expression = '^(?<Root>' + (ConvertTo-CleanerPatternRegex -Pattern $pattern)
            if ($entry['SuffixRegex']) { $expression += $entry['SuffixRegex'] }
            $expression += ')'
            if ($entry['Scope'] -eq 'Contents') { $expression += '(?:\\.*)?' }
            $expression += '$'
            $match = [regex]::Match($path, $expression, [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
            if ($match.Success) { $entryMatch = $entry; $rootPath = $match.Groups['Root'].Value; break }
        }
        if ($null -eq $entryMatch) { throw '路径不在此迁移类别的准确白名单内。' }
    }
    $rootPath = ConvertTo-CleanerCanonicalPath -LiteralPath $rootPath
    $permittedContainers = @()
    if ($entryMatch['AllowProtectedRoot']) { $permittedContainers = @($rootPath) }
    foreach ($candidate in @($path, $rootPath)) {
        $forbidden = Get-CleanerForbiddenReason -LiteralPath $candidate -Context $Context -PermittedContainerRoots $permittedContainers
        if ($forbidden) { throw $forbidden }
        $forbidden = Get-CleanerMigrationForbiddenReason -LiteralPath $candidate -Context $Context
        if ($forbidden) { throw $forbidden }
    }
    # 缺失尾部也核实最近的已有父目录；该函数通过句柄检查全部已有祖先。
    if ($chain.Exists) { $snapshot = Get-CleanerEntryMetadata -LiteralPath $path }
    else {
        if (-not $chain.ExistingParent) { throw '找不到可核实的本地父目录。' }
        $parentSnapshot = Get-CleanerEntryMetadata -LiteralPath $chain.ExistingParent
        if (-not $parentSnapshot.IsDirectory) { throw '已有父路径不是目录。' }
        $snapshot = $null
    }
    $rootState = Test-CleanerPathChain -LiteralPath $rootPath -AllowMissing:$allowMissing
    if (-not $rootState.IsSafe) { throw $rootState.Reason }
    if ($entryMatch['Scope'] -in @('Contents', 'Container')) {
        if ($rootState.Exists -and ($rootState.Attributes -band [IO.FileAttributes]::Directory) -eq 0) { throw '迁移白名单根必须是普通目录。' }
    }
    if ($entryMatch['Scope'] -eq 'File' -and $null -ne $snapshot) {
        if ($snapshot.IsDirectory -or $snapshot.LinkCount -ne 1) { throw '配置或清单必须是普通单链接文件。' }
    }
    if ($Category -eq 'MoveChat' -and -not $chain.Exists) {
        if ($path -ine $rootPath -or -not (Test-CleanerRetainedChat -LiteralPath $rootPath -Context $Context)) {
            throw '原聊天文件夹缺失且没有可核实的保留副本。'
        }
    }
    if ($Category -eq 'Junction' -and -not $chain.Exists) {
        if ($path -ine $rootPath -or -not (Test-CleanerRetainedCache -LiteralPath $rootPath -Context $Context)) {
            throw '联接源必须存在；缺失缓存根仅允许有已验证的同根保留副本的事务阶段。'
        }
    }
    $Result.IsSafe = $true; $Result.Reason = 'OK'; $Result.RootPath = $rootPath; $Result.Scope = $entryMatch['Scope']
    return [pscustomobject]$Result
}

function Test-SafeTarget {
    <#
    .SYNOPSIS
        校验类别白名单、禁止区和目标至盘根的每一级重解析点。
    .DESCRIPTION
        返回 IsSafe、Reason、Path/NormalizedPath、Category、RootPath、ExternalOnly、MigrationOnly。
        未知类别、不可访问路径、短名、UNC、根目录、同步目录均失败关闭。
        ExternalOnly 的 IsSafe 仅表示路径匹配；不授权通用删除。
        MigrationOnly 类别独立授权迁移：源必须存在，目标/配置/清单/备份自动允许缺失尾部。
        Junction 缺失根须有同根安全保留副本；迁移类别忽略调用者的 -AllowMissing。
    .PARAMETER LiteralPath
        本地绝对路径；不展开用户输入中的环境变量或通配符。迁移缺失规则由类别决定。
    .PARAMETER Category
        targets.psd1 中的类别名称。迁移类别不能传给删除函数。
    .PARAMETER Context
        原用户上下文。
    .PARAMETER AllowMissing
        仅用于计划中新缓存目录的校验；允许叶项不存在，但所有已存在的祖先仍须安全。
        删除函数始终使用默认的必须存在检查。
    .EXAMPLE
        (Test-SafeTarget -LiteralPath 'C:\Windows\Temp' -Category WindowsTemp).IsSafe
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [Parameter(Mandatory = $true)][string]$Category, $Context, [switch]$AllowMissing)
    $result = [ordered]@{ IsSafe = $false; Reason = ''; Path = $LiteralPath; NormalizedPath = $LiteralPath; Category = $Category; RootPath = $null; ExternalOnly = $false; MigrationOnly = $false; Scope = $null; Exists = $false }
    try {
        if ($null -eq $Context) { $Context = Get-CleanerContext }
        $targets = Get-CleanerTargets
        if ($null -ne $targets['CategoryAliases'] -and $targets['CategoryAliases'].ContainsKey($Category)) { $Category = $targets['CategoryAliases'][$Category] }
        if (-not $targets.Categories.ContainsKey($Category)) { throw "未知类别：$Category" }
        $definition = $targets.Categories[$Category]
        $result.ExternalOnly = [bool]$definition['ExternalOnly']
        $result.MigrationOnly = [bool]$definition['MigrationOnly']
        if ($definition['RequiresOriginalUser'] -and -not $Context.OriginalUserVerified) { throw '无法确认提权前的原用户身份；请同时传入原 SID 和原用户目录。' }
        if ($definition['MigrationOnly']) {
            return Test-CleanerMigrationTarget -LiteralPath $LiteralPath -Category $Category -Definition $definition -Context $Context -Result $result
        }
        if ($Category -eq 'UserTemp') {
            $candidateTemp = ConvertTo-CleanerCanonicalPath -LiteralPath $LiteralPath
            $localAppData = ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern '%LOCALAPPDATA%' -Context $Context)
            foreach ($userPath in @($localAppData, $candidateTemp)) {
                $userPathReason = Get-CleanerUserPathReason -LiteralPath $userPath -Context $Context
                if ($userPathReason) { throw $userPathReason }
            }
            $standardTemp = ConvertTo-CleanerCanonicalPath -LiteralPath (Expand-CleanerPath -Pattern '%LOCALAPPDATA%\Temp' -Context $Context)
            if (-not (Test-CleanerPattern -Path $candidateTemp -Pattern $standardTemp)) {
                throw 'UserTemp 仅授权原用户 LocalAppData\Temp；其他 TEMP 位置（含其他账户、用户数据、同步目录或盘根）需要人工确认，不自动授权。'
            }
        }
        $chain = Test-CleanerPathChain -LiteralPath $LiteralPath -AllowMissing:$AllowMissing
        $result.Path = $chain.Path; $result.NormalizedPath = $chain.Path
        $result.Exists = $chain.Exists
        if (-not $chain.IsSafe) { throw $chain.Reason }
        $path = $chain.Path
        if (-not $path.Substring(0, 2).Equals($targets.CleanupDrive, [StringComparison]::OrdinalIgnoreCase)) { throw '清理仅允许 C 盘；拒绝其他卷。' }
        $forbidden = Get-CleanerForbiddenReason -LiteralPath $path -Context $Context
        if ($forbidden) { throw $forbidden }
        if ($chain.Exists) {
            # 同时核实句柄最终路径；遇到大小写敏感目录时失败关闭，避免忽略大小写匹配越过原用户边界。
            $snapshot = Get-CleanerEntryMetadata -LiteralPath $path
            $chain.Attributes = [IO.FileAttributes]$snapshot.Attributes
        }
        else {
            $existingParent = [IO.Path]::GetDirectoryName($path)
            while ($existingParent -and -not [IO.Directory]::Exists($existingParent)) { $existingParent = [IO.Path]::GetDirectoryName($existingParent) }
            if (-not $existingParent) { throw '找不到可核实的本地父目录。' }
            [void](Get-CleanerEntryMetadata -LiteralPath $existingParent)
        }
        foreach ($entry in $definition['Targets']) {
            $pattern = Expand-CleanerPath -Pattern $entry['Path'] -Context $Context
            if ($entry['Scope'] -eq 'File') {
                if ((Test-CleanerPattern -Path $path -Pattern $pattern -Exact) -and ((-not $chain.Exists) -or ($chain.Attributes -band [IO.FileAttributes]::Directory) -eq 0)) {
                    $result.IsSafe = $true; $result.RootPath = $path; $result.Scope = $entry['Scope']; break
                }
            }
            else {
                $expression = '^(?<Root>' + (ConvertTo-CleanerPatternRegex -Pattern $pattern) + ')(?:\\(?<Relative>.*))?$'
                $match = [regex]::Match($path, $expression, [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
                if (-not $match.Success) { continue }
                $rootPath = $match.Groups['Root'].Value
                # TEMP 等配置不能把盘根、用户目录或 AppData 根变成通配的清理白名单。
                $rootPath = ConvertTo-CleanerCanonicalPath -LiteralPath $rootPath
                $unsafeRoot = Get-CleanerForbiddenReason -LiteralPath $rootPath -Context $Context
                if ($unsafeRoot) { continue }
                $rootState = Test-CleanerPathChain -LiteralPath $rootPath -AllowMissing:$AllowMissing
                if (-not $rootState.IsSafe) { continue }
                if ($rootState.Exists -and ($rootState.Attributes -band [IO.FileAttributes]::Directory) -eq 0) { continue }
                $relative = $match.Groups['Relative'].Value
                # 排除项是根下的准确子名称；同时拒绝直接传入该子项或其任意后代。
                foreach ($childName in $entry['ExcludeChildren']) {
                    if ([string]::IsNullOrWhiteSpace([string]$childName) -or $childName -in @('.', '..') -or
                        $childName -match '[\\/:*?\[\]]') { throw 'ExcludeChildren 必须是非空的单个子项名称。' }
                    if ($relative -and ($relative.Split([char]'\')[0] -ieq $childName)) {
                        throw ('白名单明确保留的子项：' + $childName)
                    }
                }
                $allowed = $entry['Scope'] -eq 'Contents'
                if ($entry['Scope'] -eq 'SelectedFiles') {
                    $allowed = [string]::IsNullOrEmpty($relative)
                    if ($relative -and ($entry['Recursive'] -or -not $relative.Contains('\')) -and ($chain.Attributes -band [IO.FileAttributes]::Directory) -eq 0) {
                        foreach ($filePattern in $entry['FilePatterns']) {
                            if (Test-CleanerPattern -Path ([IO.Path]::GetFileName($relative)) -Pattern $filePattern -Exact) { $allowed = $true; break }
                        }
                    }
                }
                if ($allowed) { $result.IsSafe = $true; $result.RootPath = $rootPath; $result.Scope = $entry['Scope']; break }
            }
        }
        if (-not $result.IsSafe) { throw '路径不在此类别白名单内（或不符合文件名筛选）。' }
        $result.Reason = 'OK'
    }
    catch { $result.IsSafe = $false; $result.Reason = $_.Exception.Message }
    return [pscustomobject]$result
}

function Get-CleanerFinalHandlePath {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)
    $native = Get-CleanerNativeType
    $buffer = [Text.StringBuilder]::new(32768)
    $length = $native::GetFinalPathNameByHandleW($Handle, $buffer, [uint32]$buffer.Capacity, 0)
    if ($length -eq 0 -or $length -ge $buffer.Capacity) { throw '无法核实已打开句柄的最终路径。' }
    $path = $buffer.ToString()
    if ($path.StartsWith('\\?\', [StringComparison]::Ordinal)) { $path = $path.Substring(4) }
    return ConvertTo-CleanerCanonicalPath -LiteralPath $path
}

function Get-CleanerHandleMetadata {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)
    $native = Get-CleanerNativeType
    $memory = [Runtime.InteropServices.Marshal]::AllocHGlobal(64)
    try {
        if (-not $native::GetFileInformationByHandle($Handle, $memory)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        $attributes = [Runtime.InteropServices.Marshal]::ReadInt32($memory, 0)
        $volume = [Runtime.InteropServices.Marshal]::ReadInt32($memory, 28)
        $links = [Runtime.InteropServices.Marshal]::ReadInt32($memory, 40)
        $indexHigh = [Runtime.InteropServices.Marshal]::ReadInt32($memory, 44)
        $indexLow = [Runtime.InteropServices.Marshal]::ReadInt32($memory, 48)
        $fileId = "$volume/$indexHigh/$indexLow"
        # FileIdInfo 提供卷序号和 128 位文件标识，避免 ReFS 上截断标识造成错误去重。
        if ($native::GetFileInformationByHandleEx($Handle, 18, $memory, 24)) {
            $idBytes = [byte[]]::new(24)
            [Runtime.InteropServices.Marshal]::Copy($memory, $idBytes, 0, 24)
            $fileId = [BitConverter]::ToString($idBytes)
        }
        if (($attributes -band 0x400) -ne 0) { throw '重解析点：拒绝跟随。' }
        if (($attributes -band 0x441000) -ne 0) { throw '离线或按需召回文件：避免触发云端下载。' }
        if (($attributes -band 0x10) -ne 0) {
            # FileCaseSensitiveInfo = 23（Windows 10 1803+）；旧系统/文件系统不支持时使用其默认语义。
            if ($native::GetFileInformationByHandleEx($Handle, 23, $memory, 4)) {
                if (([Runtime.InteropServices.Marshal]::ReadInt32($memory, 0) -band 1) -ne 0) { throw '拒绝启用大小写敏感的目录，避免路径白名单产生别名歧义。' }
            }
            else {
                $caseError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                if ($caseError -notin @(1, 50, 87)) { throw [ComponentModel.Win32Exception]::new($caseError) }
            }
        }
        if (-not $native::GetFileInformationByHandleEx($Handle, 1, $memory, 24)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        $allocation = [Runtime.InteropServices.Marshal]::ReadInt64($memory, 0)
        $logical = [Runtime.InteropServices.Marshal]::ReadInt64($memory, 8)
        if (-not $native::GetFileInformationByHandleEx($Handle, 0, $memory, 40)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        $lastWrite = [DateTime]::FromFileTimeUtc([Runtime.InteropServices.Marshal]::ReadInt64($memory, 16))
        return [pscustomobject]@{
            Attributes = $attributes; IsDirectory = (($attributes -band 0x10) -ne 0)
            LogicalBytes = [long]$logical; AllocatedBytes = [long]$allocation
            LinkCount = $links; FileId = $fileId; LastWriteTimeUtc = $lastWrite
        }
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($memory) }
}

function Open-CleanerParentGuards {
    # 每一级目录均以 OPEN_REPARSE_POINT 打开且不共享 DELETE，锁住祖先以避免校验后的替换。
    param([string]$LiteralPath)
    $native = Get-CleanerNativeType
    $handles = [Collections.Generic.List[Microsoft.Win32.SafeHandles.SafeFileHandle]]::new()
    $handle = $null
    $transferred = $false
    try {
        $parent = [IO.Path]::GetDirectoryName($LiteralPath)
        $parents = [Collections.Generic.List[string]]::new()
        while ($parent) {
            $parents.Insert(0, $parent)
            if ($parent.Length -le 3) { break }
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
        foreach ($directory in $parents) {
            $handle = $native::CreateFileW($directory, 0x80, 3, [IntPtr]::Zero, 3, 0x02300000, [IntPtr]::Zero)
            if ($handle.IsInvalid) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
            $handles.Add($handle)
            $metadata = Get-CleanerHandleMetadata -Handle $handle
            if (-not $metadata.IsDirectory) { throw '父路径不是目录。' }
            $final = Get-CleanerFinalHandlePath -Handle $handle
            if (-not $final.Equals($directory, [StringComparison]::OrdinalIgnoreCase)) { throw (New-CleanerPathException '父目录最终路径发生变化或跨越卷别名。' $directory $final) }
            $handle = $null
        }
        $result = [pscustomobject]@{ Handles = $handles }
        # 成功写入输出管道后才移交；写出时被取消仍须释放。
        $result
        $transferred = $true
    }
    finally {
        # 取消也可能绕过 catch；未交接的当前句柄及整组祖先句柄均由本函数释放。
        if (-not $transferred) {
            if ($null -ne $handle) { $handle.Dispose() }
            foreach ($guard in $handles) { $guard.Dispose() }
        }
    }
}

function Get-CleanerEntryMetadata {
    param([string]$LiteralPath)
    $native = Get-CleanerNativeType
    $guards = $null; $handle = $null
    try {
        $chain = Test-CleanerPathChain -LiteralPath $LiteralPath
        if (-not $chain.IsSafe) { throw $chain.Reason }
        $guards = Open-CleanerParentGuards -LiteralPath $chain.Path
        $handle = $native::CreateFileW($chain.Path, 0x80, 7, [IntPtr]::Zero, 3, 0x02300000, [IntPtr]::Zero)
        if ($handle.IsInvalid) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        $final = Get-CleanerFinalHandlePath -Handle $handle
        if (-not $final.Equals($chain.Path, [StringComparison]::OrdinalIgnoreCase)) { throw '文件最终路径与请求不一致。' }
        return Get-CleanerHandleMetadata -Handle $handle
    }
    finally {
        if ($null -ne $handle) { $handle.Dispose() }
        if ($null -ne $guards) { foreach ($guard in $guards.Handles) { $guard.Dispose() } }
    }
}

function Get-CleanerChildren {
    # 枚举期间锁住祖先和目录本身；绝不使用 -Recurse。
    param([string]$LiteralPath)
    $native = Get-CleanerNativeType
    $guards = $null; $handle = $null
    try {
        $check = Test-CleanerPathChain -LiteralPath $LiteralPath
        if (-not $check.IsSafe) { throw $check.Reason }
        $guards = Open-CleanerParentGuards -LiteralPath $check.Path
        $handle = $native::CreateFileW($check.Path, 0x80, 3, [IntPtr]::Zero, 3, 0x02300000, [IntPtr]::Zero)
        if ($handle.IsInvalid) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        $metadata = Get-CleanerHandleMetadata -Handle $handle
        if (-not $metadata.IsDirectory) { throw '枚举目标不是目录。' }
        if (-not (Get-CleanerFinalHandlePath -Handle $handle).Equals($check.Path, [StringComparison]::OrdinalIgnoreCase)) { throw '枚举目录最终路径不一致。' }
        return @(Get-ChildItem -LiteralPath $check.Path -Force -ErrorAction Stop)
    }
    finally {
        if ($null -ne $handle) { $handle.Dispose() }
        if ($null -ne $guards) { foreach ($guard in $guards.Handles) { $guard.Dispose() } }
    }
}

function Get-DirectorySize {
    <#
    .SYNOPSIS
        只读统计逻辑大小和实际分配空间，不跟随重解析点。
    .DESCRIPTION
        LogicalBytes 按目录项统计；AllocatedBytes 对已见硬链接去重。
        SkippedItems/SkippedCount 包含重解析点、离线文件、拒绝访问、长路径等未知项。
        有跳过项时总量返回 null；KnownLogicalBytes/KnownAllocatedBytes 保留已知小计。
        IsComplete 为 false 表示存在未知项，不能把未知项理解为零。
        EstimatedReclaimableBytes 不包含多硬链接文件；组件存储仍须通过 DISM 分析。
    .PARAMETER LiteralPath
        本地绝对目录或文件路径。允许只读扫描盘根和非白名单目录。
    .EXAMPLE
        Get-DirectorySize -LiteralPath 'C:\Users\张三\AppData\Local'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    $skipped = [Collections.Generic.List[object]]::new()
    $stack = [Collections.Generic.Stack[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [long]$logical = 0; [long]$allocated = 0; [long]$reclaimable = 0
    [long]$files = 0; [long]$directories = 0
    $root = Test-CleanerPathChain -LiteralPath $LiteralPath
    if (-not $root.IsSafe) { $skipped.Add([pscustomobject]@{ Path = $LiteralPath; Reason = $root.Reason }) }
    else { $stack.Push($root.Path) }
    while ($stack.Count -gt 0) {
        $path = $stack.Pop()
        try {
            $metadata = Get-CleanerEntryMetadata -LiteralPath $path
            if ($metadata.IsDirectory) {
                $directories++
                foreach ($child in @(Get-CleanerChildren -LiteralPath $path)) { $stack.Push($child.FullName) }
            }
            else {
                $files++; $logical += $metadata.LogicalBytes
                if ($seen.Add($metadata.FileId)) {
                    $allocated += $metadata.AllocatedBytes
                    if ($metadata.LinkCount -eq 1) { $reclaimable += $metadata.AllocatedBytes }
                }
            }
        }
        catch { $skipped.Add([pscustomobject]@{ Path = $path; Reason = $_.Exception.Message }) }
    }
    $reportedLogical = $logical; $reportedAllocated = $allocated; $reportedReclaimable = $reclaimable
    if ($skipped.Count -gt 0) { $reportedLogical = $null; $reportedAllocated = $null; $reportedReclaimable = $null }
    $reparsePoints = @($skipped.ToArray() | Where-Object { $_.Reason -match '重解析点' })
    return [pscustomobject]@{
        Path = $LiteralPath; LogicalBytes = $reportedLogical; AllocatedBytes = $reportedAllocated; ActualBytes = $reportedAllocated
        KnownLogicalBytes = $logical; KnownAllocatedBytes = $allocated; KnownEstimatedReclaimableBytes = $reclaimable
        EstimatedReclaimableBytes = $reportedReclaimable; FileCount = $files; DirectoryCount = $directories
        IsComplete = ($skipped.Count -eq 0); SkippedCount = $skipped.Count
        SkippedItems = $skipped.ToArray(); Skipped = $skipped.ToArray()
        ReparsePoints = $reparsePoints; ReparsePointCount = $reparsePoints.Count
    }
}

function Write-CleanerLog {
    <#
    .SYNOPSIS
        按 UTF-8 编码追加 JSONL 审计记录。
    .DESCRIPTION
        首次实际写入时才创建日志目录。-WhatIf 不创建目录或日志文件。
        日志路径同样拒绝重解析点、禁止区和同步目录；日志不提供数据回滚能力。
    .PARAMETER Action
        操作名称。
    .PARAMETER Path
        操作对象，可以是路径、服务名或命令名。
    .PARAMETER Result
        成功、失败、跳过、WhatIf 等结果。
    .PARAMETER Bytes
        预计释放的实际分配字节数（多硬链接按零）。
    .PARAMETER Message
        可选原因或详细说明。
    .PARAMETER LogPath
        可覆盖上下文中的日志文件。
    .PARAMETER Context
        原用户上下文。
    .EXAMPLE
        Write-CleanerLog -Action Remove -Path 'C:\Windows\Temp\a.tmp' -Result Skipped -Bytes 0 -Message '文件被占用'
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Result,
        [ValidateRange(0, [long]::MaxValue)][long]$Bytes = 0,
        [string]$Message = '', [string]$LogPath, $Context
    )
    if ($null -eq $Context) { $Context = Get-CleanerContext }
    if (-not $LogPath) { $LogPath = $Context.LogPath }
    $check = Test-CleanerPathChain -LiteralPath $LogPath -AllowMissing
    if (-not $check.IsSafe) { throw "不安全的日志路径：$($check.Reason)" }
    $forbidden = Get-CleanerForbiddenReason -LiteralPath $check.Path -Context $Context
    if ($forbidden) { throw "不安全的日志路径：$forbidden" }
    if ([IO.Path]::GetExtension($check.Path) -ne '.jsonl') { throw '日志文件必须使用 .jsonl 扩展名。' }
    $record = [ordered]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o'); OriginalUserSid = $Context.OriginalUserSid
        Action = $Action; Path = $Path; Result = $Result; Bytes = $Bytes; Message = $Message
    }
    $line = ($record | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine
    if (-not $PSCmdlet.ShouldProcess($check.Path, '追加 UTF-8 JSONL 审计日志')) { return }
    $native = Get-CleanerNativeType
    $guards = $null; $handle = $null; $stream = $null
    $directoryGuards = [Collections.Generic.List[object]]::new()
    try {
        $directory = [IO.Path]::GetDirectoryName($check.Path)
        $toCreate = [Collections.Generic.Stack[string]]::new()
        $candidate = $directory
        while (-not [IO.Directory]::Exists($candidate)) {
            $toCreate.Push($candidate)
            $candidate = [IO.Path]::GetDirectoryName($candidate)
            if (-not $candidate) { throw '找不到日志目录的本地祖先。' }
        }
        while ($toCreate.Count -gt 0) {
            $next = $toCreate.Pop()
            $guard = Open-CleanerParentGuards -LiteralPath $next
            $directoryGuards.Add($guard)
            [void][IO.Directory]::CreateDirectory($next)
            $created = Test-CleanerPathChain -LiteralPath $next
            if (-not $created.IsSafe) { throw $created.Reason }
        }
        $guards = Open-CleanerParentGuards -LiteralPath $check.Path
        $handle = $native::CreateFileW($check.Path, 0x40000080, 1, [IntPtr]::Zero, 4, 0x00300000, [IntPtr]::Zero)
        if ($handle.IsInvalid) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        $metadata = Get-CleanerHandleMetadata -Handle $handle
        if ($metadata.IsDirectory -or $metadata.LinkCount -ne 1) { throw '日志必须是普通单链接文件。' }
        $final = Get-CleanerFinalHandlePath -Handle $handle
        if (-not $final.Equals($check.Path, [StringComparison]::OrdinalIgnoreCase)) { throw (New-CleanerPathException '日志文件最终路径发生变化。' $check.Path $final) }
        $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Write)
        [void]$stream.Seek(0, [IO.SeekOrigin]::End)
        $bytesToWrite = [Text.UTF8Encoding]::new($false).GetBytes($line)
        $stream.Write($bytesToWrite, 0, $bytesToWrite.Length)
        $stream.Flush()
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $handle) { $handle.Dispose() }
        if ($null -ne $guards) { foreach ($guard in $guards.Handles) { $guard.Dispose() } }
        foreach ($group in $directoryGuards) { foreach ($guard in $group.Handles) { $guard.Dispose() } }
    }
}

function Write-CleanerAudit {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Action, [string]$Path, [string]$Result, [long]$Bytes = 0, [string]$Message = '', $Context)
    try {
        if ($PSCmdlet.ShouldProcess($Path, '记录操作审计')) {
            Write-CleanerLog -Action $Action -Path $Path -Result $Result -Bytes $Bytes -Message $Message -Context $Context -Confirm:$false
        }
    }
    catch { Write-Warning "审计日志写入失败：$($_.Exception.Message)" }
}

function Remove-CleanerLeaf {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$LiteralPath, [string]$Category, [DateTime]$CutoffUtc, [bool]$IsDirectory, $Context)
    Assert-CleanerDeletionCategory -Category $Category
    $native = Get-CleanerNativeType
    $guards = $null; $handle = $null; $disposition = [IntPtr]::Zero
    try {
        $validation = Test-SafeTarget -LiteralPath $LiteralPath -Category $Category -Context $Context
        if (-not $validation.IsSafe -or $validation.ExternalOnly) { throw "拒绝删除：$($validation.Reason)" }
        if ($IsDirectory -and $validation.Path.Equals($validation.RootPath, [StringComparison]::OrdinalIgnoreCase)) { throw '不删除类别白名单根目录。' }
        $guards = Open-CleanerParentGuards -LiteralPath $validation.Path
        # 独占打开：被其他进程持有的文件跳过。只标记此句柄删除，不调用递归 Remove-Item。
        $handle = $native::CreateFileW($validation.Path, 0x10080, 0, [IntPtr]::Zero, 3, 0x02300000, [IntPtr]::Zero)
        if ($handle.IsInvalid) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        $metadata = Get-CleanerHandleMetadata -Handle $handle
        if ($metadata.IsDirectory -ne $IsDirectory) { throw '文件/目录类型在校验后发生变化。' }
        if (-not (Get-CleanerFinalHandlePath -Handle $handle).Equals($validation.Path, [StringComparison]::OrdinalIgnoreCase)) { throw '最终路径发生变化，拒绝删除。' }
        if (-not $IsDirectory -and $metadata.LastWriteTimeUtc -gt $CutoffUtc) { throw '在 MinAgeHours 时间范围内修改，跳过。' }
        if (($metadata.Attributes -band 1) -ne 0 -and -not $IsDirectory) { throw '只读文件，跳过且不修改属性。' }
        $again = Test-SafeTarget -LiteralPath $validation.Path -Category $Category -Context $Context
        if (-not $again.IsSafe) { throw $again.Reason }
        if (-not $PSCmdlet.ShouldProcess($validation.Path, '通过独占句柄删除文件或空目录')) {
            return [pscustomobject]@{ Success = $false; Reason = 'WhatIf 或用户拒绝'; Bytes = 0; LogicalBytes = 0 }
        }
        $disposition = [Runtime.InteropServices.Marshal]::AllocHGlobal(1)
        [Runtime.InteropServices.Marshal]::WriteByte($disposition, 0, 1)
        # FileDispositionInfo = 4。非空目录会由 Windows 拒绝，绝不递归删除。
        if (-not $native::SetFileInformationByHandle($handle, 4, $disposition, 1)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        [long]$released = 0
        [long]$logicalRemoved = 0
        if (-not $IsDirectory -and $metadata.LinkCount -eq 1) { $released = $metadata.AllocatedBytes }
        if (-not $IsDirectory) { $logicalRemoved = $metadata.LogicalBytes }
        $handle.Dispose(); $handle = $null
        return [pscustomobject]@{ Success = $true; Reason = 'OK'; Bytes = $released; LogicalBytes = $logicalRemoved }
    }
    catch { return [pscustomobject]@{ Success = $false; Reason = $_.Exception.Message; Bytes = 0; LogicalBytes = 0 } }
    finally {
        if ($disposition -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($disposition) }
        if ($null -ne $handle) { $handle.Dispose() }
        if ($null -ne $guards) { foreach ($guard in $guards.Handles) { $guard.Dispose() } }
    }
}

function Remove-SafeItem {
    <#
    .SYNOPSIS
        仅清理类别白名单内的内容，每个子项删除前重新校验。
    .DESCRIPTION
        目录目标本身始终保留；文件目标只处理该文件。跳过重解析点、占用、只读、近期文件。
        原生句柄锁定所有父目录，防止重解析点检查后被替换；不使用递归删除。
        ReleasedBytes/Bytes 是预计释放的实际分配空间，多硬链接按零，最终空间以卷基线为准。
        返回 DeletedCount、PlannedCount、SkippedItems 和 IsComplete。-WhatIf 不写日志。
    .PARAMETER LiteralPath
        白名单目录或文件的本地绝对路径。
    .PARAMETER Category
        类别名；MigrationOnly/ExternalOnly 类别拒绝直接删除。
    .PARAMETER MinAgeHours
        最少未修改小时数，默认 24；范围 0 到 876000。
        SystemLogs 必须通过管理员检查，且有效下限始终至少为 168 小时。
    .PARAMETER Context
        原用户上下文。
    .EXAMPLE
        Remove-SafeItem -LiteralPath 'C:\Windows\Temp' -Category WindowsTemp -MinAgeHours 24 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Category,
        [ValidateRange(0, 876000)][double]$MinAgeHours = 24,
        [Nullable[DateTime]]$DeadlineUtc,
        $Context
    )
    Assert-CleanerDeletionCategory -Category $Category
    if ([double]::IsNaN($MinAgeHours) -or [double]::IsInfinity($MinAgeHours)) { throw 'MinAgeHours 必须是有限数字。' }
    if ($null -eq $Context) { $Context = Get-CleanerContext }
    if ($Category -eq 'SystemLogs') {
        Assert-Admin -Context $Context
        $MinAgeHours = [Math]::Max([double]168, $MinAgeHours)
    }
    $skipped = [Collections.Generic.List[object]]::new()
    $stack = [Collections.Generic.Stack[object]]::new()
    [long]$released = 0; [long]$logicalRemoved = 0; [long]$plannedBytes = 0
    [int]$deleted = 0; [int]$planned = 0
    $cutoff = [DateTime]::UtcNow.AddHours(-$MinAgeHours)
    $root = Test-SafeTarget -LiteralPath $LiteralPath -Category $Category -Context $Context
    if (-not $root.IsSafe -or $root.ExternalOnly) {
        $reason = $root.Reason
        if ($root.ExternalOnly) { $reason = '此类别必须使用官方工具，禁止 Remove-SafeItem 直接删除。' }
        $skipped.Add([pscustomobject]@{ Path = $LiteralPath; Reason = $reason })
        Write-CleanerAudit -Action Remove -Path $LiteralPath -Result Skipped -Message $reason -Context $Context
    }
    else { $stack.Push([pscustomobject]@{ Path = $root.Path; Post = $false; IsRoot = $true }) }
    while ($stack.Count -gt 0) {
        if ($null -ne $DeadlineUtc -and [DateTime]::UtcNow -ge $DeadlineUtc) {
            $reason = '已达到快速清理时间预算，剩余内容保留；可稍后继续或使用完整模式。'
            $skipped.Add([pscustomobject]@{ Path = $LiteralPath; Reason = $reason })
            Write-CleanerAudit -Action Remove -Path $LiteralPath -Result Skipped -Message $reason -Context $Context
            break
        }
        $frame = $stack.Pop()
        $path = $frame.Path
        try {
            $check = Test-SafeTarget -LiteralPath $path -Category $Category -Context $Context
            if (-not $check.IsSafe -or $check.ExternalOnly) { throw $check.Reason }
            $metadata = Get-CleanerEntryMetadata -LiteralPath $path
            if ($metadata.IsDirectory -and -not $frame.Post) {
                $stack.Push([pscustomobject]@{ Path = $path; Post = $true; IsRoot = $frame.IsRoot })
                foreach ($child in @(Get-CleanerChildren -LiteralPath $path)) {
                    $stack.Push([pscustomobject]@{ Path = $child.FullName; Post = $false; IsRoot = $false })
                }
                continue
            }
            if ($metadata.IsDirectory -and $frame.IsRoot) { continue }
            if (-not $metadata.IsDirectory -and $metadata.LastWriteTimeUtc -gt $cutoff) { throw '在 MinAgeHours 时间范围内修改，跳过。' }
            if ($metadata.IsDirectory -and @(Get-CleanerChildren -LiteralPath $path).Count -gt 0) { throw '目录仍有未删除项，保留目录。' }
            if (-not $metadata.IsDirectory -and ($metadata.Attributes -band 1) -ne 0) { throw '只读文件，跳过且不修改属性。' }
            $planned++
            if (-not $metadata.IsDirectory -and $metadata.LinkCount -eq 1) { $plannedBytes += $metadata.AllocatedBytes }
            if (-not $PSCmdlet.ShouldProcess($path, '删除白名单内文件或空子目录（不可恢复）')) {
                $skipped.Add([pscustomobject]@{ Path = $path; Reason = 'WhatIf 或用户拒绝' })
                # WhatIfPreference 传递给日志函数，演练不会落盘。
                Write-CleanerAudit -Action Remove -Path $path -Result Skipped -Message 'WhatIf 或用户拒绝' -Context $Context
                continue
            }
            $outcome = Remove-CleanerLeaf -LiteralPath $path -Category $Category -CutoffUtc $cutoff -IsDirectory $metadata.IsDirectory -Context $Context -Confirm:$false
            if (-not $outcome.Success) { throw $outcome.Reason }
            $deleted++; $released += $outcome.Bytes; $logicalRemoved += $outcome.LogicalBytes
            Write-CleanerAudit -Action Remove -Path $path -Result Success -Bytes $outcome.Bytes -Context $Context
        }
        catch {
            $skipped.Add([pscustomobject]@{ Path = $path; Reason = $_.Exception.Message })
            Write-CleanerAudit -Action Remove -Path $path -Result Skipped -Message $_.Exception.Message -Context $Context
        }
    }
    return [pscustomobject]@{
        Path = $LiteralPath; Category = $Category; ReleasedBytes = $released; Bytes = $released
        LogicalBytesRemoved = $logicalRemoved; DeletedCount = $deleted; PlannedCount = $planned; PlannedBytes = $plannedBytes
        IsComplete = ($skipped.Count -eq 0); SkippedCount = $skipped.Count
        SkippedItems = $skipped.ToArray(); Skipped = $skipped.ToArray()
    }
}

function ConvertTo-CleanerNativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW/CRT 规则；保留空参数、引号和末尾反斜杠。
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-External {
    <#
    .SYNOPSIS
        包装外部程序，执行前调用 ShouldProcess 并检查退出码。
    .DESCRIPTION
        不使用 Invoke-Expression；读取 stdout/stderr 防止管道死锁。默认仅退出码 0 成功。
        DISM 另接受表示需重启的 3010；可用 SuccessExitCodes 显式覆盖。
        -WhatIf 不启动进程、不写日志。DISM /ResetBase 和 robocopy /MIR、/PURGE 永久拒绝。
        .cmd/.bat 仅接受无 shell 元字符的参数，禁用 AutoRun；cmd.exe 仅支持 mklink /J。
        其他程序按 Windows argv 规则转义。
        用户缓存工具要求已核实的原 SID 等于当前 SID，避免使用另一个管理员的工具配置。
    .PARAMETER FilePath
        可执行程序绝对路径或可通过 Get-Command 查找的程序名。
    .PARAMETER ArgumentList
        参数字符串数组，每个元素代表一个参数。
    .PARAMETER Description
        向用户显示并写入日志的动作说明。
    .PARAMETER SuccessExitCodes
        允许的成功退出码；例如 robocopy 可显式使用 0..7。
    .PARAMETER OutputEncoding
        可选 stdout/stderr 解码编码；省略时保留 ProcessStartInfo 默认行为。
    .PARAMETER Context
        原用户上下文。
    .EXAMPLE
        Invoke-External -FilePath dism.exe -ArgumentList @('/Online','/Cleanup-Image','/AnalyzeComponentStore') -Description '分析组件存储' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Description,
        [Alias('AllowedExitCodes', 'AcceptExitCodes')][int[]]$SuccessExitCodes = @(0),
        $Context,
        [System.Text.Encoding]$OutputEncoding,
        [ValidateSet('Junction','MoveChat')][string]$JunctionCategory = 'Junction',
        [scriptblock]$OutputLine, [scriptblock]$ProgressCallback
    )
    if ($null -eq $Context) { $Context = Get-CleanerContext }
    if ($ArgumentList.Count -gt 0) {
        foreach ($argument in $ArgumentList) {
            if ($null -eq $argument -or $argument -match '[\x00\r\n]') { throw '外部命令参数不能包含 NUL、换行或 null。' }
        }
    }
    $name = [IO.Path]::GetFileName($FilePath).ToLowerInvariant()
    if ($name -eq 'dism' -or $name -eq 'dism.exe') {
        if (@($ArgumentList | Where-Object { $_ -match '(?i)[-/]ResetBase\b' }).Count -gt 0) { throw '永久禁止 DISM /ResetBase。' }
        if (-not $PSBoundParameters.ContainsKey('SuccessExitCodes')) { $SuccessExitCodes = @(0, 3010) }
    }
    if ($name -eq 'robocopy' -or $name -eq 'robocopy.exe') {
        if (@($ArgumentList | Where-Object { $_ -match '(?i)(?:^|\s)/(MIR|PURGE)(?:$|[\s:=])' }).Count -gt 0) { throw '禁止镜像删除目标的 robocopy /MIR 或 /PURGE。' }
    }
    $systemNames = @('dism', 'dism.exe', 'powercfg', 'powercfg.exe', 'vssadmin', 'vssadmin.exe', 'wsl', 'wsl.exe', 'cmd', 'cmd.exe', 'cleanmgr', 'cleanmgr.exe', 'robocopy', 'robocopy.exe', 'diskpart', 'diskpart.exe')
    if ($systemNames -contains $name) {
        $systemDirectory = [Environment]::SystemDirectory
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $systemDirectory = [IO.Path]::Combine($Context.SystemRoot, 'Sysnative') }
        if (-not $name.EndsWith('.exe')) { $name += '.exe' }
        $resolved = [IO.Path]::Combine($systemDirectory, $name)
    }
    elseif ($FilePath -match '^[A-Za-z]:[\\/]') { $resolved = ConvertTo-CleanerCanonicalPath -LiteralPath $FilePath }
    else {
        if ($FilePath -match '[\\/:*?\[\]\x00-\x1f]') { throw '程序路径必须是绝对路径或不含通配符的单个命令名。' }
        $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $resolved = $command.Source
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "找不到可执行文件：$resolved" }
    $resolvedName = [IO.Path]::GetFileName($resolved).ToLowerInvariant()
    if ((Get-CleanerTargets).UserScopedExecutables -contains $resolvedName) {
        if (-not $Context.OriginalUserVerified -or $Context.OriginalUserSid -ne $Context.CurrentUserSid) {
            throw '用户缓存/配置工具必须以已核实的原用户身份执行，不能借用另一个管理员账户。'
        }
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
    if ($null -ne $OutputEncoding) {
        $startInfo.StandardOutputEncoding = $OutputEncoding
        $startInfo.StandardErrorEncoding = $OutputEncoding
    }
    $extension = [IO.Path]::GetExtension($resolved)
    if ($extension -eq '.cmd' -or $extension -eq '.bat') {
        if ($resolved -match '[%!^&|<>"\r\n]' -or @($ArgumentList | Where-Object { $_ -match '[%!^&|<>()"\r\n]' }).Count -gt 0) { throw '批处理命令包含不安全的 shell 元字符，拒绝执行。' }
        $startInfo.FileName = [IO.Path]::Combine([Environment]::SystemDirectory, 'cmd.exe')
        $quotedArguments = @($ArgumentList | ForEach-Object { '"' + $_ + '"' })
        $startInfo.Arguments = '/d /s /c ""' + $resolved + '" ' + ($quotedArguments -join ' ') + '"'
    }
    elseif ($resolvedName -eq 'cmd.exe') {
        if (-not $Context.OriginalUserVerified) { throw '创建缓存联接前必须核实原用户身份。' }
        $commandIndex = -1
        for ($index = 0; $index -lt $ArgumentList.Count; $index++) {
            if ($ArgumentList[$index] -ieq '/c') { $commandIndex = $index + 1; break }
            if ($ArgumentList[$index] -notmatch '^/(?:d|s|v:off)$') { throw 'cmd.exe 仅允许禁用 AutoRun/延迟展开后的 mklink /J。' }
        }
        if ($commandIndex -lt 0 -or ($ArgumentList.Count - $commandIndex) -ne 4 -or $ArgumentList[$commandIndex] -ine 'mklink' -or $ArgumentList[$commandIndex + 1] -ine '/J') {
            throw 'cmd.exe 仅允许四个独立参数：mklink、/J、缓存路径、目标路径。'
        }
        $linkPath = $ArgumentList[$commandIndex + 2]; $targetPath = $ArgumentList[$commandIndex + 3]
        if ($linkPath -match '[%!^&|<>()"\r\n]' -or $targetPath -match '[%!^&|<>()"\r\n]') { throw '联接路径包含不安全的 cmd 元字符。' }
        $linkPath = ConvertTo-CleanerCanonicalPath -LiteralPath $linkPath
        $targetPath = ConvertTo-CleanerCanonicalPath -LiteralPath $targetPath
        $linkCheck = Test-SafeTarget -LiteralPath $linkPath -Category $JunctionCategory -Context $Context
        if (-not $linkCheck.IsSafe -or $linkCheck.Exists -or $linkCheck.Path -ine $linkCheck.RootPath) {
            throw '联接源必须是有安全保留副本的缺失白名单缓存根。'
        }
        $targetCheck = Test-SafeTarget -LiteralPath $targetPath -Category MigrationDestination -Context $Context
        if (-not $targetCheck.IsSafe -or -not $targetCheck.Exists) { throw '联接目标必须是非系统数据卷上已有的安全目录。' }
        $targetMetadata = Get-CleanerEntryMetadata -LiteralPath $targetPath
        if (-not $targetMetadata.IsDirectory) { throw '联接目标必须是普通目录。' }
        $startInfo.FileName = $resolved
        $startInfo.Arguments = '/d /v:off /s /c "mklink /J "' + $linkPath + '" "' + $targetPath + '""'
    }
    else {
        if ($extension -ne '.exe' -and $extension -ne '.com') { throw '仅允许 .exe/.com 或受限的 .cmd/.bat。' }
        $startInfo.FileName = $resolved
        $startInfo.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-CleanerNativeArgument -Value $_ }) -join ' ')
    }
    if (-not $PSCmdlet.ShouldProcess(($resolved + ' ' + ($ArgumentList -join ' ')), $Description)) {
        return [pscustomobject]@{ FilePath = $resolved; ArgumentList = $ArgumentList; ExitCode = $null; Success = $false; Skipped = $true; WasWhatIf = [bool]$WhatIfPreference; RebootRequired = $false; StandardOutput = ''; StandardError = ''; Output = '' }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Write-CleanerAudit -Action External -Path $resolved -Result Started -Message $Description -Context $Context
        if (-not $process.Start()) { throw '无法启动外部程序。' }
        $stdoutTask = $null
        if ($null -eq $OutputLine) { $stdoutTask = $process.StandardOutput.ReadToEndAsync() }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdout = ''
        if ($null -ne $OutputLine) {
            $lineTask = $process.StandardOutput.ReadLineAsync()
            while ($null -ne $lineTask) {
                if ($lineTask.Wait(500)) {
                    $line = $lineTask.GetAwaiter().GetResult()
                    if ($null -eq $line) { $lineTask = $null }
                    else { $null = & $OutputLine $line; $lineTask = $process.StandardOutput.ReadLineAsync() }
                }
                if ($null -ne $ProgressCallback) { $null = & $ProgressCallback }
            }
        }
        while (-not $process.WaitForExit(1000)) { if ($null -ne $ProgressCallback) { $null = & $ProgressCallback } }
        if ($null -ne $stdoutTask) { $stdout = $stdoutTask.GetAwaiter().GetResult() }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
        $success = $SuccessExitCodes -contains $exitCode
        $result = [pscustomobject]@{ FilePath = $resolved; ArgumentList = $ArgumentList; ExitCode = $exitCode; Success = $success; Skipped = $false; WasWhatIf = $false; RebootRequired = ($exitCode -eq 3010); StandardOutput = $stdout; StandardError = $stderr; Output = $stdout }
        if (-not $success) {
            $exception = [InvalidOperationException]::new("外部程序失败（退出码 $exitCode）：$Description`n$stderr")
            $exception.Data['ExternalResult'] = $result
            throw $exception
        }
        Write-CleanerAudit -Action External -Path $resolved -Result Success -Message ($Description + '; ExitCode=' + $exitCode) -Context $Context
        return $result
    }
    catch {
        Write-CleanerAudit -Action External -Path $resolved -Result Failed -Message $_.Exception.Message -Context $Context
        throw
    }
    finally { $process.Dispose() }
}

function Assert-Admin {
    <#
    .SYNOPSIS
        检查真实进程令牌的管理员权限；不自动启动提权进程。
    .PARAMETER Context
        可选上下文，仅为统一接口；权限始终重新读取真实令牌。
    .EXAMPLE
        Assert-Admin
    #>
    [CmdletBinding()]
    param($Context)
    if (-not (Test-CleanerWindows)) { throw '管理员检查仅支持 Windows。' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '此操作需要管理员 PowerShell。提权前请保存原用户 SID 和用户目录。' }
    }
    finally { $identity.Dispose() }
}

function Set-CleanerServiceStartMode {
    # Win32_Service 读取为 Auto，ChangeStartMode 写入却要求 Automatic。
    # 不写 DelayedAutoStart；恢复自动启动时必须核对原值，不能假定 CIM 会保留它。
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Auto', 'Automatic', 'Manual', 'Disabled')][string]$StartMode,
        [Nullable[bool]]$ExpectedDelayedAutoStart
    )
    if ($Name -notmatch '^[A-Za-z0-9_.-]+$') { throw "无效或包含通配符的服务名：$Name" }
    if (-not $PSCmdlet.ShouldProcess($Name, ('设置服务启动类型为 ' + $StartMode))) { return }
    $configuration = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $Name + "'") -ErrorAction Stop
    if ($null -eq $configuration) { throw "无法读取服务配置：$Name" }
    $cimStartMode = $StartMode
    if ($cimStartMode -eq 'Auto') { $cimStartMode = 'Automatic' }
    $change = Invoke-CimMethod -InputObject $configuration -MethodName ChangeStartMode -Arguments @{ StartMode = $cimStartMode } -ErrorAction Stop
    if ($null -eq $change) { throw "服务启动类型修改未返回结果：$Name" }
    $returnProperty = $change.PSObject.Properties['ReturnValue']
    if ($null -eq $returnProperty -or $null -eq $returnProperty.Value -or [uint32]$returnProperty.Value -ne 0) {
        throw "服务启动类型修改失败：$Name/$StartMode"
    }
    $updated = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $Name + "'") -ErrorAction Stop
    if ($null -eq $updated) { throw "无法核实修改后的服务配置：$Name" }
    $actualStartMode = [string]$updated.StartMode
    if ($actualStartMode -eq 'Auto') { $actualStartMode = 'Automatic' }
    if ($actualStartMode -ne $cimStartMode) { throw "服务启动类型未恢复到请求值：$Name/$actualStartMode，预期 $cimStartMode" }
    if ($null -ne $ExpectedDelayedAutoStart) {
        $delayedProperty = $updated.PSObject.Properties['DelayedAutoStart']
        if ($null -eq $delayedProperty -or $null -eq $delayedProperty.Value) { throw "无法核实服务延迟自动启动值：$Name" }
        if ([Convert]::ToBoolean($delayedProperty.Value) -ne [bool]$ExpectedDelayedAutoStart) {
            throw "服务延迟自动启动值未恢复：$Name，预期 DelayedAutoStart=$ExpectedDelayedAutoStart，实际 $($delayedProperty.Value)；请人工核实。"
        }
    }
}

function Stop-ServiceTemporarily {
    <#
    .SYNOPSIS
        记录服务原状态后临时停止，返回供 finally 恢复的状态令牌。
    .DESCRIPTION
        不强制停止依赖服务。默认不修改启动类型；DisableStartup 可在停止前临时禁用启动。
        运行中却原本已禁用的服务仍拒绝停止，以免无法恢复。
        批量停止失败时在 finally 中立即恢复已改变的服务；回滚失败的令牌仍可重试。
        -WhatIf 仅返回 Changed=false 的令牌；暂停状态在恢复时重新暂停。
    .PARAMETER Name
        服务内部名称数组，不接受通配符。
    .PARAMETER TimeoutSeconds
        等待服务停止的秒数，默认 30。
    .PARAMETER Context
        日志上下文。
    .PARAMETER DisableStartup
        在停止前临时把启动类型设为 Disabled；包括原本已停止的服务，恢复时还原原启动类型。
    .PARAMETER StateCollection
        可选的调用方 IList。获准修改前登记同一个令牌对象，随后原地更新；异常和取消时仍可恢复。
        未提供时，普通异常的 Exception.Data['ServiceStates'] 也保留令牌；取消时应使用此集合。
    .EXAMPLE
        $state = [Collections.Generic.List[object]]::new()
        try { Stop-ServiceTemporarily -Name wuauserv -StateCollection $state; '在此执行操作' }
        finally { Restore-ServiceState -State $state -Confirm:$false }
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string[]]$Name,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30,
        $Context, [switch]$DisableStartup,
        [AllowEmptyCollection()][System.Collections.IList]$StateCollection
    )
    Assert-Admin
    if ($null -eq $Context) { $Context = Get-CleanerContext }
    $states = [Collections.Generic.List[object]]::new()
    $completed = $false
    $failure = $null
    try {
        foreach ($serviceName in ($Name | Select-Object -Unique)) {
            if ($serviceName -notmatch '^[A-Za-z0-9_.-]+$') { throw "无效或包含通配符的服务名：$serviceName" }
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            $service.Refresh()
            $status = $service.Status.ToString()
            if ($status -notin @('Running', 'Stopped', 'Paused')) { throw "服务正处于过渡状态：$serviceName/$status" }
            $startType = ''
            $configuration = $null
            $startProperty = $service.PSObject.Properties['StartType']
            if ($null -ne $startProperty) { $startType = [string]$startProperty.Value }
            else {
                $configuration = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $serviceName + "'") -ErrorAction Stop
                if ($null -eq $configuration) { throw "无法读取服务启动类型：$serviceName" }
                $startType = [string]$configuration.StartMode
            }
            $startMode = ''
            $originalDelayedAutoStart = $null
            if ($DisableStartup) {
                if ($null -eq $configuration) {
                    $configuration = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $serviceName + "'") -ErrorAction Stop
                    if ($null -eq $configuration) { throw "无法读取服务启动类型：$serviceName" }
                }
                $startType = [string]$configuration.StartMode
                switch ($startType) {
                    { $_ -in @('Auto', 'Automatic') } {
                        $startMode = 'Automatic'
                        $delayedProperty = $configuration.PSObject.Properties['DelayedAutoStart']
                        if ($null -eq $delayedProperty -or $null -eq $delayedProperty.Value) { throw "无法记录服务原延迟自动启动值，拒绝禁用启动：$serviceName" }
                        $originalDelayedAutoStart = [Convert]::ToBoolean($delayedProperty.Value)
                    }
                    'Manual' { $startMode = 'Manual' }
                    'Disabled' { $startMode = 'Disabled' }
                    default { throw "不支持临时禁用此服务的启动类型：$serviceName/$startType" }
                }
            }
            if ([string]::IsNullOrWhiteSpace($startType)) { throw "无法核实服务启动类型：$serviceName" }
            if ($status -ne 'Stopped' -and $startType -eq 'Disabled') { throw "运行中的已禁用服务无法可靠恢复，拒绝停止：$serviceName" }
            $state = [pscustomobject]@{
                Name = $serviceName; OriginalStatus = $status; OriginalStartType = $startType
                OriginalStartMode = $startMode; OriginalDelayedAutoStart = $originalDelayedAutoStart
                StartupChanged = $false; WasRunning = ($status -eq 'Running'); WasPaused = ($status -eq 'Paused')
                Changed = $false; Stopped = ($status -eq 'Stopped'); Restored = $false; WasWhatIf = [bool]$WhatIfPreference
            }
            $states.Add($state)
            if ($status -eq 'Stopped' -and (-not $DisableStartup -or $startMode -eq 'Disabled')) { continue }
            $action = "临时停止服务，随后恢复为 $status"
            if ($DisableStartup) { $action = "临时禁用启动并停止服务，随后恢复为 $startType/$status" }
            if ($PSCmdlet.ShouldProcess($serviceName, $action)) {
                # 必须先交给调用方；不能依赖函数正常返回，或仅依赖内部回滚成功。
                if ($null -ne $StateCollection) { [void]$StateCollection.Add($state) }
                # 在发送配置/停止请求前记录改变，响应失败或超时时也必须尝试回滚。
                $state.Changed = $true
                if ($DisableStartup -and $startMode -ne 'Disabled') {
                    $state.StartupChanged = $true
                    Set-CleanerServiceStartMode -Name $serviceName -StartMode Disabled -Confirm:$false
                }
                $service.Refresh()
                if ($service.Status.ToString() -notin @('Running', 'Stopped', 'Paused')) { throw "服务正处于过渡状态：$serviceName/$($service.Status)" }
                if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
                    try { Stop-Service -InputObject $service -ErrorAction Stop -Confirm:$false }
                    finally {
                        # 停止请求可能已生效但响应失败；尽可能更新共享令牌的实际状态。
                        # 观察失败时保留 Changed，恢复方重新查询，不能掩盖原始停止错误。
                        try {
                            $service.Refresh()
                            $state.Stopped = ($service.Status -eq [ServiceProcess.ServiceControllerStatus]::Stopped)
                        }
                        catch { $state.Stopped = $null }
                    }
                }
                $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds($TimeoutSeconds))
                $state.Stopped = $true
                Write-CleanerAudit -Action StopService -Path $serviceName -Result Success -Message ('OriginalStatus=' + $status) -Context $Context
            }
        }
        $completed = $true
        return $states.ToArray()
    }
    catch {
        $failure = $_.Exception
        $failure.Data['ServiceStates'] = $states.ToArray()
        throw
    }
    finally {
        if (-not $completed) {
            try { Restore-ServiceState -State $states.ToArray() -TimeoutSeconds $TimeoutSeconds -Context $Context -Confirm:$false }
            catch {
                if ($null -ne $failure) { $failure.Data['ServiceRollbackError'] = $_.Exception }
                Write-Warning "服务停止未完成，恢复也失败；请使用 StateCollection 或异常中的 ServiceStates 重试：$($_.Exception.Message)" -WarningAction Continue
            }
        }
    }
}

function Restore-ServiceState {
    <#
    .SYNOPSIS
        恢复 Stop-ServiceTemporarily 返回令牌中实际改变的服务。
    .DESCRIPTION
        通常放在 finally。未停止/演练的令牌不改变服务；失败继续恢复其他服务，最后抛错。
        恢复可选的临时启动类型修改，保留原 Stopped/Running/Paused 状态。
        状态恢复失败仍尝试还原启动类型；过渡状态先等待稳定，恢复令牌可重试。
    .PARAMETER State
        Stop-ServiceTemporarily 返回的令牌数组或 StateCollection，也可从管道传入，允许部分修改的令牌。
    .PARAMETER TimeoutSeconds
        等待每个服务恢复的秒数，默认 30。
    .PARAMETER Context
        日志上下文。
    .EXAMPLE
        Restore-ServiceState -State $state -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][AllowEmptyCollection()][object[]]$State, [ValidateRange(1, 300)][int]$TimeoutSeconds = 30, $Context)
    begin {
        Assert-Admin
        if ($null -eq $Context) { $Context = Get-CleanerContext }
        $errors = [Collections.Generic.List[string]]::new()
    }
    process {
        for ($index = $State.Count - 1; $index -ge 0; $index--) {
            $token = $State[$index]
            $tokenName = '<未知服务>'
            try {
                if ($null -eq $token) { continue }
                # 兼容旧令牌；新增字段必须在 StrictMode 下按可选属性读取。
                $nameProperty = $token.PSObject.Properties['Name']
                if ($null -ne $nameProperty) { $tokenName = [string]$nameProperty.Value }
                $startupProperty = $token.PSObject.Properties['StartupChanged']
                $startupChanged = $null -ne $startupProperty -and [bool]$startupProperty.Value
                $changedProperty = $token.PSObject.Properties['Changed']
                $changed = $null -ne $changedProperty -and [bool]$changedProperty.Value
                $restoredProperty = $token.PSObject.Properties['Restored']
                $restored = $null -ne $restoredProperty -and [bool]$restoredProperty.Value
                $whatIfProperty = $token.PSObject.Properties['WasWhatIf']
                if (($null -ne $whatIfProperty -and [bool]$whatIfProperty.Value) -or
                    (-not $changed -and -not $startupChanged) -or ($restored -and -not $startupChanged)) { continue }
                $startModeProperty = $token.PSObject.Properties['OriginalStartMode']
                $originalStartMode = ''
                if ($null -ne $startModeProperty) { $originalStartMode = [string]$startModeProperty.Value }
                if ($tokenName -notmatch '^[A-Za-z0-9_.-]+$' -or $token.OriginalStatus -notin @('Running', 'Paused', 'Stopped') -or
                    ($startupChanged -and $originalStartMode -notin @('Auto', 'Automatic', 'Manual', 'Disabled'))) { throw '无效的服务恢复令牌。' }
                if (-not $PSCmdlet.ShouldProcess($tokenName, ('恢复服务原状态 ' + $token.OriginalStatus))) { continue }
                $startupArguments = @{ Name = $tokenName; StartMode = $originalStartMode; Confirm = $false }
                $delayedProperty = $token.PSObject.Properties['OriginalDelayedAutoStart']
                if ($null -ne $delayedProperty -and $null -ne $delayedProperty.Value) {
                    $startupArguments['ExpectedDelayedAutoStart'] = [Convert]::ToBoolean($delayedProperty.Value)
                }
                $tokenErrors = [Collections.Generic.List[string]]::new()
                $steps = @('Startup', 'Status')
                if ($token.OriginalStatus -eq 'Stopped') { $steps = @('Status', 'Startup') }
                foreach ($step in $steps) {
                    $service = $null
                    try {
                        if ($step -eq 'Startup') {
                            if ($startupChanged) {
                                # 仅在启动类型及延迟启动值均核实后清除，失败仍可重试。
                                Set-CleanerServiceStartMode @startupArguments
                                $token.StartupChanged = $false
                            }
                            continue
                        }
                        $service = Get-Service -Name $tokenName -ErrorAction Stop
                        $service.Refresh()
                        switch ($service.Status.ToString()) {
                            'StopPending' { $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds($TimeoutSeconds)) }
                            'StartPending' { $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds($TimeoutSeconds)) }
                            'ContinuePending' { $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds($TimeoutSeconds)) }
                            'PausePending' { $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Paused, [TimeSpan]::FromSeconds($TimeoutSeconds)) }
                        }
                        $service.Refresh()
                        if ($token.OriginalStatus -eq 'Stopped') {
                            if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
                                Stop-Service -InputObject $service -ErrorAction Stop -Confirm:$false
                                $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds($TimeoutSeconds))
                            }
                        }
                        elseif ($service.Status -eq [ServiceProcess.ServiceControllerStatus]::Stopped) {
                            Start-Service -InputObject $service -ErrorAction Stop -Confirm:$false
                            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds($TimeoutSeconds))
                        }
                        elseif ($service.Status -eq [ServiceProcess.ServiceControllerStatus]::Paused -and $token.OriginalStatus -eq 'Running') {
                            Resume-Service -InputObject $service -ErrorAction Stop -Confirm:$false
                            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds($TimeoutSeconds))
                        }
                        if ($token.OriginalStatus -eq 'Paused') {
                            $service.Refresh()
                            if ($service.Status -eq [ServiceProcess.ServiceControllerStatus]::Running) {
                                Suspend-Service -InputObject $service -ErrorAction Stop -Confirm:$false
                                $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Paused, [TimeSpan]::FromSeconds($TimeoutSeconds))
                            }
                        }
                        $service.Refresh()
                        if ($service.Status.ToString() -ne $token.OriginalStatus) { throw '服务未恢复到记录的状态。' }
                    }
                    catch { $tokenErrors.Add($step + ': ' + $_.Exception.Message) }
                    finally {
                        if ($null -ne $service) {
                            try {
                                $service.Refresh()
                                $stoppedProperty = $token.PSObject.Properties['Stopped']
                                if ($null -ne $stoppedProperty) { $token.Stopped = ($service.Status -eq [ServiceProcess.ServiceControllerStatus]::Stopped) }
                            }
                            catch { $tokenErrors.Add('StatusCheck: ' + $_.Exception.Message) }
                        }
                    }
                }
                if ($tokenErrors.Count -gt 0) { throw ($tokenErrors -join '; ') }
                $token.Restored = $true
                Write-CleanerAudit -Action RestoreService -Path $tokenName -Result Success -Message $token.OriginalStatus -Context $Context
            }
            catch {
                $message = $_.Exception.Message
                $errors.Add($tokenName + ': ' + $message)
                try { Write-CleanerAudit -Action RestoreService -Path $tokenName -Result Failed -Message $message -Context $Context }
                catch { $errors.Add($tokenName + ' (审计): ' + $_.Exception.Message) }
            }
        }
    }
    end { if ($errors.Count -gt 0) { throw ('部分服务恢复失败：' + ($errors -join '; ')) } }
}
