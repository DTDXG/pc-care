Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script:definitions = @{}
foreach ($file in @('common.ps1', 'clean.ps1', 'migrate.ps1', 'move.ps1', 'partition.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo ('scripts/' + $file)), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors.Message -join ';') }
    foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true)) {
        $script:definitions[$node.Name] = $node.Extent.Text
        . ([scriptblock]::Create($node.Extent.Text))
    }
}
$script:checks = 0
function Assert-T8 { param([bool]$Value, [string]$Message) $script:checks++; if (-not $Value) { throw ('FAIL: ' + $Message) } }
function Assert-ThrowsT8 {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = ''
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-T8 ($caught -match $Pattern) ('expected rejection: ' + $Pattern + '; actual: ' + $caught)
}
$local = 'C:\Users\me\AppData\Local'
$plain = $local + '\CDriveCleaner\Logs'
$packaged = $local + '\Packages\OpenAI.Codex_abc123\LocalCache\Local\CDriveCleaner\Logs'
$portable = 'C:\Users\me\.pc-care\Logs'
Assert-T8 ((Get-CleanerLogBase $local '') -ceq $plain) 'unpackaged log base'
Assert-T8 ((Get-CleanerLogBase $local 'OpenAI.Codex_abc123') -ceq $packaged) 'packaged log base'
foreach ($family in @('', 'a\b_pub', '.._pub', 'a..b_pub', 'a:b_pub', 'a b_pub', 'missing', 'a_b_c', '_pub', 'app_', "app_pub`n")) {
    Assert-T8 ((Get-CleanerLogBase $local $family) -ceq $plain) ('invalid family falls back: ' + $family)
}

$script:CleanerTargets = Import-PowerShellDataFile (Join-Path $repo 'scripts/targets.psd1')
$context = [pscustomobject]@{
    OriginalUserSid = 'S-test'; CurrentUserSid = 'S-test'; OriginalUserProfile = 'C:\Users\me'; OriginalUserVerified = $true
    SystemDrive = 'C:'; SystemRoot = 'C:\Windows'; IsAdmin = $false; SyncRoots = @(); ProtectedMachineRoots = @('C:\Program Files'); LogPath = ''
    Variables = @{ USERPROFILE = 'C:\Users\me'; LOCALAPPDATA = $local; APPDATA = 'C:\Users\me\AppData\Roaming'
        SystemRoot = 'C:\Windows'; SystemDrive = 'C:'; ProgramData = 'C:\ProgramData'; ProgramFiles = 'C:\Program Files'
        'ProgramFiles(x86)' = 'C:\Program Files (x86)'; ProgramW6432 = 'C:\Program Files' }
}
# Execute the actual context function's final log-selection statements, after its Windows identity/registry prelude.
$contextAst = [Management.Automation.Language.Parser]::ParseInput($script:definitions['Get-CleanerContext'], [ref]$null, [ref]$null)
$statements = @($contextAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true).Body.EndBlock.Statements)
$tail = @($statements[($statements.Count - 3)..($statements.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n"
$contextTail = [scriptblock]::Create('param($context, [string]$LogPath, [string]$LogDirectory)' + "`n" + $tail)
$oldLog = [Environment]::GetEnvironmentVariable('CLEANER_LOG_PATH')
try {
    [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', $null)
    & {
        function Get-CleanerPackageFamilyName { throw 'default location must not depend on the client package' }
        $resolved = & $contextTail -context $context
        Assert-T8 ($resolved.LogPath.StartsWith($portable + '\cleaner-')) 'Get-CleanerContext uses client-independent default'
        $explicit = $plain + '\explicit.jsonl'
        [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', ($plain + '\environment.jsonl'))
        $resolved = & $contextTail -context $context -LogPath $explicit
        Assert-T8 ($resolved.LogPath -ceq $explicit) 'explicit LogPath wins over environment and package'
        $resolved = & $contextTail -context $context
        Assert-T8 ($resolved.LogPath -ceq ($plain + '\environment.jsonl')) 'environment wins over package'
        function Get-CleanerPackageFamilyName { throw 'explicit paths must not query package identity' }
        $resolved = & $contextTail -context $context -LogPath $explicit
        Assert-T8 ($resolved.LogPath -ceq $explicit) 'explicit path does not query package identity'
        $resolved = & $contextTail -context $context
        Assert-T8 ($resolved.LogPath.EndsWith('\environment.jsonl')) 'environment does not query package identity'
    }
    [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', $null)
    & {
        function Get-CleanerPackageFamilyName { return @{ FamilyName = ''; Error = 'package lookup failed: 5' } }
        $resolved = & $contextTail -context $context
        Assert-T8 ($resolved.LogPath.StartsWith($portable + '\cleaner-')) 'package lookup failure cannot change default'
        Assert-T8 ($resolved.PackageIdentityDiagnostic -ceq '') 'no package query needed'
    }
} finally { [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', $oldLog) }

# Real Reflection.Emit declaration is built in memory; never invoke its Windows entry points on Linux.
& {
    $script:CleanerNativeType = $null
    function Test-CleanerWindows { return $true }
    $native = Get-CleanerNativeType
    Assert-T8 ($native.FullName -ceq 'CDriveCleaner.NativeV5') 'new native type avoids reusing V4'
    $method = $native.GetMethod('GetCurrentPackageFamilyName')
    Assert-T8 ($method.ReturnType -eq [int]) 'package API returns LONG error code'
    Assert-T8 ($method.GetParameters()[0].ParameterType -eq [uint32].MakeByRefType()) 'package API length is ref uint'
    Assert-T8 ($method.GetParameters()[1].ParameterType -eq [Text.StringBuilder]) 'package API Unicode buffer'
}
class T8Native {
    static [int]$PackageMode = 15700
    static [int]$PackageCalls = 0
    static [string]$Family = 'OpenAI.Codex_abc123'
    static [string]$Path = ''
    static [string]$FailureAt = '/guard/profile/logs'
    static [bool]$Reparse = $false
    static [Collections.Generic.List[string]]$Visited = [Collections.Generic.List[string]]::new()
    static [int] GetCurrentPackageFamilyName([ref]$length, [Text.StringBuilder]$buffer) {
        [T8Native]::PackageCalls++
        if ([T8Native]::PackageMode -ne 0) { return [T8Native]::PackageMode }
        if ($null -eq $buffer) { $length.Value = [uint32]([T8Native]::Family.Length + 1); return 122 }
        $null = $buffer.Append([T8Native]::Family)
        return 0
    }
    static [Microsoft.Win32.SafeHandles.SafeFileHandle] CreateFileW([string]$path, [uint32]$access, [uint32]$share, [IntPtr]$security, [uint32]$creation, [uint32]$flags, [IntPtr]$template) {
        if ($share -ne 3 -or $flags -ne 0x02300000) { throw 'ancestor guard flags changed' }
        [T8Native]::Path = $path
        [T8Native]::Visited.Add($path)
        return [Microsoft.Win32.SafeHandles.SafeFileHandle]::new([IntPtr]123, $false)
    }
    static [bool] GetFileInformationByHandle([Microsoft.Win32.SafeHandles.SafeFileHandle]$handle, [IntPtr]$memory) {
        [Runtime.InteropServices.Marshal]::Copy([byte[]]::new(64), 0, $memory, 64)
        $attributes = 0x10
        if ([T8Native]::Reparse -and [T8Native]::Path -ceq [T8Native]::FailureAt) { $attributes = $attributes -bor 0x400 }
        [Runtime.InteropServices.Marshal]::WriteInt32($memory, 0, $attributes)
        return $true
    }
    static [bool] GetFileInformationByHandleEx([Microsoft.Win32.SafeHandles.SafeFileHandle]$handle, [int]$kind, [IntPtr]$memory, [uint32]$size) {
        [Runtime.InteropServices.Marshal]::Copy([byte[]]::new([int]$size), 0, $memory, [int]$size)
        return $true
    }
}
& {
    function Get-CleanerNativeType { return [T8Native] }
    foreach ($code in @(15700, 5, 122, 0)) {
        [T8Native]::PackageMode = $code; [T8Native]::PackageCalls = 0
        $package = Get-CleanerPackageFamilyName
        if ($code -eq 0) {
            Assert-T8 ($package.FamilyName -ceq 'OpenAI.Codex_abc123' -and [T8Native]::PackageCalls -eq 2) '122 retries using returned buffer length'
        } else {
            Assert-T8 ($package.FamilyName -ceq '') ('API failure has no family: ' + $code)
            Assert-T8 (($package.Error -eq '') -eq ($code -eq 15700)) ('only no-package is silent: ' + $code)
            Assert-T8 ([T8Native]::PackageCalls -le 4) 'buffer retries are bounded'
        }
    }
    [T8Native]::PackageMode = 0; [T8Native]::Family = 'bad_family_extra'
    $package = Get-CleanerPackageFamilyName
    Assert-T8 ($package.FamilyName -ceq '' -and $package.Error) 'API-sourced invalid family rejected with diagnostic'
}

$context.LogPath = $packaged + '\parent.jsonl'
Assert-T8 (-not (Get-CleanerForbiddenReason $packaged $context)) 'packaged directory is not forbidden'
$entries = @(Get-CleanerMigrationTarget $script:CleanerTargets.Categories.MigrationManifest $context)
Assert-T8 (@($entries | Where-Object { $_.Path -ceq $packaged -and $_.Scope -eq 'Container' }).Count -eq 1) 'packaged directory is AuditDirectory container'
foreach ($bad in @(($local + '\Packages'), ($local + '\Packages\Other_pub\LocalState'), ($local + '\Packages\Other_pub\LocalCache\Local\OtherLogs'))) {
    $context.LogPath = $bad + '\parent.jsonl'
    Assert-ThrowsT8 { Get-CleanerMigrationTarget $script:CleanerTargets.Categories.MigrationManifest $context } '记录目录不安全'
}
$context.LogPath = $packaged + '\parent.jsonl'
& {
    function Get-CleanerPackageFamilyName { throw 'child must use the parent directory without a package lookup' }
    $script:chainVisits = @()
    function Test-CleanerPathChain { param($LiteralPath, [switch]$AllowMissing) $script:chainVisits += $LiteralPath; return @{ IsSafe = $true } }
    foreach ($directory in @($plain, $packaged, $portable)) {
        $parentLog = $context.LogPath
        $oldLog = [Environment]::GetEnvironmentVariable('CLEANER_LOG_PATH')
        try {
            [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', $parentLog)
            $child = & $contextTail -context $context -LogDirectory $directory
            $first = $child.LogPath
            $child = & $contextTail -context $context -LogDirectory $directory
            Assert-T8 ($child.LogPath.StartsWith($directory + '\cleaner-') -and $child.LogPath.EndsWith('.jsonl')) 'child receives requested directory and JSONL shape'
            Assert-T8 ($child.LogPath -cne $first -and $child.LogPath -cne $parentLog) 'child logs are unique and ignore inherited file'
        } finally { [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', $oldLog) }
    }
    Assert-T8 ($script:chainVisits.Count -eq 6) 'each child log passes strict path-chain validator'
    foreach ($bad in @('D:\CDriveCleaner\Logs', 'C:\Users\other\AppData\Local\CDriveCleaner\Logs',
        ($local + '\Wrong\Logs'), ($plain + '\..\Logs'), ($packaged + '\..\Logs'), ($plain + '\file.jsonl'),
        ($local + '\Packages\invalid\LocalCache\Local\CDriveCleaner\Logs'), '\\server\share\CDriveCleaner\Logs')) {
        Assert-ThrowsT8 { Set-CleanerChildLogDirectory $bad $context } '记录目录不安全'
    }
    function Test-CleanerPathChain { param($LiteralPath, [switch]$AllowMissing) return @{ IsSafe = $false; Reason = 'mock reparse refusal' } }
    Assert-ThrowsT8 { Set-CleanerChildLogDirectory $packaged $context } '记录目录无法安全使用'
}

# Actual whitelist matching accepts only records in this context's directory.
& {
    $context.LogPath = $packaged + '\parent.jsonl'
    function Test-CleanerPathChain {
        param($LiteralPath, [switch]$AllowMissing)
        return @{ IsSafe = $true; Path = $LiteralPath; Exists = $false; Attributes = $null; ExistingParent = $local }
    }
    function Get-CleanerEntryMetadata { param($LiteralPath) return @{ IsDirectory = $true } }
    Assert-T8 ((Test-SafeTarget ($packaged + '\moves.json') MigrationManifest $context).IsSafe) 'actual AuditDirectory matching accepts packaged manifest'
    foreach ($path in @(($local + '\Packages'), ($local + '\Packages\Other_pub\LocalState\moves.json'),
        ($local + '\Packages\Other_pub\LocalCache\Local\CDriveCleaner\Logs\moves.json'))) {
        $check = Test-SafeTarget $path MigrationManifest $context
        Assert-T8 (-not $check.IsSafe -and $check.Reason -match '白名单') ('other Packages paths not whitelisted: ' + $path)
    }
}
# Drive the actual child entry functions through their context call; invalid directories stop before work.
& {
    function Get-CleanerContext {
        param($OriginalUserSid, $OriginalUserProfile, $LogDirectory)
        $script:receivedLogDirectory = $LogDirectory
        return (& $contextTail -context $context -LogDirectory $LogDirectory)
    }
    function Get-CleanCurrentSid { return 'S-test' }
    function Read-CleanJsonFile { throw 'unsafe clean child reached report read' }
    function Get-PcOutputPath { param($Path, $Kind, $Context) return 'memory-result.json' }
    function Write-PcJson { param($Value, $Path) $script:partitionRefusal = $Value }
    function Read-PcJson { throw 'unsafe partition child reached plan read' }
    $script:BitLockerShrinkPolicy = 'Block'
    # Test move's real context-initialization statements, excluding its two import statements and all later work.
    $moveAst = [Management.Automation.Language.Parser]::ParseInput($script:definitions['Invoke-MoveMain'], [ref]$null, [ref]$null)
    $init = @($moveAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true).Body.EndBlock.Statements)
    $stop = 2
    while ($init[$stop].Extent.Text -notmatch '^\$script:MigrationContext=Get-CleanerContext') { $stop++ }
    $moveInit = [scriptblock]::Create('param($Arguments)' + "`n" + (($init[2..$stop] | ForEach-Object { $_.Extent.Text }) -join "`n"))
    foreach ($bad in @('D:\CDriveCleaner\Logs', ($local + '\wrong\Logs'), ($plain + '\..\Logs'))) {
        Assert-ThrowsT8 { Invoke-CleanCommand -ReportPath 'unused.json' -AdminPhase $true -OriginalUserSid 'S-test' -OriginalUserProfile 'C:\Users\me' -LogDirectory $bad } '无法确认当前账户'
        Assert-T8 ($script:receivedLogDirectory -ceq $bad) 'clean child passes directory unchanged to strict context validation'
        Assert-ThrowsT8 { & $moveInit @{ Worker = $true; ElevatedChild = $false; OriginalUserSid = 'S-test'; OriginalUserProfile = 'C:\Users\me'; LogDirectory = $bad } } '记录目录不安全'
        Assert-T8 ($script:receivedLogDirectory -ceq $bad) 'move child passes directory unchanged to strict context validation'
        $null = Invoke-PcPartitionMain -Child $true -ExpectedSid 'S-test' -OriginalProfile 'C:\Users\me' -LogDirectory $bad
        Assert-T8 ($script:receivedLogDirectory -ceq $bad) 'partition child passes directory unchanged to strict context validation'
        Assert-T8 ($script:partitionRefusal.Status -ceq 'Refused' -and $script:partitionRefusal.Reason -match '未修改任何分区') 'partition child refuses invalid log directory before reading or executing'
    }
}

# Exercise the real guard loop with host-native lexical paths; native calls remain mocked.
& {
    $guardInputPath = '/guard/profile/logs/file.jsonl'
    $expected = '/,/guard,/guard/profile,/guard/profile/logs'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $guardInputPath = 'C:\guard\profile\logs\file.jsonl'
        $expected = 'C:\,C:\guard,C:\guard\profile,C:\guard\profile\logs'
    }
    [T8Native]::FailureAt = [IO.Path]::GetDirectoryName($guardInputPath)
    function Get-CleanerNativeType { return [T8Native] }
    function Get-CleanerFinalHandlePath {
        param($Handle)
        if ($script:mismatch -and [T8Native]::Path -ceq [T8Native]::FailureAt) { return '/redirected/logs' }
        return [T8Native]::Path
    }
    $script:mismatch = $false; [T8Native]::Reparse = $false; [T8Native]::Visited.Clear()
    $guards = Open-CleanerParentGuards $guardInputPath
    try {
        Assert-T8 (([T8Native]::Visited -join ',') -ceq $expected) 'guard loop visits all four expected ancestors'
        Assert-T8 ($guards.Handles.Count -eq 4) 'all ancestors stay guarded'
    } finally { foreach ($handle in $guards.Handles) { $handle.Dispose() } }
    $script:mismatch = $true; [T8Native]::Visited.Clear()
    Assert-ThrowsT8 { Open-CleanerParentGuards $guardInputPath } '父目录最终路径发生变化'
    Assert-T8 (([T8Native]::Visited -join ',') -ceq $expected) 'final-path mismatch tested after visiting every ancestor'
    try { Open-CleanerParentGuards $guardInputPath | Out-Null }
    catch { $diagnostic = Get-CleanFailureDiagnostics 'Clean/ResultFile' '/guard/profile/logs/file.jsonl' $_ }
    Assert-T8 ($diagnostic.RequestedPath -ceq [T8Native]::FailureAt -and $diagnostic.FinalPath -ceq '/redirected/logs') 'real guard failure preserves requested and final ancestor paths'
    $script:mismatch = $false; [T8Native]::Reparse = $true; [T8Native]::Visited.Clear()
    Assert-ThrowsT8 { Open-CleanerParentGuards $guardInputPath } '重解析点'
    Assert-T8 (([T8Native]::Visited -join ',') -ceq $expected) 'reparse refusal tested after visiting every ancestor'
}

# Inspect actual commands and actual move launch arguments; Start-Process never executes.
$context.LogPath = $packaged + '\parent.jsonl'
$command = New-CleanAdminCommand 'C:\pc care\clean.ps1' 'C:\report.json' @(@{Id = 'cache:WindowsTemp'}) 'C:\result.json' $context ([guid]::NewGuid())
Assert-T8 ($command.Replace('/', '\').Contains("-LogDirectory '$packaged'")) 'clean admin command inherits parent directory'
$command = New-PcElevationCommand 'C:\pc care\partition.ps1' 'C:\plan.json' 'C:\result.json' 'S-test' -LogDirectory $packaged -OriginalUserProfile $context.OriginalUserProfile
Assert-T8 ($command.Replace('/', '\').Contains("-LogDirectory '$packaged'") -and $command.Replace('/', '\').Contains("-OriginalUserProfile 'C:\Users\me'")) 'partition elevation inherits parent directory and original profile'
& {
    $script:MigrationContext = $context; $script:MigrationSid = $context.OriginalUserSid; $script:MigrationProfile = $context.OriginalUserProfile
    $script:MoveScriptPath = 'C:\pc care\move.ps1'; $script:launchArguments = ''
    function Assert-MigrationTarget { param($Path, $Category) }
    function Test-Path { param($LiteralPath) return $false }
    function Get-Process { param($Id) return @{ Path = 'C:\pwsh.exe' } }
    function Start-Process {
        param($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru, $WindowStyle, $ErrorAction)
        $script:launchArguments = $ArgumentList
        return @{ Id = 1234; StartTime = [datetime]::UtcNow }
    }
    $null = Invoke-MoveElevatedChild @{ Id = ('a' * 32) } $script:MoveScriptPath ($packaged + '\move-result.json')
    Assert-T8 ($script:launchArguments.Replace('/', '\').Contains('-LogDirectory ' + $packaged)) 'actual move elevated launcher inherits parent directory'
    function Get-MoveStatusPath { param($Manifest, $Id) return ($packaged + '\status.json') }
    function Open-MoveShortLock { param($Path) return @{} }
    function Read-MoveStatus { param($Path) return $null }
    function Save-MoveStatus { param($Path, $Status) }
    function Close-MigrationManifestLock { param($Lock) }
    function Get-MoveStatusResult { param($Status, $Record, $Alive) return @{} }
    $null = Start-MoveWorker @{ Id = ('a' * 32); State = 'Copying'; TotalBytes = 10 } ($packaged + '\moves.json') Move
    Assert-T8 ($script:launchArguments.Replace('/', '\').Contains('-LogDirectory ' + $packaged)) 'actual move worker launcher inherits parent directory'
}
Write-Host ('PASS t8-packaged-logdir: {0} assertions; AST-only loading; mocked native calls and child processes.' -f $script:checks)
