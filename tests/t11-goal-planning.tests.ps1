Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/partition.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
foreach ($definition in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:checks = 0
function Check { param([bool]$Value, [string]$Message); $script:checks++; if (-not $Value) { throw $Message } }
function Item { param([string]$Id, [long]$Bytes, [bool]$Lower = $false); return @{ Id = $Id; Bytes = $Bytes; IsLowerBound = $Lower } }
function Volume { param([string]$Letter, [long]$Size); return @{ DriveLetter = $Letter; Size = $Size } }
$a = Get-PcCapacityAssessment 500GB 430GB 100GB
Check ($a.PolicyUsableBytes -eq 10GB -and $a.LimitingFactor -eq 'ReservePolicy') 'Policy limit must be distinct from technical limit'
$a = Get-PcCapacityAssessment 500GB 100GB 10GB
Check ($a.LimitingFactor -eq 'WindowsShrinkLimit') 'Windows limit must be explicit'
$a = Get-PcCapacityAssessment 500GB 100GB $null
Check ($a.LimitingFactor -eq 'WindowsLimitUnknown' -and $null -eq $a.WindowsMaxShrinkBytes) 'Unknown is not zero'
$a = Get-PcCapacityAssessment 500GB $null 10GB
Check ($null -eq $a.PolicyUsableBytes -and $a.LimitingFactor -eq 'Unknown') 'Unknown used space remains unknown'
$a = Get-PcCapacityAssessment 100GB 95GB 10GB
Check ($a.PolicyUsableBytes -eq 0) 'Reserve deficit must not become negative capacity'
$downloads = Item 'move:KnownFolder:Downloads' 10GB
$desktop = Item 'move:KnownFolder:Desktop' 40GB
$a = Get-PcMigrationAssessment @($downloads) @((Volume 'D' 11GB))
Check ($a.Status -eq 'Full' -and $a.RequiredBytes -eq 11GB) 'Exact 10 percent boundary fits'
Check (-not $a.CountsFutureSourceRelease) 'Future source release must not increase capacity'
$a = Get-PcMigrationAssessment @($downloads) @((Volume 'D' (11GB - 1)))
Check ($a.Status -eq 'NoFit' -and $a.ShortfallBytes -eq 1) 'One byte deficit is rejected'
$a = Get-PcMigrationAssessment @($downloads, $desktop) @((Volume 'D' 20GB))
Check ($a.Status -eq 'Partial' -and $a.Assignments[0].Id -eq $downloads.Id -and $a.RemainingIds[0] -eq $desktop.Id) 'Only complete fitting projects are offered'
$a = Get-PcMigrationAssessment @($desktop) @((Volume 'D' 25GB), (Volume 'E' 25GB))
Check ($a.Status -eq 'NoFit' -and $a.ShortfallBytes -eq 0) 'Aggregate capacity cannot split an indivisible folder'
$a = Get-PcMigrationAssessment @($downloads, $downloads) @((Volume 'D' 50GB))
Check ($a.Status -eq 'SizeUnknown') 'Duplicate items must not produce a plan'
$a = Get-PcMigrationAssessment @((Item 'move:KnownFolder:Desktop' 10GB $true)) @((Volume 'D' 50GB))
Check ($a.Status -eq 'SizeUnknown') 'Lower bound cannot certify fit'
$a = Get-PcMigrationAssessment @(@{ Id = 'move:KnownFolder:Desktop'; Bytes = 10GB }) @((Volume 'D' 50GB))
Check ($a.Status -eq 'SizeUnknown') 'Missing measurement reliability is unknown'
$a = Get-PcMigrationAssessment @((Item 'arbitrary:path' 10GB)) @((Volume 'D' 50GB))
Check ($a.Status -eq 'SizeUnknown') 'Arbitrary paths are not migration targets'
$a = Get-PcMigrationAssessment @($downloads) @()
Check ($a.Status -eq 'NoDestination' -and $a.Assignments.Count -eq 0) 'No partition means no destination'
$a = Get-PcMigrationAssessment @() @((Volume 'D' 50GB))
Check ($a.Status -eq 'NoTargets') 'No selected targets means no fit claim'
$a = Get-PcMigrationAssessment @((Item 'move:KnownFolder:Downloads' ([long]::MaxValue))) @((Volume 'D' 50GB))
Check ($a.Status -eq 'SizeUnknown') 'Overflow must not produce a fitting project'
$a = Get-PcMigrationAssessment @($downloads, (Item 'move:KnownFolder:Videos' 10GB)) @((Volume 'D' 11GB))
Check ($a.Status -eq 'Partial' -and $a.RequiredBytes -eq 22GB -and $a.Assignments.Count -eq 1) 'Copies accumulate until source release; no double spending'
$a = Get-PcMigrationAssessment @($downloads, $desktop) @((Volume 'D' 11GB), (Volume 'E' 44GB))
Check ($a.Status -eq 'Full' -and $a.Assignments.Count -eq 2) 'Multiple partitions permit full assignment when each folder fits'
Write-Output "PASS t11-goal-planning: $script:checks checks; AST functions only; no disk operations."
