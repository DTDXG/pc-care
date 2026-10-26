param([Parameter(Mandatory=$true)][string]$FixtureParent)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows-only isolated native smoke test' }
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/common.ps1')
$fixture = Join-Path ([IO.Path]::GetFullPath($FixtureParent)) ('native-' + [guid]::NewGuid().ToString('N'))
if (-not (Test-Path -LiteralPath $FixtureParent -PathType Container)) { throw 'FixtureParent must already exist' }
$tempRoot = Join-Path $fixture 'Temp'
[void][IO.Directory]::CreateDirectory($tempRoot)
$ctx = Get-CleanerContext
$ctx.Variables.LOCALAPPDATA = $fixture
$ctx.LogPath = Join-Path $fixture 'audit.jsonl'
$old = Join-Path $tempRoot 'old.tmp'; $recent = Join-Path $tempRoot 'recent.tmp'; $readOnly = Join-Path $tempRoot 'readonly.tmp'
$empty = Join-Path $tempRoot 'empty'; $nested = Join-Path $tempRoot 'nested'
foreach ($file in @($old,$recent,$readOnly)) { [IO.File]::WriteAllText($file, 'isolated pc-care smoke fixture') }
foreach ($file in @($old,$readOnly)) { [IO.File]::SetLastWriteTimeUtc($file,[datetime]::UtcNow.AddDays(-3)) }
[IO.File]::SetAttributes($readOnly,[IO.FileAttributes]::ReadOnly)
[void][IO.Directory]::CreateDirectory($empty); [void][IO.Directory]::CreateDirectory($nested)
$nestedFile = Join-Path $nested 'old.tmp'
[IO.File]::WriteAllText($nestedFile,'isolated nested fixture')
[IO.File]::SetLastWriteTimeUtc($nestedFile,[datetime]::UtcNow.AddDays(-3))
$outsideDir = Join-Path $fixture 'outside-directory'
[void][IO.Directory]::CreateDirectory($outsideDir)
$linkTarget = Join-Path $outsideDir 'old.tmp'
[IO.File]::WriteAllText($linkTarget,'junction target must remain')
[IO.File]::SetLastWriteTimeUtc($linkTarget,[datetime]::UtcNow.AddDays(-3))
$junction = Join-Path $tempRoot 'linked-directory'
New-Item -ItemType Junction -Path $junction -Target $outsideDir -ErrorAction Stop | Out-Null
$expired = Remove-SafeItem $tempRoot UserTemp -Context $ctx -DeadlineUtc ([datetime]::UtcNow.AddSeconds(-1)) -Confirm:$false
if ($expired.DeletedCount -ne 0 -or -not [IO.File]::Exists($old)) { throw 'expired budget mutated the fixture' }
$result = Remove-SafeItem $tempRoot UserTemp -Context $ctx -Confirm:$false
if ([IO.File]::Exists($old) -or [IO.File]::Exists($nestedFile)) { throw ('old test files not removed: ' + ($result.SkippedItems | ConvertTo-Json -Compress)) }
if ([IO.Directory]::Exists($empty) -or [IO.Directory]::Exists($nested)) { throw 'empty child directories not removed' }
if (-not [IO.Directory]::Exists($tempRoot) -or -not [IO.File]::Exists($recent) -or -not [IO.File]::Exists($readOnly)) { throw 'root/recent/readonly protection failed' }
if (-not [IO.File]::Exists($linkTarget)) { throw 'junction target was followed' }
if ($result.IsComplete -or $result.SkippedCount -lt 2) { throw 'skipped files not reported' }
$outside = Join-Path $fixture 'outside.tmp'; [IO.File]::WriteAllText($outside,'must remain')
[IO.File]::SetLastWriteTimeUtc($outside,[datetime]::UtcNow.AddDays(-3))
$refused = Remove-SafeItem $outside UserTemp -Context $ctx -Confirm:$false
if (-not [IO.File]::Exists($outside) -or $refused.DeletedCount -ne 0) { throw 'outside whitelist accepted' }
$budgetRoot = Join-Path $tempRoot 'budget-sample'
[void][IO.Directory]::CreateDirectory($budgetRoot)
1..50 | ForEach-Object {
    $sample = Join-Path $budgetRoot ('sample-' + $_ + '.tmp')
    [IO.File]::WriteAllText($sample,'budget test file')
    [IO.File]::SetLastWriteTimeUtc($sample,[datetime]::UtcNow.AddDays(-3))
}
$bounded = Remove-SafeItem $budgetRoot UserTemp -Context $ctx -DeadlineUtc ([datetime]::UtcNow.AddMilliseconds(300)) -Confirm:$false
$remaining = @([IO.Directory]::GetFiles($budgetRoot)).Count
if ($bounded.IsComplete -or $remaining -eq 0 -or ($bounded.DeletedCount + $remaining) -ne 50) { throw 'in-progress budget stop lost accounting' }
if (-not ($bounded.SkippedItems.Reason -match '时间预算')) { throw 'budget stop reason missing' }
$script:CleanerContext = $null
$ctx2 = Get-CleanerContext
if (-not $ctx2.LogPath.StartsWith($ctx2.OriginalUserProfile + '\.pc-care\Logs\')) { throw 'default log depends on client' }
Write-CleanerLog -Action SelfTest -Path $fixture -Result Passed -Context $ctx2 -Confirm:$false
if (-not (Test-Path -LiteralPath $ctx2.LogPath -PathType Leaf)) { throw 'client-independent log could not be written' }
Write-Host ('PASS native smoke: expired/in-progress budget, old-file deletion, empty children, retained root, recent/readonly/outside/junction protection; fixture ' + $fixture)
