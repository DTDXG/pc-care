Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/common.ps1')
$script:checks = 0
function Assert-T9 { param([bool]$Value, [string]$Message) $script:checks++; if (-not $Value) { throw $Message } }
$ctx = [pscustomobject]@{
    OriginalUserProfile = 'C:\Users\me'; OriginalUserSid = 'test'; CurrentUserSid = 'test'
    OriginalUserVerified = $true; IsAdmin = $false; SystemDrive = 'C:'; LogPath = ''
    SyncRoots = @(); ProtectedMachineRoots = @('C:\Program Files')
    Variables = @{ USERPROFILE = 'C:\Users\me'; LOCALAPPDATA = 'C:\Users\me\AppData\Local'
        APPDATA = 'C:\Users\me\AppData\Roaming'; SystemRoot = 'C:\Windows'; SystemDrive = 'C:'
        ProgramData = 'C:\ProgramData'; ProgramFiles = 'C:\Program Files'
        'ProgramFiles(x86)' = 'C:\Program Files (x86)'; ProgramW6432 = 'C:\Program Files' }
}
$ordinary = 'C:\Users\me\AppData\Local\Temp\safe.tmp'
Assert-T9 (-not (Get-CleanerForbiddenReason $ordinary $ctx)) 'ordinary temp allowed'
Assert-T9 ([bool](Get-CleanerForbiddenReason 'C:\Program Files\App\cache.tmp' $ctx)) 'program files remain forbidden'
Assert-T9 ([bool](Get-CleanerForbiddenReason 'C:\Users\me' $ctx)) 'profile root protected'
Assert-T9 ([bool](Get-CleanerForbiddenReason 'C:\Users\me\OneDrive\safe.tmp' $ctx)) 'sync segment protected'
$ctx.SyncRoots = @('C:\Users\me\AppData\Local\Temp')
Assert-T9 ([bool](Get-CleanerForbiddenReason $ordinary $ctx)) 'changed sync roots invalidate compiled rules'
$ctx.SyncRoots = @()
Assert-T9 (-not (Get-CleanerForbiddenReason $ordinary $ctx)) 'removed sync root invalidates rules'
$ctx.ProtectedMachineRoots += 'C:\Users\me\AppData\Local\Temp'
Assert-T9 ([bool](Get-CleanerForbiddenReason $ordinary $ctx)) 'changed machine roots invalidate rules'
$ctx.ProtectedMachineRoots = @('C:\Program Files')
$targets = Get-CleanerTargets
$savedForbidden = $targets.ForbiddenPaths
try {
    $targets.ForbiddenPaths += '%LOCALAPPDATA%\Temp'
    Assert-T9 ([bool](Get-CleanerForbiddenReason $ordinary $ctx)) 'policy mutation invalidates rules'
    $ctx.Variables.LOCALAPPDATA = 'C:\Users\me\Different'
    Assert-T9 (-not (Get-CleanerForbiddenReason $ordinary $ctx)) 'changed variables cannot reuse stale expanded rules'
} finally { $targets.ForbiddenPaths = $savedForbidden; $ctx.Variables.LOCALAPPDATA = 'C:\Users\me\AppData\Local' }
$expansionCtx = [pscustomobject]@{ Variables = @{ USERPROFILE = 'C:\Users\张$1${name}$$\'; 'ProgramFiles(x86)' = 'C:\Program Files (x86)' } }
Assert-T9 ((Expand-CleanerPath '%userprofile%file.tmp' $expansionCtx) -ceq 'C:\Users\张$1${name}$$\file.tmp') 'replacement dollars, Unicode, trailing slash and case preserved'
Assert-T9 ((Expand-CleanerPath '%ProgramFiles(x86)%\App' $expansionCtx) -ceq 'C:\Program Files (x86)\App') 'token regex punctuation preserved'
$thrown = $false
try { Expand-CleanerPath '%UNKNOWN%\x' $expansionCtx | Out-Null } catch { $thrown = $true }
Assert-T9 $thrown 'unknown variables remain rejected'
foreach ($pattern in @('C:\Users\*\Temp', '*.db', 'C:\a+b\中文', 'C:\temp?', 'C:\Temp\')) {
    foreach ($path in @('C:\Users\me\Temp\x', 'C:\Users\me\Temp2', 'cache.db', 'C:\a+b\中文', 'C:\TEMP1', 'C:\Temp\a')) {
        foreach ($exact in @($false, $true)) {
            $expression = '^(?:' + (ConvertTo-CleanerPatternRegex $pattern) + ')'
            if ($exact) { $expression += '$' } else { $expression += '(?:\\|$)' }
            $expected = [regex]::IsMatch($path, $expression, [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')
            Assert-T9 ((Test-CleanerPattern $path $pattern -Exact:$exact) -eq $expected) 'cached matcher preserves original semantics'
        }
    }
}
$oldLog = [Environment]::GetEnvironmentVariable('CLEANER_LOG_PATH')
try {
    [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', $null)
    & {
        function Get-CleanerPackageFamilyName { throw 'client package lookup is forbidden in this test' }
        Set-CleanerContextLogPath $ctx
        Assert-T9 ($ctx.LogPath.StartsWith('C:\Users\me\.pc-care\Logs\cleaner-')) 'portable default needs no client identity'
        Assert-T9 ((Assert-CleanerLogDirectory 'C:\Users\me\.pc-care\Logs' $ctx) -ceq 'C:\Users\me\.pc-care\Logs') 'portable parent accepted'
    }
} finally { [Environment]::SetEnvironmentVariable('CLEANER_LOG_PATH', $oldLog) }
foreach ($bad in @('C:\Users\other\.pc-care\Logs', 'C:\Users\me\.pc-care', 'C:\Users\me\.pc-care\Logs\other')) {
    $thrown = $false
    try { Assert-CleanerLogDirectory $bad $ctx | Out-Null } catch { $thrown = $true }
    Assert-T9 $thrown 'portable directory does not broaden record authorization'
}

# Expiration is handled inside a large target, before any deletion or traversal.
& {
    $script:deleted = 0; $script:enumerated = 0
    function Test-SafeTarget { param($LiteralPath, $Category, $Context) return @{ IsSafe=$true; ExternalOnly=$false; Path=$LiteralPath } }
    function Write-CleanerAudit { }
    function Get-CleanerChildren { $script:enumerated++; throw 'expired traversal must not enumerate' }
    function Remove-CleanerLeaf { $script:deleted++; throw 'expired traversal must not delete' }
    $result = Remove-SafeItem -LiteralPath $ordinary -Category UserTemp -Context $ctx -DeadlineUtc ([datetime]::UtcNow.AddSeconds(-1)) -Confirm:$false
    Assert-T9 (-not $result.IsComplete -and $result.DeletedCount -eq 0 -and $result.SkippedCount -eq 1) 'deadline yields an honest partial result'
    Assert-T9 ($script:deleted -eq 0 -and $script:enumerated -eq 0) 'deadline preserves unvisited contents'
}

foreach ($name in @('clean.ps1', 'clean-cache.ps1')) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo ('scripts/' + $name)), [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$outcome = Get-CleanOutcome @(@{Result='partial'; SkippedCount=1; SkippedItems=@(@{Reason='已达到快速清理时间预算，剩余内容保留。'})})
Assert-T9 ($outcome.Status -eq 'Partial' -and $outcome.Reason -match '时间预算') 'public result preserves timeout reason'
& {
    $ctx | Add-Member -NotePropertyName CleanMode -NotePropertyValue Full -Force
    $ctx | Add-Member -NotePropertyName CleanCacheBudgetSeconds -NotePropertyValue 42 -Force
    $command = New-CleanAdminCommand 'C:\skill\clean.ps1' 'C:\report.json' @(@{Id='cache:WindowsTemp'}) 'C:\result.json' $ctx ([guid]::NewGuid())
    Assert-T9 ($command.Contains("-Mode 'Full'") -and $command.Contains('-CacheBudgetSeconds 42')) 'child receives selected mode and budget'
}
& {
    $script:CacheCleanerDeadlineUtc = [datetime]::UtcNow.AddSeconds(-1)
    $script:CacheCleanerBudgetReported = @{}; $script:skips = 0
    function Add-CacheSkip { param($Name, $LiteralPath, $Reason, [switch]$Quiet) $script:skips++ }
    Assert-T9 (Test-CacheTimeBudget UserTemp 'C:\temp') 'cache deadline detected'
    Assert-T9 (Test-CacheTimeBudget UserTemp 'C:\temp') 'repeat deadline detected'
    Assert-T9 ($script:skips -eq 1) 'one summary rather than thousands of skip records'
}
& {
    $script:roots = @(); $script:CacheCleanerDeadlineUtc = $null
    function Test-Path { param($LiteralPath, $PathType) return $true }
    function Test-SafeTarget { return @{ IsSafe=$true } }
    function Remove-CacheTarget { param($Name, $LiteralPath) $script:roots += $LiteralPath }
    function Get-ChildItem { throw 'unfiltered roots should use one shared traversal' }
    Remove-CacheDirectoryChildren UserTemp 'C:\Users\me\AppData\Local\Temp'
    Assert-T9 ($script:roots.Count -eq 1 -and $script:roots[0] -ceq 'C:\Users\me\AppData\Local\Temp') 'temporary root visited once'
}
Write-Host ('PASS t9-portable-quick: {0} assertions; no real deletion.' -f $script:checks)
