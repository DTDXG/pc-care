Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$script:definitions=@{};$script:assertions=0
function Import-T6Functions {
    param([string]$Path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors.Message -join ';')}
    foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
        $script:definitions[$node.Name]=$node.Extent.Text
        . ([scriptblock]::Create($node.Extent.Text))
        Set-Item ('Function:script:'+$node.Name) (Get-Item ('Function:'+$node.Name)).ScriptBlock
    }
}
foreach($file in @('common.ps1','migrate.ps1','move.ps1')){Import-T6Functions (Join-Path $repo ('scripts/'+$file))}
function Restore-T6 {param([string[]]$Names) foreach($name in $Names){. ([scriptblock]::Create($script:definitions[$name]));Set-Item ('Function:script:'+$name) (Get-Item ('Function:'+$name)).ScriptBlock}}
function Assert-T6 {param([bool]$Condition,[string]$Message) $script:assertions++;if(-not $Condition){throw ('FAIL: '+$Message)}}
function Assert-ThrowsT6 {param([scriptblock]$Action,[string]$Message) $thrown=$false;try{$null=& $Action}catch{$thrown=$true};Assert-T6 $thrown $Message}
$script:CleanerTargets=Import-PowerShellDataFile (Join-Path $repo 'scripts/targets.psd1')
$script:MigrationSid='S-test';$script:MigrationProfile='C:\Users\me';$script:MoveDocument=[pscustomobject]@{Entries=@()}
$script:MigrationContext=[pscustomobject]@{
    OriginalUserSid='S-test';CurrentUserSid='S-test';OriginalUserProfile='C:\Users\me';OriginalUserVerified=$true
    SystemDrive='C:';SystemRoot='C:\Windows';SyncRoots=@();ProtectedMachineRoots=@('C:\Program Files');LogPath='C:\Users\me\AppData\Local\CDriveCleaner\Logs\audit.jsonl'
    Variables=@{USERPROFILE='C:\Users\me';APPDATA='C:\Users\me\AppData\Roaming';LOCALAPPDATA='C:\Users\me\AppData\Local';ProgramData='C:\ProgramData';SystemRoot='C:\Windows';SystemDrive='C:';ProgramFiles='C:\Program Files';'ProgramFiles(x86)'='C:\Program Files (x86)';ProgramW6432='C:\Program Files'}
}
function New-T6Facts {return @{AlreadyMoved=$false;OneDrive=$false;RunningApps=@();IsFixed=$true;IsLocal=$true;FileSystem='NTFS';SystemVolume=$false;Forbidden=$false;NonEmpty=$false;Resume=$false;Bytes=[long]1000;FreeBytes=[long]1100}}
function New-T6Inventory {
    param([int]$Count=1)
    $files=@{};for($i=0;$i -lt $Count;$i++){$files[('文件'+$i+'.db')]=[pscustomobject]@{Length=[long]10;WriteTicks=[long]100;Hash='';FileId=('id'+$i)}}
    return [pscustomobject]@{Files=$files;Directories=@{};Links=@{};ForeignLinks=@{};Excluded=@();FileCount=[long]$Count;Bytes=[long]($Count*10)}
}
function New-T6Record {param([string]$Kind='KnownFolder') $r=New-MoveRecord $Kind 'Documents' 'C:\Users\me\Documents' 'D:\资料\文档' @('WeChat') $false 'root';$r.InventorySha256=('A'*64);$r.ActiveAt=[datetimeoffset]::new([datetime]::new(50),[timespan]::Zero).ToString('o');return $r}
function Open-CleanerParentGuards {param([string]$LiteralPath) [pscustomobject]@{Handles=@()}}
function Test-CleanerPathChain {param([string]$LiteralPath,[switch]$AllowMissing) [pscustomobject]@{IsSafe=$true;Path=$LiteralPath;Exists=$true;Attributes=[IO.FileAttributes]::Directory;ExistingParent='C:\Users\me'}}

# Preflight: every condition has a failing case and the exact 10% boundary.
$f=New-T6Facts;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Done') '10% exact boundary accepted'
foreach($key in @('IsFixed','IsLocal')){$f=New-T6Facts;$f[$key]=$false;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Failed') $key}
foreach($key in @('SystemVolume','Forbidden','NonEmpty','OneDrive')){$f=New-T6Facts;$f[$key]=$true;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Failed') $key}
$f=New-T6Facts;$f.FileSystem='exFAT';Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Failed') 'non NTFS rejected'
$f=New-T6Facts;$f.FreeBytes=1099;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'NotEnoughSpace') '10% margin enforced'
$f=New-T6Facts;$f.AlreadyMoved=$true;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'AlreadyMoved') 'already moved'
$f=New-T6Facts;$f.NonEmpty=$true;$f.Resume=$true;Assert-T6 ((Get-MovePreflightDecision $f).Status -eq 'Done') 'P3 resume accepts nonempty only via resume'
$f=New-T6Facts;$f.RunningApps=@('微信');$decision=Get-MovePreflightDecision $f;Assert-T6 ($decision.Status -eq 'NeedsAppExit' -and $decision.Reason.Contains('微信')) 'running app in Chinese'
foreach($name in @('WeChat.exe','Weixin','WeChatAppEx.exe','QQ.exe','QQNT')){$apps=@(Get-MoveRunningApps @('WeChat','QQ') @($name));Assert-T6 ($apps.Count -eq 1) ('process '+$name)}
Assert-T6 (@(Get-MoveRunningApps @('WeChat') @('notepad')).Count -eq 0) 'unrelated process allowed'

# Detection is the same bounded configuration convention as v1/checkup, with a fake FS.
$folders=@{Documents='C:\Users\me\Documents'}
$fakeRoots=@('C:\Users\me\Documents\WeChat Files','C:\Users\me\Documents\xwechat_files','C:\Users\me\Documents\Tencent Files','C:\Chat\WeChat Files','C:\Chat\xwechat_files','C:\CustomQQ')
$exists={param($p) $p -in $fakeRoots}
$reg={param($k,$n) if($n -eq 'FileSavePath'){'C:\Chat'};if($n -eq 'DataPath'){'C:\CustomQQ'}}
$markers={param($p) if($p -eq 'C:\CustomQQ'){[pscustomobject]@{Name='nt_qq';Attributes=[IO.FileAttributes]::Directory}}}
$roots=@(Get-CleanerChatRoots $script:MigrationContext $folders $reg {param($p) ''} $exists -MarkerChildren $markers)
Assert-T6 ($roots.Count -eq 6) 'detect old/new WeChat, QQ and configured roots'
foreach($path in $fakeRoots){Assert-T6 ($path -in $roots.Path) ('detected '+$path)}
$roots=@(Get-CleanerChatRoots $script:MigrationContext $folders {param($k,$n) ''} {param($p) if($p -like '*xwechat*'){'{"settings":{"data_dir":"C:\\Custom微信"}}'}} {param($p) $p -eq 'C:\Custom微信'} -MarkerChildren {param($p) [pscustomobject]@{Name='All Users';Attributes=[IO.FileAttributes]::Directory}})
Assert-T6 ($roots.Count -eq 1 -and $roots[0].Path -eq 'C:\Custom微信') 'JSON exact custom root needs direct app marker'
Assert-T6 (@(Resolve-CleanerChatPaths 'C:\Chat\xwechat_files' @('WeChat Files','xwechat_files') $true).Count -eq 1) 'no double suffix'
Assert-T6 (@(ConvertFrom-CleanerChatConfig "C:\Chat`r`nMyDocument:" Text).Count -eq 1) 'text configuration rejects marker'
$roots=@(Get-CleanerChatRoots $script:MigrationContext $folders {param($k,$n) 'C:\Users\me\Documents'} {param($p) ''} {param($p) $true})
Assert-T6 (@($roots | Where-Object {$_.Path -eq $folders.Documents}).Count -eq 0) 'custom setting cannot authorize all Documents'
$roots=@(Get-CleanerChatRoots $script:MigrationContext $folders {param($k,$n) 'C:\Windows'} {param($p) ''} {param($p) $true})
Assert-T6 (@($roots | Where-Object {$_.Path -like 'C:\Windows*'}).Count -eq 0) 'forbidden custom config rejected'

# Exact new whitelist roots; old cache-only Junction category still derives only DevCache.
function Get-CleanerKnownFolderMap {param($Context) return @{Documents='C:\Users\me\Documents';Desktop='C:\Users\me\Desktop'}}
function Get-CleanerChatRoots {param($Context,[switch]$IncludeMissing,$KnownFolders,$Issues) @([pscustomobject]@{App='WeChat';Path='C:\Users\me\Documents\WeChat Files'},[pscustomobject]@{App='WeChat';Path='C:\Users\me\Documents\xwechat_files'},[pscustomobject]@{App='QQ';Path='C:\Users\me\Documents\Tencent Files'})}
foreach($category in @('MoveChat','MoveChatBackup','MoveChatParent')) {
    $def=$script:CleanerTargets.Categories[$category]
    Assert-T6 ($def.ExternalOnly -and $def.MigrationOnly) ($category+' cannot delete')
    $targets=@(Get-CleanerMigrationTarget $def $script:MigrationContext)
    Assert-T6 ($targets.Count -eq 3) ($category+' exact derived roots')
    Assert-ThrowsT6 {Assert-CleanerDeletionCategory $category} ($category+' deletion guard')
}
$chatTargets=@(Get-CleanerMigrationTarget $script:CleanerTargets.Categories.MoveChat $script:MigrationContext)
Assert-T6 (@($chatTargets | Where-Object {$_.Path -in @('C:\Users\me\Documents','C:\Users\me\AppData')}).Count -eq 0) 'no broad data root'
$cacheTargets=@(Get-CleanerMigrationTarget $script:CleanerTargets.Categories.Junction $script:MigrationContext)
Assert-T6 (@($cacheTargets | Where-Object {$_.Path -like '*WeChat*' -or $_.Path -like '*Tencent Files*'}).Count -eq 0) 'cache junction whitelist unchanged'
$auditTargets=@(Get-CleanerMigrationTarget $script:CleanerTargets.Categories.MigrationManifest $script:MigrationContext)
Assert-T6 (@($auditTargets | Where-Object {$_.Path -like '*move-inventory-' -and $_.SuffixRegex -match 'tsv' -and $_.Scope -eq 'File'}).Count -eq 1) 'P2 inventory sidecar whitelist exact audit directory'

# P4a: chat root containment; require exit before copy and before switch.
$chats=@([pscustomobject]@{App='WeChat';Path='C:\Users\me\Documents\WeChat Files'},[pscustomobject]@{App='QQ';Path='C:\Users\me\Documents\Tencent Files'},[pscustomobject]@{App='QQ';Path='C:\Users\me\DocumentsOther\Tencent Files'})
$included=@(Get-MoveIncludedChats 'C:\Users\me\Documents' $chats)
Assert-T6 ($included.Count -eq 2 -and 'WeChat' -in $included -and 'QQ' -in $included) 'P4a included chat data with path boundary'
$script:runningNames=@('WeChatAppEx')
function Get-Process {param($ErrorAction) foreach($p in $script:runningNames){[pscustomobject]@{ProcessName=$p}}}
$r=New-T6Record;Assert-ThrowsT6 {Assert-MoveAppsClosed $r} 'P4a Documents refuses running included chat'
$script:mutations=0
function Set-MoveKnownFolder {$script:mutations++}
function Set-MoveState {$script:mutations++}
Assert-ThrowsT6 {Invoke-MoveSwitch $r (New-T6Inventory) 'fake' @{}} 'P4a second process gate before switching'
Assert-T6 ($script:mutations -eq 0) 'P4a running process gate has no side effects'
$script:runningNames=@()

# P4b: old chat root is retained inside active Documents; orchestration returns AlreadyMoved.
$r.State='Active';$old=Find-MoveContainingRecord 'C:\Users\me\Documents\WeChat Files' @($r)
Assert-T6 ($old.Id -eq $r.Id) 'P4b retained chat is part of Documents move'
Assert-T6 ($null -eq (Find-MoveContainingRecord 'C:\Users\me\Documents2\WeChat Files' @($r))) 'P4b sibling not covered'
function Assert-MoveRecord {param($Record,[switch]$ForRollback)}
function Read-MoveInventory {param($Manifest,$Record) New-T6Inventory}
function Assert-MoveActive {param($Record,$Baseline,[switch]$Inventory,[switch]$AllowRunning)}
$doc=[pscustomobject]@{Entries=@($r)}
$oldResult=Invoke-MoveNew WeChat '' 'D:\Chat' 'fake' $doc $false
Assert-T6 ($oldResult.Status -eq 'AlreadyMoved' -and $oldResult.Id -eq $r.Id) 'P4b no separate chat move from retained Documents'

# P4c: /XJ agrees with inventory. No traversal or identity access through skipped links.
$script:visited=[Collections.Generic.List[string]]::new();$script:identities=0;$script:verifiedLinks=0
function Get-MigrationVerifiedJunction {param($Path,$Target) $script:verifiedLinks++;return $true}
$enumerate={param($p)
    $script:visited.Add($p)
    if($p -eq 'C:\src') {
        [pscustomobject]@{FullName='C:\src\WeChat Files';Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)}
        [pscustomobject]@{FullName='C:\src\normal.db';Attributes=[IO.FileAttributes]::Normal;Length=[long]10;LastWriteTimeUtc=[datetime]::new(100)}
        [pscustomobject]@{FullName='C:\src\WeChat Files.cdrive-retained-a';Attributes=[IO.FileAttributes]::Directory}
    }else{throw 'must not enumerate link or excluded retained chat'}
}
$identity={param($p) $script:identities++;[pscustomobject]@{IsDirectory=$false;FileId='file';LogicalBytes=[long]10;LastWriteTimeUtc=[datetime]::new(100)}}
$tree=Get-MoveInventory 'C:\src' -AllowedLinks @{'WeChat Files'='D:\Chat'} -Excluded @('WeChat Files.cdrive-retained-a') -Enumerate $enumerate -Identity $identity -Guard {param($p) [pscustomobject]@{Handles=@()}}
Assert-T6 ($script:visited.Count -eq 1 -and $script:identities -eq 0 -and $tree.FileCount -eq 1) 'P4c no link/retained data traversal'
Assert-T6 ($tree.Links['WeChat Files'] -eq 'D:\Chat' -and $script:verifiedLinks -eq 1) 'P4c verified skipped link recorded'
# Foreign links are now recorded and skipped (R2 below).
$target=New-T6Inventory 0;$target.Files=$tree.Files;$target.FileCount=1;$target.Bytes=10
Assert-MoveInventoryMatch $tree $target -AllowMissingLinks
Assert-ThrowsT6 {Assert-MoveInventoryMatch $tree $target} 'P4c active target must have restored link'

# P2: immutable, authenticated, non-JSON sidecar round trip including Chinese names, dirs, links.
Restore-T6 @('Read-MoveInventory','Assert-MoveRecord','Set-MoveState')
$baseline=New-T6Inventory 5000;$baseline.Directories['空目录']='dir-id';$baseline.Links['聊天']='D:\Chat';$baseline.Excluded=@('旧聊天副本')
$lines=@(ConvertTo-MoveInventoryLines $baseline)
$converted=ConvertFrom-MoveInventoryLines $lines
Assert-T6 ($converted.FileCount -eq 5000 -and $converted.Bytes -eq 50000 -and $converted.Directories['空目录'] -eq 'dir-id' -and $converted.Links['聊天'] -eq 'D:\Chat') 'P2 line-based round trip'
Assert-ThrowsT6 {ConvertFrom-MoveInventoryLines @("F`tLi5cZXNjYXBl`t1`t2`t`tid")} 'P2 sidecar refuses path escape'
Assert-ThrowsT6 {ConvertFrom-MoveInventoryLines @($lines[0],$lines[0])} 'P2 duplicate inventory record rejected'
function Assert-MigrationTarget {param([string]$Path,[string]$Category)}
$testDir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testDir)
try {
    $r=New-T6Record;$manifest=Join-Path $testDir 'moves.json'
    Write-MoveInventory $manifest $r $baseline
    $path=Join-Path $testDir $r.InventoryFile
    Assert-T6 ([IO.File]::Exists($path) -and $r.EntryCount -eq 5003) 'P2 metadata covers every inventory row'
    $read=Read-MoveInventory $manifest $r
    Assert-T6 ($read.FileCount -eq 5000 -and $read.Bytes -eq 50000) 'P2 SHA-verified read'
    Assert-ThrowsT6 {Write-MoveInventory $manifest $r $baseline} 'P2 sidecar never overwritten'
    $json=ConvertTo-Json -InputObject $r -Depth 8
    $r.EntryCount=1;$r.TotalBytes=10;$small=ConvertTo-Json -InputObject $r -Depth 8
    Assert-T6 ([math]::Abs($json.Length-$small.Length) -lt 30 -and $json.Length -lt 2000 -and $json -notmatch '文件4999') 'P2 manifest size independent of inventory count'
    [IO.File]::AppendAllText($path,"tampered`n")
    Assert-ThrowsT6 {Read-MoveInventory $manifest $r} 'P2 modified sidecar digest rejected before conversion'
}
finally {foreach($p in [IO.Directory]::EnumerateFiles($testDir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($testDir)}

# P3: only recorded entries may exist in resumed target; changed/missing files can be recopied.
$b=New-T6Inventory 3;$partial=New-T6Inventory 1;$partial.Files['文件0.db'].Length=2
Assert-MoveDestinationSubset $b $partial
Assert-T6 $true 'P3 partial changed file accepted for recopy'
$partial.Files['foreign.db']=$partial.Files['文件0.db'];Assert-ThrowsT6 {Assert-MoveDestinationSubset $b $partial} 'P3 foreign file blocks resume'
$partial=New-T6Inventory 0;$partial.Directories['foreign']=$true;Assert-ThrowsT6 {Assert-MoveDestinationSubset $b $partial} 'P3 foreign directory blocks resume'
$partial=New-T6Inventory 0;$partial.Links['foreign']='D:\other';Assert-ThrowsT6 {Assert-MoveDestinationSubset $b $partial} 'P3 foreign link blocks resume'

# Stage journal, rollback plan, active guard. Cache field retains migrate manifest compatibility.
$script:journal=[Collections.Generic.List[string]]::new()
function Write-MigrationManifest {param($Path,$Document) $script:journal.Add($Document.Entries[0].State)}
$r=New-T6Record;$document=[pscustomobject]@{Entries=@($r)}
foreach($state in @('Copying','Copied','Verified','Switching','Active')){Set-MoveState $r $state 'fake' $document}
Assert-T6 (($script:journal -join ',') -eq 'Copying,Copied,Verified,Switching,Active' -and $r.Steps.Count -eq 5) 'each transition recorded in order'
Assert-T6 ((Get-MoveRollbackPlan $r) -contains 'RestoreKnownFolder') 'known-folder rollback plan'
$app=New-T6Record WeChat
Assert-T6 ((Get-MoveRollbackPlan $app) -contains 'RemoveVerifiedJunction' -and (Get-MoveRollbackPlan $app) -contains 'KeepDestination') 'app rollback removes only link and keeps destination'
$r.State='Releasing';Assert-ThrowsT6 {Get-MoveRollbackPlan $r} 'partial release cannot claim full rollback'
$r.State='Copying';Assert-ThrowsT6 {Invoke-MoveRelease $r (New-T6Inventory) 'fake' $document} 'release refuses before verified active'
Restore-T6 @('Assert-MoveActive')
$r.State='Active'
Assert-ThrowsT6 {Assert-MoveActive $r (New-T6Inventory)} 'release refuses inactive known folder path'

# A Windows-native fake lets the performance test run the real per-file deletion helper.
class T6MoveNative {
    static [string] $Path
    static [int] $Deletes
    static [uint32] $Share
    static [uint32] $Flags
    static [Microsoft.Win32.SafeHandles.SafeFileHandle] CreateFileW([string]$path,[uint32]$access,[uint32]$share,[IntPtr]$security,[uint32]$mode,[uint32]$flags,[IntPtr]$template) {
        [T6MoveNative]::Path=$path;[T6MoveNative]::Share=$share;[T6MoveNative]::Flags=$flags
        return [Microsoft.Win32.SafeHandles.SafeFileHandle]::new([IntPtr]4242,$false)
    }
    static [bool] SetFileInformationByHandle([Microsoft.Win32.SafeHandles.SafeFileHandle]$handle,[int]$kind,[IntPtr]$memory,[uint32]$size) {
        [T6MoveNative]::Deletes++
        return $true
    }
}
function Get-CleanerNativeType {return [T6MoveNative]}
function Get-CleanerFinalHandlePath {param($Handle) return [T6MoveNative]::Path}
function Get-CleanerHandleMetadata {
    param($Handle)
    $path=[T6MoveNative]::Path;$id='root';$directory=$true
    if($path -match '文件(\d+)\.db$'){$id='id'+$matches[1];$directory=$false}
    return [pscustomobject]@{FileId=$id;IsDirectory=$directory;LogicalBytes=[long]10;LastWriteTimeUtc=[datetime]::new(100)}
}
Restore-T6 @('Remove-MoveRetainedLeaf')

function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) $f=New-T6Facts;$f.Bytes=$Bytes;$f.FreeBytes=100000;return $f}

# P1: full release orchestration, 5000 files. Record validation/conversion each exactly once.
$script:counts=@{Validate=0;Convert=0;Read=0;Active=0;Delete=0;Inventory=0}
$script:large=New-T6Inventory 5000;$script:largeLines=@(ConvertTo-MoveInventoryLines $script:large)
$script:convertDefinition=$script:definitions['ConvertFrom-MoveInventoryLines']
function Assert-MoveRecord {param($Record,[switch]$ForRollback) $script:counts.Validate++}
function Read-MoveInventory {
    param($Manifest,$Record)
    $script:counts.Read++
    . ([scriptblock]::Create($script:convertDefinition))
    $script:counts.Convert++;ConvertFrom-MoveInventoryLines $script:largeLines
}
function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks,$Excluded) $script:counts.Inventory++;return $script:large}
function Assert-MoveActive {param($Record,$Baseline,[switch]$Inventory,[switch]$AllowRunning) $script:counts.Active++}
function Get-MoveEntryIdentity {param($Path) [pscustomobject]@{FileId='root'}}
function Get-MigrationExistingEntry {param($Path) [pscustomobject]@{FullName=$Path;Attributes=[IO.FileAttributes]::Normal}}
$r=New-T6Record;$r.State='Active';$document=[pscustomobject]@{Entries=@($r)}
$result=Invoke-MoveRecord $r 'fake' $document Release
Assert-T6 ($result.Status -eq 'Done' -and $r.State -eq 'Released') 'release completes fake operation'
Assert-T6 ($script:counts.Validate -eq 1 -and $script:counts.Convert -eq 1 -and $script:counts.Read -eq 1) 'P1 record/inventory work constant for 5000 files'
Assert-T6 ($script:counts.Active -ge 8 -and $script:counts.Active -le 12 -and $script:counts.Inventory -eq 1) 'P1 active checks batched; no whole-inventory revalidation per file'
Assert-T6 ([T6MoveNative]::Deletes -eq 5001) 'P1 each file plus root handled once'
# The same real helper refuses a substituted identity, length/time change or wrong final path.
$beforeDeletes=[T6MoveNative]::Deletes
Assert-ThrowsT6 {Remove-MoveRetainedLeaf 'C:\Users\me\Documents\文件0.db' @{FileId='different';Length=10;WriteTicks=100} $false $false} 'per-file identity substitution refuses delete'
Assert-ThrowsT6 {Remove-MoveRetainedLeaf 'C:\Users\me\Documents\文件0.db' @{FileId='id0';Length=11;WriteTicks=100} $false $false} 'per-file size change refuses delete'
Assert-ThrowsT6 {Remove-MoveRetainedLeaf 'C:\Users\me\Documents\文件0.db' @{FileId='id0';Length=10;WriteTicks=101} $false $false} 'per-file timestamp change refuses delete'
Assert-T6 ([T6MoveNative]::Deletes -eq $beforeDeletes) 'failed per-file guard never marks deletion'
function Remove-MoveRetainedLeaf {param($Path,$Expected,$Directory,$Hash,$Checkpoint) $script:counts.Delete++}
# P1 wall-clock safety check even when fewer than 1000 entries processed.
$script:now=[datetime]::new(2026,1,1);$script:activeCalls=0
Invoke-MoveReleaseLoop $r (New-T6Inventory 3) {param($r,$b) $script:activeCalls++} {} { $script:now=$script:now.AddSeconds(31);$script:now }
Assert-T6 ($script:activeCalls -eq 5) 'P1 30-second active guard and final check'

# P3 actual Copying orchestration with fake Windows boundaries, including a killed copy.
$script:copyCalls=0;$script:switchCalls=0;$script:crash=$true
function Invoke-MoveCopy {param($Record,$Baseline,[switch]$Resume) $script:copyCalls++;if($script:crash){throw '模拟中断'}}
function New-MigrationDirectory {param($Path) $script:mutations++;return $true}
function Invoke-MoveSwitch {param($Record,$Baseline,$Manifest,$Document) $script:switchCalls++;Set-MoveState $Record Active $Manifest $Document}
$r=New-T6Record;$r.State='Copying';$document=[pscustomobject]@{Entries=@($r)}
Assert-ThrowsT6 {Invoke-MoveRecord $r fake $document Move} 'P3 interrupted copy returns without switch'
Assert-T6 ($r.State -eq 'Copying' -and $script:switchCalls -eq 0) 'P3 Copying persists after interruption'
$script:crash=$false;$result=Invoke-MoveRecord $r fake $document Move
Assert-T6 ($result.Status -eq 'Done' -and $script:copyCalls -eq 2 -and $script:switchCalls -eq 1) 'P3 resume reaches switch after verify'
Assert-T6 ($result.ResumeHint -match 'ResumeId' -and $result.Schema -eq 'pc-care/move/1') 'P3 result gives safe resume guidance'
$r.State='Copied';$script:copyCalls=0;$null=Invoke-MoveRecord $r fake $document Move
Assert-T6 ($script:copyCalls -eq 0) 'P3 interrupted verification resumes without repeating copy'

# WhatIf through actual orchestration: zero write, external-tool, log or delete calls.
$script:mutations=0
function Read-MoveInventory {throw 'WhatIf must not read/conversion inventory for release'}
function Write-MigrationManifest {$script:mutations++}
function Invoke-External {$script:mutations++}
function Invoke-MoveCopy {$script:mutations++}
function New-MigrationDirectory {$script:mutations++}
function Invoke-MoveRelease {$script:mutations++}
function Invoke-MoveRollback {$script:mutations++}
$WhatIfPreference=$true
foreach($operation in @('Move','Release','Rollback')){
    $r=New-T6Record;$result=Invoke-MoveRecord $r fake @{Entries=@($r)} $operation
    Assert-T6 ($result.StoppedAt -eq 'WhatIf') ('WhatIf '+$operation)
}
Assert-T6 ($script:mutations -eq 0) 'WhatIf no writes, external tools, release or rollback'
$WhatIfPreference=$false

# Actual copy adapter: verify resumable robocopy arguments, progress callbacks and foreign-file refusal.
Restore-T6 @('Invoke-MoveCopy','Assert-MoveAppsClosed','Get-MigrationExistingEntry','Set-MoveState')
$script:copyBaseline=New-T6Inventory 4;$script:copyActual=New-T6Inventory 1;$script:copyArgs=@();$script:externalCalls=0
function Get-CimInstance {param($ClassName,$Filter) return @()}
function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks,$Excluded) if($Path -eq 'C:\Users\me\Documents'){$script:copyBaseline}else{$script:copyActual}}
function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) $f=New-T6Facts;$f.Bytes=$Bytes;$f.FreeBytes=100000;$f.NonEmpty=$NonEmpty;$f.Resume=$Resume;return $f}
function Invoke-External {
    param($FilePath,$ArgumentList,$Description,$SuccessExitCodes,$OutputEncoding,$OutputLine,$ProgressCallback,$Confirm)
    $script:externalCalls++;$script:copyArgs=$ArgumentList
    if($OutputLine){$null=& $OutputLine '  新文件 10 C:\Users\me\Documents\文件1.db'}
    if($ProgressCallback){$null=& $ProgressCallback}
    [pscustomobject]@{ExitCode=1}
}
$r=New-T6Record
Invoke-MoveCopy $r $script:copyBaseline -Resume
Assert-T6 ($script:externalCalls -eq 1 -and '/XJ' -in $script:copyArgs -and '/E' -in $script:copyArgs) 'copy adapter runs resumable copy with /XJ'
Assert-T6 (@($script:copyArgs | Where-Object {$_ -in @('/MIR','/PURGE','/MOVE','/MOV')}).Count -eq 0) 'copy adapter never removes source/destination files'
$script:copyActual.Files['foreign.db']=$script:copyActual.Files['文件0.db']
Assert-ThrowsT6 {Invoke-MoveCopy $r $script:copyBaseline -Resume} 'P3 real copy adapter refuses foreign file before external tool'
Assert-T6 ($script:externalCalls -eq 1) 'P3 foreign file has no copy side effects'

# P4c actual known-folder switch recreates skipped link at destination and leaves old link intact.
Restore-T6 @('Invoke-MoveSwitch','Assert-MoveInventoryMatch')
$script:copyActual=New-T6Inventory 0
$script:created=[Collections.Generic.List[string]]::new();$script:activated=''
function Get-CleanerKnownFolderMap {param($Context) return @{Documents='C:\Users\me\Documents'}}
function Set-MoveKnownFolder {param($Name,$Path) $script:activated=$Path}
function New-MovePreservedJunction {param($Path,$Target) $script:created.Add($Path+' => '+$Target)}
function Get-MigrationExistingEntry {param($Path) return $null}
function Assert-MoveActive {param($Record,$Baseline,[switch]$Inventory,[switch]$AllowRunning)}
function Write-MigrationManifest {param($Path,$Document)}
$r=New-T6Record;$r.State='Verified';$inventory=New-T6Inventory 0;$inventory.Links['WeChat Files']='D:\Chat'
Invoke-MoveSwitch $r $inventory fake @{Entries=@($r)}
Assert-T6 ($script:activated -eq $r.Destination -and $script:created.Count -eq 1 -and $script:created[0].StartsWith('D:\资料\文档\WeChat Files')) 'P4c restored link uses new Documents path'
Assert-T6 ($r.State -eq 'Active') 'P4c switch only active after link restoration'

# Actual rollback adapters use exact retained name; no destination deletion callback is reached.
Restore-T6 @('Invoke-MoveRollback')
$script:renames=[Collections.Generic.List[string]]::new();$script:removedLinks=[Collections.Generic.List[string]]::new();$script:linkPresent=$true
function Get-MigrationExistingEntry {
    param($Path)
    if($Path -like '*.cdrive-retained-*'){return [pscustomobject]@{Attributes=[IO.FileAttributes]::Directory}}
    if($script:linkPresent){return [pscustomobject]@{Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)}}
    return $null
}
function Remove-MoveVerifiedJunction {param($Path,$Target) $script:removedLinks.Add($Path+' => '+$Target);$script:linkPresent=$false}
function Move-MoveDirectory {param($Source,$Target) $script:renames.Add($Source+' => '+$Target)}
$app=New-T6Record WeChat;$app.State='Active';$app.Source='C:\Users\me\Documents\WeChat Files';$app.RetainedSource=$app.Source+'.cdrive-retained-'+$app.Id
Invoke-MoveRollback $app (New-T6Inventory) fake @{Entries=@($app)}
Assert-T6 ($script:removedLinks.Count -eq 1 -and $script:removedLinks[0].StartsWith($app.Source)) 'app rollback only removes verified source junction'
Assert-T6 ($script:renames.Count -eq 1 -and $script:renames[0] -eq ($app.RetainedSource+' => '+$app.Source) -and $app.State -eq 'RolledBack') 'app rollback restores exact retained name'
$r=New-T6Record;$r.State='Active'
Invoke-MoveRollback $r (New-T6Inventory) fake @{Entries=@($r)}
Assert-T6 ($script:activated -eq $r.Source -and $r.State -eq 'RolledBack') 'known-folder rollback restores original API location'

# Install detection is read-only and does not invent data roots from installation paths.
$installs=@(Get-MoveAppInstallations $script:MigrationContext {param($h,$k,$n) if($k -match 'WeChat' -and $n -eq 'InstallPath'){'C:\Program Files\Tencent\WeChat'}})
Assert-T6 ($installs.Count -eq 2 -and $installs[0].Installed -eq $true -and $installs[0].InstallPaths.Count -eq 1 -and $null -eq $installs[1].Installed) 'installation detection reports unknown without false absence'
$plan=@(Get-MoveChatPlan @(@{Path='C:\a\WeChat Files'},@{Path='C:\b\xwechat_files'},@{Path='C:\a\WeChat Files'}) 'D:\Chat')
Assert-T6 ($plan.Count -eq 2 -and $plan[0].Destination -eq 'D:\Chat\WeChat Files' -and $plan[1].Destination -eq 'D:\Chat\xwechat_files') 'multi-layout plan covers both versions exactly once'
$plan=@(Get-MoveChatPlan @(@{Path='C:\a\data'},@{Path='C:\b\data'}) 'D:\Chat')
Assert-T6 ($plan[0].Destination -ne $plan[1].Destination) 'custom roots with same leaf have different targets'

# WhatIf new move goes through discovery/preflight, with every mutation faked and counted.
Restore-T6 @('Invoke-MoveNew')
$script:mutations=0
function Get-MigrationExistingEntry {param($Path) if($Path.StartsWith('C:')){[pscustomobject]@{Attributes=[IO.FileAttributes]::Directory;PSIsContainer=$true}}}
function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks,$Excluded) New-T6Inventory}
function Write-MoveInventory {$script:mutations++}
function Set-MoveState {$script:mutations++}
function Invoke-MoveRecord {$script:mutations++}
function Get-MoveAppInstallations {param($Context) @()}
function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) New-T6Facts}
$WhatIfPreference=$true
$result=Invoke-MoveNew KnownFolder Documents 'D:\new' fake @{Entries=@()} $false
Assert-T6 ($result.StoppedAt -eq 'WhatIf' -and $result.Preview -and $script:mutations -eq 0) 'WhatIf new move has no writes or external tools'
$WhatIfPreference=$false

# P3 rerunning the identical command selects its previous Copying record before discovering new paths.
$WhatIfPreference=$false;$script:resumed=''
function Invoke-MoveRecord {param($Record,$Manifest,$Document,$Operation) $script:resumed=$Record.Id;New-MoveResult Done Copying '' $Record}
$r=New-T6Record;$r.Folder='Documents';$r.State='Copying'
$null=Invoke-MoveNew KnownFolder Documents $r.Destination fake @{Entries=@($r)} $false
Assert-T6 ($script:resumed -eq $r.Id) 'P3 identical command resumes existing record'

# Real shared whitelist matching with fake handles; sidecar scope must not leak outside log directory.
Restore-T6 @('Assert-MoveRecord','Assert-MigrationTarget','Test-CleanerRetainedChat')
function Get-CleanerEntryMetadata {param($LiteralPath) [pscustomobject]@{IsDirectory=($LiteralPath -notmatch '\.(tsv|json)(?:\.|$)');LinkCount=1}}
foreach($path in @('C:\Users\me\AppData\Local\CDriveCleaner\Logs\move-inventory-'+('a'*32)+'.tsv')) {
    Assert-T6 ((Test-SafeTarget $path MigrationManifest $script:MigrationContext).IsSafe) 'P2 sidecar accepted by actual MigrationManifest matching'
}
foreach($path in @('C:\Users\me\AppData\Local\pc-care\move-inventory-a.tsv','C:\Users\me\AppData\Local\CDriveCleaner\Logs\other.tsv','C:\Users\me\Documents')) {
    Assert-T6 (-not (Test-SafeTarget $path MigrationManifest $script:MigrationContext).IsSafe) 'P2 non-sidecar/outside log rejected'
}
foreach($path in @('C:\Users\me\Documents','C:\Users\me\AppData','C:\Users\me\Documents\OtherApp')) {
    Assert-T6 (-not (Test-SafeTarget $path MoveChat $script:MigrationContext).IsSafe) 'exact chat whitelist refuses broad and unrelated root'
}
function Test-CleanerPathChain {param($LiteralPath,[switch]$AllowMissing) [pscustomobject]@{IsSafe=$true;Path=$LiteralPath;Exists=($LiteralPath -notlike '*WeChat Files');Attributes=[IO.FileAttributes]::Directory;ExistingParent='C:\Users\me\Documents'}}
function Get-CleanerChildren {param($LiteralPath) @()}
Assert-T6 (-not (Test-SafeTarget 'C:\Users\me\Documents\WeChat Files' MoveChat $script:MigrationContext).IsSafe) 'missing chat root requires retained-copy proof'
function Get-CleanerChildren {param($LiteralPath) [pscustomobject]@{FullName=('C:\Users\me\Documents\WeChat Files.cdrive-retained-'+('a'*32))}}
Assert-T6 ((Test-SafeTarget 'C:\Users\me\Documents\WeChat Files' MoveChat $script:MigrationContext).IsSafe) 'exact retained chat sibling proves interrupted switch'

# Persistent lock is released by the OS on interruption and can reopen without unlink races.
function Assert-MigrationTarget {param($Path,$Category)}
$testDir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($testDir)
try {
    $lockPath=Join-Path $testDir 'moves.json';$lock=Open-MigrationManifestLock $lockPath -Persistent
    Assert-ThrowsT6 {Open-MigrationManifestLock $lockPath -Persistent} 'P3 concurrent move cannot acquire same lock'
    Close-MigrationManifestLock $lock
    Assert-T6 ([IO.File]::Exists($lockPath+'.lock')) 'P3 persistent lock file is not unlinked'
    $lock=Open-MigrationManifestLock $lockPath -Persistent;Close-MigrationManifestLock $lock
    Assert-T6 $true 'P3 stale lock file allows resume after handle is released'
}
finally {if($null -ne $lock){$lock.Stream.Dispose()};foreach($p in [IO.Directory]::EnumerateFiles($testDir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($testDir)}

# Rollback can restore the original even when the destination disk is disconnected.
function Assert-MigrationTarget {param($Path,$Category) if($Path.StartsWith('D:')){throw '模拟数据盘不在线'}}
$r=New-T6Record
Assert-MoveRecord $r -ForRollback
Assert-T6 $true 'rollback validates recorded path without accessing offline data volume'
Assert-ThrowsT6 {Assert-MoveRecord $r} 'move/release still require a reachable safe destination'
function Assert-MigrationTarget {param($Path,$Category)}

# Streaming hash agrees with SHA256 and works without Windows APIs.
$bytes=[Text.Encoding]::UTF8.GetBytes('聊天内容');$stream=[IO.MemoryStream]::new($bytes);$sha=[Security.Cryptography.SHA256]::Create()
try {Assert-T6 ((Get-MoveStreamHash $stream) -eq [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')) 'streaming hash correct'} finally {$stream.Dispose();$sha.Dispose()}

# P3 tiny hashed files must not each print progress; the enclosing inventory reports the phase.
& {
    $script:hashLines=0
    function Write-Host {param($Object) $script:hashLines++}
    for($i=0;$i -lt 10;$i++) {
        $stream=[IO.MemoryStream]::new([byte[]]@(1,2,3))
        try {$null=Get-MoveStreamHash $stream} finally {$stream.Dispose()}
    }
    Assert-T6 ($script:hashLines -eq 0) 'P3 hash progress does not flood one line per small file'
}

# Self-elevation passes original identity, continuation data and an explicit result path; cancellation is a result.
$script:elevationArgs='';$script:elevationCalls=0
function Get-Process {param($Id,$ErrorAction) [pscustomobject]@{Path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';ProcessName='notepad'}}
function Start-Process {param($FilePath,$ArgumentList,$Verb,[switch]$Wait,[switch]$PassThru,$ErrorAction) $script:elevationCalls++;$script:elevationArgs=$ArgumentList;throw '模拟取消'}
$output=Join-Path $PSScriptRoot ('not-created-'+[guid]::NewGuid().ToString('N')+'.json')
$result=Invoke-MoveElevatedChild @{ResumeId=('a'*32)} 'C:\pc-care\move.ps1' $output
Assert-T6 ($result.Status -eq 'Failed' -and $result.StoppedAt -eq 'Elevation' -and $result.Reason.Contains('取消') -and $script:elevationCalls -eq 1) 'UAC cancellation skips without attempting a move'
Assert-T6 ($script:elevationArgs.Contains('-OriginalUserSid') -and $script:elevationArgs.Contains('S-test') -and $script:elevationArgs.Contains('-OriginalUserProfile') -and $script:elevationArgs.Contains('-ResumeId') -and $script:elevationArgs.Contains('-ResultPath')) 'elevation preserves identity and resume command'
Restore-T6 @('Set-MoveKnownFolder')
$script:MigrationContext.CurrentUserSid='other'
Assert-ThrowsT6 {Set-MoveKnownFolder Documents 'D:\docs'} 'another account cannot change original known folder'
$script:MigrationContext.CurrentUserSid='S-test'

# Result writer creates a fresh JSON, emits a final RESULT line and does nothing in preview.
$testDir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($testDir)
try {
    $path=Join-Path $testDir 'result.json';$result=New-MoveResult Done Active '' (New-T6Record)
    $text=@(Write-MoveResult $result $path)
    $json=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-T6 ($json.Schema -eq 'pc-care/move/1' -and $text[-1] -eq ('RESULT: '+$path)) 'result schema and final locator line'
    Assert-ThrowsT6 {Write-MoveResult $result $path} 'result JSON never overwritten'
    $preview=Join-Path $testDir 'preview.json';$WhatIfPreference=$true;$text=@(Write-MoveResult $result $preview)
    Assert-T6 (-not [IO.File]::Exists($preview) -and $text[-1] -eq ('RESULT: '+$preview)) 'WhatIf result printed without writing reserved path'
    $WhatIfPreference=$false
}
finally {$WhatIfPreference=$false;foreach($p in [IO.Directory]::EnumerateFiles($testDir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($testDir)}
Assert-ThrowsT6 {Assert-MigrationSeparation 'C:\src' 'C:\dest'} 'same volume rejected by pure separation logic'
Assert-ThrowsT6 {Assert-MigrationSeparation 'C:\src' 'C:\src\child'} 'nested destination rejected by pure separation logic'


# R1/R5: default request dispatch is cheap and detached; both hosts use process-only policy.
& {
    Restore-T6 @('Invoke-MoveNew','Invoke-MoveRecord','Assert-MoveRecord','Get-MoveEntryIdentity','Write-MoveInventory','Read-MoveInventory','Set-MoveState','Invoke-MoveCopy','Assert-MoveActive')
    $script:MoveRunBackground=$true;$script:MoveShortWrites=$false;$script:MoveScriptPath='C:\pc care\move.ps1'
    $script:starts=0;$script:saves=0;$script:workerArguments='';$script:window='';$script:waited=$false
    $script:workerStart=[datetime]::SpecifyKind([datetime]::new(2026,10,23),[DateTimeKind]::Utc)
    function Assert-MigrationTarget {param($Path,$Category)}
    function Get-CleanerKnownFolderMap {param($Context) @{Documents='C:\Users\me\Documents'}}
    function Get-CleanerChatRoots {param($Context,$KnownFolders,$Issues,[switch]$IncludeMissing) @()}
    function Get-Process {param($Id,$ErrorAction) [pscustomobject]@{Path='C:\Windows\powershell.exe';Id=42;StartTime=$script:workerStart;ProcessName='notepad'}}
    function Start-Process {param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru,[switch]$Wait,$Verb,$ErrorAction)
        $script:starts++;$script:workerArguments=$ArgumentList;$script:window=$WindowStyle;$script:waited=[bool]$Wait
        Assert-T6 (-not $Verb) 'R1 worker never requests UAC'
        [pscustomobject]@{Id=42;StartTime=$script:workerStart}
    }
    function Get-MigrationExistingEntry {param($Path) if($Path -like 'C:*'){[pscustomobject]@{PSIsContainer=$true;Attributes=[IO.FileAttributes]::Directory}}}
    function Get-MoveEntryIdentity {param($Path) @{FileId='root'}}
    function Get-MoveInventory {throw 'R1 foreground must not scan'}
    function Read-MoveInventory {throw 'R1 foreground must not load the large inventory'}
    function Write-MigrationManifest {param($Path,$Document) $script:saves++}
    function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) $f=New-T6Facts;$f.Bytes=$Bytes;return $f}
    $dir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($dir)
    try {
        $manifest=Join-Path $dir 'moves.json';$doc=[pscustomobject]@{Entries=@()}
        $result=Invoke-MoveNew KnownFolder Documents 'D:\new' $manifest $doc $false
        Assert-T6 ($result.Status -eq 'Running' -and $doc.Entries.Count -eq 1 -and $doc.Entries[0].State -eq 'Scanning' -and $script:saves -eq 1) 'R1 request persists resumable Scanning before any full scan'
        Assert-T6 ($script:starts -eq 1 -and $script:window -eq 'Hidden' -and -not $script:waited) 'R1 worker hidden and detached without Wait'
        Assert-T6 ($result.Id -eq $doc.Entries[0].Id -and $result.NextAction -match '30 秒.*-Status -Id') 'R1 agent polling flow has record id and plain hint'
        Assert-T6 ($script:workerArguments -match '-ExecutionPolicy Bypass' -and $script:workerArguments -match '-Worker' -and $script:workerArguments -match '-Operation Move') 'R5 actual worker arguments allow process-only execution'
        $again=Invoke-MoveNew KnownFolder Documents 'D:\new' $manifest $doc $false
        Assert-T6 ($again.Status -eq 'Running' -and $again.Id -eq $result.Id -and $script:starts -eq 1) 'R1 second identical request reuses live worker and record'
        $snapshot=Read-MoveStatus (Get-MoveStatusPath $manifest $result.Id)
        Assert-T6 ($snapshot.WorkerPid -eq 42 -and $snapshot.WorkerStartTime -and $snapshot.LastUpdate -and $snapshot.Phase -eq 'Scanning') 'R1 small status carries pid start time phase counters timestamp'
        $stalled=Get-MoveStatusResult $snapshot $doc.Entries[0] {param($s) $false}
        Assert-T6 ($stalled.Status -eq 'Stalled' -and $stalled.Reason.Contains('重新运行')) 'R1 dead worker reports recoverable Stalled'
        $snapshot.FinalResultPath='final.json'
        $final=Get-MoveStatusResult $snapshot $doc.Entries[0] {throw 'must not check pid after final'} {param($p) @{Status='Done';Path=$p}}
        Assert-T6 ($final.Status -eq 'Done' -and $final.Path -eq 'final.json') 'R1 Status returns final result when complete'
        Save-MoveStatus (Get-MoveStatusPath $manifest $result.Id) $snapshot
        $same=Start-MoveWorker $doc.Entries[0] $manifest Release
        Assert-T6 ($same.Status -eq 'Running' -and $script:starts -eq 1) 'R1 live worker always returns Running even after final file was just written'
        $snapshot.FinalResultPath=''
        Assert-T6 (-not (Test-MoveWorkerAlive $snapshot {param($number) @{StartTime=$script:workerStart.AddSeconds(1)}})) 'R1 recycled pid is not the original worker'
        Assert-T6 (Test-MoveWorkerAlive $snapshot {param($number) @{StartTime=$script:workerStart}}) 'R1 live pid and exact start time match'
        $workerPath=Join-Path $dir ('move-worker-'+$result.Id+'.json')
        $held=Open-MigrationManifestLock $workerPath -Persistent
        try {Assert-ThrowsT6 {Open-MigrationManifestLock $workerPath -Persistent} 'R1 worker record lock excludes a second owner'} finally {Close-MigrationManifestLock $held}
        $held=Open-MigrationManifestLock $workerPath -Persistent;Close-MigrationManifestLock $held
        Assert-T6 $true 'R1 interrupted worker lock can be resumed without deleting lock file'
        # A dead process is resumed using the same record; no new baseline or id in the caller.
        function Test-MoveWorkerAlive {param($Status) $false}
        $again=Invoke-MoveNew KnownFolder Documents 'D:\new' $manifest $doc $false
        Assert-T6 ($again.Id -eq $result.Id -and $doc.Entries.Count -eq 1 -and $script:starts -eq 2) 'R1 rerun starts a replacement only after worker is gone'
        # Progress output can have many local clocks, but the status file is throttled globally.
        $script:MoveWorkerStatus=Read-MoveStatus (Get-MoveStatusPath $manifest $result.Id)
        $script:MoveStatusPath=Get-MoveStatusPath $manifest $result.Id;$script:MoveStatusLastWrite=[datetime]::MinValue;$script:statusWrites=0
        function Save-MoveStatus {param($Path,$Value) $script:statusWrites++}
        for($i=0;$i -lt 20;$i++){Write-MoveProgress '核对文件' $i 0 @{Last=[datetime]::MinValue} -Force}
        Assert-T6 ($script:statusWrites -eq 1) 'R1 status writes at most once per three seconds across local progress clocks'
        $script:MoveWorkerStatus=$null
    }
    finally { $script:MoveRunBackground=$false;$script:MoveWorkerStatus=$null;foreach($p in [IO.Directory]::EnumerateFiles($dir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($dir) }
    foreach ($args in @(@{Worker=$true;Id=('b'*32);Operation='Release'},@{ElevatedChild=$true;Foreground=$true;ResumeId=('a'*32)})) {
        $argv=Get-MoveHostArguments 'C:\pc care\move.ps1' $args
        Assert-T6 (($argv[0..4] -join '|') -eq '-NoProfile|-ExecutionPolicy|Bypass|-File|C:\pc care\move.ps1') 'R5 both host argument lists use NoProfile and process policy before File'
    }
    Assert-T6 ($script:elevationArgs -match '-ExecutionPolicy Bypass') 'R5 actual elevated launch also bypasses Restricted policy for this process'
}

# R1/R2: real orchestration, inventory, copy adapter, switch and release with only Windows boundaries faked.
& {
    Restore-T6 @('Invoke-MoveNew','Invoke-MoveRecord','Get-MoveInventory','Read-MoveInventory','Write-MoveInventory','Invoke-MoveCopy','Invoke-MoveSwitch','Invoke-MoveRelease','Assert-MoveActive','Set-MoveState','Assert-MoveRecord','Remove-MoveForeignLink','Get-MoveLinkMetadata','Remove-MoveVerifiedJunction')
    $script:MoveShortWrites=$false;$script:MoveRunBackground=$false;$script:MoveWorkerStatus=$null
    $script:phaseScans=@{Inventory=0;Copying=0;Verifying=0;ReleaseSource=0};$script:identityCalls=0;$script:copied=$false
    $script:currentFolder='C:\Users\me\Documents';$script:targetExists=$false;$script:enumerated=[Collections.Generic.List[string]]::new();$script:deleted=[Collections.Generic.List[string]]::new()
    $script:legacy=@{'My Music'='C:\Users\me\Music';'My Pictures'='C:\Users\me\Pictures';'My Videos'='C:\Users\me\Videos'}
    $script:inventoryCode=[scriptblock]::Create($script:definitions['Get-MoveInventory'])
    function Assert-MigrationTarget {param($Path,$Category)}
    function Write-MigrationManifest {param($Path,$Document)}
    function Get-CleanerKnownFolderMap {param($Context) @{Documents=$script:currentFolder}}
    function Get-CleanerChatRoots {param($Context,$KnownFolders,$Issues,[switch]$IncludeMissing) @()}
    function Get-Process {param($Id,$ErrorAction) @{ProcessName='notepad'}}
    function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) @()}
    function Get-MoveEntryIdentity {param($Path) $script:identityCalls++;@{FileId='root'}}
    function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) $f=New-T6Facts;$f.Bytes=$Bytes;$f.FreeBytes=100000;return $f}
    function Get-MigrationExistingEntry {param($Path)
        if ($Path -like 'C:*' -or $script:targetExists) {[pscustomobject]@{PSIsContainer=$true;Attributes=[IO.FileAttributes]::Directory}}
    }
    function New-MigrationDirectory {param($Path) $script:targetExists=$true;return $true}
    function Invoke-External {param($FilePath,$ArgumentList,$Description,$SuccessExitCodes,$OutputEncoding,$OutputLine,$ProgressCallback,$Confirm)
        $script:measuredCopyArgs=$ArgumentList;$script:copied=$true;@{ExitCode=1}
    }
    function Set-MoveKnownFolder {param($Name,$Path) $script:currentFolder=$Path}
    function Remove-MoveRetainedLeaf {param($Path,$Expected,$Directory,$Hash,$Checkpoint) $script:deleted.Add($Path)}
    function Get-CleanerNativeType {return [T6MoveNative]}
    function Get-CleanerFinalHandlePath {param($Handle) [T6MoveNative]::Path}
    function Get-MoveLinkMetadata {param($Path,$Handle)
        $name=$Path.Substring($Path.LastIndexOf('\')+1)
        if(-not $script:legacy.ContainsKey($name)){throw '不是原来的链接'}
        [pscustomobject]@{Tag='A0000003';Target=('\'+[char]63+[char]63+'\'+$script:legacy[$name]);Flags=0}
    }
    function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks=@{},$Excluded=@())
        $script:phaseScans[$script:MoveStep]++
        . $script:inventoryCode
        Get-MoveInventory $Path -Hash:$Hash -AllowedLinks $AllowedLinks -Excluded $Excluded -Identity {throw 'R1 ordinary entry must not open identity handle'} -Enumerate {
            param($p)
            $script:enumerated.Add($p)
            if ($p -notin @('C:\Users\me\Documents','D:\资料\文档')) {throw 'R2 link target was enumerated'}
            if ($p.StartsWith('C:') -or $script:copied) {
                for($i=0;$i -lt 50;$i++){[pscustomobject]@{FullName=($p+'\file'+$i+'.txt');Attributes=[IO.FileAttributes]::Normal;Length=[long]10;LastWriteTimeUtc=[datetime]::new(100)}}
            }
            if($p.StartsWith('C:')){foreach($name in $script:legacy.Keys){[pscustomobject]@{FullName=($p+'\'+$name);Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)}}}
        } -Guard {param($p) @{Handles=@()}}
    }
    $dir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($dir)
    try {
        $doc=[pscustomobject]@{Entries=@()};$manifest=Join-Path $dir 'moves.json'
        $result=Invoke-MoveNew KnownFolder Documents 'D:\资料\文档' $manifest $doc $false
        Assert-T6 ($result.Status -eq 'Done' -and $result.SkippedLinks -eq 3 -and $result.SkippedLinkDetails.Count -eq 3) 'R2 Documents with three compatibility junctions moves and verifies'
        Assert-T6 ($script:phaseScans.Inventory -eq 1 -and $script:phaseScans.Copying -eq 0 -and $script:phaseScans.Verifying -eq 2) 'R1 full move bound: baseline source 1, copy 0, verify source 1 + destination 1'
        $record=$doc.Entries[0]
        Assert-T6 ($record.ActiveAt -and $script:identityCalls -eq 3) 'R1 root handle checks stay constant; R3 ActiveAt recorded'
        Assert-T6 ('/XJ' -in $script:measuredCopyArgs -and '/XJD' -in $script:measuredCopyArgs -and '/XJF' -in $script:measuredCopyArgs -and '/SL' -notin $script:measuredCopyArgs) 'R2 robocopy excludes junctions and file links without SL'
        foreach($name in $script:legacy.Keys){Assert-T6 (($record.Source+'\'+$name) -in $script:measuredCopyArgs) ('R2 link explicitly excluded '+$name)}
        $before=[T6MoveNative]::Deletes
        $result=Invoke-MoveRecord $record $manifest $doc Release
        Assert-T6 ($result.Status -eq 'Done' -and $record.State -eq 'Released' -and [T6MoveNative]::Deletes-$before -eq 3) 'R2 release removes only three link handles plus retained data'
        Assert-T6 ($script:phaseScans.ReleaseSource -eq 2) 'R1 release bound: destination 1 + retained source 1, no final rescan'
        Assert-T6 (@($script:deleted | Where-Object {$_ -like '*\Music*' -or $_ -like '*\Pictures*' -or $_ -like '*\Videos*'}).Count -eq 0 -and @($script:enumerated | Where-Object {$_ -notin @($record.Source,$record.Destination)}).Count -eq 0) 'R2 legacy targets never enumerated or deleted'
        Assert-T6 ([T6MoveNative]::Share -eq 0 -and ([T6MoveNative]::Flags -band 0x00200000) -ne 0) 'R2 deleting links uses exclusive no-follow handle'
        $expected=@{Tag='A0000003';Target='wrong';Flags=0};$before=[T6MoveNative]::Deletes
        Assert-ThrowsT6 {Remove-MoveForeignLink ($record.Source+'\My Music') $expected} 'R2 changed link target refuses deletion'
        Assert-T6 ([T6MoveNative]::Deletes -eq $before) 'R2 changed link target has no deletion effect'
        Remove-MoveVerifiedJunction ($record.Source+'\My Music') $script:legacy['My Music']
        Assert-T6 ([T6MoveNative]::Share -eq 0) 'R2 preserved chat junction removal shares the same exclusive no-follow implementation'
        $record.State='Active';$script:currentFolder=$record.Destination;$before=[T6MoveNative]::Deletes
        Invoke-MoveRollback $record (Read-MoveInventory $manifest $record) $manifest $doc
        Assert-T6 ([T6MoveNative]::Deletes -eq $before -and $script:currentFolder -eq $record.Source) 'R2 rollback leaves foreign links untouched'
        Write-Output ('SCAN COUNTS full move: Inventory='+$script:phaseScans.Inventory+', Copying='+$script:phaseScans.Copying+', Verifying='+$script:phaseScans.Verifying+', ReleaseSource='+$script:phaseScans.ReleaseSource+'; total=5')
    }
    finally {foreach($p in [IO.Directory]::EnumerateFiles($dir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($dir)}
}

# R2: file and directory symlink target text and relative flag survive the authenticated sidecar.
& {
    Restore-T6 @('Get-MoveInventory')
    $visited=[Collections.Generic.List[string]]::new()
    $tree=Get-MoveInventory 'C:\links' -Enumerate {param($p)
        $visited.Add($p);if($p -ne 'C:\links'){throw 'must never visit symlink target'}
        [pscustomobject]@{FullName='C:\links\file-link';Attributes=[IO.FileAttributes]::ReparsePoint}
        [pscustomobject]@{FullName='C:\links\dir-link';Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)}
    } -LinkMetadata {param($p) [pscustomobject]@{Tag='A000000C';Target='..\outside';Flags=1}} -Guard {param($p) @{Handles=@()}}
    Assert-T6 ($visited.Count -eq 1 -and $tree.ForeignLinks.Count -eq 2 -and $tree.Bytes -eq 0 -and $tree.FileCount -eq 0) 'R2 file and directory symlinks never traversed or counted as data'
    $b=New-T6Inventory 0
    $b.ForeignLinks['relative-file']=[pscustomobject]@{Tag='A000000C';Target='..\outside.txt';Flags=1}
    $b.ForeignLinks['absolute-dir']=[pscustomobject]@{Tag='A000000C';Target='D:\outside';Flags=0}
    $roundtrip=ConvertFrom-MoveInventoryLines @(ConvertTo-MoveInventoryLines $b)
    Assert-T6 ($roundtrip.FileCount -eq 0 -and $roundtrip.Bytes -eq 0 -and (Test-MoveLinkEqual $b.ForeignLinks['relative-file'] $roundtrip.ForeignLinks['relative-file'])) 'R2 symlinks count as skipped metadata, never data'
    Assert-T6 (-not (Test-MoveLinkEqual $b.ForeignLinks['relative-file'] @{Tag='A000000C';Target='..\outside.txt';Flags=0})) 'R2 symlink relative flag participates in identity'
    $target=[Text.Encoding]::Unicode.GetBytes('..\file');$buffer=New-Object byte[] (20+$target.Length)
    [BitConverter]::GetBytes([Convert]::ToUInt32('A000000C',16)).CopyTo($buffer,0);[BitConverter]::GetBytes([uint16]$target.Length).CopyTo($buffer,10)
    [BitConverter]::GetBytes([uint32]1).CopyTo($buffer,16);$target.CopyTo($buffer,20)
    $link=ConvertFrom-MoveReparseBuffer $buffer $buffer.Length
    Assert-T6 ($link.Tag -eq 'A000000C' -and $link.Target -eq '..\file' -and $link.Flags -eq 1) 'R2 raw Windows symlink buffer decoded without following target'
}

# R3: ordinary use of the destination, both independent deletion tolerances and strict old-side guard.
& {
    $base=New-T6Inventory 100;$actual=New-T6Inventory 100;$at=[datetimeoffset]::new([datetime]::new(1000),[timespan]::Zero).ToString('o')
    $actual.Files['文件0.db'].Length=20;$actual.Files['文件0.db'].WriteTicks=1001
    $actual.Files['new.txt']=@{Length=999;WriteTicks=2000;Hash='';FileId='new'}
    $actual.Files.Remove('文件1.db');$actual.Files.Remove('文件2.db')
    $decision=Get-MoveReleaseAssessment $base $actual $at
    Assert-T6 ($decision.ChangedAfterMove -eq 1 -and $decision.MissingAtDestination -eq 2 -and $decision.MissingBytes -eq 20) 'R3 post-move edits, new files and exactly two percent missing accepted'
    $actual.Files.Remove('文件3.db')
    Assert-ThrowsT6 {Get-MoveReleaseAssessment $base $actual $at} 'R3 more than two percent file count refused'
    $base=New-T6Inventory 100;$actual=New-T6Inventory 100;$base.Files['文件0.db'].Length=1000;$base.Bytes=1990;$actual.Files.Remove('文件0.db')
    Assert-ThrowsT6 {Get-MoveReleaseAssessment $base $actual $at} 'R3 only one missing file still refused when over two percent bytes'
    $base=New-T6Inventory 100;$actual=New-T6Inventory 100;$actual.Files['文件0.db'].WriteTicks=1000
    Assert-ThrowsT6 {Get-MoveReleaseAssessment $base $actual $at} 'R3 changed file at or before ActiveAt refused'
    Assert-ThrowsT6 {Get-MoveReleaseAssessment $base $actual ''} 'R3 legacy record without ActiveAt never releases blindly'
    Restore-T6 @('Invoke-MoveRelease','Assert-MoveInventoryMatch')
    $script:retained=New-T6Inventory 100;$script:oldSideDeletes=0
    for($i=0;$i -lt 7;$i++){$script:retained.Files[('新保存'+$i+'.txt')]=@{Length=10;WriteTicks=100;Hash='';FileId='new'}}
    function Assert-MoveActive {param($Record,$Baseline,[switch]$Inventory) $Record.ChangedAfterMove=1;$Record.MissingAtDestination=2}
    function Get-MoveEntryIdentity {param($Path) @{FileId='root'}}
    function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks,$Excluded) $script:retained}
    function Remove-MoveRetainedLeaf {$script:oldSideDeletes++}
    $record=New-T6Record;$record.State='Active';$reason=''
    try {Invoke-MoveRelease $record $base fake @{Entries=@($record)}}catch{$reason=$_.Exception.Message}
    Assert-T6 ($reason -match '原位置多了这些文件' -and ([regex]::Matches($reason,'新保存')).Count -eq 5 -and $script:oldSideDeletes -eq 0) 'R3 old-location extras name at most five files and prevent any release'
    $script:retained=New-T6Inventory 100;$script:retained.Files['文件0.db'].WriteTicks=101
    Assert-ThrowsT6 {Invoke-MoveRelease $record $base fake @{Entries=@($record)}} 'R3 retained original timestamp changes still refuse'
    Assert-T6 ($script:oldSideDeletes -eq 0) 'R3 strict old-side failures delete nothing'
    $result=New-MoveResult Done Active '' $record
    Assert-T6 ($result.ChangedAfterMove -eq 1 -and $result.MissingAtDestination -eq 2) 'R3 destination assessment counts included in result JSON'
}

# R4: actual catch-up state machine, versioned authenticated sidecars, crash in deletion phase, then resume.
& {
    Restore-T6 @('Invoke-MoveRecord','Read-MoveInventory','Write-MoveInventory','Set-MoveState','Assert-MoveRecord','Complete-MoveCatchup','Assert-MoveInventoryMatch')
    $script:MoveRunBackground=$false;$script:MoveShortWrites=$false
    function Assert-MigrationTarget {param($Path,$Category)}
    function Write-MigrationManifest {param($Path,$Document) $script:catchupJournal.Add($Document.Entries[0].State)}
    function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) $f=New-T6Facts;$f.Bytes=$Bytes;return $f}
    function Assert-MoveAppsClosed {param($Record)}
    function Get-MoveEntryIdentity {param($Path) @{FileId='root'}}
    function New-MigrationDirectory {param($Path) $true}
    function Invoke-MoveSwitch {param($Record,$Baseline,$Manifest,$Document) $script:catchupSwitches++;Set-MoveState $Record Active $Manifest $Document}
    $script:old=New-T6Inventory 3;$script:new=New-T6Inventory 2
    $script:new.Files.Remove('文件1.db');$script:new.Files['新增.txt']=@{Length=10;WriteTicks=200;Hash='';FileId='added'}
    $script:new.Files['文件0.db'].WriteTicks=200;$script:new.FileCount=2;$script:new.Bytes=20
    $script:destination=New-T6Inventory 3;$script:copyRounds=0;$script:catchupSwitches=0;$script:dieInCatchup=$true;$script:catchupJournal=[Collections.Generic.List[string]]::new()
    function Invoke-MoveCopy {param($Record,$Baseline,[switch]$Resume,$PartialInventory) $script:copyRounds++;if($script:copyRounds -gt 1){Assert-T6 ($Resume -and $null -ne $PartialInventory) 'R4 catch-up copy reuses scanned destination and counts only outstanding bytes';$script:destination=$script:new}}
    function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks,$Excluded) if($Path.StartsWith('C:')){$script:new}else{$script:destination}}
    function Remove-MoveRetainedLeaf {param($Path,$Expected,$Directory,$Hash)
        if($script:dieInCatchup){$script:dieInCatchup=$false;throw '模拟补充复制阶段中断'}
        $name=$Path.Substring($Path.LastIndexOf('\')+1);$script:destination.Files.Remove($name)
    }
    $dir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($dir)
    try {
        $manifest=Join-Path $dir 'moves.json';$record=New-T6Record;$record.InventorySha256='';Write-MoveInventory $manifest $record $script:old
        $oldFile=$record.InventoryFile;$oldHash=$record.InventorySha256;$record.State='Prepared';$doc=@{Entries=@($record)}
        Assert-ThrowsT6 {Invoke-MoveRecord $record $manifest $doc Move} 'R4 simulate interruption after new baseline is committed, before removing deleted copies'
        Assert-T6 ($record.State -eq 'CatchingUp' -and $record.InventoryFile -like '*-v2.tsv' -and $record.PreviousInventory.InventorySha256 -eq $oldHash -and $script:catchupSwitches -eq 0) 'R4 catch-up deletion journal persists old digest and versioned baseline before mutation'
        $result=Invoke-MoveRecord $record $manifest $doc Move
        Assert-T6 ($result.Status -eq 'Done' -and $script:copyRounds -eq 2 -and $script:catchupSwitches -eq 1) 'R4 changed added and deleted source files settle after incremental second copy'
        Assert-T6 ([IO.File]::Exists((Join-Path $dir $oldFile)) -and (Read-MoveInventory $manifest $record).Files.ContainsKey('新增.txt')) 'R4 old immutable sidecar kept and latest baseline authenticated'
        Assert-T6 ('CatchingUp' -in $script:catchupJournal -and $record.ActiveAt) 'R4 resume repeats interrupted catch-up phase then exact verify and switch'
        # Changed destination copy of a source-deleted file must never be erased.
        $actual=New-T6Inventory 3;$actual.Files['文件2.db'].WriteTicks=999
        Assert-ThrowsT6 {Get-MoveCatchupRemovalPlan $script:old $script:new $actual} 'R4 source-deleted file with changed destination copy refuses removal'
        $actual=New-T6Inventory 3;$plan=Get-MoveCatchupRemovalPlan $script:old $script:new $actual
        Assert-T6 ($plan.Files.Count -eq 2 -and '文件1.db' -in $plan.Files -and '文件2.db' -in $plan.Files) 'R4 only unchanged copies of source-deleted files may be removed'
        # A killed copy may already contain newly added source files; they are not foreign user data.
        $script:destination=New-T6Inventory 3;$script:destination.Files['新增.txt']=$script:new.Files['新增.txt'];$script:copyRounds=0
        function Invoke-MoveCopy {param($Record,$Baseline,[switch]$Resume,$PartialInventory)
            Assert-MoveDestinationSubset $Baseline $script:destination
            $script:copyRounds++;$script:destination=$script:new
        }
        $resume=New-T6Record;$resume.InventorySha256='';Write-MoveInventory $manifest $resume $script:old;$resume.State='Copying'
        $result=Invoke-MoveRecord $resume $manifest @{Entries=@($resume)} Move
        Assert-T6 ($result.Status -eq 'Done' -and $script:copyRounds -eq 1 -and $resume.InventoryFile -like '*-v2.tsv') 'R4 interrupted copy accepts already-copied new source files through catch-up, not a frozen-subset failure'
        # Persistent source changes: at most three catch-up copies in one invocation; rerun can converge.
        $script:changingTicks=300;$script:freeze=$false;$script:copyRounds=0;$script:catchupSwitches=0
        $script:changingBase=New-T6Inventory 1
        function Get-MoveInventory {param($Path,[switch]$Hash,$AllowedLinks,$Excluded)
            if($Path.StartsWith('C:')){if(-not $script:freeze){$script:changingTicks++};$v=New-T6Inventory 1;$v.Files['文件0.db'].WriteTicks=$script:changingTicks;return $v}
            return $script:destination
        }
        function Invoke-MoveCopy {param($Record,$Baseline,[switch]$Resume) $script:copyRounds++;$script:destination=New-T6Inventory 1;$script:destination.Files['文件0.db'].WriteTicks=$Baseline.Files['文件0.db'].WriteTicks}
        $record=New-T6Record;$record.InventorySha256='';Write-MoveInventory $manifest $record $script:changingBase;$record.State='Prepared';$doc=@{Entries=@($record)}
        $reason='';try{$null=Invoke-MoveRecord $record $manifest $doc Move}catch{$reason=$_.Exception.Message}
        Assert-T6 ($script:copyRounds -eq 4 -and $script:catchupSwitches -eq 0 -and $reason.Contains('暂时不要修改') -and $record.State -eq 'Copied') 'R4 three catch-up round limit gives a plain retry reason and never switches unstable source'
        $script:freeze=$true;$result=Invoke-MoveRecord $record $manifest $doc Move
        Assert-T6 ($result.Status -eq 'Done' -and $script:catchupSwitches -eq 1) 'R4 retry has a fresh bounded catch-up allowance and can settle'
        # Both the record validator and actual shared whitelist admit only this id's versioned sidecars.
        $record.InventoryFile='move-inventory-'+('f'*32)+'-v2.tsv'
        Assert-ThrowsT6 {Assert-MoveRecord $record} 'R4 other record inventory name refused'
    }
    finally {foreach($p in [IO.Directory]::EnumerateFiles($dir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($dir)}
}

# R6: captured English/Chinese robocopy errors, five-file cap, and actual failure adapter.
& {
    $english=@('2026/10/23 12:00:00 ERROR 32 (0x00000020) Copying File C:\Users\me\Documents\locked.docx',
        'The process cannot access the file because it is being used by another process.')
    $chinese=@('2026/10/23 12:00:00 错误 32 (0x00000020) 正在复制文件 C:\Users\me\Documents\占用.docx',
        '另一个程序正在使用此文件，进程无法访问。')
    foreach($sample in @($english,$chinese)){
        $reason=Get-MoveCopyFailureReason $sample
        Assert-T6 ($reason.Contains('这些文件正被其他软件使用') -and $reason.Contains('.docx')) 'R6 locked copy failure gives Chinese reason and English/Chinese file path'
    }
    $many=@(for($i=0;$i -lt 8;$i++){'ERROR 5 (0x00000005) Copying File C:\src\file'+$i+'.txt'})
    $reason=Get-MoveCopyFailureReason $many
    Assert-T6 (([regex]::Matches($reason,'file\d')).Count -eq 5 -and $reason.Contains('访问权限')) 'R6 up to five files with likely access cause'
    Assert-T6 ((Get-MoveCopyFailureReason @('ERROR 112 (0x00000070) Copying File C:\src\large.zip')).Contains('磁盘空间不足')) 'R6 disk full has actionable Chinese reason'
    Restore-T6 @('Invoke-MoveCopy')
    function Assert-MoveAppsClosed {param($Record)}
    function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) @()}
    function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) $f=New-T6Facts;$f.Bytes=$Bytes;return $f}
    function Invoke-External {param($FilePath,$ArgumentList,$Description,$SuccessExitCodes,$OutputEncoding,$OutputLine,$ProgressCallback,$Confirm)
        $null=& $OutputLine 'ERROR 32 (0x00000020) Copying File C:\src\locked.docx'
        $ex=[InvalidOperationException]::new('模拟真实外部程序退出码 8');$ex.Data['ExternalResult']=@{ExitCode=8};throw $ex
    }
    $reason='';try{Invoke-MoveCopy (New-T6Record) (New-T6Inventory 0)}catch{$reason=$_.Exception.Message}
    Assert-T6 ($reason.Contains('locked.docx') -and $reason.Contains('关闭相关软件')) 'R6 actual thrown ExternalResult preserves parsed copy reason'
}

# R7: custom data roots need conservative direct markers; generic JSON filePath never grants broad deletion.
& {
    Restore-T6 @('Get-CleanerChatRoots','Get-CleanerChatRootRecognition','Get-CleanerMigrationTarget')
    $issues=[Collections.Generic.List[string]]::new();$folders=@{Documents='C:\Users\me\Documents'}
    $roots=@(Get-CleanerChatRoots $script:MigrationContext $folders {param($k,$n) ''} {param($p) '{"filePath":"C:\\Users\\me\\OtherApp"}'} {param($p) $p -eq 'C:\Users\me\OtherApp'} -MarkerChildren {param($p) @()} -Issues $issues)
    Assert-T6 ($roots.Count -eq 0 -and $issues.Count -gt 0 -and $issues[0] -eq '找到了自定义的聊天文件位置，但无法确认，暂不搬家') 'R7 generic custom JSON path rejected with Issue'
    $names=(Get-CleanerTargets).MoveChats.WeChat.Names
    foreach($marker in @('All Users','wxid_ab123')) {
        $child={param($p) [pscustomobject]@{Name=$marker;Attributes=[IO.FileAttributes]::Directory}}.GetNewClosure()
        Assert-T6 ((Get-CleanerChatRootRecognition 'C:\custom' WeChat $names $child) -eq 'Marker') ('R7 WeChat direct marker '+$marker)
    }
    foreach($marker in @('nt_qq','12345','123456789012')) {
        $child={param($p) [pscustomobject]@{Name=$marker;Attributes=[IO.FileAttributes]::Directory}}.GetNewClosure()
        Assert-T6 ((Get-CleanerChatRootRecognition 'C:\custom' QQ @('Tencent Files') $child) -eq 'Marker') ('R7 QQ direct marker '+$marker)
    }
    foreach($entry in @(@{Name='1234';Attributes=[IO.FileAttributes]::Directory},@{Name='1234567890123';Attributes=[IO.FileAttributes]::Directory},@{Name='All Users';Attributes=[IO.FileAttributes]::Normal},@{Name='All Users';Attributes=([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)})){
        $child={param($p) $entry}.GetNewClosure()
        $app='WeChat';if($entry.Name -match '^\d+$'){$app='QQ'}
        Assert-T6 (-not (Get-CleanerChatRootRecognition 'C:\custom' $app $names $child)) 'R7 unrelated numeric names, files and linked markers do not authorize root'
    }
    Assert-T6 ((Get-CleanerChatRootRecognition 'C:\chat\WeChat Files' WeChat $names {throw 'known leaf needs no child scan'}) -eq 'Name') 'R7 known leaf name is sufficient without marker scan'
    $roots=@(Get-CleanerChatRoots $script:MigrationContext $folders {param($k,$n) ''} {param($p) ''} {param($p) $true} -MarkerChildren {throw 'defaults need no custom check'})
    Assert-T6 ($roots.Count -eq 3) 'R7 default Documents roots unchanged'
    $roots=@(Get-CleanerChatRoots $script:MigrationContext $folders {param($k,$n) ''} {param($p) '{"filePath":"C:\\custom"}'} {param($p) $p -eq 'C:\custom'} -MarkerChildren {param($p) [pscustomobject]@{Name='wxid_test';Attributes=[IO.FileAttributes]::Directory}})
    Assert-T6 ($roots.Count -eq 1 -and $roots[0].App -eq 'WeChat' -and $roots[0].Recognition -eq 'Marker') 'R7 recognized arbitrary custom root is allowed only for matching app'
    # Retained sibling proof preserves marker-based authorization after the chat source was renamed.
    $roots=@(Get-CleanerChatRoots $script:MigrationContext @{} {param($k,$n) if($n -eq 'DataPath'){'C:\custom'}} {param($p) ''} {param($p) $false} -IncludeMissing -MarkerChildren {
        param($p)
        if($p -eq 'C:'){[pscustomobject]@{Name=('custom.cdrive-retained-'+('a'*32));FullName=('C:\custom.cdrive-retained-'+('a'*32));Attributes=[IO.FileAttributes]::Directory}}
        if($p -like '*cdrive-retained-*'){[pscustomobject]@{Name='nt_qq';Attributes=[IO.FileAttributes]::Directory}}
    })
    Assert-T6 (@($roots | Where-Object {$_.App -eq 'QQ' -and $_.Path -eq 'C:\custom'}).Count -eq 1) 'R7 marker-recognized root remains identifiable in exact retained sibling during switch/release'
    function Get-CleanerChatRoots {param($Context,[switch]$IncludeMissing)
        # Reuse real discovery with a maliciously broad generic config and empty fake markers.
        . ([scriptblock]::Create($script:definitions['Get-CleanerChatRoots']))
        Get-CleanerChatRoots $Context @{} {param($k,$n) ''} {param($p) '{"filePath":"C:\\Users\\me\\OtherApp"}'} {param($p) $true} -IncludeMissing:$IncludeMissing -MarkerChildren {param($p) @()}
    }
    foreach($category in @('MoveChat','MoveChatBackup','MoveChatParent')){
        Assert-T6 (@(Get-CleanerMigrationTarget (Get-CleanerTargets).Categories[$category] $script:MigrationContext).Count -eq 0) ('R7 unrecognized custom roots never whitelisted: '+$category)
    }
}

# R4/P2: actual shared whitelist permits versions and rejects invalid sidecars outside the log directory.
& {
    Restore-T6 @('Get-CleanerMigrationTarget','Test-SafeTarget')
    function Get-CleanerEntryMetadata {param($LiteralPath) [pscustomobject]@{IsDirectory=($LiteralPath -notmatch '\.(tsv|json)(?:\.|$)');LinkCount=1}}
    foreach($suffix in @('.tsv','-v2.tsv','-v10.tsv','-v200.tsv')){
        Assert-T6 ((Test-SafeTarget ('C:\Users\me\AppData\Local\CDriveCleaner\Logs\move-inventory-'+('a'*32)+$suffix) MigrationManifest $script:MigrationContext).IsSafe) ('R4 version whitelist '+$suffix)
    }
    foreach($suffix in @('-v1.tsv','-v0.tsv','-v02.tsv','-v2.tsv.exe','-v2.tsv\child')){
        Assert-T6 (-not (Test-SafeTarget ('C:\Users\me\AppData\Local\CDriveCleaner\Logs\move-inventory-'+('a'*32)+$suffix) MigrationManifest $script:MigrationContext).IsSafe) ('R4 invalid sidecar version/name refused '+$suffix)
    }
}

# R1: short manifest locks merge fresh records without losing another worker's phase or rollback order.
& {
    Restore-T6 @('Read-MigrationManifest','Write-MigrationManifest','Save-MoveRecord')
    function Assert-MigrationTarget {param($Path,$Category)}
    $script:MoveShortWrites=$true;$script:MigrationWroteState=$true;$script:MoveWorkerStatus=$null
    $dir=Join-Path $PSScriptRoot ('.t6-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($dir)
    try {
        $manifest=Join-Path $dir 'moves.json';$a=New-T6Record;$b=New-T6Record
        Save-MoveRecord $a $manifest @{Entries=@($a)}
        Save-MoveRecord $b $manifest @{Entries=@($b)}
        $a.State='Active';Save-MoveRecord $a $manifest @{Entries=@($a)}
        $fresh=Read-MigrationManifest $manifest
        Assert-T6 ($fresh.Entries.Count -eq 2 -and $fresh.Entries[0].Id -eq $a.Id -and $fresh.Entries[1].Id -eq $b.Id -and $fresh.Entries[0].State -eq 'Active' -and $fresh.Entries[1].State -eq 'Prepared') 'R1 atomic manifest updates preserve other records and original reverse-rollback order'
        $path=Join-Path $dir 'move-operations.json';$held=Open-MigrationManifestLock $path -Persistent;$script:queuePauses=0
        $queued=Open-MoveOperationLock $path {$script:queuePauses++;Close-MigrationManifestLock $held}
        try {Assert-T6 ($script:queuePauses -eq 1) 'R1 workers queue conflicting folder operations without blocking foreground queries'} finally {Close-MigrationManifestLock $queued}
        $script:predecessorReads=0;$script:rollbackPauses=0
        function Read-MigrationManifest {param($Path)
            $script:predecessorReads++;$state='RollingBack';if($script:predecessorReads -gt 1){$state='RolledBack'}
            @{Entries=@(@{Id=('a'*32);State=$state},@{Id=('b'*32);State='Active';RollbackAfter=('a'*32)})}
        }
        function Read-MoveStatus {param($Path) @{WorkerPid=123;WorkerStartTime='2026-10-23T00:00:00Z';FinalResultPath=''}}
        function Test-MoveWorkerAlive {param($Status) $true}
        $doc=@{Entries=@(@{Id=('a'*32);State='RollingBack'},@{Id=('b'*32);State='Active';RollbackAfter=('a'*32)})}
        $latest=Wait-MoveRollbackPredecessor $doc ('b'*32) $manifest {$script:rollbackPauses++}
        Assert-T6 ($script:rollbackPauses -eq 1 -and $latest.Entries[0].State -eq 'RolledBack') 'R1 batch rollback waits for newer folder to finish before restoring contained chat data'
        function Read-MoveStatus {param($Path) @{FinalResultPath='failed.json'}}
        $script:predecessorReads=0
        Assert-ThrowsT6 {Wait-MoveRollbackPredecessor $doc ('b'*32) $manifest {throw 'should not spin'}} 'R1 failed predecessor stops queued rollback with original data preserved'
    }
    finally {$script:MoveShortWrites=$false;foreach($p in [IO.Directory]::EnumerateFiles($dir)){[IO.File]::Delete($p)};[IO.Directory]::Delete($dir)}
}

# R7/P3: after partial release removed an app marker, only the same previously recognized root may resume.
& {
    Restore-T6 @('Assert-MoveRecord')
    function Assert-MigrationTarget {param($Path,$Category)}
    function Get-CleanerChatRoots {param($Context,[switch]$IncludeMissing) @()}
    function Get-MigrationExistingEntry {param($Path) @{Attributes=[IO.FileAttributes]::Directory}}
    function Get-MoveEntryIdentity {param($Path) @{FileId=$script:customRootId}}
    $r=New-T6Record QQ;$r.Source='C:\CustomChat';$r.RetainedSource=$r.Source+'.cdrive-retained-'+$r.Id;$r.Recognition='Marker';$r.State='Releasing';$script:customRootId='root'
    Assert-MoveRecord $r
    Assert-T6 $true 'R7 partial release resumes a previously identified custom root even after marker directories were removed'
    $script:customRootId='substituted'
    Assert-ThrowsT6 {Assert-MoveRecord $r} 'R7 custom retained root substitution refuses resume'
    $r.Recognition='';$script:customRootId='root'
    Assert-ThrowsT6 {Assert-MoveRecord $r} 'R7 never-recognized custom roots remain unauthorized'
}

# R1/R5: elevation transfers worker ownership, including the launch token, rather than leaving an unguarded child.
& {
    $args=@{Worker=$true;WorkerToken=('c'*32);Operation='Release';Id=('a'*32);ReleaseSource=$false;Rollback=$false;Foreground=$false}
    $record=New-T6Record
    $child=Get-MoveElevationContinuation $args $record
    Assert-T6 ($child.Worker -and -not $child.Foreground -and $child.Operation -eq 'Release' -and $child.Id -eq $record.Id -and $child.WorkerToken -eq $args.WorkerToken) 'R1 elevated continuation reacquires worker lock with same record operation and launch token'
    Assert-T6 (-not $child.ReleaseSource -and -not $child.Rollback -and -not $child.ResumeId) 'R5 elevated Worker child has no conflicting public action arguments'
    $argv=Get-MoveHostArguments 'C:\pc care\move.ps1' $child
    Assert-T6 ('-Worker' -in $argv -and '-WorkerToken' -in $argv -and '-ExecutionPolicy' -in $argv -and 'Bypass' -in $argv) 'R5 elevated worker receives policy and continuation arguments'
    $chat=New-T6Record WeChat;$chat.Source='C:\Users\me\Documents\WeChat Files';$chat.State='Copying'
    Assert-T6 ($null -ne (Find-MovePendingOverlap 'C:\Users\me\Documents' @($chat))) 'R1 parent folder request waits for unfinished contained chat move'
    Assert-T6 ($null -eq (Find-MovePendingOverlap 'C:\Users\me\Documents2' @($chat))) 'R1 unrelated folder name prefix does not block a move'
    $chat.State='Active'
    Assert-T6 ($null -eq (Find-MovePendingOverlap 'C:\Users\me\Documents' @($chat))) 'P4c completed chat move may still be included in Documents move'
}

# R1/R4: catch-up must not demand enough free space to duplicate the whole already-copied data again.
& {
    Restore-T6 @('Invoke-MoveCopy')
    function Assert-MoveAppsClosed {param($Record)}
    function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) @()}
    function Get-MoveInventory {throw 'catch-up already scanned destination; no redundant scan allowed'}
    function Get-MoveVolumeFacts {param($Path,$Bytes,$NonEmpty,$Resume) $f=New-T6Facts;$f.Bytes=$Bytes;$f.FreeBytes=150;return $f}
    $script:incrementalCopies=0
    function Invoke-External {param($FilePath,$ArgumentList,$Description,$SuccessExitCodes,$OutputEncoding,$OutputLine,$ProgressCallback,$Confirm) $script:incrementalCopies++;@{ExitCode=1}}
    $baseline=New-T6Inventory 100;$partial=New-T6Inventory 100;$partial.Files['文件0.db'].WriteTicks=99
    Invoke-MoveCopy (New-T6Record) $baseline -Resume -PartialInventory $partial
    Assert-T6 ($script:incrementalCopies -eq 1) 'R4 catch-up succeeds with space for the changed file and reserve, without allocating the baseline twice'
}

# Exercise loader used in production; it must not execute migrate body on Linux.
Import-MoveMigrationFunctions (Join-Path $repo 'scripts/migrate.ps1')
Assert-T6 ((Get-MigrationValue @{a=42} @('a')) -eq 42) 'AST migration reuse loader works'
Write-Output ('PASS t6-move: '+$script:assertions+' assertions')
