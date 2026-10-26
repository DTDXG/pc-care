<#
.SYNOPSIS
把用户文件夹和微信、QQ 聊天文件搬到数据盘，保留原件并支持续传、还原。
.DESCRIPTION
默认启动独立后台进程，代理每隔 30 秒查询 -Status -Id；宿主退出不影响搬家。
扫描使用枚举元数据；每轮核对写独立、带摘要的库存文件，Copying 可安全续传。
自定义聊天位置仅接受已知目录名，或直属的微信 All Users/wxid_*、QQ nt_qq/5-12 位号码目录。
用户确认可用后才执行 ReleaseSource。释放原件后不能再还原旧副本。
WhatIf 不写文件、不启动外部程序、不请求权限。所有 Windows 操作与决策分离。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('KnownFolder','WeChat','QQ')][string]$Kind,
    [ValidateSet('Desktop','Documents','Downloads','Pictures','Videos')][string]$Folder,
    [string]$Destination,
    [switch]$ReleaseSource, [switch]$Rollback, [switch]$Status, [string]$Id, [string]$ResumeId,
    [switch]$Worker, [ValidateSet('Move','Release','Rollback')][string]$Operation='Move', [switch]$Foreground, [string]$WorkerToken,
    [switch]$VerifyHash, [string]$ResultPath, [string]$LogDirectory,
    [string]$OriginalUserSid, [string]$OriginalUserProfile, [switch]$ElevatedChild
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') {throw '此脚本只能在 Windows 上运行。'}

function Import-MoveMigrationFunctions {
    param([string]$Path)
    # 只加载可复用函数；绝不执行 migrate 的旧入口或其确认/写入动作。
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw '迁移基础脚本无法读取。' }
    foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
        Set-Item -LiteralPath ('Function:script:' + $node.Name) -Value ([scriptblock]::Create($node.Body.Extent.Text.Substring(1,$node.Body.Extent.Text.Length-2)))
    }
}

function Test-MoveWithin {
    param([string]$Path,[string]$Root)
    return ($Path -ieq $Root -or $Path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))
}

function New-MoveResult {
    param([string]$Status='Failed',[string]$StoppedAt='Preflight',[string]$Reason='', $Record=$null)
    return [pscustomobject]@{
        Schema='pc-care/move/1'; GeneratedAt=[datetimeoffset]::Now.ToString('o')
        Status=$Status; StoppedAt=$StoppedAt; Reason=$Reason
        Id=(Get-MigrationValue $Record @('Id') ''); Source=(Get-MigrationValue $Record @('Source') '')
        Destination=(Get-MigrationValue $Record @('Destination') '')
        Installations=@(Get-MigrationValue $Record @('Installations') @())
        IncludedChatData=@(Get-MigrationValue $Record @('IncludedChatData') @())
        NextAction=$(if ($Status -eq 'Running') {'每隔 30 秒运行 -Status -Id '+(Get-MigrationValue $Record @('Id') '')+' 查看进度'} else {''})
        SkippedLinks=[long](Get-MigrationValue $Record @('SkippedLinks') 0)
        ChangedAfterMove=[long](Get-MigrationValue $Record @('ChangedAfterMove') 0)
        MissingAtDestination=[long](Get-MigrationValue $Record @('MissingAtDestination') 0)
        Issues=@(Get-MigrationValue $Record @('Issues') @())
        ResumeHint='如执行中断，重新运行相同的搬家指令，或指定 -ResumeId 和本次 Id，即可安全继续。'
        Preview=[bool]$WhatIfPreference
        SourceKept=([string](Get-MigrationValue $Record @('State') '') -ne 'Released')
    }
}

function Get-MovePreflightDecision {
    param($Facts)
    if ($Facts.AlreadyMoved) { return New-MoveResult 'AlreadyMoved' 'Preflight' '这个文件夹已经搬过，原位置已指向其他位置。' }
    if ($Facts.OneDrive) { return New-MoveResult 'Failed' 'Preflight' '这个文件夹由 OneDrive 管理，请在 OneDrive 的同步和备份设置中调整位置。' }
    if (@($Facts.RunningApps).Count) { return New-MoveResult 'NeedsAppExit' 'Preflight' ('请先完全退出'+($Facts.RunningApps -join '、')+'，再继续搬家。') }
    if (-not $Facts.IsFixed -or $Facts.FileSystem -ine 'NTFS' -or -not $Facts.IsLocal) { return New-MoveResult 'Failed' 'Preflight' '目标必须是电脑内的本地固定 NTFS 磁盘。' }
    if ($Facts.SystemVolume) { return New-MoveResult 'Failed' 'Preflight' '请选择系统盘以外的数据盘。' }
    if ($Facts.Forbidden) { return New-MoveResult 'Failed' 'Preflight' '目标位于系统或受保护的目录，请换一个资料文件夹。' }
    if ($Facts.NonEmpty -and -not $Facts.Resume) { return New-MoveResult 'Failed' 'Preflight' '目标文件夹已有内容，请选择空文件夹。' }
    if ([decimal]$Facts.FreeBytes -lt ([decimal]$Facts.Bytes + [math]::Ceiling([decimal]$Facts.Bytes / 10))) { return New-MoveResult 'NotEnoughSpace' 'Preflight' '目标盘空间不足，需要能容纳全部数据并留出百分之十的余量。' }
    return New-MoveResult 'Done' 'Preflight'
}

function Get-MoveRunningApps {
    param([string[]]$Apps,[string[]]$ProcessNames)
    foreach ($app in @($Apps | Select-Object -Unique)) {
        $names=@('QQ','QQNT','QQProtect','TIM'); $title='QQ'
        if ($app -eq 'WeChat') { $names=@('WeChat','Weixin','WeChatAppEx','WeChatPlayer'); $title='微信' }
        foreach ($process in $ProcessNames) {
            if (($process -replace '\.exe$','') -in $names) { $title; break }
        }
    }
}

function Assert-MoveAppsClosed {
    param($Record)
    $apps=@($Record.IncludedChatData)
    if ($Record.Kind -ne 'KnownFolder') { $apps+= $Record.Kind }
    $running=@(Get-MoveRunningApps $apps @(Get-Process -ErrorAction Stop | ForEach-Object {$_.ProcessName}))
    if ($running.Count) {
        $ex=[InvalidOperationException]::new(('请先完全退出'+($running -join '、')+'，再继续搬家。'))
        $ex.Data['MoveStatus']='NeedsAppExit'; throw $ex
    }
}

function Get-MoveIncludedChats {
    param([string]$Source,[object[]]$Chats)
    @($Chats | Where-Object { Test-MoveWithin $_.Path $Source } | ForEach-Object {$_.App} | Select-Object -Unique)
}

function Find-MoveContainingRecord {
    param([string]$Path,[object[]]$Records)
    foreach ($record in $Records) {
        if ($record.Kind -eq 'KnownFolder' -and $record.State -in @('Active','Releasing','Released') -and
            (Test-MoveWithin $Path $record.RetainedSource)) { return $record }
    }
    return $null
}

function Write-MoveProgress {
    param([string]$Phase,[long]$Files,[long]$Bytes,$Clock,[switch]$Force)
    $now=[datetime]::UtcNow
    if ($Force -or ($now-$Clock.Last).TotalSeconds -ge 3) {
        Write-Host ('{0}：已处理 {1} 个文件，{2} 字节。' -f $Phase,$Files,$Bytes)
        if ($null -ne (Get-Variable MoveWorkerStatus -Scope Script -ErrorAction SilentlyContinue) -and $null -ne $script:MoveWorkerStatus) {
            $script:MoveWorkerStatus.Phase=$Phase; $script:MoveWorkerStatus.FilesDone=$Files; $script:MoveWorkerStatus.BytesDone=$Bytes
            $script:MoveWorkerStatus.LastUpdate=[datetimeoffset]::UtcNow.ToString('o')
            if (($now-$script:MoveStatusLastWrite).TotalSeconds -ge 3) {
                Save-MoveStatus $script:MoveStatusPath $script:MoveWorkerStatus;$script:MoveStatusLastWrite=$now
            }
        }
        $Clock.Last=$now
    }
}

function Get-MoveEntryIdentity {
    param([string]$Path)
    # 仅根身份校验使用；普通文件的枚举阶段不调用此函数。
    $native=Get-CleanerNativeType; $handle=$null
    try {
        $handle=$native::CreateFileW($Path,0x80,7,[IntPtr]::Zero,3,0x02300000,[IntPtr]::Zero)
        if ($handle.IsInvalid) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
        if ((Get-CleanerFinalHandlePath $handle) -ine $Path) { throw '文件的实际位置发生变化，已停止。' }
        return Get-CleanerHandleMetadata $handle
    }
    finally { if ($null -ne $handle) {$handle.Dispose()} }
}

function Get-MoveStreamHash {
    param($Stream,[scriptblock]$Checkpoint)
    $sha=[Security.Cryptography.SHA256]::Create()
    $bufferLength=[int][math]::Min(1048576,[math]::Max(4096,$Stream.Length))
    $buffer=New-Object byte[] $bufferLength
    $clock=@{Last=[datetime]::UtcNow};$lastCheck=[datetime]::UtcNow;[long]$bytes=0
    try {
        while (($read=$Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $null=$sha.TransformBlock($buffer,0,$read,$buffer,0);$bytes+=$read
            Write-MoveProgress '核对文件内容' 0 $bytes $clock
            if ($null -ne $Checkpoint -and ([datetime]::UtcNow-$lastCheck).TotalSeconds -ge 30) {$null=& $Checkpoint;$lastCheck=[datetime]::UtcNow}
        }
        $null=$sha.TransformFinalBlock($buffer,0,0)
        return [BitConverter]::ToString($sha.Hash).Replace('-','')
    }
    finally {$sha.Dispose()}
}

function Get-MoveFileHash {
    param([string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {return Get-MoveStreamHash $stream} finally {$stream.Dispose()}
}

function Get-MoveInventory {
    param([string]$Path,[switch]$Hash,$AllowedLinks=@{},[string[]]$Excluded=@(),
        [scriptblock]$Enumerate={param($p) ([IO.DirectoryInfo]::new($p)).EnumerateFileSystemInfos()},
        [scriptblock]$Identity={param($p) Get-MoveEntryIdentity $p},
        [scriptblock]$Digest={param($p) Get-MoveFileHash $p},
        [scriptblock]$Guard={param($p) Open-CleanerParentGuards -LiteralPath ($p+'\.pc-care-read-guard')},
        [scriptblock]$LinkMetadata={param($p) Get-MoveLinkMetadata $p})
    # Identity 保留为兼容测试注入参数；普通项绝不调用它。仅根及删除前使用句柄。
    $files=@{}; $directories=@{}; $links=@{}; $foreign=@{}; [long]$bytes=0
    $rootGuards=& $Guard $Path
    try {
        $stack=[Collections.Generic.Stack[string]]::new(); $stack.Push($Path)
        $clock=@{Last=[datetime]::MinValue}
        while ($stack.Count) {
            $parent=$stack.Pop()
            foreach ($entry in (& $Enumerate $parent)) {
                $relative=$entry.FullName.Substring($Path.Length+1)
                if ($relative -in $Excluded) { continue }
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    if ($AllowedLinks.ContainsKey($relative)) {
                        $target=[string]$AllowedLinks[$relative]
                        $null=Get-MigrationVerifiedJunction $entry.FullName $target
                        $links[$relative]=$target
                    }
                    else { $foreign[$relative]=& $LinkMetadata $entry.FullName }
                    continue # 不进入，不计入数据量；复制时一并排除。
                }
                if (([int]$entry.Attributes -band 0x441000) -ne 0) { throw '发现尚未下载的云端文件，请先在同步软件中处理。' }
                if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $directories[$relative]=''; $stack.Push($entry.FullName) }
                else {
                    $digestValue=''; if ($Hash) {$digestValue=& $Digest $entry.FullName}
                    $files[$relative]=[pscustomobject]@{Length=[long]$entry.Length;WriteTicks=[long]$entry.LastWriteTimeUtc.Ticks;Hash=$digestValue;FileId=''}
                    $bytes+=[long]$entry.Length
                }
                Write-MoveProgress '核对文件' $files.Count $bytes $clock
            }
        }
        Write-MoveProgress '核对文件' $files.Count $bytes $clock -Force
        return [pscustomobject]@{Path=$Path;FileCount=[long]$files.Count;Bytes=$bytes;Files=$files;Directories=$directories;Links=$links;ForeignLinks=$foreign;Excluded=@($Excluded)}
    } finally {if($null -ne $rootGuards){foreach($h in $rootGuards.Handles){$h.Dispose()}}}
}

function Get-MoveForeignLinks {
    param($Inventory)
    return Get-MigrationValue $Inventory @('ForeignLinks') @{}
}

function ConvertTo-MoveInventoryLines {
    param($Inventory)
    # Windows 路径不允许制表符/换行；仍使用 Base64，避免行格式和编码歧义。
    foreach ($name in $Inventory.Directories.Keys) { 'D' + "`t" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($name)) + "`t" + $Inventory.Directories[$name] }
    foreach ($name in $Inventory.Files.Keys) {
        $file=$Inventory.Files[$name]
        @('F',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($name)),[string]$file.Length,[string]$file.WriteTicks,[string]$file.Hash,[string]$file.FileId) -join "`t"
    }
    foreach ($name in $Inventory.Links.Keys) { @('J',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($name)),[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Inventory.Links[$name]))) -join "`t" }
    foreach ($name in (Get-MoveForeignLinks $Inventory).Keys) {
        $link=(Get-MoveForeignLinks $Inventory)[$name]
        @('L',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($name)),[string]$link.Tag,[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($link.Target)),[string](Get-MigrationValue $link @('Flags') 0)) -join "`t"
    }
    foreach ($name in $Inventory.Excluded) { 'X' + "`t" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($name)) }
}

function ConvertFrom-MoveInventoryLines {
    param([Collections.IEnumerable]$Lines)
    $files=@{}; $dirs=@{}; $links=@{}; $foreign=@{}; $excluded=[Collections.Generic.List[string]]::new(); $seen=@{}; [long]$bytes=0
    foreach ($line in $Lines) {
        $parts=$line.Split([char]9)
        if ($parts.Count -lt 2) { throw '文件核对清单格式无效。' }
        $relative=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))
        # 借用共享规范化器，拒绝绝对路径、越界、别名和非法字符。
        $canonical=ConvertTo-CleanerCanonicalPath -LiteralPath ('C:\inventory\'+$relative)
        if ($canonical -cne ('C:\inventory\'+$relative) -or $seen.ContainsKey($relative)) { throw '文件核对清单有重复或无效路径。' }
        $seen[$relative]=$true
        switch ($parts[0]) {
            'D' { if ($parts.Count -ne 3) {throw '目录记录无效。'}; $dirs[$relative]=$parts[2] }
            'F' {
                if ($parts.Count -ne 6 -or $parts[2] -notmatch '^\d+$' -or $parts[3] -notmatch '^\d+$' -or $parts[4] -notmatch '^(?:[0-9A-Fa-f]{64})?$') { throw '文件记录无效。' }
                $files[$relative]=[pscustomobject]@{Length=[long]$parts[2];WriteTicks=[long]$parts[3];Hash=$parts[4];FileId=$parts[5]}
                $bytes+=[long]$parts[2]
            }
            'J' { if ($parts.Count -ne 3) {throw '链接记录无效。'}; $links[$relative]=ConvertTo-CleanerCanonicalPath ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[2]))) }
            'L' {
                if ($parts.Count -ne 5 -or $parts[4] -notmatch '^[01]$' -or $parts[2] -notmatch '^[0-9A-F]{8}$') {throw '链接记录无效。'}
                $foreign[$relative]=[pscustomobject]@{Tag=$parts[2];Target=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[3]));Flags=[int]$parts[4]}
            }
            'X' { if ($parts.Count -ne 2) {throw '排除记录无效。'}; $excluded.Add($relative) }
            default { throw '文件核对清单有未知记录。' }
        }
    }
    return [pscustomobject]@{FileCount=[long]$files.Count;Bytes=$bytes;Files=$files;Directories=$dirs;Links=$links;ForeignLinks=$foreign;Excluded=$excluded.ToArray()}
}

function Write-MoveInventory {
    param([string]$Manifest,$Record,$Inventory)
    $path=Join-Path ([IO.Path]::GetDirectoryName($Manifest)) $Record.InventoryFile
    Assert-MigrationTarget $path 'MigrationManifest'
    $stream=$null; $writer=$null
    try {
        $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
        ConvertTo-MoveInventoryLines $Inventory | ForEach-Object {$writer.WriteLine($_)}
    }
    finally {if($null -ne $writer){$writer.Dispose()};if($null -ne $stream){$stream.Dispose()}}
    $Record.InventorySha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $Record.EntryCount=[long]($Inventory.Files.Count+$Inventory.Directories.Count+$Inventory.Links.Count+(Get-MoveForeignLinks $Inventory).Count+$Inventory.Excluded.Count)
    $Record.TotalBytes=[long]$Inventory.Bytes
}

function Read-MoveInventory {
    param([string]$Manifest,$Record)
    $path=Join-Path ([IO.Path]::GetDirectoryName($Manifest)) $Record.InventoryFile
    Assert-MigrationTarget $path 'MigrationManifest'
    # 同一个只读句柄先摘要后解析，校验后不允许文件替换或改写。
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha=[Security.Cryptography.SHA256]::Create(); $reader=$null
    try {
        $digest=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')
        if ($digest -ine $Record.InventorySha256) { throw '文件核对清单已改变，已停止。' }
        $stream.Position=0; $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true))
        $lines=[Collections.Generic.List[string]]::new()
        while (-not $reader.EndOfStream) {$lines.Add($reader.ReadLine())}
        $inventory=ConvertFrom-MoveInventoryLines $lines
        if (($inventory.Files.Count+$inventory.Directories.Count+$inventory.Links.Count+(Get-MoveForeignLinks $inventory).Count+$inventory.Excluded.Count) -ne $Record.EntryCount -or $inventory.Bytes -ne $Record.TotalBytes) {throw '文件核对清单的统计不一致。'}
        return $inventory
    }
    finally {if($null -ne $reader){$reader.Dispose()};$stream.Dispose();$sha.Dispose()}
}

function New-MoveRecord {
    param([string]$MoveKind,[string]$FolderName,[string]$Source,[string]$Target,[string[]]$Chats,[bool]$Hash,[string]$RootId)
    $moveId=[guid]::NewGuid().ToString('N'); $retained=$Source
    if ($MoveKind -ne 'KnownFolder') {$retained=$Source+'.cdrive-retained-'+$moveId}
    return [pscustomobject]@{
        Id=$moveId;Cache=$MoveKind;Kind=$MoveKind;Folder=$FolderName;Source=$Source;Destination=$Target;RetainedSource=$retained
        UserSid=$script:MigrationSid;Profile=$script:MigrationProfile;BatchRoot=$Target;Installations=@();State='Prepared';Steps=@();IncludedChatData=@($Chats);VerifyHash=$Hash;RootId=$RootId
        InventoryFile=('move-inventory-'+$moveId+'.tsv');InventorySha256='';EntryCount=[long]0;TotalBytes=[long]0
        ActiveAt=''; InventoryVersion=1; PreviousInventory=$null; InitialAllowedLinks=@{}; InitialExcluded=@()
        SkippedLinks=[long]0; ChangedAfterMove=[long]0; MissingAtDestination=[long]0; Issues=@(); Recognition=''
    }
}

function Assert-MoveRecord {
    param($Record,[switch]$ForRollback)
    if ($Record.Id -notmatch '^[0-9a-f]{32}$' -or $Record.Kind -notin @('KnownFolder','WeChat','QQ') -or
        $Record.UserSid -ne $script:MigrationSid -or $Record.Profile -ine $script:MigrationProfile -or
        $Record.InventoryFile -cnotmatch ('^move-inventory-'+$Record.Id+'(?:-v[2-9][0-9]*|-v1[0-9]+)?\.tsv$') -or
        ($Record.InventorySha256 -notmatch '^[0-9A-Fa-f]{64}$' -and $Record.State -ne 'Scanning') -or
        $Record.EntryCount -lt 0 -or $Record.TotalBytes -lt 0 -or -not $Record.RootId) { throw '搬家记录无效或不属于当前用户。' }
    if ($Record.State -eq 'CatchingUp') {
        $previous=Get-MigrationValue $Record @('PreviousInventory')
        if ($null -eq $previous -or $previous.InventoryFile -cnotmatch ('^move-inventory-'+$Record.Id+'(?:-v(?:[2-9][0-9]*|1[0-9]+))?\.tsv$') -or
            $previous.InventorySha256 -notmatch '^[0-9A-Fa-f]{64}$' -or $previous.EntryCount -lt 0 -or $previous.TotalBytes -lt 0) {throw '补充复制的记录无效，原件保留。'}
    }
    foreach ($name in @('Source','Destination','RetainedSource')) {
        if ((ConvertTo-CleanerCanonicalPath $Record.$name) -cne $Record.$name) {throw '搬家记录包含不规范的位置。'}
        if (Get-CleanerForbiddenReason -LiteralPath $Record.$name -Context $script:MigrationContext) {throw '搬家记录包含受保护的位置。'}
    }
    Assert-MigrationSeparation $Record.Source $Record.Destination
    if (Get-CleanerMigrationForbiddenReason $Record.Destination $script:MigrationContext) {throw '记录中的目标位于受保护的区域。'}
    # 还原只核对目标的记录路径，不要求数据盘在线；原件和待移除链接仍严格核实。
    if (-not $ForRollback) {Assert-MigrationTarget $Record.Destination 'MigrationDestination'}
    $retained=$Record.Source
    if ($Record.Kind -eq 'KnownFolder') {
        if (-not (Get-CleanerTargets).MigrationKnownFolders.ContainsKey($Record.Folder)) {throw '用户文件夹记录无效。'}
    }
    else {
        $retained=$Record.Source+'.cdrive-retained-'+$Record.Id
        $roots=@(Get-CleanerChatRoots -Context $script:MigrationContext -IncludeMissing)
        $authorized=@($roots | Where-Object {$_.App -eq $Record.Kind -and $_.Path -ieq $Record.Source}).Count -gt 0
        if (-not $authorized -and $null -ne $script:MoveDocument) {
            foreach ($old in $script:MoveDocument.Entries) {
                if ($old.Kind -eq 'KnownFolder' -and $old.Folder -eq 'Documents' -and $old.UserSid -eq $script:MigrationSid -and $old.State -in @('Active','Releasing','Released')) {
                    foreach ($name in (Get-CleanerTargets).MoveChats[$Record.Kind].Names) {
                        if ($Record.Source -ieq ($old.Source+'\'+$name)) {$authorized=$true}
                    }
                }
            }
        }
        if (-not $authorized -and (Get-MigrationValue $Record @('Recognition') '') -eq 'Marker' -and
            $Record.State -in @('SourceRetained','Active','Releasing','RollingBack','LinkRemoved')) {
            # 部分释放可能已删掉识别标记；原来确认过的根必须仍是同一保留目录。
            $kept=Get-MigrationExistingEntry $Record.RetainedSource
            if ($null -ne $kept) {$authorized=((Get-MoveEntryIdentity $Record.RetainedSource).FileId -eq $Record.RootId)}
            elseif ($Record.State -eq 'Releasing') {$authorized=$true} # 仅允许记录最终完成，不再删除其他路径。
        }
        if (-not $authorized -and $Record.State -ne 'Released') {throw '记录中的聊天原件不在已确认的存储位置内。'}
    }
    if ($Record.Source.Substring(0,2) -ine $script:MigrationContext.SystemDrive) {throw '记录中的原件不在原系统盘。'}
    if ($Record.RetainedSource -cne $retained -or $Record.State -notin @('Scanning','Prepared','Copying','Copied','CatchingUp','Verified','Switching','SourceRetained','Active','Releasing','Released','RollingBack','LinkRemoved','RolledBack')) {throw '搬家阶段或保留位置无效。'}
    $parent=$Record.Source.Substring(0,$Record.Source.LastIndexOf('\'))
    $check=Test-CleanerPathChain -LiteralPath $parent
    if (-not $check.IsSafe) {throw '原文件夹的上级位置已改变，已停止。'}
}

function Set-MoveState {
    param($Record,[string]$State,[string]$Manifest,$Document)
    $Record.State=$State
    if ($State -eq 'Active' -and -not (Get-MigrationValue $Record @('ActiveAt') '')) { $Record | Add-Member ActiveAt ([datetimeoffset]::UtcNow.ToString('o')) -Force }
    $Record.Steps=@($Record.Steps)+@([pscustomobject]@{Step=$State;At=[datetimeoffset]::Now.ToString('o')})
    # 清单只写固定数量的阶段信息；不把每个文件或每次进度写入清单。
    Save-MoveRecord $Record $Manifest $Document
}

function Assert-MoveDestinationSubset {
    param($Baseline,$Actual)
    $bf=Get-MoveForeignLinks $Baseline; $af=Get-MoveForeignLinks $Actual
    foreach ($name in $af.Keys) {if (-not $bf.ContainsKey($name) -or -not (Test-MoveLinkEqual $bf[$name] $af[$name])) {throw '文件夹内出现其他链接，已停止。'}}
    foreach ($name in $Actual.Files.Keys) {if(-not $Baseline.Files.ContainsKey($name)){throw '目标中出现其他文件，不能续传。'}}
    foreach ($name in $Actual.Directories.Keys) {if(-not $Baseline.Directories.ContainsKey($name)){throw '目标中出现其他文件夹，不能续传。'}}
    foreach ($name in $Actual.Links.Keys) {if(-not $Baseline.Links.ContainsKey($name) -or $Baseline.Links[$name] -ine $Actual.Links[$name]){throw '目标中出现其他链接，不能续传。'}}
}

function Assert-MoveInventoryMatch {
    param($Baseline,$Actual,[switch]$Identity,[switch]$AllowMissingLinks)
    Assert-MigrationInventoryMatch $Baseline $Actual -CheckTime
    foreach ($name in $Baseline.Files.Keys) {if($Baseline.Files[$name].Hash -and $Baseline.Files[$name].Hash -ine $Actual.Files[$name].Hash){throw '文件内容核对不一致，已停止。'}}
    if ($Identity) {
        foreach ($name in $Baseline.Files.Keys) {if($Baseline.Files[$name].FileId -and $Actual.Files[$name].FileId -and $Baseline.Files[$name].FileId -ne $Actual.Files[$name].FileId){throw '原文件被替换，已停止。'}}
        foreach ($name in $Baseline.Directories.Keys) {if($Baseline.Directories[$name] -and $Actual.Directories[$name] -and $Baseline.Directories[$name] -ne $Actual.Directories[$name]){throw '原文件夹被替换，已停止。'}}
    }
    $bf=Get-MoveForeignLinks $Baseline; $af=Get-MoveForeignLinks $Actual
    if ($af.Count -gt 0 -or -not $AllowMissingLinks) {
        if ($bf.Count -ne $af.Count) {throw '文件夹内的链接已改变。'}
        foreach ($name in $bf.Keys) {if (-not $af.ContainsKey($name) -or -not (Test-MoveLinkEqual $bf[$name] $af[$name])) {throw '文件夹内的链接已改变。'}}
    }
    if (-not $AllowMissingLinks -and $Baseline.Links.Count -ne $Actual.Links.Count) {throw '文件夹内的链接数已改变。'}
    foreach ($name in $Actual.Links.Keys) {if(-not $Baseline.Links.ContainsKey($name) -or $Actual.Links[$name] -ine $Baseline.Links[$name]){throw '文件夹内的链接位置已改变。'}}
}

function Get-MoveRollbackPlan {
    param($Record)
    if ($Record.State -in @('Releasing','Released')) {throw '原件已开始释放，不能自动还原；目标数据仍保留。'}
    if ($Record.Kind -eq 'KnownFolder') {return @('RestoreKnownFolder','KeepDestination')}
    return @('RemoveVerifiedJunction','RestoreRetainedName','KeepDestination')
}

function Set-MoveKnownFolder {
    param([string]$Name,[string]$Path)
    if ($script:MigrationContext.CurrentUserSid -ne $script:MigrationSid) {throw '当前账户不同，不能修改原用户的文件夹位置。'}
    $id=[guid](Get-CleanerTargets).MigrationKnownFolders[$Name]
    $native=Get-CleanerNativeType
    $code=$native::SHSetKnownFolderPath([ref]$id,0,[IntPtr]::Zero,$Path)
    if ($code -lt 0) {[Runtime.InteropServices.Marshal]::ThrowExceptionForHR($code)}
    $map=Get-CleanerKnownFolderMap -Context $script:MigrationContext
    if (-not $map.ContainsKey($Name) -or $map[$Name] -ine $Path) {throw '系统未确认新的文件夹位置，原件仍保留。'}
}

function Assert-MoveActive {
    param($Record,$Baseline,[switch]$Inventory,[switch]$AllowRunning)
    if (-not $AllowRunning) {Assert-MoveAppsClosed $Record}
    if ($Record.Kind -eq 'KnownFolder') {
        $map=Get-CleanerKnownFolderMap -Context $script:MigrationContext
        if (-not $map.ContainsKey($Record.Folder) -or $map[$Record.Folder] -ine $Record.Destination) {throw '新的文件夹位置尚未生效，不能释放原件。'}
    }
    else {$null=Get-MigrationVerifiedJunction $Record.Source $Record.Destination}
    foreach ($relative in $Baseline.Links.Keys) {$null=Get-MigrationVerifiedJunction ($Record.Destination+'\'+$relative) $Baseline.Links[$relative]}
    Assert-MigrationTarget $Record.Destination 'MigrationDestination'
    $decision=Get-MovePreflightDecision (Get-MoveVolumeFacts $Record.Destination 0 $false $true)
    if ($decision.Status -ne 'Done') {throw $decision.Reason}
    if ($Inventory) {
        $actual=Get-MoveInventory $Record.Destination -Hash:$Record.VerifyHash -AllowedLinks $Baseline.Links
        $assessment=Get-MoveReleaseAssessment $Baseline $actual $Record.ActiveAt
        $Record | Add-Member ChangedAfterMove $assessment.ChangedAfterMove -Force
        $Record | Add-Member MissingAtDestination $assessment.MissingAtDestination -Force
    }
}

function Invoke-MoveCopy {
    param($Record,$Baseline,[switch]$Resume,$PartialInventory=$null)
    Assert-MoveAppsClosed $Record
    # 若宿主被结束而 robocopy 仍在运行，禁止第二个复制进程同时写同一目标。
    $orphans=@(Get-CimInstance Win32_Process -Filter "Name='robocopy.exe'" -ErrorAction Stop | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($Record.Destination,[StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($orphans.Count) {throw '上次复制仍在进行，请等待复制结束后再继续；不会结束它。'}
    $partial=[pscustomobject]@{Files=@{};Directories=@{};Links=@{};ForeignLinks=@{}}
    if ($Resume) {
        if ($null -ne $PartialInventory) {$partial=$PartialInventory}
        else {$partial=Get-MoveInventory $Record.Destination -AllowedLinks $Baseline.Links}
        Assert-MoveDestinationSubset $Baseline $partial
    }
    [long]$copiedBytes=0
    foreach ($name in $partial.Files.Keys) {
        if ($partial.Files[$name].Length -eq $Baseline.Files[$name].Length -and $partial.Files[$name].WriteTicks -eq $Baseline.Files[$name].WriteTicks) {$copiedBytes+=$partial.Files[$name].Length}
    }
    $facts=Get-MoveVolumeFacts $Record.Destination ([math]::Max(0,$Baseline.Bytes-$copiedBytes)) ($partial.Files.Count+$partial.Directories.Count -gt 0) $true
    $facts.FreeBytes-=[math]::Ceiling([decimal]$copiedBytes/10)
    $decision=Get-MovePreflightDecision $facts
    if ($decision.Status -ne 'Done') {$ex=[InvalidOperationException]::new($decision.Reason);$ex.Data['MoveStatus']=$decision.Status;throw $ex}
    $progress=@{Last=[datetime]::MinValue;Files=[long]0;Bytes=[long]0;Errors=[Collections.Generic.List[string]]::new()}
    $line={param($text)
        if ($text -match '(?i)\bERROR\s+\d+|错误\s*\d+') {if ($progress.Errors.Count -lt 20) {$progress.Errors.Add($text)}}
        if ($text -match '\s(\d+)\s+([A-Za-z]:\\.*)$') {$progress.Files++;$progress.Bytes+=[long]$matches[1]}
    }.GetNewClosure()
    $tick={Write-MoveProgress '复制（本次）' $progress.Files $progress.Bytes $progress}.GetNewClosure()
    $arguments=@($Record.Source,$Record.Destination,'/E','/COPY:DAT','/DCOPY:DAT','/R:1','/W:1','/XJ','/XJD','/XJF','/BYTES','/FP','/NP','/NDL','/NJH','/NJS','/UNICODE')
    if ($Baseline.Excluded.Count) {
        $arguments+='/XD'
        foreach ($relative in $Baseline.Excluded) {$arguments+=($Record.Source+'\'+$relative)}
    }
    $skipped=@((Get-MoveForeignLinks $Baseline).Keys)
    if ($skipped.Count) {
        $arguments+='/XD'; foreach ($name in $skipped) {$arguments+=($Record.Source+'\'+$name)}
        $arguments+='/XF'; foreach ($name in $skipped) {$arguments+=($Record.Source+'\'+$name)}
    }
    $sourceGuards=$null;$targetGuards=$null
    try {
    $sourceGuards=Open-CleanerParentGuards -LiteralPath ($Record.Source+'\.pc-care-copy-guard')
    $targetGuards=Open-CleanerParentGuards -LiteralPath ($Record.Destination+'\.pc-care-copy-guard')
    try { $copy=Invoke-External -FilePath robocopy.exe -ArgumentList $arguments -Description '复制资料，保留原件' -SuccessExitCodes @(0,1,2,3,4,5,6,7) -OutputEncoding ([Text.Encoding]::Unicode) -OutputLine $line -ProgressCallback $tick -Confirm:$false }
    catch {
        if ($_.Exception.Data.Contains('ExternalResult')) {throw (Get-MoveCopyFailureReason $progress.Errors)}
        throw
    }
    if ($null -eq $copy.ExitCode -or $copy.ExitCode -ge 8) {throw (Get-MoveCopyFailureReason $progress.Errors)}
    Write-MoveProgress '复制（本次）' $progress.Files $progress.Bytes $progress -Force
    } finally {foreach($group in @($sourceGuards,$targetGuards)){if($null -ne $group){foreach($h in $group.Handles){$h.Dispose()}}}}
}

function Invoke-MoveSwitch {
    param($Record,$Baseline,[string]$Manifest,$Document)
    Assert-MoveAppsClosed $Record
    if ($Record.Kind -eq 'KnownFolder') {
        $map=Get-CleanerKnownFolderMap -Context $script:MigrationContext
        if ($map[$Record.Folder] -in @($Record.Source,$Record.Destination)) {
            Set-MoveState $Record 'Switching' $Manifest $Document
            Set-MoveKnownFolder $Record.Folder $Record.Destination
            # /XJ 跳过的已搬家聊天目录，在新文档目录恢复同一个链接。
            foreach ($relative in $Baseline.Links.Keys) {
                $path=$Record.Destination+'\'+$relative
                if ($null -eq (Get-MigrationExistingEntry $path)) {
                    # 受约束的专用创建器；不扩大 common 的缓存联接权限。
                    New-MovePreservedJunction $path $Baseline.Links[$relative]
                }
                $null=Get-MigrationVerifiedJunction $path $Baseline.Links[$relative]
            }
        }
        else {throw '系统中的文件夹位置被其他程序修改，已停止。'}
    }
    else {
        if ($Record.State -eq 'Verified') {Set-MoveState $Record 'Switching' $Manifest $Document}
        $sourceItem=Get-MigrationExistingEntry $Record.Source
        if ($null -ne $sourceItem -and ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            if (Test-Path -LiteralPath $Record.RetainedSource) {throw '保留位置已有文件，已停止。'}
            if ((Get-MoveEntryIdentity $Record.Source).FileId -ne $Record.RootId) {throw '原文件夹已被替换，已停止。'}
            Assert-MigrationTarget $Record.Source 'MoveChat'
            Assert-MigrationTarget $Record.RetainedSource 'MoveChatBackup'
            Move-MoveDirectory $Record.Source $Record.RetainedSource
        }
        if (-not (Test-Path -LiteralPath $Record.RetainedSource -PathType Container)) {throw '未找到保留的原件，已停止。'}
        Set-MoveState $Record 'SourceRetained' $Manifest $Document
        if ($null -eq (Get-MigrationExistingEntry $Record.Source)) {
            $null=Invoke-External -FilePath cmd.exe -ArgumentList @('/d','/v:off','/c','mklink','/J',$Record.Source,$Record.Destination) -JunctionCategory MoveChat -Description '让聊天软件使用新位置' -Confirm:$false
        }
        $null=Get-MigrationVerifiedJunction $Record.Source $Record.Destination
        # 通过原路径读取关键文件；验证链接最终到达正确文件，且数据可读。
        Test-MoveChatReadable $Record $Baseline
    }
    Assert-MoveActive $Record $Baseline
    Set-MoveState $Record 'Active' $Manifest $Document
}

function New-MovePreservedJunction {
    param([string]$Path,[string]$Target)
    # 仅供已校验库存的 J 项使用。New-Item -Junction 不经过命令解释器。
    $check=Test-CleanerPathChain -LiteralPath $Path -AllowMissing
    if (-not $check.IsSafe -or $check.Exists) {throw '新位置无法恢复聊天文件的链接。'}
    Assert-MigrationTarget $Target 'MigrationDestination'
    $null=New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop
}

function Test-MoveChatReadable {
    param($Record,$Baseline)
    $keys=@($Baseline.Files.Keys | Where-Object {$_ -match '(?i)(\.db$|\.dat$|\.ini$|\.json$)'} | Select-Object -First 8)
    if (-not $keys.Count) {$keys=@($Baseline.Files.Keys | Select-Object -First 1)}
    foreach ($relative in $keys) {
        $path=$Record.Source+'\'+$relative; $stream=[IO.File]::OpenRead($path)
        try {
            if ((Get-CleanerFinalHandlePath $stream.SafeFileHandle) -ine ($Record.Destination+'\'+$relative)) {throw '聊天文件没有指向新位置。'}
            $null=$stream.ReadByte()
        }
        finally {$stream.Dispose()}
    }
}

function Remove-MoveVerifiedJunction {
    param([string]$Path,[string]$Target)
    $expected=Get-MoveLinkMetadata $Path
    $text=$expected.Target
    if ($text.StartsWith(('\'+[char]63+[char]63+'\'))) {$text=$text.Substring(4)}
    if ($expected.Tag -ne 'A0000003' -or $text.TrimEnd('\') -ine $Target) {throw '原位置的链接已改变，已停止。'}
    # 第二次打开独占、不跟随的删除句柄，重读同一目标；只删除链接本身。
    Remove-MoveForeignLink $Path $expected
}

function Invoke-MoveRollback {
    param($Record,$Baseline,[string]$Manifest,$Document)
    $null=Get-MoveRollbackPlan $Record
    Assert-MoveAppsClosed $Record
    foreach ($other in $Document.Entries) {
        if ($other.Id -ne $Record.Id -and $other.Kind -eq 'KnownFolder' -and $other.State -in @('Active','Releasing','Released') -and (Test-MoveWithin $Record.Source $other.Source)) {throw '请先还原包含这些聊天文件的文档搬家，再还原聊天文件。'}
    }
    Set-MoveState $Record 'RollingBack' $Manifest $Document
    if ($Record.Kind -eq 'KnownFolder') {
        if ((Get-MoveEntryIdentity $Record.Source).FileId -ne $Record.RootId) {throw '保留的原文件夹已改变，不能自动还原。'}
        $map=Get-CleanerKnownFolderMap -Context $script:MigrationContext
        if ($map[$Record.Folder] -notin @($Record.Source,$Record.Destination)) {throw '文件夹位置被其他程序修改，不能自动还原。'}
        Set-MoveKnownFolder $Record.Folder $Record.Source
    }
    else {
        $source=Get-MigrationExistingEntry $Record.Source
        $retained=Get-MigrationExistingEntry $Record.RetainedSource
        if ($null -ne $source -and ($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            if ($null -eq $retained -or (Get-MoveEntryIdentity $Record.RetainedSource).FileId -ne $Record.RootId) {throw '保留的原件无法核实，不能自动还原。'}
            Remove-MoveVerifiedJunction $Record.Source $Record.Destination
            Set-MoveState $Record 'LinkRemoved' $Manifest $Document; $source=$null
        }
        if ($null -eq $source -and $null -ne $retained) {
            if ((Get-MoveEntryIdentity $Record.RetainedSource).FileId -ne $Record.RootId) {throw '保留的原件已改变，已停止。'}
            Move-MoveDirectory $Record.RetainedSource $Record.Source
        }
        elseif ($null -eq $source -or (Get-MoveEntryIdentity $Record.Source).FileId -ne $Record.RootId) {throw '原文件夹已被替换，已停止。'}
    }
    Set-MoveState $Record 'RolledBack' $Manifest $Document
}

function Remove-MoveRetainedLeaf {
    param([string]$Path,$Expected,[bool]$Directory,[bool]$Hash,[scriptblock]$Checkpoint)
    # Reviewed equivalent to Remove-CleanerLeaf: migration-only 类别不能交给通用删除器。
    # 授权范围/库存在外层每操作校验一次；这里仅做常数次、同句柄的身份/路径/大小/时间检查。
    $guards=$null;$handle=$null;$stream=$null;$memory=[IntPtr]::Zero;$native=Get-CleanerNativeType
    try {
        $guards=Open-CleanerParentGuards -LiteralPath $Path
        $handle=$native::CreateFileW($Path,0x10081,0,[IntPtr]::Zero,3,0x02300000,[IntPtr]::Zero)
        if ($handle.IsInvalid) {throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())}
        $metadata=Get-CleanerHandleMetadata $handle
        if ((Get-CleanerFinalHandlePath $handle) -ine $Path -or $metadata.IsDirectory -ne $Directory -or ($Expected.FileId -and $metadata.FileId -ne $Expected.FileId)) {throw '保留的原件被替换，已停止释放。'}
        if (-not $Directory -and ($metadata.LogicalBytes -ne $Expected.Length -or $metadata.LastWriteTimeUtc.Ticks -ne $Expected.WriteTicks)) {throw '保留的原文件已修改，已停止释放。'}
        if ($Hash -and -not $Directory) {
            # 读取与删除使用同一个独占句柄，防止核对后文件被换掉。
            $stream=[IO.FileStream]::new($handle,[IO.FileAccess]::Read)
            $digest=Get-MoveStreamHash $stream $Checkpoint
            if ($digest -ine $Expected.Hash) {throw '保留的原文件内容已修改，已停止释放。'}
            # FileStream 在 finally 中才关闭；句柄在标记删除前仍有效。
        }
        $memory=[Runtime.InteropServices.Marshal]::AllocHGlobal(1);[Runtime.InteropServices.Marshal]::WriteByte($memory,0,1)
        if (-not $native::SetFileInformationByHandle($handle,4,$memory,1)) {throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())}
    }
    finally {
        if ($memory -ne [IntPtr]::Zero) {[Runtime.InteropServices.Marshal]::FreeHGlobal($memory)}
        if ($null -ne $stream) {$stream.Dispose()}
        if ($null -ne $handle) {$handle.Dispose()}
        if ($null -ne $guards) {foreach($guard in $guards.Handles){$guard.Dispose()}}
    }
}

function Invoke-MoveReleaseLoop {
    param($Record,$Baseline,[scriptblock]$CheckActive,[scriptblock]$DeleteFile,[scriptblock]$UtcNow={ [datetime]::UtcNow })
    $null=& $CheckActive $Record $Baseline
    $last=& $UtcNow;[long]$done=0;[long]$bytes=0;$clock=@{Last=[datetime]::MinValue}
    foreach ($relative in $Baseline.Files.Keys) {
        $null=& $DeleteFile ($Record.RetainedSource+'\'+$relative) $Baseline.Files[$relative] $Record.VerifyHash
        $done++;$bytes+=$Baseline.Files[$relative].Length
        Write-MoveProgress '释放原件' $done $bytes $clock
        $now=& $UtcNow
        if (($done % 1000) -eq 0 -or ($now-$last).TotalSeconds -ge 30) {$null=& $CheckActive $Record $Baseline;$last=$now}
    }
    $null=& $CheckActive $Record $Baseline
    Write-MoveProgress '释放原件' $done $bytes $clock -Force
}

function Invoke-MoveRelease {
    param($Record,$Baseline,[string]$Manifest,$Document)
    if ($Record.State -notin @('Active','Releasing')) {throw '搬家尚未核实完成，不能释放原件。'}
    Assert-MoveActive $Record $Baseline -Inventory
    if ($Record.State -eq 'Releasing' -and $null -eq (Get-MigrationExistingEntry $Record.RetainedSource)) {Set-MoveState $Record 'Released' $Manifest $Document;return}
    if ((Get-MoveEntryIdentity $Record.RetainedSource).FileId -ne $Record.RootId) {throw '保留的原文件夹被替换，不能释放。'}
    $retainedGuards=Open-CleanerParentGuards -LiteralPath ($Record.RetainedSource+'\.pc-care-release-guard')
    try {
    # 整体核对一次，不在每个文件里重新转换或扫描库存。续跑只允许缺少已释放项。
    $remaining=Get-MoveInventory $Record.RetainedSource -Hash:$Record.VerifyHash -AllowedLinks $Baseline.Links -Excluded $Baseline.Excluded
    $extras=@($remaining.Files.Keys | Where-Object {-not $Baseline.Files.ContainsKey($_)} | Select-Object -First 5)
    if ($extras.Count) {throw ('原位置多了这些文件，为了安全没有删除原件：'+($extras -join '、'))}
    Assert-MoveDestinationSubset $Baseline $remaining
    if ($Record.State -eq 'Active') {Assert-MoveInventoryMatch $Baseline $remaining -Identity}
    foreach ($name in $remaining.Files.Keys) {
        $a=$Baseline.Files[$name];$b=$remaining.Files[$name]
        if (($a.FileId -and $b.FileId -and $a.FileId -ne $b.FileId) -or $a.Length -ne $b.Length -or $a.WriteTicks -ne $b.WriteTicks -or $a.Hash -ne $b.Hash) {throw '保留的原文件已改变，不能释放。'}
    }
    foreach ($name in $remaining.Directories.Keys) {if($Baseline.Directories[$name] -and $remaining.Directories[$name] -and $Baseline.Directories[$name] -ne $remaining.Directories[$name]){throw '保留的原文件夹被替换，不能释放。'}}
    foreach ($relative in $Baseline.Excluded) {if(Test-Path -LiteralPath ($Record.RetainedSource+'\'+$relative)){throw '文档内还有聊天搬家的原件，请先确认并释放那次聊天搬家。'}}
    Set-MoveState $Record 'Releasing' $Manifest $Document
    $check={param($r,$b) Assert-MoveActive $r $b}
    $delete={param($path,$expected,$hash)
        # 中断释放可重跑；缺失叶节点不等同于授权其他路径。
        if ($null -ne (Get-MigrationExistingEntry $path)) {Remove-MoveRetainedLeaf $path $expected $false $hash -Checkpoint {Assert-MoveActive $Record $Baseline}}
    }
    Invoke-MoveReleaseLoop $Record $Baseline $check $delete
    foreach ($relative in $Baseline.Links.Keys) {
        $path=$Record.RetainedSource+'\'+$relative
        if ($null -ne (Get-MigrationExistingEntry $path)) {Remove-MoveVerifiedJunction $path $Baseline.Links[$relative]}
    }
    foreach ($relative in (Get-MoveForeignLinks $Baseline).Keys) {
        $path=$Record.RetainedSource+'\'+$relative
        if ($null -ne (Get-MigrationExistingEntry $path)) {Remove-MoveForeignLink $path (Get-MoveForeignLinks $Baseline)[$relative]}
    }
    # 深度排序一次，绝不为每个目录重新扫描整份库存。
    $lastCheck=[datetime]::UtcNow;$directoryCount=0;$releaseClock=@{Last=[datetime]::MinValue}
    foreach ($relative in @($Baseline.Directories.Keys | Sort-Object Length -Descending)) {
        $path=$Record.RetainedSource+'\'+$relative
        if ($null -ne (Get-MigrationExistingEntry $path)) {Remove-MoveRetainedLeaf $path @{FileId=$Baseline.Directories[$relative]} $true $false}
        $directoryCount++
        Write-MoveProgress '释放原件（整理文件夹）' $Baseline.FileCount $Baseline.Bytes $releaseClock
        if (($directoryCount % 1000) -eq 0 -or ([datetime]::UtcNow-$lastCheck).TotalSeconds -ge 30) {Assert-MoveActive $Record $Baseline;$lastCheck=[datetime]::UtcNow}
    }
    Assert-MoveActive $Record $Baseline
    } finally {if($null -ne $retainedGuards){foreach($h in $retainedGuards.Handles){$h.Dispose()}}}
    Remove-MoveRetainedLeaf $Record.RetainedSource @{FileId=$Record.RootId} $true $false
    Set-MoveState $Record 'Released' $Manifest $Document
}

function Invoke-MoveRecord {
    param($Record,[string]$Manifest,$Document,[string]$Operation)
    $script:MoveCurrentRecord=$Record
    Assert-MoveRecord $Record -ForRollback:($Operation -eq 'Rollback')
    if ($WhatIfPreference) {return New-MoveResult 'Done' 'WhatIf' '仅预览，没有修改任何内容。' $Record}
    if (Test-MoveBackground) {return Start-MoveWorker $Record $Manifest $Operation}
    $script:MoveStep=$Operation
    if ($Record.State -eq 'Scanning' -and $Operation -eq 'Rollback') {
        Set-MoveState $Record RolledBack $Manifest $Document
        return New-MoveResult Done RolledBack '尚未复制，原位置保留。' $Record
    }
    if ($Record.State -eq 'Scanning') {
        Assert-MoveAppsClosed $Record
        $script:MoveStep='Inventory'
        if ((Get-MoveEntryIdentity $Record.Source).FileId -ne $Record.RootId) {throw '原文件夹已被替换，已停止。'}
        $baseline=Get-MoveInventory $Record.Source -Hash:$Record.VerifyHash -AllowedLinks $Record.InitialAllowedLinks -Excluded $Record.InitialExcluded
        $decision=Get-MovePreflightDecision (Get-MoveVolumeFacts $Record.Destination $baseline.Bytes $false $false)
        if ($decision.Status -ne 'Done') {throw $decision.Reason}
        Write-MoveNextInventory $Manifest $Record $baseline
        Set-MoveState $Record Prepared $Manifest $Document
    }
    else {$baseline=Read-MoveInventory $Manifest $Record}
    $Record | Add-Member SkippedLinks ([long](Get-MoveForeignLinks $baseline).Count) -Force
    Set-MoveProgressTotals $Record $baseline
    if ($Operation -ne 'Rollback') {
        $volumeCheck=Get-MovePreflightDecision (Get-MoveVolumeFacts $Record.Destination 0 $false $true)
        if ($volumeCheck.Status -ne 'Done') {$ex=[InvalidOperationException]::new($volumeCheck.Reason);$ex.Data['MoveStatus']=$volumeCheck.Status;throw $ex}
    }
    if ($Operation -eq 'Release' -and $Record.State -eq 'Released') {return New-MoveResult Done Released '本次保留的原件已释放。' $Record}
    $parents=Open-CleanerParentGuards -LiteralPath $Record.Source
    try {
        if ($Operation -eq 'Release') {$script:MoveStep='ReleaseSource';Invoke-MoveRelease $Record $baseline $Manifest $Document}
        elseif ($Operation -eq 'Rollback') {Invoke-MoveRollback $Record $baseline $Manifest $Document}
        else {
            if ($Record.State -in @('Active','Released')) {Assert-MoveActive $Record $baseline -AllowRunning;return New-MoveResult AlreadyMoved Active '本次搬家已完成。' $Record}
            $rounds=0; $verifiedNow=$false; $copyPartial=$null
            while ($Record.State -in @('Prepared','Copying','Copied','CatchingUp')) {
                if ($Record.State -eq 'CatchingUp') {
                    $copyPartial=Complete-MoveCatchup $Record $baseline $Manifest $Document
                }
                if ($Record.State -in @('Prepared','Copying')) {
                    $resumeCopy=($Record.State -eq 'Copying');$partial=$copyPartial;$copyPartial=$null
                    $script:MoveStep='Copying'
                    if ($resumeCopy -and $null -eq $partial) {
                        # 掉电时可能已复制了源中新加的文件；先更新基准，不能把这些文件误判为外来文件。
                        $current=Get-MoveInventory $Record.Source -Hash:$Record.VerifyHash -AllowedLinks $baseline.Links -Excluded $baseline.Excluded
                        $partial=Get-MoveInventory $Record.Destination -Hash:$Record.VerifyHash -AllowedLinks $baseline.Links
                        if (-not (Test-MoveInventoryEqual $baseline $current)) {
                            Assert-MoveAppsClosed $Record
                            if ($rounds -ge 3) {throw '这个文件夹一直有文件在变化。请暂时不要修改其中的文件，稍后重新运行即可继续。'}
                            $rounds++;$baseline=Set-MoveCatchupBaseline $Record $current $Manifest $Document
                            $copyPartial=Complete-MoveCatchup $Record $baseline $Manifest $Document $partial
                            continue
                        }
                    }
                    $script:MoveStep='Copying';Set-MoveState $Record Copying $Manifest $Document
                    $null=New-MigrationDirectory $Record.Destination
                    Invoke-MoveCopy $Record $baseline -Resume:$resumeCopy -PartialInventory $partial
                    Set-MoveState $Record Copied $Manifest $Document
                }
                $script:MoveStep='Verifying'
                $source=Get-MoveInventory $Record.Source -Hash:$Record.VerifyHash -AllowedLinks $baseline.Links -Excluded $baseline.Excluded
                $target=Get-MoveInventory $Record.Destination -Hash:$Record.VerifyHash -AllowedLinks $baseline.Links
                if (-not (Test-MoveInventoryEqual $baseline $source)) {
                    Assert-MoveAppsClosed $Record
                    if ($rounds -ge 3) {throw '这个文件夹一直有文件在变化。请暂时不要修改其中的文件，稍后重新运行即可继续。'}
                    $rounds++
                    $baseline=Set-MoveCatchupBaseline $Record $source $Manifest $Document
                    $copyPartial=Complete-MoveCatchup $Record $baseline $Manifest $Document $target
                    continue
                }
                Assert-MoveInventoryMatch $baseline $target -AllowMissingLinks
                Set-MoveState $Record Verified $Manifest $Document
                $verifiedNow=$true
            }
            if ($Record.State -notin @('Verified','Switching','SourceRetained')) {throw '本次记录不能继续搬家，请先还原。'}
            $script:MoveStep='Switching'
            if (-not $verifiedNow) {
                $target=Get-MoveInventory $Record.Destination -Hash:$Record.VerifyHash -AllowedLinks $baseline.Links
                Assert-MoveInventoryMatch $baseline $target -AllowMissingLinks
                $retained=$Record.Source
                if ($Record.State -in @('Switching','SourceRetained') -and (Test-Path -LiteralPath $Record.RetainedSource)) {$retained=$Record.RetainedSource}
                $source=Get-MoveInventory $retained -Hash:$Record.VerifyHash -AllowedLinks $baseline.Links -Excluded $baseline.Excluded
                Assert-MoveInventoryMatch $baseline $source -Identity
            }
            if ($Record.State -eq 'Verified' -and (Get-MoveEntryIdentity $Record.Source).FileId -ne $Record.RootId) {throw '原文件夹已被替换，已停止。'}
            Invoke-MoveSwitch $Record $baseline $Manifest $Document
        }
        $reason='';if($Operation -eq 'Rollback'){$reason='已还原原位置；新位置的副本及搬家后新增的文件仍保留，请继续保管。'}
        $result=New-MoveResult Done $Record.State $reason $Record
        $details=@(foreach ($name in (Get-MoveForeignLinks $baseline).Keys) {[pscustomobject]@{RelativePath=$name;Link=(Get-MoveForeignLinks $baseline)[$name]}})
        $result | Add-Member SkippedLinkDetails $details
        return $result
    } finally {if($null -ne $parents){foreach($h in $parents.Handles){$h.Dispose()}}}
}

function Get-MoveVolumeFacts {
    param([string]$Path,[long]$Bytes,[bool]$NonEmpty,[bool]$Resume)
    $drive=[IO.DriveInfo]::new($Path.Substring(0,3))
    $volumeId=Get-MoveVolumeIdentity $Path.Substring(0,3)
    $systemId=Get-MoveVolumeIdentity ($script:MigrationContext.SystemDrive+'\')
    return @{
        AlreadyMoved=$false;OneDrive=$false;RunningApps=@();IsFixed=($drive.IsReady -and $drive.DriveType -eq [IO.DriveType]::Fixed)
        FileSystem=$drive.DriveFormat;IsLocal=($Path -match '^[A-Za-z]:\\');SystemVolume=($volumeId -ieq $systemId -or $Path.Substring(0,2) -in @($script:MigrationContext.SystemDrive,'C:'))
        Forbidden=[bool](Get-CleanerMigrationForbiddenReason $Path $script:MigrationContext);NonEmpty=$NonEmpty;Resume=$Resume;Bytes=$Bytes;FreeBytes=$drive.AvailableFreeSpace
    }
}

function Get-MoveVolumeIdentity {
    param([string]$Root)
    $native=Get-CleanerNativeType;$buffer=[Text.StringBuilder]::new(128)
    if (-not $native::GetVolumeNameForVolumeMountPointW($Root,$buffer,[uint32]$buffer.Capacity)) {throw '无法核实目标磁盘的实际位置，已停止。'}
    return $buffer.ToString()
}

function Invoke-MoveNew {
    param([string]$MoveKind,[string]$FolderName,[string]$Target,[string]$Manifest,$Document,[bool]$Hash,[string]$SelectedSource,[string]$BatchRoot)
    if (($MoveKind -ne 'KnownFolder' -and $FolderName) -or $MoveKind -notin @('KnownFolder','WeChat','QQ') -or -not $Target -or ($MoveKind -eq 'KnownFolder' -and -not $FolderName)) {throw '请提供要搬家的文件夹和目标位置。'}
    $Target=ConvertTo-CleanerCanonicalPath $Target
    $matching=@($Document.Entries | Where-Object {$_.Kind -eq $MoveKind -and $_.Folder -eq $FolderName -and $_.Destination -ieq $Target -and $_.State -ne 'RolledBack'})
    if ($matching.Count -eq 1) {return Invoke-MoveRecord $matching[0] $Manifest $Document 'Move'}
    $folders=Get-CleanerKnownFolderMap -Context $script:MigrationContext
    $issues=[Collections.Generic.List[string]]::new()
    $chats=@(Get-CleanerChatRoots -Context $script:MigrationContext -KnownFolders $folders -Issues $issues)
    $included=@();$allowedLinks=@{};$excluded=[Collections.Generic.List[string]]::new()
    if ($MoveKind -eq 'KnownFolder') {
        if (-not $folders.ContainsKey($FolderName)) {throw '无法读取这个用户文件夹的位置。'}
        $source=$folders[$FolderName]
        foreach ($root in $script:MigrationContext.SyncRoots) {if(Test-MoveWithin $source $root){return New-MoveResult 'Failed' 'Preflight' '这个文件夹由 OneDrive 或其他同步软件管理，请在同步软件中调整位置。'}}
        if ($source -match '(?i)\\OneDrive(?: - [^\\]+)?(?:\\|$)') {return New-MoveResult 'Failed' 'Preflight' '这个文件夹由 OneDrive 管理，请在 OneDrive 中调整位置。'}
        $included=@(Get-MoveIncludedChats $source $chats)
        foreach ($other in $Document.Entries) {
            if ($other.Kind -ne 'KnownFolder' -and $other.State -in @('Active','Released') -and (Test-MoveWithin $other.Source $source)) {
                Assert-MoveRecord $other
                $null=Get-MigrationVerifiedJunction $other.Source $other.Destination
                $relative=$other.Source.Substring($source.Length+1);$allowedLinks[$relative]=$other.Destination
                if ($other.State -eq 'Active') {$excluded.Add($other.RetainedSource.Substring($source.Length+1))}
                if ($other.Kind -notin $included) {$included+= $other.Kind}
            }
        }
    }
    else {
        # 优先检查保留的旧 Documents，避免同一份聊天数据搬第二次。
        foreach ($old in $Document.Entries) {
            if ($old.Kind -eq 'KnownFolder' -and $old.State -in @('Active','Releasing','Released') -and $MoveKind -in $old.IncludedChatData -and
                @($chats | Where-Object {$_.App -eq $MoveKind -and -not (Test-MoveWithin $_.Path $old.Source) -and -not (Test-MoveWithin $_.Path $old.Destination)}).Count -eq 0) {
                Assert-MoveRecord $old
                $baseline=Read-MoveInventory $Manifest $old
                Assert-MoveActive $old $baseline -AllowRunning
                return New-MoveResult 'AlreadyMoved' 'Preflight' '这些聊天文件已随用户文件夹一起搬家，原件仍按那次记录保留。' $old
            }
        }
        $roots=@($chats | Where-Object {$_.App -eq $MoveKind})
        if (-not $roots.Count) {
            $reason='没有找到能可靠确认的聊天文件位置。';if($issues.Count){$reason=$issues[0]}
            $result=New-MoveResult Failed Preflight $reason;$result.Issues=$issues.ToArray();return $result
        }
        # 多版本并存时，每个准确数据根有独立记录，逐项处理。
        $candidates=@($roots | Where-Object { $_.Path.StartsWith($script:MigrationContext.SystemDrive+'\',[StringComparison]::OrdinalIgnoreCase) })
        if (-not $candidates.Count) {return New-MoveResult 'AlreadyMoved' 'Preflight' '聊天文件已经位于其他磁盘。'}
        $batchRecords=@($Document.Entries | Where-Object {$_.Kind -eq $MoveKind -and (Get-MigrationValue $_ @('BatchRoot') '') -ieq $Target -and $_.Destination -ine $Target -and $_.State -ne 'RolledBack'})
        if (-not $SelectedSource -and ($candidates.Count -gt 1 -or $batchRecords.Count)) {
            return Invoke-MoveChatBatch $MoveKind $candidates $Target $Manifest $Document $Hash
        }
        if ($SelectedSource) {
            if ($SelectedSource -notin $candidates.Path) {throw '本次聊天位置已改变，已停止。'}
            $source=$SelectedSource
        }
        else {$source=$candidates[0].Path}

    }
    # 相同指令恢复同一记录，不能把目标已有副本当作新搬家覆盖。
    $existing=@($Document.Entries | Where-Object {$_.Kind -eq $MoveKind -and $_.Folder -eq $FolderName -and $_.Destination -ieq $Target -and $_.State -ne 'RolledBack'})
    if ($existing.Count -gt 1) {throw '有多条相同搬家记录，请指定本次 Id。'}
    if ($existing.Count -eq 1) {return Invoke-MoveRecord $existing[0] $Manifest $Document 'Move'}
    $pending=Find-MovePendingOverlap $source $Document.Entries
    if ($null -ne $pending) {
        $snapshot=Read-MoveStatus (Get-MoveStatusPath $Manifest $pending.Id)
        $result=Get-MoveStatusResult $snapshot $pending
        $result.Reason='相关文件夹还有一次未完成的搬家，请先完成那次处理，再继续当前搬家。'
        if ($result.Status -ne 'Running') {
            $result.Status='Stalled';$resume='-ResumeId '
            if($pending.State -eq 'Releasing'){$resume='-ReleaseSource -Id '}
            elseif($pending.State -in @('RollingBack','LinkRemoved')){$resume='-Rollback -Id '}
            $result.NextAction='先运行 '+$resume+$pending.Id+' 继续那次处理，完成后再执行当前搬家'
        }
        return $result
    }
    $entry=Get-MigrationExistingEntry $source
    if ($null -eq $entry) {throw '原文件夹不存在。'}
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {return New-MoveResult 'AlreadyMoved' 'Preflight' '这个文件夹已指向其他位置，不会重复搬家。'}
    if (-not $source.StartsWith($script:MigrationContext.SystemDrive+'\',[StringComparison]::OrdinalIgnoreCase)) {return New-MoveResult 'AlreadyMoved' 'Preflight' '这个文件夹已经位于数据盘。'}
    Assert-MigrationSeparation $source $Target
    $category='MoveChat';if($MoveKind -eq 'KnownFolder'){$category='UserFolder'}
    Assert-MigrationTarget $source $category
    Assert-MigrationTarget $Target 'MigrationDestination'
    $record=New-MoveRecord $MoveKind $FolderName $source $Target $included $Hash (Get-MoveEntryIdentity $source).FileId
    if ($BatchRoot) {$record.BatchRoot=$BatchRoot}
    $record.Installations=@(Get-MoveAppInstallations $script:MigrationContext)
    $script:MoveCurrentRecord=$record
    Assert-MoveAppsClosed $record
    $record.State='Scanning';$record.InitialAllowedLinks=$allowedLinks;$record.InitialExcluded=$excluded.ToArray();$record.Issues=$issues.ToArray()
    if ($MoveKind -ne 'KnownFolder') {$record.Recognition=Get-MigrationValue ($chats | Where-Object {$_.Path -ieq $source} | Select-Object -First 1) @('Recognition') 'Default'}
    $destinationEntry=Get-MigrationExistingEntry $Target
    if ($null -ne $destinationEntry -and -not $destinationEntry.PSIsContainer) {throw '目标位置是文件，请选择空文件夹。'}
    $nonEmpty=($null -ne (Get-MigrationExistingEntry $Target) -and (Test-MoveDestinationNonEmpty $Target))
    $decision=Get-MovePreflightDecision (Get-MoveVolumeFacts $Target 0 $nonEmpty $false)
    if ($decision.Status -ne 'Done') {return $decision}
    if ($WhatIfPreference) {return New-MoveResult 'Done' 'WhatIf' '仅预览，没有修改任何内容。' $record}
    $Document.Entries=@($Document.Entries)+@($record)
    Set-MoveState $record 'Scanning' $Manifest $Document
    Invoke-MoveRecord $record $Manifest $Document 'Move'
}

function Find-MovePendingOverlap {
    param([string]$Source,[object[]]$Records)
    foreach ($record in $Records) {
        if ($record.State -notin @('Active','Released','RolledBack') -and
            ((Test-MoveWithin $Source $record.Source) -or (Test-MoveWithin $record.Source $Source))) {return $record}
    }
    return $null
}

function Get-MoveChatPlan {
    param([object[]]$Roots,[string]$Target)
    $seen=@{};$used=@{}
    foreach ($root in @($Roots | Sort-Object Path)) {
        if ($seen.ContainsKey($root.Path)) {continue};$seen[$root.Path]=$true
        $name=$root.Path.Substring($root.Path.LastIndexOf('\')+1);$leaf=$name;$i=1
        while ($used.ContainsKey($leaf)) {$i++;$leaf=$name+'-'+$i}
        $used[$leaf]=$true
        [pscustomobject]@{Source=$root.Path;Destination=$Target+'\'+$leaf}
    }
}

function Invoke-MoveChatBatch {
    param([string]$MoveKind,[object[]]$Roots,[string]$Target,[string]$Manifest,$Document,[bool]$Hash)
    $all=[Collections.Generic.List[object]]::new()
    foreach ($root in $Roots) {$all.Add($root)}
    $records=@($Document.Entries | Where-Object {$_.Kind -eq $MoveKind -and (Get-MigrationValue $_ @('BatchRoot') '') -ieq $Target -and $_.Destination -ine $Target -and $_.State -ne 'RolledBack'})
    foreach ($r in $records) {$all.Add([pscustomobject]@{Path=$r.Source})}
    $plan=@(Get-MoveChatPlan $all.ToArray() $Target)
    Assert-MigrationTarget $Target 'MigrationDestination'
    foreach ($entry in @(Get-MoveDestinationChildren $Target)) {
        if (@($records | Where-Object {$_.Destination -ieq $entry.FullName}).Count -ne 1) {throw '目标文件夹已有其他内容，请换一个空文件夹。'}
    }
    $gate=New-MoveRecord $MoveKind '' '' '' @() $Hash 'unused'
    Assert-MoveAppsClosed $gate
    $results=[Collections.Generic.List[object]]::new()
    foreach ($item in $plan) {
        $one=Invoke-MoveNew $MoveKind '' $item.Destination $Manifest $Document $Hash -SelectedSource $item.Source -BatchRoot $Target
        $results.Add($one)
        if ($one.Status -notin @('Done','AlreadyMoved','Running')) {break}
    }
    $last=$results[$results.Count-1] | Select-Object *
    if ($last.Status -eq 'AlreadyMoved' -and @($results | Where-Object {$_.Status -eq 'Done'}).Count -gt 0) {$last.Status='Done'}
    $last | Add-Member -NotePropertyName Items -NotePropertyValue $results.ToArray() -Force
    return $last
}

function Test-MoveDestinationNonEmpty {
    param([string]$Path)
    $iterator=([IO.DirectoryInfo]::new($Path)).EnumerateFileSystemInfos().GetEnumerator()
    try {return $iterator.MoveNext()} finally {if($iterator -is [IDisposable]){$iterator.Dispose()}}
}

function Get-MoveDestinationChildren {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop}
}

function Get-MoveAppInstallations {
    param($Context,[scriptblock]$Read={param($hive,$key,$name) Get-CleanerRegistryValue -Hive $hive -SubKey $key -Name $name})
    # 数据还在、软件已卸载时仍可搬；安装信息只报告能读到的值，不据此猜聊天路径。
    foreach ($app in @('WeChat','QQ')) {
        $keys=@('Software\Tencent\QQ','Software\Tencent\QQNT')
        if ($app -eq 'WeChat') {$keys=@('Software\Tencent\WeChat','Software\Tencent\Weixin')}
        $paths=@{}
        foreach ($key in $keys) {
            foreach ($hive in @([Microsoft.Win32.Registry]::Users,[Microsoft.Win32.Registry]::LocalMachine)) {
                $subkey=$key;if($hive -eq [Microsoft.Win32.Registry]::Users){$subkey=$Context.OriginalUserSid+'\'+$key}
                foreach ($name in @('InstallPath','InstallLocation')) {
                    $value=& $Read $hive $subkey $name
                    if ($value -is [string] -and $value -match '^[A-Za-z]:[\\/]') {
                        try {$path=ConvertTo-CleanerCanonicalPath $value;$paths[$path]=$true} catch {}
                    }
                }
            }
        }
        [pscustomobject]@{App=$app;InstallPaths=@($paths.Keys);Installed=$(if($paths.Count -gt 0){$true}else{$null})}
    }
}

function Move-MoveDirectory {
    param([string]$Source,[string]$Target)
    $sourceMetadata=Get-MoveEntryIdentity $Source
    [IO.Directory]::Move($Source,$Target)
    if ((Get-MoveEntryIdentity $Target).FileId -ne $sourceMetadata.FileId) {throw '原件改名后未能核实，已停止。'}
}

function Write-MoveResult {
    param($Result,[string]$Path)
    Assert-MigrationTarget $Path 'MigrationManifest'
    if ($WhatIfPreference) {Write-Output ($Result | ConvertTo-Json -Depth 8);Write-Output ('RESULT: '+$Path);return}
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $stream=$null;$writer=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($true));$writer.Write((ConvertTo-Json -InputObject $Result -Depth 8))
    }
    finally {if($null -ne $writer){$writer.Dispose()};if($null -ne $stream){$stream.Dispose()}}
    Write-Output ('RESULT: '+$Path)
}

function Invoke-MoveElevatedChild {
    param([hashtable]$Arguments,[string]$Script,[string]$OutputPath)
    Assert-MigrationTarget $OutputPath 'MigrationManifest'
    if (Test-Path -LiteralPath $OutputPath) {throw '结果文件已存在，请换一个新文件名。'}
    $hostPath=(Get-Process -Id $PID).Path
    $child=@{};foreach ($key in $Arguments.Keys) {$child[$key]=$Arguments[$key]}
    $child.ElevatedChild=$true;$child.OriginalUserSid=$script:MigrationSid;$child.OriginalUserProfile=$script:MigrationProfile;$child.ResultPath=$OutputPath
    $child.LogDirectory=Split-Path -Path $script:MigrationContext.LogPath -Parent
    $parts=Get-MoveHostArguments $Script $child
    try {
        $null=Start-Process -FilePath $hostPath -ArgumentList (@($parts | ForEach-Object {ConvertTo-CleanerNativeArgument $_}) -join ' ') -Verb RunAs -Wait -PassThru -ErrorAction Stop
        if (Test-Path -LiteralPath $OutputPath) {return (Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json)}
        return New-MoveResult 'Failed' 'Elevation' '没有获得原账户的权限确认，本次操作已跳过；原件和副本均保留。'
    }
    catch {return New-MoveResult 'Failed' 'Elevation' '权限确认被取消，本次操作已跳过；原件和副本均保留。'}
}

function Test-MoveLinkEqual {
    param($Left,$Right)
    return ($Left.Tag -ceq $Right.Tag -and $Left.Target -ceq $Right.Target -and
        (Get-MigrationValue $Left @('Flags') 0) -eq (Get-MigrationValue $Right @('Flags') 0))
}

function ConvertFrom-MoveReparseBuffer {
    param([byte[]]$Buffer,[int]$Length)
    if ($Length -lt 8) {throw '无法核对这个链接，已停止。'}
    $tag=[BitConverter]::ToUInt32($Buffer,0).ToString('X8');$flags=0;$start=16
    if ($tag -eq 'A000000C') {$start=20;if($Length -lt 20){throw '链接记录不完整。'};$flags=[BitConverter]::ToUInt32($Buffer,16)}
    elseif ($tag -ne 'A0000003') {throw '发现无法核对的特殊文件，请先在相关软件中处理。'}
    $offset=[BitConverter]::ToUInt16($Buffer,8);$bytes=[BitConverter]::ToUInt16($Buffer,10)
    if (($bytes % 2) -ne 0 -or $start+$offset+$bytes -gt $Length) {throw '链接记录不完整。'}
    return [pscustomobject]@{Tag=$tag;Target=[Text.Encoding]::Unicode.GetString($Buffer,$start+$offset,$bytes);Flags=$flags}
}

function Get-MoveLinkMetadata {
    param([string]$Path,$Handle=$null)
    $native=Get-CleanerNativeType;$own=($null -eq $Handle)
    try {
        if ($own) {
            $Handle=$native::CreateFileW($Path,0,7,[IntPtr]::Zero,3,0x02200000,[IntPtr]::Zero)
            if ($Handle.IsInvalid) {throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())}
        }
        $buffer=New-Object byte[] 16384;[uint32]$length=0
        # FSCTL_GET_REPARSE_POINT 查询的就是这个不跟随链接的句柄。
        if (-not $native::DeviceIoControl($Handle,0x900A8,[IntPtr]::Zero,0,$buffer,$buffer.Length,[ref]$length,[IntPtr]::Zero)) {throw '链接已改变或无法核对，原件保留。'}
        return ConvertFrom-MoveReparseBuffer $buffer $length
    }
    finally {if($own -and $null -ne $Handle){$Handle.Dispose()}}
}

function Remove-MoveForeignLink {
    param([string]$Path,$Expected)
    $guards=$null;$handle=$null;$memory=[IntPtr]::Zero;$native=Get-CleanerNativeType
    try {
        $guards=Open-CleanerParentGuards -LiteralPath $Path
        $handle=$native::CreateFileW($Path,0x10080,0,[IntPtr]::Zero,3,0x02200000,[IntPtr]::Zero)
        if ($handle.IsInvalid) {throw '链接正被其他软件使用，原件保留，请稍后重试。'}
        if ((Get-CleanerFinalHandlePath $handle) -ine $Path -or -not (Test-MoveLinkEqual $Expected (Get-MoveLinkMetadata $Path $handle))) {throw '原位置的链接已改变，已停止释放。'}
        $memory=[Runtime.InteropServices.Marshal]::AllocHGlobal(1);[Runtime.InteropServices.Marshal]::WriteByte($memory,0,1)
        if (-not $native::SetFileInformationByHandle($handle,4,$memory,1)) {throw '这个链接暂时无法移除，原件保留。'}
    }
    finally {
        if($memory -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::FreeHGlobal($memory)}
        if($null -ne $handle){$handle.Dispose()};if($null -ne $guards){foreach($h in $guards.Handles){$h.Dispose()}}
    }
}

function Get-MoveReleaseAssessment {
    param($Baseline,$Actual,$ActiveAt)
    try {$activeTicks=Get-MoveUtcTicks $ActiveAt} catch {throw '记录中缺少搬家完成时间，原件保留，请先重新核实搬家。'}
    [long]$changed=0;[long]$missing=0;[long]$missingBytes=0
    foreach ($name in $Baseline.Files.Keys) {
        $old=$Baseline.Files[$name]
        if (-not $Actual.Files.ContainsKey($name)) {$missing++;$missingBytes+=$old.Length;continue}
        $file=$Actual.Files[$name]
        if ($file.Length -eq $old.Length -and $file.WriteTicks -eq $old.WriteTicks) {continue}
        if ($file.WriteTicks -gt $activeTicks) {$changed++;continue}
        throw ('新位置的这些文件无法核对，为了安全没有删除 C 盘上的原件：'+$name)
    }
    if ([decimal]$missing -gt [decimal]$Baseline.FileCount*0.02 -or [decimal]$missingBytes -gt [decimal]$Baseline.Bytes*0.02) {
        throw '新位置少了很多文件，为了安全没有删除 C 盘上的原件'
    }
    return [pscustomobject]@{ChangedAfterMove=$changed;MissingAtDestination=$missing;MissingBytes=$missingBytes}
}

function Test-MoveInventoryEqual {
    param($Baseline,$Actual)
    try {Assert-MoveInventoryMatch $Baseline $Actual -Identity;return $true} catch {return $false}
}

function Write-MoveNextInventory {
    param([string]$Manifest,$Record,$Inventory)
    $version=[int](Get-MigrationValue $Record @('InventoryVersion') 1)
    if ($Record.InventorySha256) {$version++}
    while ($true) {
        $name='move-inventory-'+$Record.Id
        if ($version -gt 1) {$name+='-v'+$version}
        $name+='.tsv'
        if (-not [IO.File]::Exists((Join-Path ([IO.Path]::GetDirectoryName($Manifest)) $name))) {break}
        $version++ # 中断留下的未引用文件保留，不能覆盖。
    }
    $Record.InventoryFile=$name;$Record | Add-Member InventoryVersion $version -Force
    Write-MoveInventory $Manifest $Record $Inventory
    $Record | Add-Member SkippedLinks ([long](Get-MoveForeignLinks $Inventory).Count) -Force
}

function Set-MoveCatchupBaseline {
    param($Record,$Source,[string]$Manifest,$Document)
    $old=[pscustomobject]@{InventoryFile=$Record.InventoryFile;InventorySha256=$Record.InventorySha256;EntryCount=$Record.EntryCount;TotalBytes=$Record.TotalBytes}
    # 先落盘新库存和旧库存指针，再进行任何删除；中断只重做当前阶段。
    Write-MoveNextInventory $Manifest $Record $Source
    $Record | Add-Member PreviousInventory $old -Force
    Set-MoveState $Record CatchingUp $Manifest $Document
    Set-MoveProgressTotals $Record $Source
    return $Source
}

function Get-MoveCatchupRemovalPlan {
    param($Old,$New,$Actual)
    $files=[Collections.Generic.List[string]]::new();$dirs=[Collections.Generic.List[string]]::new()
    foreach ($name in $Actual.Files.Keys) {if(-not $Old.Files.ContainsKey($name) -and -not $New.Files.ContainsKey($name)){throw ('新位置出现其他文件，已停止：'+$name)}}
    foreach ($name in $Actual.Directories.Keys) {if(-not $Old.Directories.ContainsKey($name) -and -not $New.Directories.ContainsKey($name)){throw ('新位置出现其他文件夹，已停止：'+$name)}}
    if ((Get-MoveForeignLinks $Actual).Count) {throw '新位置出现其他链接，已停止。'}
    foreach ($name in $Old.Files.Keys) {
        if ($New.Files.ContainsKey($name) -or -not $Actual.Files.ContainsKey($name)) {continue}
        $a=$Old.Files[$name];$b=$Actual.Files[$name]
        if ($a.Length -ne $b.Length -or $a.WriteTicks -ne $b.WriteTicks -or ($a.Hash -and $a.Hash -ne $b.Hash)) {throw ('新位置的这个文件已改变，没有删除：'+$name)}
        $files.Add($name)
    }
    foreach ($name in $Old.Directories.Keys) {if(-not $New.Directories.ContainsKey($name) -and $Actual.Directories.ContainsKey($name)){$dirs.Add($name)}}
    return [pscustomobject]@{Files=$files.ToArray();Directories=@($dirs.ToArray() | Sort-Object Length -Descending)}
}

function Complete-MoveCatchup {
    param($Record,$Baseline,[string]$Manifest,$Document,$Actual=$null)
    $old=Read-MoveInventory $Manifest $Record.PreviousInventory
    if ($null -eq $Actual) {$Actual=Get-MoveInventory $Record.Destination -Hash:$Record.VerifyHash -AllowedLinks $old.Links}
    $plan=Get-MoveCatchupRemovalPlan $old $Baseline $Actual
    foreach ($name in $plan.Files) {
        $file=$old.Files[$name]
        Remove-MoveRetainedLeaf ($Record.Destination+'\'+$name) @{FileId='';Length=$file.Length;WriteTicks=$file.WriteTicks;Hash=$file.Hash} $false $Record.VerifyHash
        $Actual.Files.Remove($name)
    }
    foreach ($name in $plan.Directories) {Remove-MoveRetainedLeaf ($Record.Destination+'\'+$name) @{FileId=''} $true $false;$Actual.Directories.Remove($name)}
    Set-MoveState $Record Copying $Manifest $Document
    return $Actual
}

function Get-MoveCopyFailureReason {
    param([Collections.IEnumerable]$Lines)
    $names=[Collections.Generic.List[string]]::new();$codes=[Collections.Generic.List[int]]::new()
    foreach ($line in $Lines) {
        if ($line -match '(?i)(?:\bERROR\s+|错误\s*)(\d+)') {
            $codes.Add([int]$matches[1])
            if ($line -match '([A-Za-z]:\\.*)$') {if($names.Count -lt 5 -and -not $names.Contains($matches[1])){$names.Add($matches[1].Trim())}}
        }
    }
    $reason='复制没有完成，原件保留，可继续本次搬家。'
    if (32 -in $codes -or 33 -in $codes) {$reason='这些文件正被其他软件使用，请关闭相关软件后重新运行'}
    elseif (5 -in $codes) {$reason='这些文件暂时没有访问权限，请关闭相关软件后重新运行'}
    elseif (2 -in $codes -or 3 -in $codes) {$reason='这些文件在复制时被移动或删除，请暂时不要更改这个文件夹，然后重新运行'}
    elseif (112 -in $codes) {$reason='新位置的磁盘空间不足，请腾出空间后重新运行'}
    if ($names.Count) {$reason+='：'+($names -join '、')}
    return $reason
}

function Test-MoveBackground {
    return ($null -ne (Get-Variable MoveRunBackground -Scope Script -ErrorAction SilentlyContinue) -and $script:MoveRunBackground)
}

function Get-MoveHostArguments {
    param([string]$Script,[hashtable]$Arguments)
    $parts=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script)
    foreach ($key in @($Arguments.Keys | Sort-Object)) {
        if ($Arguments[$key] -is [bool] -or $Arguments[$key] -is [Management.Automation.SwitchParameter]) {if($Arguments[$key]){$parts+=('-'+$key)}}
        elseif ($null -ne $Arguments[$key] -and [string]$Arguments[$key]) {$parts+=('-'+$key);$parts+=[string]$Arguments[$key]}
    }
    return ,$parts
}

function Open-MoveShortLock {
    param([string]$Path)
    $until=[datetime]::UtcNow.AddSeconds(10)
    while ($true) {
        try {return Open-MigrationManifestLock $Path -Persistent}
        catch [IO.IOException] {if([datetime]::UtcNow -ge $until){throw '另一次操作正在保存进度，请稍后重试。'};Start-Sleep -Milliseconds 50}
    }
}

function Open-MoveOperationLock {
    param([string]$Path,[scriptblock]$Pause={Start-Sleep -Milliseconds 500})
    $clock=@{Last=[datetime]::MinValue}
    while ($true) {
        try {return Open-MigrationManifestLock $Path -Persistent}
        catch [IO.IOException] {Write-MoveProgress '等待上一次搬家完成' 0 0 $clock;$null=& $Pause}
    }
}

function Wait-MoveRollbackPredecessor {
    param($Document,[string]$MoveId,[string]$Manifest,[scriptblock]$Pause={Start-Sleep -Milliseconds 500})
    $current=@($Document.Entries | Where-Object {$_.Id -eq $MoveId})
    if ($current.Count -ne 1) {throw '未找到这次搬家记录。'}
    $after=Get-MigrationValue $current[0] @('RollbackAfter') ''
    if (-not $after) {return $Document}
    if ($after -cnotmatch '^[0-9a-f]{32}$' -or $after -eq $MoveId) {throw '还原顺序记录无效，原件保留。'}
    $clock=@{Last=[datetime]::MinValue}
    while ($true) {
        $latest=Read-MigrationManifest $Manifest
        $predecessor=@($latest.Entries | Where-Object {$_.Id -eq $after})
        if ($predecessor.Count -eq 1 -and $predecessor[0].State -eq 'RolledBack') {return $latest}
        $snapshot=Read-MoveStatus (Get-MoveStatusPath $Manifest $after)
        if ($null -eq $snapshot -or $snapshot.FinalResultPath -or -not (Test-MoveWorkerAlive $snapshot)) {throw '前一次还原尚未完成，请重新运行还原指令继续；文件均保留。'}
        Write-MoveProgress '等待前一次还原完成' 0 0 $clock
        $null=& $Pause
    }
}

function Save-MoveRecord {
    param($Record,[string]$Manifest,$Document)
    if ($null -eq (Get-Variable MoveShortWrites -Scope Script -ErrorAction SilentlyContinue) -or -not $script:MoveShortWrites) {Write-MigrationManifest $Manifest $Document;return}
    $lock=Open-MoveShortLock $Manifest
    try {
        $latest=Read-MigrationManifest $Manifest
        $found=$false
        $entries=@(foreach ($entry in $latest.Entries) {if($entry.Id -eq $Record.Id){$Record;$found=$true}else{$entry}})
        if (-not $found) {$entries+=@($Record)}
        $latest.Entries=$entries
        Write-MigrationManifest $Manifest $latest
    }
    finally {Close-MigrationManifestLock $lock}
}

function Get-MoveStatusPath {
    param([string]$Manifest,[string]$MoveId)
    if ($MoveId -cnotmatch '^[0-9a-f]{32}$') {throw '请提供有效的本次 Id。'}
    return Join-Path ([IO.Path]::GetDirectoryName($Manifest)) ('move-status-'+$MoveId+'.json')
}

function Save-MoveStatus {
    param([string]$Path,$Value)
    # 仅这个小进度文件原子替换；最终结果和库存始终使用唯一名称。
    Assert-MigrationTarget $Path MigrationManifest
    $temp=$Path+'.tmp-'+[guid]::NewGuid().ToString('N')
    Assert-MigrationTarget $temp MigrationManifest
    [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Value -Depth 8),[Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) {[IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value)} else {[IO.File]::Move($temp,$Path)}
}

function Read-MoveStatus {
    param([string]$Path)
    Assert-MigrationTarget $Path MigrationManifest
    if (-not [IO.File]::Exists($Path)) {return $null}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader=$null
    try {$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8);return ConvertFrom-Json -InputObject $reader.ReadToEnd()}
    finally {if($null -ne $reader){$reader.Dispose()};$stream.Dispose()}
}

function Get-MoveUtcTicks {
    param($Value)
    # PS7 ConvertFrom-Json 可把 ISO 字符串变成 DateTime；5.1 保持字符串。
    if ($Value -is [datetimeoffset]) {return $Value.UtcDateTime.Ticks}
    if ($Value -is [datetime]) {return $Value.ToUniversalTime().Ticks}
    if (-not $Value) {throw '时间记录无效。'}
    return [datetimeoffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime.Ticks
}

function Test-MoveWorkerAlive {
    param($Status,[scriptblock]$Lookup={param($number) Get-Process -Id $number -ErrorAction Stop})
    if ($null -eq $Status -or $Status.WorkerPid -le 0 -or -not $Status.WorkerStartTime) {return $false}
    try {
        $process=& $Lookup $Status.WorkerPid
        return ($process.StartTime.ToUniversalTime().Ticks -eq (Get-MoveUtcTicks $Status.WorkerStartTime))
    } catch {return $false}
}

function Get-MoveStatusResult {
    param($Snapshot,$Record,[scriptblock]$Alive={param($s) Test-MoveWorkerAlive $s},[scriptblock]$Final={param($p) Assert-MigrationTarget $p MigrationManifest;Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json})
    if ($null -ne $Snapshot -and $Snapshot.FinalResultPath) {return & $Final $Snapshot.FinalResultPath}
    if ($null -ne $Snapshot -and (& $Alive $Snapshot)) {
        $result=New-MoveResult Running $Snapshot.Phase '正在后台处理，您可以继续使用电脑；需要搬家的聊天软件请保持退出。' $Record
    }
    else {$result=New-MoveResult Stalled 'Interrupted' '上次处理已中断，重新运行相同的指令即可从当前阶段继续。' $Record}
    $result | Add-Member Progress $Snapshot
    return $result
}

function Start-MoveWorker {
    param($Record,[string]$Manifest,[string]$Operation)
    if ($script:MigrationContext.CurrentUserSid -ne $script:MigrationSid) {throw '请回到原账户继续搬家。'}
    $path=Get-MoveStatusPath $Manifest $Record.Id
    $launch=Open-MoveShortLock ($path+'.launch.json')
    try {
        $snapshot=Read-MoveStatus $path
        if ($null -ne $snapshot -and (Test-MoveWorkerAlive $snapshot)) {
            $running=New-MoveResult Running $snapshot.Phase '上次处理仍在后台进行，请稍后查看进度。' $Record
            $running | Add-Member Progress $snapshot
            return $running
        }
        $token=[guid]::NewGuid().ToString('N')
        $startArgs=@{Worker=$true;WorkerToken=$token;Id=$Record.Id;Operation=$Operation;OriginalUserSid=$script:MigrationSid;OriginalUserProfile=$script:MigrationProfile}
        $startArgs.LogDirectory=Split-Path -Path $script:MigrationContext.LogPath -Parent
        $parts=Get-MoveHostArguments $script:MoveScriptPath $startArgs
        $process=Start-Process -FilePath ((Get-Process -Id $PID).Path) -ArgumentList (@($parts | ForEach-Object {ConvertTo-CleanerNativeArgument $_}) -join ' ') -WindowStyle Hidden -PassThru -ErrorAction Stop
        $snapshot=[pscustomobject]@{Schema='pc-care/move-status/1';RunToken=$token;Id=$Record.Id;Operation=$Operation;Phase=$Record.State;FilesDone=[long]0;BytesDone=[long]0;TotalFiles=[long]0;TotalBytes=$Record.TotalBytes;LastUpdate=[datetimeoffset]::UtcNow.ToString('o');WorkerPid=$process.Id;WorkerStartTime=$process.StartTime.ToUniversalTime().ToString('o');FinalResultPath=''}
        Save-MoveStatus $path $snapshot
        return Get-MoveStatusResult $snapshot $Record {param($s) $true}
    }
    finally {Close-MigrationManifestLock $launch}
}

function Set-MoveProgressTotals {
    param($Record,$Baseline)
    if ($null -ne (Get-Variable MoveWorkerStatus -Scope Script -ErrorAction SilentlyContinue) -and $null -ne $script:MoveWorkerStatus) {
        $script:MoveWorkerStatus.TotalFiles=$Baseline.FileCount;$script:MoveWorkerStatus.TotalBytes=$Baseline.Bytes
    }
}

function Get-MoveElevationContinuation {
    param([hashtable]$Arguments,$Record)
    $child=@{}
    foreach ($key in @('Foreground','Kind','Folder','Destination','Rollback','ReleaseSource','Id','ResumeId','VerifyHash')) {$child[$key]=Get-MigrationValue $Arguments @($key) ''}
    if ($null -ne $Record) {$child.Id=$Record.Id;$child.ResumeId=''}
    if ($Arguments.Worker) {
        $child.Worker=$true;$child.Operation=$Arguments.Operation;$child.WorkerToken=$Arguments.WorkerToken
        $child.Foreground=$false;$child.Rollback=$false;$child.ReleaseSource=$false
    }
    return $child
}

function Invoke-MoveMain {
    param([hashtable]$Arguments,[string]$Root,[string]$Script)
    . (Join-Path $Root 'common.ps1')
    Import-MoveMigrationFunctions (Join-Path $Root 'migrate.ps1')
    $contextArgs=@{}
    if ($Arguments.OriginalUserSid) {$contextArgs.OriginalUserSid=$Arguments.OriginalUserSid;$contextArgs.OriginalUserProfile=$Arguments.OriginalUserProfile}
    $logDirectory=[string](Get-MigrationValue $Arguments @('LogDirectory') '')
    if (($Arguments.Worker -or $Arguments.ElevatedChild) -and -not $logDirectory) {throw '没有收到原账户的记录目录，已停止搬家。'}
    if ($logDirectory) {$contextArgs.LogDirectory=$logDirectory}
    $script:MigrationContext=Get-CleanerContext @contextArgs
    $script:MigrationSid=$script:MigrationContext.OriginalUserSid;$script:MigrationProfile=$script:MigrationContext.OriginalUserProfile
    $script:MigrationLog=$script:MigrationContext.LogPath;$script:MigrationCmdlet=$script:MoveCmdlet;$script:MigrationWroteState=(-not $WhatIfPreference)
    $script:MoveRunBackground=(-not $Arguments.Worker -and -not $Arguments.Foreground)
    $script:MoveShortWrites=($Arguments.Worker -or $Arguments.ElevatedChild)
    $script:MoveScriptPath=$Script;$script:MoveWorkerStatus=$null;$script:MoveStatusLastWrite=[datetime]::MinValue
    $manifest=Join-Path ([IO.Path]::GetDirectoryName($script:MigrationLog)) 'moves.json'
    $output=$Arguments.ResultPath
    if (-not $output) {$output=Join-Path ([IO.Path]::GetDirectoryName($manifest)) ('move-result-'+[guid]::NewGuid().ToString('N')+'.json')}
    $defaultOutput=Join-Path ([IO.Path]::GetDirectoryName($manifest)) ('move-result-'+[guid]::NewGuid().ToString('N')+'.json')
    $lock=$null;$workerLock=$null;$operationLock=$null;$script:MoveStep='Preflight';$script:MoveCurrentRecord=$null;$result=$null;$elevate=$false
    try {
        try {
            Assert-MigrationTarget $output 'MigrationManifest'
            if (Test-Path -LiteralPath $output) {throw '指定的结果文件已存在。'}
        } catch {$output=$defaultOutput;throw '结果保存位置不可用，没有执行搬家；本次结果改存默认日志文件夹。'}
        if ($script:MigrationContext.CurrentUserSid -ne $script:MigrationSid) {throw '权限确认使用了另一个账户，本次搬家已跳过；请回到原账户。'}
        Assert-MoveRequest $Arguments
        if ($Arguments.Status) {
            $snapshot=Read-MoveStatus (Get-MoveStatusPath $manifest $Arguments.Id)
            $result=Get-MoveStatusResult $snapshot @{Id=$Arguments.Id}
            Write-MoveResult $result $output
            return
        }
        if ($Arguments.Worker -and -not $WhatIfPreference) {
            $script:MoveStatusPath=Get-MoveStatusPath $manifest $Arguments.Id
            $launch=Open-MoveShortLock ($script:MoveStatusPath+'.launch.json')
            try {
                try {$workerLock=Open-MigrationManifestLock (Join-Path ([IO.Path]::GetDirectoryName($manifest)) ('move-worker-'+$Arguments.Id+'.json')) -Persistent}
                catch [IO.IOException] {
                    $running=New-MoveResult Running 'Worker' '这次搬家已在后台进行，请稍后查看进度。' @{Id=$Arguments.Id}
                    Write-MoveResult $running $output
                    return # 同一记录已有工作进程，不能写它的最终状态。
                }
                $snapshot=Read-MoveStatus $script:MoveStatusPath
                if ($Arguments.WorkerToken -and (Get-MigrationValue $snapshot @('RunToken') '') -ne $Arguments.WorkerToken) {throw '本次后台任务已经重新启动，请查看最新进度。'}
                $script:MoveWorkerStatus=$snapshot
                if ($null -eq $script:MoveWorkerStatus) {throw '后台进度记录不存在，请重新运行原指令。'}
                $script:MoveWorkerStatus.WorkerPid=$PID
                $script:MoveWorkerStatus.WorkerStartTime=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
                $script:MoveWorkerStatus.FinalResultPath=''
                Save-MoveStatus $script:MoveStatusPath $script:MoveWorkerStatus
            }
            finally {Close-MigrationManifestLock $launch}
        }
        elseif ($Arguments.ElevatedChild) {
            $selected=$Arguments.Id;if($Arguments.ResumeId){$selected=$Arguments.ResumeId}
            if ($selected) {$script:MoveStatusPath=Get-MoveStatusPath $manifest $selected;$script:MoveWorkerStatus=Read-MoveStatus $script:MoveStatusPath}
        }
        elseif (-not $WhatIfPreference) {$lock=Open-MoveShortLock $manifest}
        $document=Read-MigrationManifest $manifest;$script:MoveDocument=$document
        $operation='Move';if($Arguments.Rollback){$operation='Rollback'};if($Arguments.ReleaseSource){$operation='Release'};if($Arguments.Worker){$operation=$Arguments.Operation}
        $selected=$Arguments.Id;if($Arguments.ResumeId){$selected=$Arguments.ResumeId}
        if ($Arguments.Worker -and -not $WhatIfPreference) {
            if ($operation -eq 'Rollback') {$document=Wait-MoveRollbackPredecessor $document $selected $manifest}
            # 同时请求的多个搬家可以排队，避免文档与其中的聊天目录交叉操作。
            # 这把锁只由后台进程持有，不妨碍前台查询/新建小记录。
            $operationLock=Open-MoveOperationLock (Join-Path ([IO.Path]::GetDirectoryName($manifest)) 'move-operations.json')
            $document=Read-MigrationManifest $manifest;$script:MoveDocument=$document
        }
        if ($selected -or $operation -ne 'Move') {
            $records=@($document.Entries | Where-Object {(-not $selected -or $_.Id -eq $selected) -and $_.State -ne 'RolledBack'})
            if (-not $records.Count) {throw '未找到可处理的搬家记录。'}
            if ($operation -eq 'Rollback' -and -not $selected) {
                [array]::Reverse($records)
                $previous=''
                foreach ($one in $records) {
                    $one | Add-Member RollbackAfter $previous -Force
                    if (-not $WhatIfPreference) {Save-MoveRecord $one $manifest $document}
                    $previous=$one.Id
                }
            }
            $outcomes=@(foreach($record in $records){Invoke-MoveRecord $record $manifest $document $operation})
            $result=$outcomes[0] | Select-Object *
            if ($outcomes.Count -gt 1) {$result | Add-Member Items $outcomes}
        }
        else {$result=Invoke-MoveNew $Arguments.Kind $Arguments.Folder $Arguments.Destination $manifest $document $Arguments.VerifyHash}
    }
    catch {
        $status=[string]$_.Exception.Data['MoveStatus'];if(-not $status){$status='Failed'}
        $result=New-MoveResult $status $script:MoveStep '搬家未完成，原件和目标数据已保留；若正在释放原件，已释放的部分无法还原。' $script:MoveCurrentRecord
        if ($_.Exception.Message -match '[\u4e00-\u9fff]' -and $_.Exception.Message -notmatch 'SID|junction|reparse|重解析') {$result.Reason=$_.Exception.Message}
        $result | Add-Member Diagnostic $_.Exception.Message
        $denied=($_.Exception -is [UnauthorizedAccessException] -or (($_.Exception.HResult -band 0xffff) -eq 5))
        $elevate=($denied -and -not $Arguments.ElevatedChild -and -not $script:MigrationContext.IsAdmin -and -not $WhatIfPreference)
    }
    finally {if($null -ne $lock){Close-MigrationManifestLock $lock}}
    try {
        if ($elevate) {
            $childArgs=Get-MoveElevationContinuation $Arguments $script:MoveCurrentRecord
            if ($Arguments.Worker) {
                # 权限子进程接管同一个工作锁/进度身份；父进程消失也不会留下无锁的删除进程。
                if ($null -ne $operationLock) {Close-MigrationManifestLock $operationLock;$operationLock=$null}
                if ($null -ne $workerLock) {Close-MigrationManifestLock $workerLock;$workerLock=$null}
            }
            $result=Invoke-MoveElevatedChild $childArgs $Script $output
        }
        if (-not [IO.File]::Exists($output)) {Write-MoveResult $result $output} else {Write-Output ('RESULT: '+$output)}
        if ($Arguments.Worker -and $null -ne $script:MoveWorkerStatus) {
            $latestStatus=Read-MoveStatus $script:MoveStatusPath
            if ((Get-MigrationValue $latestStatus @('RunToken') '') -eq (Get-MigrationValue $script:MoveWorkerStatus @('RunToken') '') -and -not $latestStatus.FinalResultPath) {
                $latestStatus.FinalResultPath=$output;$latestStatus.Phase=$result.StoppedAt
                $latestStatus.LastUpdate=[datetimeoffset]::UtcNow.ToString('o')
                Save-MoveStatus $script:MoveStatusPath $latestStatus
            }
        }
    }
    finally {if($null -ne $operationLock){Close-MigrationManifestLock $operationLock};if($null -ne $workerLock){Close-MigrationManifestLock $workerLock}}
}

function Assert-MoveRequest {
    param([hashtable]$Arguments)
    if ([int]$Arguments.Rollback+[int]$Arguments.ReleaseSource+[int]$Arguments.Status+[int]$Arguments.Worker -gt 1 -or
        ($Arguments.ResumeId -and ($Arguments.Rollback -or $Arguments.ReleaseSource -or $Arguments.Status -or $Arguments.Worker)) -or
        (($Arguments.ReleaseSource -or $Arguments.Status -or $Arguments.Worker) -and -not $Arguments.Id)) {throw '请一次选择搬家、查看进度、释放原件或还原中的一种操作，并提供本次 Id。'}
    foreach ($value in @($Arguments.Id,$Arguments.ResumeId)) {if($value -and $value -cnotmatch '^[0-9a-f]{32}$'){throw '请提供有效的本次 Id。'}}
}

$script:MoveCmdlet=$PSCmdlet
$arguments=@{Kind=$Kind;Folder=$Folder;Destination=$Destination;ReleaseSource=[bool]$ReleaseSource;Rollback=[bool]$Rollback;Status=[bool]$Status;Worker=[bool]$Worker;Operation=$Operation;Foreground=[bool]$Foreground;WorkerToken=$WorkerToken;Id=$Id;ResumeId=$ResumeId;VerifyHash=[bool]$VerifyHash;ResultPath=$ResultPath;LogDirectory=$LogDirectory;OriginalUserSid=$OriginalUserSid;OriginalUserProfile=$OriginalUserProfile;ElevatedChild=[bool]$ElevatedChild}
if ($Status -or $WhatIfPreference -or $PSCmdlet.ShouldProcess('用户资料','搬家并保留原件，或执行已指定的还原/释放操作')) {Invoke-MoveMain $arguments $PSScriptRoot $PSCommandPath}
