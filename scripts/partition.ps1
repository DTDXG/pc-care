<#
.SYNOPSIS
    先规划，再由聊天中的第二次确认授权执行分区。
.DESCRIPTION
    -Plan 不提权；-Apply 代表宿主已取得用户对该方案的第二次确认。
    加密 C 盘压缩还需用户在聊天中确认能找到恢复密钥，再传 -RecoveryKeyConfirmed。
    Layout 示例（GB 使用 Windows 的 1 GB = 1024^3 字节）：
    {"DiskNumber":0,"Count":2,"Volumes":[{"Label":"资料","SizeGB":100,"Letter":"D",
    "Folders":["文档","下载"]},{"Label":"软件与游戏","SizeGB":"rest","Letter":"E"}]}
    DiskNumber、Count、Letter、Folders 均可省略；Count 单独使用时自动均分。
    rest 只能出现一次且必须最后。空目录列表表示不建目录。
    不支持创建逻辑分区；已有扩展分区的磁盘会说明原因并拒绝修改。
    Windows API 仅在适配函数中调用；决策函数只接收普通对象。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Plan')][switch]$Plan,
    [Parameter(ParameterSetName = 'Plan')][string]$Layout,
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')][switch]$Apply,
    [Parameter(ParameterSetName = 'Plan')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')][string]$PlanPath,
    [Parameter(ParameterSetName = 'Apply')][string]$ResultPath,
    [Parameter(ParameterSetName = 'Apply')][string]$OriginalUserSid,
    [Parameter(ParameterSetName = 'Apply')][string]$OriginalUserProfile,
    [string]$LogDirectory,
    [Parameter(ParameterSetName = 'Apply')][switch]$ElevatedChild,
    [Parameter(ParameterSetName = 'Apply')][switch]$RecoveryKeyConfirmed,
    [Parameter(ParameterSetName = 'Apply', DontShow = $true)][hashtable]$ChildState
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 唯一的加密压缩策略：AllowWithRecoveryKeyConfirmation 或 Block。
$script:BitLockerShrinkPolicy = 'AllowWithRecoveryKeyConfirmation'

function Get-PcValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Get-PcAligned {
    param([long]$Bytes, [long]$Alignment = 1MB, [switch]$Up)
    [long]$remainder = $Bytes % $Alignment
    if ($Up -and $remainder -ne 0) { return [long]($Bytes + $Alignment - $remainder) }
    return [long]($Bytes - $remainder)
}

function Get-PcReserve {
    param([long]$UsedBytes)
    return [long][math]::Max(($UsedBytes + 60GB), 120GB)
}

function Get-PcUsable {
    param([long]$CSize, [long]$UsedBytes, $MaxShrinkBytes)
    [long]$available = [math]::Max([long]0, $CSize - (Get-PcReserve $UsedBytes))
    if ($null -ne $MaxShrinkBytes) { $available = [math]::Min($available, [long]$MaxShrinkBytes) }
    return Get-PcAligned $available
}

function Test-PcInternalDisk {
    param($Disk)
    return (-not [bool](Get-PcValue $Disk 'IsRemovable' $false) -and
        [string]$Disk.BusType -in @('NVMe', 'SATA', 'SAS', 'ATA', 'SCSI', 'RAID', 'Virtual', 'File Backed Virtual'))
}

function Test-PcDataPartition {
    param($Disk, $Partition)
    return ((Test-PcInternalDisk $Disk) -and [string]$Partition.DriveLetter -match '^[A-Z]$' -and
        $Partition.DriveLetter -ne 'C' -and [bool]$Partition.HasVolume -and
        [string]$Partition.FileSystem -in @('NTFS', 'ReFS', 'exFAT', 'FAT32') -and
        -not $Partition.IsSystem -and -not $Partition.IsBoot -and -not $Partition.IsHidden)
}

function Test-PcEmptyDisk {
    param($Disk, [bool]$Explicit)
    if (-not (Test-PcInternalDisk $Disk)) { return $false }
    if (@($Disk.Partitions).Count -eq 0) { return $true }
    if (-not $Explicit) { return $false }
    # 即便没有盘符，普通文件卷和不认识的 OEM 分区也不能当作空硬盘。
    foreach ($p in $Disk.Partitions) {
        if ($p.HasVolume -and $p.FileSystem -notin @('', 'RAW')) { return $false }
        if ($p.Type -notin @('Reserved', 'System', 'Recovery')) { return $false }
    }
    return $true
}

function Get-PcFreeExtents {
    param($Disk)
    [long]$cursor = 1MB
    # 新 GPT 硬盘可能由 Windows 自动建立 16 MB 保留分区，提前让出该位置。
    if ($Disk.PartitionStyle -eq 'RAW') { $cursor = 17MB }
    [long]$end = Get-PcAligned ([long]$Disk.Size - 1MB)
    foreach ($p in @($Disk.Partitions | Sort-Object Offset)) {
        [long]$start = Get-PcAligned ([long]$p.Offset)
        if ($start -gt $cursor) { [pscustomobject]@{ Offset = $cursor; Size = [long]($start - $cursor) } }
        $cursor = [math]::Max($cursor, (Get-PcAligned ([long]$p.Offset + [long]$p.Size) -Up))
    }
    if ($end -gt $cursor) { [pscustomobject]@{ Offset = $cursor; Size = [long]($end - $cursor) } }
}

function Get-PcDefaultFolders {
    param([string]$Label)
    if ($Label -match '软件|游戏') { return @('软件', '游戏') }
    if ($Label -match '影音|归档') { return @('电影', '音乐', '归档') }
    return @('文档', '下载', '图片视频', '聊天文件')
}

function Get-PcDefaultLayout {
    param([long]$UsableBytes, [int]$Count = 0)
    if ($Count -eq 0) {
        $Count = 1
        if ($UsableBytes -ge 200GB) { $Count = 2 }
        if ($UsableBytes -gt 1TB) { $Count = 3 }
    }
    $labels = @('资料', '软件与游戏', '影音与归档')
    [long]$part = Get-PcAligned ([long][math]::Floor($UsableBytes / $Count))
    for ($i = 0; $i -lt $Count; $i++) {
        $label = '资料' + ($i + 1)
        if ($i -lt $labels.Count) { $label = $labels[$i] }
        $size = [object]([decimal]$part / 1GB)
        if ($i -eq $Count - 1) { $size = 'rest' }
        [pscustomobject]@{ Label = $label; SizeGB = $size; Folders = @(Get-PcDefaultFolders $label) }
    }
}

function Test-PcFolderName {
    param([string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name) -and $Name.Length -le 100 -and
        $Name -notin @('.', '..') -and $Name -notmatch '[\\/:*?"<>|\x00-\x1f]' -and
        -not $Name.EndsWith('.') -and -not $Name.EndsWith(' ') -and
        $Name -notmatch '^(?i:CON|PRN|AUX|NUL|CLOCK\$|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)')
}

function Resolve-PcLayout {
    param([object[]]$Volumes, [long]$UsableBytes, [string[]]$UsedLetters)
    $reasons = @(); $resolved = @(); $letters = @($UsedLetters | ForEach-Object { $_.TrimEnd(':').ToUpperInvariant() })
    [long]$total = 0
    if ($Volumes.Count -lt 1 -or $Volumes.Count -gt 23) { $reasons += '请安排 1 到 23 个数据分区。' }
    for ($i = 0; $i -lt $Volumes.Count; $i++) {
        $v = $Volumes[$i]; $label = [string](Get-PcValue $v 'Label' '')
        if ([string]::IsNullOrWhiteSpace($label) -or $label.Length -gt 32 -or $label -match '[\\/:*?"<>|\x00-\x1f]') {
            $reasons += '分区名称不能为空、超过 32 个字或包含特殊符号。'
        }
        $size = Get-PcValue $v 'SizeGB'; [long]$bytes = 0
        if ([string]$size -ieq 'rest') {
            if ($i -ne $Volumes.Count - 1) { $reasons += '剩余空间只能用于最后一个分区。' }
            $bytes = [math]::Max([long]0, $UsableBytes - $total)
        }
        else {
            [decimal]$number = 0
            if (-not [decimal]::TryParse([string]$size, [Globalization.NumberStyles]::Number,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0 -or $number -gt ([decimal][long]::MaxValue / 1GB)) {
                $reasons += '分区大小请填写 GB 数字，或最后一项填写 rest。'
            }
            else { $bytes = Get-PcAligned ([long][math]::Floor($number * 1GB)) }
        }
        if ($bytes -lt 20GB) { $reasons += '每个新分区至少需要 20 GB，请减少分区数量或调整大小。' }
        if ($bytes -gt $UsableBytes - $total) { $reasons += '安排的分区总大小超过了可用空间。' }
        if ($bytes -gt 0 -and $total -le [long]::MaxValue - $bytes) { $total += $bytes }
        else { $reasons += '分区大小无效。' }
        $letter = [string](Get-PcValue $v 'Letter' '')
        if (-not $letter) {
            foreach ($code in 68..90) { $candidate = [string][char]$code; if ($candidate -notin $letters) { $letter = $candidate; break } }
        }
        $letter = $letter.TrimEnd(':').ToUpperInvariant()
        if ($letter -notmatch '^[D-Z]$' -or $letter -in $letters) { $reasons += '盘符必须是尚未使用的 D 到 Z，且不能重复。' }
        $letters += $letter
        $folders = @(Get-PcValue $v 'Folders' (Get-PcDefaultFolders $label))
        foreach ($folder in $folders) { if (-not (Test-PcFolderName ([string]$folder))) { $reasons += '目录请使用普通名称，不要包含路径、特殊符号或保留名称。' } }
        if (@($folders | Sort-Object -Unique).Count -ne $folders.Count) { $reasons += '目录名称不能重复。' }
        $resolved += [pscustomobject]@{ Size = $bytes; DriveLetter = $letter; Label = $label; Folders = @($folders) }
    }
    return [pscustomobject]@{ Valid = ($reasons.Count -eq 0); Reasons = @($reasons | Select-Object -Unique); Volumes = @($resolved); TotalBytes = $total }
}

function Get-PcMbrReasons {
    param($Disk, [int]$NewCount)
    if ($Disk.PartitionStyle -ne 'MBR' -or $NewCount -eq 0) { return }
    $extended = @($Disk.Partitions | Where-Object { $_.Type -match 'Extended|Logical' -or $_.MbrType -in @(5, 15, 133) })
    if ($extended.Count -gt 0) { '这块硬盘已有扩展分区，本版本不能安全地在其中新建分区，请保留现有布局。' }
    elseif (@($Disk.Partitions).Count + $NewCount -gt 4) { '这块硬盘最多容纳 4 个主分区；当前方案会超过限制，请减少新分区数量。' }
}

function Get-PcFingerprint {
    param($State, [int]$DiskNumber)
    $facts = @()
    foreach ($d in @($State.Disks | Where-Object { $_.Number -eq $DiskNumber -or $_.Number -eq $State.SystemDiskNumber } | Sort-Object Number)) {
        $parts = @($d.Partitions | Sort-Object PartitionNumber | ForEach-Object {
            [ordered]@{ Number = [int]$_.PartitionNumber; Offset = [long]$_.Offset; Size = [long]$_.Size
                Type = [string]$_.Type; GptType = [string]$_.GptType; MbrType = [int]$_.MbrType; Letter = [string]$_.DriveLetter }
        })
        $facts += [ordered]@{ Number = [int]$d.Number; UniqueId = [string]$d.UniqueId; Serial = [string]$d.SerialNumber
            Size = [long]$d.Size; Style = [string]$d.PartitionStyle; Partitions = $parts }
    }
    $json = ConvertTo-Json -InputObject ([ordered]@{ SystemDiskNumber = [int]$State.SystemDiskNumber; Disks = $facts }) -Depth 8 -Compress
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-PcSafety {
    param($State, $Disk, [bool]$Shrink, [bool]$AtApply, [string]$BitLockerPolicy = $script:BitLockerShrinkPolicy)
    $blockers = @(); $pending = @(); $warnings = @()
    if (-not (Test-PcInternalDisk $Disk)) { $blockers += '本版本只处理电脑内部硬盘，不处理移动硬盘、U 盘或存储卡。' }
    if ($Disk.IsOffline -or $Disk.IsReadOnly) { $blockers += '选中的硬盘当前离线或只读，不能分区。' }
    if ([string]::IsNullOrWhiteSpace([string]$Disk.UniqueId) -and [string]::IsNullOrWhiteSpace([string]$Disk.SerialNumber)) { $blockers += '无法可靠识别这块硬盘，不能安全分区。' }
    if (-not $Disk.InspectionComplete) { $blockers += '无法完整读取这块硬盘的现有分区，已停止规划。' }
    if ($Disk.PartitionStyle -notin @('GPT', 'MBR', 'RAW')) { $blockers += '无法确认这块硬盘的分区格式，不能分区。' }
    foreach ($field in @('IsDynamic', 'IsStorageSpaces')) {
        $value = Get-PcValue $Disk $field
        if ($value -eq $true) { $blockers += '这块硬盘使用了特殊的磁盘组合或管理方式，本版本不处理，请保留现有布局。' }
        elseif ($null -eq $value) {
            $failure = Get-PcReadFailure 'DiskKind' $AtApply
            if ($failure.Fatal) { $blockers += $failure.Reason } else { $pending += $failure.Reason }
        }
    }
    if ($Disk.BusType -in @('RAID', 'Spaces')) { $blockers += '这块硬盘使用了多盘组合或存储池，本版本不处理。' }
    if ($Shrink) {
        if ($State.BitLocker -eq 'Converting') { $blockers += 'C 盘正在加密或解密，完成后才能分区' }
        elseif ($State.BitLocker -eq 'FullyEncrypted') {
            if ($BitLockerPolicy -eq 'Block') { $blockers += 'C 盘已开启磁盘加密，本版本暂不压缩，请先备份并保留现有分区。' }
            elseif ($BitLockerPolicy -ne 'AllowWithRecoveryKeyConfirmation') { $blockers += '无法确认磁盘加密的分区规则，已停止。' }
        }
        elseif ($State.BitLocker -ne 'Off') {
            $failure = Get-PcReadFailure 'BitLocker' $AtApply
            if ($failure.Fatal) { $blockers += $failure.Reason } else { $pending += $failure.Reason }
        }
        $hint = Get-PcRecoveryKeyHint $State.BitLocker
        if ($hint) { $warnings += $hint }
        if ($null -eq $State.MaxShrinkBytes) {
            $failure = Get-PcReadFailure 'MaxShrink' $AtApply
            if ($failure.Fatal) { $blockers += $failure.Reason }
            else {
                $pending += $failure.Reason
                $warnings += '当前按剩余空间估算，最终可分出的大小将在执行前由 Windows 确认；不足时会停止。'
            }
        }
    }
    return [pscustomobject]@{ Blockers = @($blockers | Select-Object -Unique); PendingChecks = @($pending | Select-Object -Unique); Warnings = @($warnings) }
}

function Get-PcReadFailure {
    param([string]$Read, [bool]$AtApply = $false)
    # 布局及盘符是规划依据，缺失即停止；仅辅助安全检查可留待提权后确认。
    $pending = ''; $reason = '无法完整读取硬盘布局或盘符，暂时不能规划；需要获得管理员权限后重新检查。'
    switch ($Read) {
        'DiskKind' { $pending = '执行前会再确认硬盘是否使用特殊的磁盘组合或管理方式。'; $reason = '获得权限后仍无法确认硬盘是否使用特殊的磁盘组合或管理方式，已停止。' }
        'BitLocker' { $pending = '执行前会再确认 C 盘的磁盘加密状态。'; $reason = '获得权限后仍无法确认 C 盘加密状态，不能安全压缩。' }
        'MaxShrink' { $pending = '执行前会再确认 Windows 允许分出的最大空间。'; $reason = '获得权限后仍无法读取 Windows 允许分出的最大空间，不能压缩。' }
    }
    $fatal = $AtApply -or -not $pending
    if (-not $fatal) { $reason = $pending }
    return [pscustomobject]@{ Fatal = [bool]$fatal; NeedsElevatedRead = (-not $AtApply); Reason = $reason }
}

function New-PcUnavailablePlan {
    param([string]$Sid, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $failure = Get-PcReadFailure 'Layout'
    return [pscustomobject]@{ Schema = 'pc-care/partition-plan/1'; GeneratedAt = $Now.ToString('o'); UserSid = $Sid
        Disk = $null; Fingerprint = ''; Situation = 'Unknown'; Mode = 'None'; Feasible = $false; NeedsElevatedRead = $failure.NeedsElevatedRead
        Blockers = @($failure.Reason); PendingChecks = @(); Warnings = @(); Before = @(); After = @(); CAfterBytes = $null
        NewVolumes = @(); PurposeMappings = @(); UsableBytes = $null; Summary = $failure.Reason; RequiresSecondChatConfirmation = $true; RequiresRecoveryKeyConfirmation = $false; RecoveryKeyHint = ''
        NextStep = 'partition'; Advice = '请先确认管理员权限，再重新检查硬盘布局；当前未修改任何分区。' }
}

function Get-PcRecoveryWarning {
    param($Disk)
    $ordered = @($Disk.Partitions | Sort-Object Offset)
    for ($i = 0; $i -lt $ordered.Count - 1; $i++) {
        if ($ordered[$i].DriveLetter -eq 'C' -and $ordered[$i + 1].Type -eq 'Recovery') {
            '恢复分区紧跟在 C 盘后面；新数据分区会排在两者之间，以后不能直接扩大 C 盘。'
        }
    }
}

function Get-PcRecoveryKeyHint {
    param([string]$BitLockerState)
    if ($BitLockerState -eq 'FullyEncrypted') {
        return 'C 盘已加密，请先在聊天中确认能找到恢复密钥。密钥通常在微软账户恢复密钥页面（https://aka.ms/myrecoverykey）、打印件、U 盘或自己保存的文件中。'
    }
    if ($BitLockerState -eq 'Unknown') { return '未能读取 C 盘的加密状态；如果你知道 C 盘已加密，请先确认能找到恢复密钥。' }
    return ''
}

function New-PcPartitionPlan {
    param($State, [string]$LayoutJson = '', [datetimeoffset]$Now = [datetimeoffset]::Now,
        [string]$BitLockerPolicy = $script:BitLockerShrinkPolicy)
    $blockers = @(); $pending = @(); $warnings = @('操作前请先把重要文件备份到移动硬盘或云盘。', '同一块硬盘上的不同分区不算备份，重要文件仍需另外保留一份。')
    $request = $null; $explicit = $false
    if ($LayoutJson) {
        try {
            $request = ConvertFrom-Json -InputObject $LayoutJson -ErrorAction Stop
            if ($null -eq $request -or $request -is [array] -or $request -is [string] -or $request -is [ValueType]) { throw '布局必须是对象。' }
            $explicit = $null -ne (Get-PcValue $request 'DiskNumber')
        }
        catch { $blockers += '无法读取调整方案，请提供包含 Count 或 Volumes 的完整 JSON 对象。' }
    }
    $systems = @($State.Disks | Where-Object { $_.Number -eq $State.SystemDiskNumber })
    if ($systems.Count -ne 1) { throw '没有找到 C 盘所在的硬盘，无法安全规划。' }
    $system = $systems[0]; $disk = $system; $situation = 'InsufficientSpace'; $mode = 'None'
    $data = @(); foreach ($d in $State.Disks) { foreach ($p in $d.Partitions) { if (Test-PcDataPartition $d $p) { $data += $p } } }
    if ($explicit) {
        [int]$requestedNumber = -1
        if (-not [int]::TryParse([string]$request.DiskNumber, [ref]$requestedNumber) -or $requestedNumber -lt 0) { $blockers += '指定的硬盘编号无效。' }
        $selected = @($State.Disks | Where-Object { $_.Number -eq $requestedNumber })
        if ($selected.Count -ne 1) { $blockers += '找不到指定的硬盘。' }
        else { $disk = $selected[0] }
        if (-not (Test-PcInternalDisk $disk)) { $blockers += '指定的是移动设备，本版本不处理，请选择电脑内部硬盘。' }
        if ($disk.Number -ne $system.Number -and -not (Test-PcEmptyDisk $disk $true)) { $blockers += '指定的非系统硬盘不能确认为空硬盘，已保留原状。' }
    }
    $candidates = @($system.Partitions | Where-Object { $_.DriveLetter -eq 'C' })
    if ($candidates.Count -ne 1) { throw '无法唯一确认 C 盘分区，已停止规划。' }
    $c = $candidates[0]; [long]$cAfter = $c.Size; [long]$usable = 0; [long]$start = 0
    if ($data.Count -gt 0) { $situation = 'ExistingData'; $disk = $system }
    else {
        $extent = @(Get-PcFreeExtents $disk | Where-Object { $_.Size -ge 20GB } | Sort-Object Size -Descending)
        if ($extent.Count -gt 0 -and ($disk.Number -eq $system.Number -or (Test-PcEmptyDisk $disk $explicit))) {
            $situation = 'UnallocatedSpace'; $mode = 'Create'; $start = $extent[0].Offset; $usable = $extent[0].Size
            if ($disk.Number -ne $system.Number) { $situation = 'EmptyDisk' }
        }
        elseif (-not $explicit) {
            $empty = @($State.Disks | Where-Object { $_.Number -ne $system.Number -and (Test-PcEmptyDisk $_ $false) } | Sort-Object Number)
            if ($empty.Count -gt 0) {
                $disk = $empty[0]; $extent = @(Get-PcFreeExtents $disk | Where-Object { $_.Size -ge 20GB } | Sort-Object Size -Descending)
                if ($extent.Count -gt 0) { $situation = 'EmptyDisk'; $mode = 'Create'; $start = $extent[0].Offset; $usable = $extent[0].Size }
            }
        }
        if ($mode -eq 'None' -and $disk.Number -eq $system.Number) {
            if ($null -eq $State.CUsedBytes) { $blockers += '无法读取 C 盘已用空间，不能计算需要保留的空间。' }
            else {
                $usable = Get-PcUsable $c.Size $State.CUsedBytes $State.MaxShrinkBytes
                # 同时为边界对齐留足空间，不能压过保留线。
                $start = Get-PcAligned ([long]$c.Offset + [long]$c.Size - $usable) -Up
                $usable = Get-PcAligned ([long]$c.Offset + [long]$c.Size - $start)
                if ($usable -ge 20GB) { $situation = 'ShrinkC'; $mode = 'Shrink' }
            }
        }
    }
    $new = @(); $mappings = @(); $before = @($disk.Partitions); $after = @($before)
    if ($mode -ne 'None') {
        $safety = Get-PcSafety $State $disk ($mode -eq 'Shrink') $false $BitLockerPolicy
        $blockers += $safety.Blockers; $pending += $safety.PendingChecks; $warnings += $safety.Warnings
        if ($mode -eq 'Shrink' -and $c.FileSystem -ne 'NTFS') { $blockers += 'C 盘不是受支持的普通文件分区，不能压缩。' }
        $volumes = @(Get-PcValue $request 'Volumes' @())
        $countValue = Get-PcValue $request 'Count'; [int]$count = 0
        if ($null -ne $countValue -and (-not [int]::TryParse([string]$countValue, [ref]$count) -or $count -lt 1 -or $count -gt 23)) { $blockers += '分区数量请填写 1 到 23 的整数。'; $count = 0 }
        if ($volumes.Count -eq 0) { $volumes = @(Get-PcDefaultLayout $usable $count) }
        elseif ($null -ne $countValue -and $count -ne $volumes.Count) { $blockers += '分区数量与分区列表不一致。' }
        $resolved = Resolve-PcLayout $volumes $usable $State.UsedLetters
        $blockers += $resolved.Reasons; $blockers += @(Get-PcMbrReasons $disk $volumes.Count)
        if ($mode -eq 'Shrink') {
            # 固定大小布局只压出需要的量，rest 也仅在此求值一次。
            $start = (Get-PcAligned ([long]$c.Offset + [long]$c.Size)) - $resolved.TotalBytes
            $cAfter = [long]($start - $c.Offset)
            if ($cAfter -lt (Get-PcReserve $State.CUsedBytes)) { $blockers += '调整后 C 盘保留空间不足，请减少新分区大小。' }
        }
        [long]$offset = $start
        foreach ($v in $resolved.Volumes) {
            $new += [pscustomobject]@{ DiskNumber = [int]$disk.Number; Offset = $offset; Size = [long]$v.Size
                DriveLetter = $v.DriveLetter; Label = $v.Label; Folders = @($v.Folders) }
            if ($offset -le [long]::MaxValue - $v.Size) { $offset += $v.Size }
        }
        $after = @($before | ForEach-Object {
            $size = [long]$_.Size; if ($mode -eq 'Shrink' -and $_.DriveLetter -eq 'C') { $size = $cAfter }
            [pscustomobject]@{ PartitionNumber = $_.PartitionNumber; Offset = $_.Offset; Size = $size; DriveLetter = $_.DriveLetter; Type = $_.Type }
        }) + @($new)
        $warnings += @(Get-PcRecoveryWarning $system)
        if ($disk.PartitionStyle -eq 'RAW') { $warnings += ('将把空硬盘 ' + $disk.Number + ' 建立为可用的新硬盘，再创建数据分区。') }
    }
    elseif ($situation -eq 'ExistingData') {
        for ($i = 0; $i -lt $data.Count; $i++) {
            $purpose = '资料'; if ($i -eq 1) { $purpose = '软件与游戏' }; if ($i -ge 2) { $purpose = '影音与归档' }
            $mappings += [pscustomobject]@{ DiskNumber = $data[$i].DiskNumber; DriveLetter = $data[$i].DriveLetter; Purpose = $purpose; Folders = @(Get-PcDefaultFolders $purpose) }
        }
    }
    if ($situation -eq 'InsufficientSpace') { $warnings += '现有空间不足，不分区；建议先清理 C 盘，仍不足时加装硬盘或使用移动硬盘。' }
    $summary = '已有数据分区，保留现有布局，按用途整理后即可搬家。'
    if ($situation -eq 'InsufficientSpace') { $summary = '空间不足，先清理 C 盘；仍不够时建议加装硬盘或使用移动硬盘。' }
    if ($new.Count -gt 0) {
        $descriptions = @($new | ForEach-Object { '{0} 盘 {1:0.#} GB（{2}）' -f $_.DriveLetter, ($_.Size / 1GB), $_.Label }) -join '、'
        $summary = '在硬盘 ' + $disk.Number + ' 的空闲空间新增 ' + $descriptions + '。'
        if ($mode -eq 'Shrink') { $summary = ('C 盘从 {0:0.#} GB 变成 {1:0.#} GB，新增 ' -f ($c.Size / 1GB), ($cAfter / 1GB)) + $descriptions + '。' }
    }
    if ($blockers.Count -gt 0) { $summary = '暂时不能执行分区方案：' + ($blockers | Select-Object -First 1) }
    $recoveryKeyHint = ''
    if ($mode -eq 'Shrink') { $recoveryKeyHint = Get-PcRecoveryKeyHint $State.BitLocker }
    return [pscustomobject]@{ Schema = 'pc-care/partition-plan/1'; GeneratedAt = $Now.ToString('o'); UserSid = [string](Get-PcValue $State 'UserSid' '')
        Disk = [pscustomobject]@{ Number = [int]$disk.Number; UniqueId = $disk.UniqueId; SerialNumber = $disk.SerialNumber; Size = [long]$disk.Size; PartitionStyle = $disk.PartitionStyle }
        Fingerprint = Get-PcFingerprint $State $disk.Number; Situation = $situation; Mode = $mode; Feasible = ($blockers.Count -eq 0); NeedsElevatedRead = ($pending.Count -gt 0)
        Blockers = @($blockers | Select-Object -Unique); PendingChecks = @($pending | Select-Object -Unique); Warnings = @($warnings | Select-Object -Unique)
        Before = @($before); After = @($after); CAfterBytes = $cAfter; NewVolumes = @($new); PurposeMappings = @($mappings)
        UsableBytes = $usable; Summary = $summary; RequiresSecondChatConfirmation = $true
        RequiresRecoveryKeyConfirmation = ($mode -eq 'Shrink' -and $State.BitLocker -in @('FullyEncrypted', 'Unknown')); RecoveryKeyHint = $recoveryKeyHint
        NextStep = 'move'; Advice = '分区完成后可按目录安排搬家；以后安装软件时请选择软件盘。' }
}

function Test-PcOverlap {
    param($Left, $Right)
    return ($Left.DiskNumber -eq $Right.DiskNumber -and
        [decimal]$Left.Offset -lt ([decimal]$Right.Offset + [decimal]$Right.Size) -and
        [decimal]$Right.Offset -lt ([decimal]$Left.Offset + [decimal]$Left.Size))
}

function Test-PcFrozenPlan {
    param($PlanObject, $State, [datetimeoffset]$Now = [datetimeoffset]::Now, [string]$BitLockerPolicy = $script:BitLockerShrinkPolicy)
    $reasons = @()
    try {
        if ($PlanObject.Schema -cne 'pc-care/partition-plan/1' -or $PlanObject.Feasible -isnot [bool] -or -not $PlanObject.Feasible) {
            $reasons += '这不是可执行的分区方案，请重新规划。'
        }
        if ($PlanObject.GeneratedAt -is [datetimeoffset]) { $date = $PlanObject.GeneratedAt }
        elseif ($PlanObject.GeneratedAt -is [datetime]) { $date = [datetimeoffset]::new($PlanObject.GeneratedAt) }
        else { $date = [datetimeoffset]::Parse($PlanObject.GeneratedAt, [Globalization.CultureInfo]::InvariantCulture) }
        if (($Now - $date).TotalHours -gt 1 -or $date -gt $Now.AddMinutes(1)) { $reasons += '方案已超过一小时或时间不正确，请重新规划并确认。' }
        if ($PlanObject.Mode -notin @('None', 'Shrink', 'Create')) { $reasons += '方案的操作类型无效。' }
        $disks = @($State.Disks | Where-Object { $_.Number -eq $PlanObject.Disk.Number })
        if ($disks.Count -ne 1) { throw '找不到方案指定的硬盘。' }
        $disk = $disks[0]
        if ($PlanObject.Fingerprint -cne (Get-PcFingerprint $State $disk.Number)) { $reasons += '硬盘或现有分区已经变化，请重新规划并确认。' }
        if ($PlanObject.Disk.UniqueId -cne $disk.UniqueId -or $PlanObject.Disk.SerialNumber -cne $disk.SerialNumber -or
            [long]$PlanObject.Disk.Size -ne $disk.Size -or $PlanObject.Disk.PartitionStyle -ne $disk.PartitionStyle) { $reasons += '方案中的硬盘身份与当前硬盘不符。' }
        $system = @($State.Disks | Where-Object { $_.Number -eq $State.SystemDiskNumber })[0]
        $c = @($system.Partitions | Where-Object { $_.DriveLetter -eq 'C' })[0]
        if ($PlanObject.Mode -eq 'None') {
            if (@($PlanObject.NewVolumes).Count -ne 0 -or $PlanObject.CAfterBytes -ne $c.Size) { $reasons += '不分区的方案不能包含磁盘修改。' }
        }
        else {
            $reasons += (Get-PcSafety $State $disk ($PlanObject.Mode -eq 'Shrink') $true $BitLockerPolicy).Blockers
            foreach ($d in $State.Disks) {
                if (@($d.Partitions | Where-Object { Test-PcDataPartition $d $_ }).Count -gt 0) {
                    $reasons += '现在已有可用的数据分区，请保留布局，改用现有数据盘整理和搬家。'
                }
            }
            # 非系统盘只允许已确认空盘；有盘符或无盘符的文件卷都不能绕过此检查。
            if ($disk.Number -ne $State.SystemDiskNumber -and -not (Test-PcEmptyDisk $disk $true)) { $reasons += '指定的非系统硬盘不能确认为空硬盘，不能修改。' }
            if ($disk.PartitionStyle -eq 'RAW' -and @($disk.Partitions).Count -ne 0) { $reasons += '尚未建立分区表的硬盘并非空盘，不能修改。' }
            if (@($PlanObject.NewVolumes).Count -lt 1) { $reasons += '方案缺少新分区。' }
            $volumes = @(); [decimal]$total = 0
            foreach ($v in $PlanObject.NewVolumes) {
                if ($v.Size -isnot [long] -and $v.Size -isnot [int]) { $reasons += '方案中的分区大小不是完整字节数。' }
                if ($v.Offset -isnot [long] -and $v.Offset -isnot [int]) { $reasons += '方案中的分区位置不是完整字节数。' }
                if ($v.Size -lt 20GB -or $v.Size % 1MB -ne 0 -or $v.Offset -lt 1MB -or $v.Offset % 1MB -ne 0 -or $v.DiskNumber -ne $disk.Number) {
                    $reasons += '新分区的位置、大小或硬盘编号不安全。'
                }
                $volumes += [pscustomobject]@{ SizeGB = ([decimal]$v.Size / 1GB); Label = $v.Label; Letter = $v.DriveLetter; Folders = @($v.Folders) }
                $total += [decimal]$v.Size
            }
            if ($total -gt $disk.Size -or $total -gt [long]::MaxValue) { throw '新分区总大小超过硬盘容量。' }
            $resolved = Resolve-PcLayout $volumes ([long]$total) $State.UsedLetters
            $reasons += $resolved.Reasons; $reasons += @(Get-PcMbrReasons $disk $volumes.Count)
            $new = @($PlanObject.NewVolumes); [long]$first = $new[0].Offset; [decimal]$cursor = $first
            foreach ($v in $new) {
                if ([decimal]$v.Offset -ne $cursor) { $reasons += '方案中的新分区位置不连续，请重新规划。' }
                $cursor += [decimal]$v.Size
            }
            if ($PlanObject.Mode -eq 'Shrink') {
                if ($disk.Number -ne $State.SystemDiskNumber -or $c.FileSystem -ne 'NTFS' -or
                    $PlanObject.CAfterBytes -isnot [long] -and $PlanObject.CAfterBytes -isnot [int]) { $reasons += '本版本只允许压缩 C 盘。' }
                if ($null -eq $State.CUsedBytes -or $PlanObject.CAfterBytes -lt (Get-PcReserve ([long]$State.CUsedBytes))) { $reasons += 'C 盘当前需要保留更多空间，已停止，请重新规划。' }
                [long]$shrink = [long]$c.Size - [long]$PlanObject.CAfterBytes
                if ($shrink -le 0 -or $PlanObject.CAfterBytes -gt $c.Size -or
                    $null -eq $State.MaxShrinkBytes -or $shrink -gt $State.MaxShrinkBytes -or $total -gt $State.MaxShrinkBytes) {
                    $reasons += 'Windows 当前允许分出的空间不足，已停止，请重新规划。'
                }
                if ($first -ne (Get-PcAligned ([long]$c.Offset + [long]$PlanObject.CAfterBytes) -Up) -or
                    $cursor -gt ([decimal]$c.Offset + [decimal]$c.Size)) { $reasons += '新分区超出了 C 盘将让出的空间。' }
                foreach ($v in $new) { foreach ($p in $disk.Partitions) { if ($p.DriveLetter -ne 'C' -and (Test-PcOverlap $v $p)) { $reasons += '新分区与现有分区重叠，不能执行。' } } }
            }
            else {
                if ($PlanObject.CAfterBytes -ne $c.Size) { $reasons += '使用空闲空间的方案不能改变 C 盘。' }
                $extents = @(Get-PcFreeExtents $disk | Where-Object { $_.Offset -le $first -and ([decimal]$_.Offset + $_.Size) -ge $cursor })
                if ($extents.Count -eq 0) { $reasons += '方案指定的位置已没有足够的连续空闲空间，已停止。' }
            }
        }
    }
    catch { $reasons += '无法完整核实方案或当前磁盘状态，已停止；请重新生成方案。' }
    return [pscustomobject]@{ Valid = ($reasons.Count -eq 0); Reasons = @($reasons | Select-Object -Unique) }
}

function Get-PcPartitionSteps {
    param($PlanObject)
    if ($PlanObject.Mode -eq 'None') { return }
    if ($PlanObject.Disk.PartitionStyle -eq 'RAW') {
        [pscustomobject]@{ Id = 'InitializeDisk'; VolumeIndex = -1; Description = ('建立空硬盘 ' + $PlanObject.Disk.Number + ' 的分区表') }
    }
    if ($PlanObject.Mode -eq 'Shrink') {
        [pscustomobject]@{ Id = 'ShrinkC'; VolumeIndex = -1; Description = ('把 C 盘缩小到 {0:0.#} GB' -f ($PlanObject.CAfterBytes / 1GB)) }
    }
    for ($i = 0; $i -lt @($PlanObject.NewVolumes).Count; $i++) {
        $v = $PlanObject.NewVolumes[$i]
        foreach ($id in @('NewPartition', 'FormatVolume', 'AssignLetter', 'CreateFolders')) {
            $text = '新建分区'; if ($id -eq 'FormatVolume') { $text = '把本次新分区建立为 NTFS 文件盘' }; if ($id -eq 'AssignLetter') { $text = '分配盘符并核实新数据盘' }; if ($id -eq 'CreateFolders') { $text = '建立分类目录' }
            [pscustomobject]@{ Id = $id; VolumeIndex = $i; Description = ($text + '：' + $v.DriveLetter + ' 盘（' + $v.Label + '）') }
        }
    }
}

function Resolve-PcAfterShrink {
    param($OriginalC, $ActualC, [long]$PlannedCSize, [object[]]$NewVolumes, [long]$LiveReserve)
    $reason = ''; $adjusted = @()
    if ($ActualC.DiskNumber -ne $OriginalC.DiskNumber -or $ActualC.PartitionNumber -ne $OriginalC.PartitionNumber -or
        $ActualC.Offset -ne $OriginalC.Offset -or $ActualC.DriveLetter -ne 'C' -or $ActualC.Size -gt $OriginalC.Size -or
        [math]::Abs([decimal]$ActualC.Size - $PlannedCSize) -gt 64MB -or $ActualC.Size -lt $LiveReserve) {
        $reason = 'C 盘实际大小或位置与方案差异过大，已停止后续操作。'
    }
    if (-not $reason) {
        [long]$cursor = Get-PcAligned ([long]$ActualC.Offset + [long]$ActualC.Size) -Up
        [long]$lost = [math]::Max([long]0, $cursor - [long]$NewVolumes[0].Offset)
        for ($i = 0; $i -lt $NewVolumes.Count; $i++) {
            $v = $NewVolumes[$i]; [long]$size = $v.Size
            if ($i -eq $NewVolumes.Count - 1) { $size -= $lost }
            if ($size -lt 20GB) { $reason = 'Windows 对齐后最后一个分区不足 20 GB，已停止后续操作。' }
            $adjusted += [pscustomobject]@{ DiskNumber = $v.DiskNumber; Offset = $cursor; Size = $size; DriveLetter = $v.DriveLetter; Label = $v.Label; Folders = @($v.Folders) }
            $cursor += $size
        }
        if ($cursor -gt ([decimal]$OriginalC.Offset + $OriginalC.Size)) { $reason = '对齐后的分区超出 C 盘已让出的范围，已停止。' }
    }
    return [pscustomobject]@{ Valid = (-not $reason); Reason = $reason; NewVolumes = @($adjusted); CAfterBytes = [long]$ActualC.Size }
}

function Test-PcNewPartitionLetter {
    param([string]$Letter, $UsedLettersBefore)
    # 缺少新建前的快照时，只允许无盘符；盘符本身永远不能作为新分区的身份证明。
    return ($Letter -eq '' -or ($null -ne $UsedLettersBefore -and $Letter -match '^[D-Z]$' -and $Letter -notin $UsedLettersBefore))
}

function Test-PcCreatedSize {
    param($Planned, $Actual, $UsedLettersBefore)
    return ($Actual.DiskNumber -eq $Planned.DiskNumber -and $Actual.PartitionNumber -gt 0 -and
        (Test-PcNewPartitionLetter $Actual.DriveLetter $UsedLettersBefore) -and
        [math]::Abs([decimal]$Actual.Offset - $Planned.Offset) -le 1MB -and
        $Actual.Size -le $Planned.Size -and $Actual.Size -ge ($Planned.Size - 16MB) -and $Actual.Size -ge 20GB)
}

function Test-PcCreatedTarget {
    param($Target, [object[]]$Created, [object[]]$PreExisting, [object[]]$Current, [string]$RunId,
        [string[]]$FileSystems, [string]$Letter = '')
    if ($null -eq $Target -or [string]::IsNullOrWhiteSpace($RunId)) { return $false }
    $records = @($Created | Where-Object { $_.RunId -ceq $RunId -and $_.Partition.DiskNumber -eq $Target.DiskNumber -and $_.Partition.PartitionNumber -eq $Target.PartitionNumber })
    if ($records.Count -ne 1 -or $Target.IsSystem -or $Target.IsBoot -or $Target.IsHidden -or $Target.FileSystem -notin $FileSystems) { return $false }
    $usedBefore = Get-PcValue $records[0] 'UsedLettersBefore'
    if ($Letter) { if ($Target.DriveLetter -ne $Letter) { return $false } }
    elseif (-not (Test-PcNewPartitionLetter $Target.DriveLetter $usedBefore)) { return $false }
    $r = $records[0].Partition
    if (-not (Test-PcNewPartitionLetter $r.DriveLetter $usedBefore) -or $r.FileSystem -notin @('', 'RAW')) { return $false }
    foreach ($field in @('Offset', 'Size')) { if ($r.$field -ne $Target.$field) { return $false } }
    foreach ($p in $PreExisting) {
        if ($p.DiskNumber -eq $Target.DiskNumber -and $p.PartitionNumber -eq $Target.PartitionNumber) { return $false }
        if (Test-PcOverlap $Target $p) { return $false }
    }
    $matches = @($Current | Where-Object { $_.DiskNumber -eq $Target.DiskNumber -and $_.PartitionNumber -eq $Target.PartitionNumber })
    if ($matches.Count -ne 1) { return $false }
    foreach ($field in @('Offset', 'Size', 'DriveLetter', 'FileSystem', 'IsSystem', 'IsBoot', 'IsHidden')) {
        if ($matches[0].$field -ne $Target.$field) { return $false }
    }
    foreach ($p in $Current) {
        if ($p.DiskNumber -eq $Target.DiskNumber -and $p.PartitionNumber -eq $Target.PartitionNumber) { continue }
        if (Test-PcOverlap $Target $p) { return $false }
    }
    return $true
}

function Test-PcFormatTarget {
    param($Target, [object[]]$Created, [object[]]$PreExisting, [object[]]$Current, [string]$RunId)
    return Test-PcCreatedTarget $Target $Created $PreExisting $Current $RunId @('', 'RAW')
}

function Get-PcLetterTakenReason {
    param([string]$Letter)
    return ('计划的 ' + $Letter + ' 盘盘符已被占用，已停止；本次新建的文件盘仍没有盘符，未建立目录，请先检查当前布局，不要重复执行。')
}

function Resolve-PcPartitionLetter {
    param([string]$CurrentLetter, [string]$PlannedLetter, [string[]]$UsedLetters)
    $letter = $PlannedLetter; $reason = ''; $warning = ''
    if ($CurrentLetter -ne $PlannedLetter -and $PlannedLetter -in $UsedLetters) {
        if ($CurrentLetter) {
            $letter = $CurrentLetter
            $warning = '计划的 ' + $PlannedLetter + ' 盘盘符已被占用，新数据盘使用了 ' + $letter + ' 盘'
        }
        else { $reason = Get-PcLetterTakenReason $PlannedLetter }
    }
    return [pscustomobject]@{ Valid = (-not $reason); Reason = $reason; Letter = $letter
        NeedsChange = ($CurrentLetter -ne $letter); Warning = $warning }
}

function Test-PcAssignLetter {
    param($Target, [object[]]$Created, [object[]]$PreExisting, [object[]]$Current, [string]$RunId,
        [string]$Letter, [string[]]$UsedLetters)
    if ($Letter -notmatch '^[D-Z]$' -or -not (Test-PcCreatedTarget $Target $Created $PreExisting $Current $RunId @('NTFS'))) {
        return [pscustomobject]@{ Valid = $false; Reason = '无法核实本次新建的文件盘，已停止分配盘符。' }
    }
    return Resolve-PcPartitionLetter $Target.DriveLetter $Letter $UsedLetters
}

function ConvertFrom-PcShellBitLockerProtection {
    param($Value)
    # Shell 枚举与 Get-BitLockerVolume 的枚举不同；只接受整数，避免隐式转换把异常值当成已解密。
    if ($Value -isnot [byte] -and $Value -isnot [sbyte] -and $Value -isnot [int16] -and $Value -isnot [uint16] -and
        $Value -isnot [int32] -and $Value -isnot [uint32] -and $Value -isnot [int64] -and $Value -isnot [uint64]) { return 'Unknown' }
    switch ([string]$Value) {
        '1' { return 'FullyEncrypted' }
        '5' { return 'FullyEncrypted' }
        '2' { return 'Off' }
        '3' { return 'Converting' }
        '4' { return 'Converting' }
        default { return 'Unknown' }
    }
}

function ConvertTo-PcBitLockerState {
    param([string]$VolumeStatus, [string]$ProtectionStatus, $EncryptionPercentage)
    # 转换状态优先于保护状态：暂停保护不等于已解密。
    if ($VolumeStatus -in @('EncryptionInProgress', 'DecryptionInProgress', 'EncryptionPaused', 'DecryptionPaused', '2', '3', '4', '5')) { return 'Converting' }
    $percentage = $null
    if ($null -ne $EncryptionPercentage) {
        [decimal]$number = 0
        if (-not [decimal]::TryParse(([string]$EncryptionPercentage).Replace(',', '.'), [Globalization.NumberStyles]::Number,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0 -or $number -gt 100) { return 'Unknown' }
        $percentage = $number
        if ($percentage -gt 0 -and $percentage -lt 100) { return 'Converting' }
    }
    if ($VolumeStatus -in @('FullyEncrypted', '1') -and ($null -eq $percentage -or $percentage -eq 100) -and $ProtectionStatus -in @('On', 'Off', '0', '1')) { return 'FullyEncrypted' }
    if ($VolumeStatus -in @('FullyDecrypted', '0') -and ($null -eq $percentage -or $percentage -eq 0) -and $ProtectionStatus -in @('Off', '0')) { return 'Off' }
    return 'Unknown'
}

function ConvertFrom-PcBitLockerStatus {
    param([string]$Text)
    $volume = ''; $protection = ''; $percentage = $null
    if ($Text -match '(?im)^\s*(?:Conversion Status|转换状态)\s*[:：]\s*(.+?)\s*$') {
        $status = $Matches[1]
        switch -Regex ($status) {
            '^(Fully Encrypted|完全加密|已完全加密|仅已用空间加密|仅已用空间已加密|仅加密已用空间|Used Space Only Encrypted)$' { $volume = 'FullyEncrypted'; break }
            '^(Fully Decrypted|完全解密|已完全解密)$' { $volume = 'FullyDecrypted'; break }
            '(Encryption|Decryption).*(Progress|Paused)|加密.*(进行|暂停|已暂停)|解密.*(进行|暂停|已暂停)|正在(加密|解密)|(加密|解密)中' { $volume = 'EncryptionInProgress'; break }
        }
    }
    if ($Text -match '(?im)^\s*(?:Protection Status|保护状态)\s*[:：]\s*(?:Protection On|保护打开|保护开启|保护已打开|保护已开启|保护已启用|开启|打开)[ \t]*(?:[(（][^\r\n]*[)）])?[ \t]*\r?$') { $protection = 'On' }
    elseif ($Text -match '(?im)^\s*(?:Protection Status|保护状态)\s*[:：]\s*(?:Protection Off|保护关闭|保护已关闭|保护已禁用|关闭)[ \t]*(?:[(（][^\r\n]*[)）])?[ \t]*\r?$') { $protection = 'Off' }
    if ($Text -match '(?im)^\s*(?:Percentage Encrypted|已加密百分比|加密百分比)\s*[:：]\s*([0-9]+(?:[.,][0-9]+)?)\s*%\s*$') { $percentage = $Matches[1] }
    return ConvertTo-PcBitLockerState $volume $protection $percentage
}

function ConvertTo-PcProtectorTypes {
    param($Protectors)
    # 仅提取已知类型；原对象可能带恢复密码，禁止回传或序列化。
    $types = @(); $known = ($null -ne $Protectors)
    $names = @('Unknown', 'Tpm', 'ExternalKey', 'RecoveryPassword', 'TpmPin', 'TpmStartupKey', 'TpmPinAndStartupKey', 'PublicKey', 'Passphrase', 'TpmCertificate', 'SidProtector')
    foreach ($p in @($Protectors)) {
        $type = [string](Get-PcValue $p 'KeyProtectorType' '')
        [int]$number = -1
        if ([int]::TryParse($type, [ref]$number) -and $number -ge 0 -and $number -lt $names.Count) { $type = $names[$number] }
        if ($type -notin $names -or $type -eq 'Unknown') { $known = $false }
        else { $types += $type }
    }
    return [pscustomobject]@{ Known = $known; Types = @($types | Select-Object -Unique) }
}

function ConvertFrom-PcProtectorStatus {
    param([string]$Text)
    # manage-bde 的密码行只在内存中经过；只返回固定类型名。
    $types = @(); $candidates = @()
    $headings = [ordered]@{
        RecoveryPassword = 'Numerical Password|Recovery Password|数字密码|恢复密码'
        Tpm = 'TPM'; ExternalKey = 'External Key|外部密钥'
        TpmPin = 'TPM And PIN|TPM 和 PIN'; TpmStartupKey = 'TPM And Startup Key|TPM 和启动密钥'
        TpmPinAndStartupKey = 'TPM And PIN And Startup Key|TPM 和 PIN 和启动密钥'
        PublicKey = 'Certificate|证书'; Passphrase = 'Password|密码'; SidProtector = 'Identity|标识'
    }
    foreach ($name in $headings.Keys) {
        foreach ($match in [regex]::Matches($Text, ('(?im)^(?<indent>[ \t]*)(?:' + $headings[$name] + ')[ \t]*[:：][ \t]*\r?$'))) {
            $candidates += [pscustomobject]@{ Type = $name; Indent = $match.Groups['indent'].Value.Length }
        }
    }
    if ($candidates.Count -gt 0) {
        # 数字密码下面还会有更深缩进的 Password 字段，它不是另一个保护器。
        $indent = @($candidates | Sort-Object Indent)[0].Indent
        $types = @($candidates | Where-Object { $_.Indent -eq $indent } | ForEach-Object { $_.Type } | Select-Object -Unique)
    }
    $empty = $Text -match '(?im)^\s*(?:None Found[.]?|未找到(?:任何)?密钥保护器[。.]?|找不到密钥保护器[。.]?)\s*$'
    return [pscustomobject]@{ Known = ($types.Count -gt 0 -or $empty); Types = @($types) }
}

function Get-PcRecoveryProtectorReason {
    param($Protectors)
    if (-not [bool](Get-PcValue $Protectors 'Known' $false)) { return '无法确认这台电脑是否有磁盘加密恢复密钥，不能安全分区。' }
    if ('RecoveryPassword' -notin @(Get-PcValue $Protectors 'Types' @())) { return '这台电脑的磁盘加密没有恢复密钥，万一需要时无法解锁，本版本不分区' }
    return ''
}

function Invoke-PcPartitionExecution {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($PlanObject, $State, $Context, [string]$BitLockerPolicy = $script:BitLockerShrinkPolicy, [hashtable]$ChildState, [switch]$RecoveryKeyConfirmed)
    $runId = [guid]::NewGuid().ToString('N'); $steps = @(Get-PcPartitionSteps $PlanObject)
    $result = [pscustomobject]@{ Schema = 'pc-care/partition/1'; GeneratedAt = [datetimeoffset]::Now.ToString('o'); RunId = $runId
        UserSid = $Context.CurrentUserSid; Status = 'Done'; Reason = ''; StoppedAt = $null; Steps = @(); CreatedPartitions = @(); FinalLayout = @(); UnassignedFormattedPartitions = @()
        CAfterBytes = $PlanObject.CAfterBytes; DiskNumber = $PlanObject.Disk.Number; NextStep = 'move'; Warnings = @(); Volumes = @() }
    # 必须最先返回；连重新检查、日志、提权及外部只读工具也不能在演练时运行。
    if ($WhatIfPreference) {
        $result.Status = 'WhatIf'
        foreach ($step in $steps) { Write-Host ('将执行：' + $step.Description); $result.Steps += [pscustomobject]@{ Id = $step.Id; VolumeIndex = $step.VolumeIndex; Status = 'WhatIf'; Description = $step.Description } }
        return $result
    }
    $validation = Test-PcFrozenPlan $PlanObject $State -BitLockerPolicy $BitLockerPolicy
    if (-not $validation.Valid) { $result.Status = 'Refused'; $result.StoppedAt = 'Preflight'; $result.Reason = $validation.Reasons -join '；'; return $result }
    if (-not $Context.IsAdmin -or ($Context.CurrentUserSid -cne $PlanObject.UserSid)) {
        $result.Status = 'Skipped'; $result.StoppedAt = 'Elevation'; $result.Reason = '未取得原账户的管理员权限，已跳过分区。'; return $result
    }
    if ($PlanObject.Mode -eq 'Shrink' -and $State.BitLocker -eq 'FullyEncrypted') {
        if (-not $RecoveryKeyConfirmed) {
            $result.Status = 'NeedsRecoveryKeyConfirmation'; $result.StoppedAt = 'Preflight'
            $result.Reason = 'C 盘已加密，请先在聊天中确认你能找到恢复密钥，再执行分区；未修改任何分区。'
            return $result
        }
        $reason = Get-PcRecoveryProtectorReason (Read-PcRecoveryProtectors $Context)
        if ($reason) { $result.Status = 'Refused'; $result.StoppedAt = 'Preflight'; $result.Reason = $reason; return $result }
    }
    if (-not $PSCmdlet.ShouldProcess($PlanObject.Summary, '执行已在聊天中二次确认的分区方案')) { $result.Status = 'Skipped'; $result.Reason = '未执行分区。'; return $result }
    $disk = @($State.Disks | Where-Object { $_.Number -eq $PlanObject.Disk.Number })[0]
    $preExisting = @($disk.Partitions); $working = @($PlanObject.NewVolumes); $created = @(); $finalLetters = @{}; $active = 'Preflight'
    $system = @($State.Disks | Where-Object { $_.Number -eq $State.SystemDiskNumber })[0]
    $originalC = @($system.Partitions | Where-Object { $_.DriveLetter -eq 'C' })[0]
    try {
        foreach ($step in $steps) {
            $active = $step.Id + ':' + $step.VolumeIndex
            $record = [pscustomobject]@{ Id = $step.Id; VolumeIndex = $step.VolumeIndex; Description = $step.Description; Status = 'Started'; Actual = $null; Reason = '' }
            $result.Steps += $record
            Write-PcPartitionLog $active 'Started' $step.Description $Context
            # 与提权包装器共享，只在可能触及磁盘的步骤开始时置位；异常退出后仍不能误报“未修改”。
            if ($null -ne $ChildState) { $ChildState.StepMayHaveRun = $true }
            switch ($step.Id) {
                'InitializeDisk' { Initialize-PcDisk $disk.Number; $record.Actual = Read-PcDisk $disk.Number }
                'ShrinkC' {
                    Resize-PcC $originalC.DiskNumber $originalC.PartitionNumber $PlanObject.CAfterBytes
                    $actualC = Read-PcPartition $originalC.DiskNumber $originalC.PartitionNumber
                    $record.Actual = $actualC; $result.CAfterBytes = [long]$actualC.Size
                    $adjusted = Resolve-PcAfterShrink $originalC $actualC $PlanObject.CAfterBytes $working (Get-PcReserve $State.CUsedBytes)
                    if (-not $adjusted.Valid) { throw $adjusted.Reason }
                    $working = @($adjusted.NewVolumes)
                    $preExisting = @($preExisting | Where-Object { $_.PartitionNumber -ne $originalC.PartitionNumber }) + @($actualC)
                }
                'NewPartition' {
                    $v = $working[$step.VolumeIndex]
                    $liveParts = @(Read-PcDiskPartitions $disk.Number)
                    foreach ($p in $liveParts) { if (Test-PcOverlap $v $p) { throw '新分区的位置已被占用，已停止。' } }
                    $usedBefore = @(Read-PcUsedLetters)
                    if ($v.DriveLetter -in $usedBefore) { throw '计划的盘符已被占用，已停止。' }
                    $new = New-PcDataPartition $v
                    # New-Partition 返回的精确对象是本次创建证据；随后再独立读取一次。
                    $created += [pscustomobject]@{ RunId = $runId; Partition = $new; UsedLettersBefore = $usedBefore }
                    $result.CreatedPartitions = @($created); $record.Actual = $new
                    $actual = Read-PcPartition $new.DiskNumber $new.PartitionNumber
                    $record.Actual = $actual | Select-Object *
                    if (-not (Test-PcCreatedSize $v $new $usedBefore) -or -not (Test-PcCreatedSize $v $actual $usedBefore) -or
                        $new.Offset -ne $actual.Offset -or $new.Size -ne $actual.Size -or $new.PartitionNumber -ne $actual.PartitionNumber) { throw '新分区的实际位置或大小超出允许差异，已停止，未格式化。' }
                }
                'FormatVolume' {
                    $entry = $created[$step.VolumeIndex]; $target = Read-PcPartition $entry.Partition.DiskNumber $entry.Partition.PartitionNumber
                    $current = @(Read-PcDiskPartitions $disk.Number)
                    if (-not (Test-PcFormatTarget $target $created $preExisting $current $runId)) { throw '不能证明目标分区由本次操作新建，已停止，未格式化。' }
                    Format-PcNewVolume $target $working[$step.VolumeIndex].Label $entry.UsedLettersBefore
                    $formatted = Read-PcPartition $target.DiskNumber $target.PartitionNumber
                    $record.Actual = $formatted | Select-Object *
                    if (-not (Test-PcCreatedTarget $formatted $created $preExisting @(Read-PcDiskPartitions $disk.Number) $runId @('NTFS'))) { throw '新文件盘格式或位置未能核实，已停止。' }
                }
                'AssignLetter' {
                    $v = $working[$step.VolumeIndex]; $entry = $created[$step.VolumeIndex]
                    $target = Read-PcPartition $entry.Partition.DiskNumber $entry.Partition.PartitionNumber
                    $current = @(Read-PcDiskPartitions $disk.Number)
                    $check = Test-PcAssignLetter $target $created $preExisting $current $runId $v.DriveLetter @(Read-PcUsedLetters)
                    if (-not $check.Valid) { throw $check.Reason }
                    [string]$finalLetter = $check.Letter
                    if ($check.NeedsChange) { $finalLetter = Set-PcPartitionLetter $target $v.DriveLetter $entry.UsedLettersBefore }
                    $assigned = Read-PcPartition $target.DiskNumber $target.PartitionNumber
                    $record.Actual = $assigned
                    if ($finalLetter -notmatch '^[D-Z]$' -or -not (Test-PcCreatedTarget $assigned $created $preExisting @(Read-PcDiskPartitions $disk.Number) $runId @('NTFS') $finalLetter)) { throw '新数据盘的盘符、格式、位置或大小未能核实，已停止建立目录。' }
                    $finalLetters[$step.VolumeIndex] = $finalLetter
                    if ($finalLetter -ne $v.DriveLetter) {
                        $choice = Resolve-PcPartitionLetter $finalLetter $v.DriveLetter @($v.DriveLetter)
                        $record.Reason = $choice.Warning; $result.Warnings += $choice.Warning
                    }
                }
                'CreateFolders' {
                    $v = $working[$step.VolumeIndex]; $entry = $created[$step.VolumeIndex]
                    $target = Read-PcPartition $entry.Partition.DiskNumber $entry.Partition.PartitionNumber
                    $letter = $finalLetters[$step.VolumeIndex]
                    if (-not (Test-PcCreatedTarget $target $created $preExisting @(Read-PcDiskPartitions $disk.Number) $runId @('NTFS') $letter)) { throw '新数据盘发生变化，已停止建立目录。' }
                    foreach ($folder in $v.Folders) { New-PcVolumeFolder $letter $folder }
                    $record.Actual = $target
                }
            }
            $record.Status = 'Done'
            Write-PcPartitionLog $active 'Done' ($record | ConvertTo-Json -Depth 8 -Compress) $Context
        }
    }
    catch {
        $result.Status = 'Failed'; $result.StoppedAt = $active
        $message = $_.Exception.Message
        # 适配器将系统异常换成中文；决策异常本身是中文。
        $result.Reason = $message
        if ($result.Steps.Count -gt 0) { $result.Steps[-1].Status = 'Failed'; $result.Steps[-1].Reason = $message }
        try { Write-PcPartitionLog $active 'Failed' $message $Context } catch { }
    }
    try { $result.FinalLayout = @(Read-PcDiskPartitions $disk.Number) }
    catch { if ($result.Status -eq 'Done') { $result.Status = 'Failed'; $result.StoppedAt = 'FinalLayout'; $result.Reason = '操作结束后无法读取完整布局，请先检查磁盘状态，不要重复执行。' } }
    for ($i = 0; $i -lt $created.Count; $i++) {
        $entry = $created[$i]; $v = $working[$i]
        $matches = @($result.FinalLayout | Where-Object { $_.DiskNumber -eq $entry.Partition.DiskNumber -and
            $_.PartitionNumber -eq $entry.Partition.PartitionNumber -and $_.Offset -eq $entry.Partition.Offset -and $_.Size -eq $entry.Partition.Size })
        $letter = $null; if ($matches.Count -eq 1) { $letter = $matches[0].DriveLetter }
        $result.Volumes += [pscustomobject]@{ DiskNumber = $entry.Partition.DiskNumber; PartitionNumber = $entry.Partition.PartitionNumber
            Label = $v.Label; PlannedLetter = $v.DriveLetter; DriveLetter = $letter }
    }
    $result.UnassignedFormattedPartitions = @($result.FinalLayout | Where-Object {
        $part = $_
        $part.FileSystem -eq 'NTFS' -and $part.DriveLetter -eq '' -and @($created | Where-Object {
            $_.Partition.DiskNumber -eq $part.DiskNumber -and $_.Partition.PartitionNumber -eq $part.PartitionNumber -and
            $_.Partition.Offset -eq $part.Offset -and $_.Partition.Size -eq $part.Size
        }).Count -eq 1
    })
    if ($result.UnassignedFormattedPartitions.Count -gt 0 -and $result.Reason -notmatch '仍没有盘符') { $result.Reason += ' 本次新建的文件盘仍没有盘符，请先检查当前布局。' }
    return $result
}

# 以下是 Windows / 文件系统适配层。测试用内存假对象替换这些入口。
function ConvertTo-PcPartitionRecord {
    param($Partition, $Volume)
    $letter = [string](Get-PcValue $Partition 'DriveLetter' '')
    if ($letter -notmatch '^[A-Za-z]$') { $letter = '' }
    $type = [string](Get-PcValue $Partition 'Type' '')
    $gpt = ([string](Get-PcValue $Partition 'GptType' '')).Trim('{}').ToLowerInvariant()
    [int]$mbr = Get-PcValue $Partition 'MbrType' 0
    if ($gpt -eq 'de94bba4-06d1-4d40-a16a-bfd50179d6ac' -or $mbr -eq 39) { $type = 'Recovery' }
    if ($mbr -in @(5, 15, 133)) { $type = 'Extended' }
    return [pscustomobject]@{ DiskNumber = [int]$Partition.DiskNumber; PartitionNumber = [int]$Partition.PartitionNumber
        Offset = [long]$Partition.Offset; Size = [long]$Partition.Size; Type = $type; GptType = $gpt; MbrType = $mbr
        DriveLetter = $letter.ToUpperInvariant(); HasVolume = ($null -ne $Volume); FileSystem = [string](Get-PcValue $Volume 'FileSystem' '')
        VolumeSize = Get-PcValue $Volume 'Size'; FreeBytes = Get-PcValue $Volume 'SizeRemaining'; Label = [string](Get-PcValue $Volume 'FileSystemLabel' '')
        IsSystem = [bool](Get-PcValue $Partition 'IsSystem' $false); IsBoot = [bool](Get-PcValue $Partition 'IsBoot' $false); IsHidden = [bool](Get-PcValue $Partition 'IsHidden' $false) }
}

function Read-PcPartition {
    param([int]$DiskNumber, [int]$PartitionNumber)
    try {
        $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
        $volume = $null
        try { $volume = Get-Volume -Partition $p -ErrorAction Stop | Select-Object -First 1 }
        catch { if ([string]$p.DriveLetter -match '^[A-Za-z]$') { throw } }
        return ConvertTo-PcPartitionRecord $p $volume
    }
    catch { throw '无法读取分区及文件盘信息，已停止。' }
}

function Read-PcDiskPartitions {
    param([int]$DiskNumber)
    try {
        $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if ($disk.NumberOfPartitions -eq 0) { return }
        $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)
        if ($partitions.Count -ne $disk.NumberOfPartitions) { throw '分区清单不完整。' }
        foreach ($p in $partitions) { Read-PcPartition $DiskNumber $p.PartitionNumber }
    }
    catch { throw '无法完整读取硬盘分区，已停止。' }
}

function Read-PcDisk {
    param([int]$DiskNumber)
    try {
        $d = Get-Disk -Number $DiskNumber -ErrorAction Stop
        return [pscustomobject]@{ Number = [int]$d.Number; UniqueId = [string]$d.UniqueId; SerialNumber = [string]$d.SerialNumber
            Size = [long]$d.Size; PartitionStyle = [string]$d.PartitionStyle }
    }
    catch { throw '无法读取指定硬盘的身份，已停止。' }
}

function Read-PcUsedLetters {
    try {
        $letters = @()
        foreach ($v in @(Get-Volume -ErrorAction Stop)) { if ([string]$v.DriveLetter -match '^[A-Za-z]$') { $letters += ([string]$v.DriveLetter).ToUpperInvariant() } }
        foreach ($p in @(Get-PSDrive -PSProvider FileSystem -ErrorAction Stop)) { if ($p.Name -match '^[A-Za-z]$') { $letters += $p.Name.ToUpperInvariant() } }
        return @($letters | Sort-Object -Unique)
    }
    catch { throw '无法确认当前可用的盘符，已停止；请先检查当前布局。' }
}

function Read-PcShellBitLockerProtection {
    if ($WhatIfPreference) { return $null }
    $shell = $null; $folder = $null; $item = $null
    try {
        $shell = New-Object -ComObject Shell.Application -ErrorAction Stop
        $folder = $shell.NameSpace('C:')
        $item = $folder.Self
        return ,($item.ExtendedProperty('System.Volume.BitLockerProtection'))
    }
    catch { return $null }
    finally {
        foreach ($com in @($item, $folder, $shell)) {
            try { if ($null -ne $com -and [Runtime.InteropServices.Marshal]::IsComObject($com)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($com) } }
            catch { }
        }
    }
}

function Read-PcBitLocker {
    param($Context)
    if ($WhatIfPreference) { return 'Unknown' }
    # 普通权限只读 Shell 属性；执行阶段仍须由原有管理员接口得出肯定结论。
    if (-not [bool](Get-PcValue $Context 'IsAdmin' $false)) {
        return ConvertFrom-PcShellBitLockerProtection (Read-PcShellBitLockerProtection)
    }
    if ($null -ne (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        try {
            $b = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            $state = ConvertTo-PcBitLockerState ([string](Get-PcValue $b 'VolumeStatus' '')) ([string](Get-PcValue $b 'ProtectionStatus' '')) (Get-PcValue $b 'EncryptionPercentage')
            if ($state -ne 'Unknown') { return $state }
        }
        catch { }
    }
    try {
        $directory = [Environment]::SystemDirectory
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $directory = Join-Path $Context.SystemRoot 'Sysnative' }
        $encoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        $r = Invoke-External -FilePath (Join-Path $directory 'manage-bde.exe') -ArgumentList @('-status', 'C:') -Description '只读检查 C 盘加密状态' -Context $Context -OutputEncoding $encoding -Confirm:$false
        return ConvertFrom-PcBitLockerStatus $r.StandardOutput
    }
    catch { return 'Unknown' }
}

function Read-PcRecoveryProtectors {
    param($Context)
    if ($WhatIfPreference) { return [pscustomobject]@{ Known = $false; Types = @() } }
    try {
        $b = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        # 直接取属性以保留已知的空数组；普通管道会把空数组变成 null。
        if ($b -is [Collections.IDictionary]) { $protectors = $b['KeyProtector'] }
        else { $protectors = $b.KeyProtector }
        $types = ConvertTo-PcProtectorTypes $protectors
        if ($types.Known) { return $types }
    }
    catch { }
    try {
        $directory = [Environment]::SystemDirectory
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $directory = Join-Path $Context.SystemRoot 'Sysnative' }
        $encoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        # Invoke-External 的失败审计默认带原始 stderr；本查询可能含密码，
        # 在本地作用域替换审计入口，只记录固定说明，绝不记录工具输出或异常。
        function Write-CleanerAudit {
            param($Action, $Path, $Result, $Bytes, $Message, $Context)
            Write-CleanerLog -Action 'Partition:RecoveryProtectorCheck' -Path 'C:' -Result $Result -Message '只读检查磁盘加密恢复密钥类型。' -Context $Context -Confirm:$false
        }
        $r = Invoke-External -FilePath (Join-Path $directory 'manage-bde.exe') -ArgumentList @('-protectors', '-get', 'C:') -Description '只读检查磁盘加密恢复密钥类型' -Context $Context -OutputEncoding $encoding -Confirm:$false
        return ConvertFrom-PcProtectorStatus $r.StandardOutput
    }
    catch { return [pscustomobject]@{ Known = $false; Types = @() } }
}

function Read-PcPartitionState {
    param($Context)
    $disks = @(); $legacy = $null; $spaces = $null
    try { $legacy = @(Get-CimInstance -ClassName Win32_DiskPartition -ErrorAction Stop) } catch { }
    try {
        $spaces = @()
        foreach ($v in @(Get-VirtualDisk -ErrorAction Stop)) { $spaces += @($v | Get-Disk -ErrorAction Stop | ForEach-Object { [int]$_.Number }) }
    }
    catch { $spaces = $null }
    foreach ($native in @(Get-Disk -ErrorAction Stop)) {
        $parts = @(); $complete = $true
        # 任何硬盘的分区表读不全，都不能把缺失的分区当成空闲或空盘。
        $parts = @(Read-PcDiskPartitions $native.Number)
        $dynamic = $null; $pooled = $null
        if ($null -ne $legacy) { $dynamic = (@($legacy | Where-Object { $_.DiskIndex -eq $native.Number -and $_.Type -match 'Logical Disk Manager|Dynamic|动态' }).Count -gt 0) }
        if (@($parts | Where-Object { $_.MbrType -eq 66 -or $_.GptType -in @('af9b60a0-1431-4f62-bc68-3311714a69ad', '5808c8aa-7e8f-42e0-85d2-e1e90434cfb3') }).Count -gt 0) { $dynamic = $true }
        if ($null -ne $spaces) { $pooled = ([int]$native.Number -in $spaces) }
        if ([string]$native.BusType -eq 'Spaces') { $pooled = $true }
        $disks += [pscustomobject]@{ Number = [int]$native.Number; UniqueId = [string]$native.UniqueId; SerialNumber = [string]$native.SerialNumber
            Size = [long]$native.Size; PartitionStyle = [string]$native.PartitionStyle; BusType = [string]$native.BusType
            IsRemovable = [bool](Get-PcValue $native 'IsRemovable' $false); IsOffline = [bool]$native.IsOffline; IsReadOnly = [bool]$native.IsReadOnly
            IsDynamic = $dynamic; IsStorageSpaces = $pooled; InspectionComplete = $complete; Partitions = @($parts) }
    }
    $cp = @($disks | ForEach-Object { $_.Partitions } | Where-Object { $_.DriveLetter -eq 'C' })
    if ($Context.SystemDrive -ne 'C:' -or $cp.Count -ne 1) { throw '本版本需要能唯一确认的 C 盘系统分区，当前电脑无法安全处理。' }
    $c = $cp[0]; $used = $null; $max = $null
    if ($null -ne $c.FreeBytes -and $null -ne $c.VolumeSize -and $c.VolumeSize -gt 0 -and $c.FreeBytes -ge 0 -and $c.FreeBytes -le $c.VolumeSize) {
        $used = [long]($c.VolumeSize - $c.FreeBytes)
    }
    try {
        $supported = Get-PartitionSupportedSize -DiskNumber $c.DiskNumber -PartitionNumber $c.PartitionNumber -ErrorAction Stop
        if ($supported.SizeMin -gt 0 -and $supported.SizeMin -le $c.Size) { $max = [long]($c.Size - $supported.SizeMin) }
    }
    catch { }
    return [pscustomobject]@{ Disks = @($disks); SystemDiskNumber = [int]$c.DiskNumber; CUsedBytes = $used; MaxShrinkBytes = $max
        BitLocker = Read-PcBitLocker $Context; UsedLetters = @(Read-PcUsedLetters); UserSid = $Context.CurrentUserSid }
}

function Initialize-PcDisk {
    param([int]$DiskNumber)
    try {
        $d = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if ($d.PartitionStyle -ne 'RAW' -or $d.NumberOfPartitions -ne 0) { throw '目标不是空白硬盘。' }
        $null = Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false -ErrorAction Stop
        $d = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if ($d.PartitionStyle -ne 'GPT') { throw '未能确认新的分区表。' }
    }
    catch { throw '建立空硬盘分区表失败，已停止，不会重试。' }
}

function Resize-PcC {
    param([int]$DiskNumber, [int]$PartitionNumber, [long]$Size)
    try {
        $c = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
        if ([string]$c.DriveLetter -ne 'C' -or $Size -ge $c.Size) { throw '只允许压缩 C 盘。' }
        $null = Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -Size $Size -Confirm:$false -ErrorAction Stop
    }
    catch { throw '缩小 C 盘失败，已停止，不会重试。' }
}

function New-PcDataPartition {
    param($Volume)
    try {
        $p = New-Partition -DiskNumber $Volume.DiskNumber -Offset $Volume.Offset -Size $Volume.Size -Confirm:$false -ErrorAction Stop
        return ConvertTo-PcPartitionRecord $p $null
    }
    catch { throw '新建分区失败，已停止，不会重试；请先检查当前布局。' }
}

function Format-PcNewVolume {
    param($Partition, [string]$Label, $UsedLettersBefore)
    try {
        $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -ErrorAction Stop
        $currentVolume = Get-Volume -Partition $p -ErrorAction Stop | Select-Object -First 1
        $live = ConvertTo-PcPartitionRecord $p $currentVolume
        if ($live.DiskNumber -ne $Partition.DiskNumber -or $live.PartitionNumber -ne $Partition.PartitionNumber -or
            $live.Offset -ne $Partition.Offset -or $live.Size -ne $Partition.Size -or
            -not (Test-PcNewPartitionLetter $live.DriveLetter $UsedLettersBefore) -or -not (Test-PcNewPartitionLetter $Partition.DriveLetter $UsedLettersBefore) -or
            $live.IsSystem -or $live.IsBoot -or $live.IsHidden -or $live.FileSystem -notin @('', 'RAW')) { throw '目标不再是本次的新空分区。' }
        # 按精确分区对象传递，绝不使用可能已经换盘的盘符作为格式化目标。
        $null = Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false -ErrorAction Stop
    }
    catch { throw '新分区建立文件盘失败，已停止，不会重试；请先检查当前布局。' }
}

function Set-PcPartitionLetter {
    param($Partition, [string]$Letter, $UsedLettersBefore)
    try {
        $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -ErrorAction Stop
        $volume = Get-Volume -Partition $p -ErrorAction Stop | Select-Object -First 1
        $live = ConvertTo-PcPartitionRecord $p $volume
        if ($Letter -notmatch '^[D-Z]$' -or $live.DiskNumber -ne $Partition.DiskNumber -or $live.PartitionNumber -ne $Partition.PartitionNumber -or
            $live.Offset -ne $Partition.Offset -or $live.Size -ne $Partition.Size -or
            -not (Test-PcNewPartitionLetter $live.DriveLetter $UsedLettersBefore) -or $live.FileSystem -ne 'NTFS' -or
            $live.IsSystem -or $live.IsBoot -or $live.IsHidden) { throw '目标发生变化。' }
        $choice = Resolve-PcPartitionLetter $live.DriveLetter $Letter @(Read-PcUsedLetters)
    }
    catch { throw '分配盘符前无法核实新文件盘或可用盘符，已停止；请先检查当前布局。' }
    if (-not $choice.Valid) { throw $choice.Reason }
    if ($choice.NeedsChange) {
        try { $null = Set-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -NewDriveLetter $Letter -Confirm:$false -ErrorAction Stop }
        catch { throw '分配盘符失败，已停止；请先检查当前布局，不要重复执行。' }
    }
    return $choice.Letter
}

function New-PcVolumeFolder {
    param([string]$Letter, [string]$Name)
    if ($Letter -notmatch '^[D-Z]$' -or -not (Test-PcFolderName $Name)) { throw '目录名称或位置不安全，已停止。' }
    $path = $Letter + ':\' + $Name
    $check = Test-CleanerPathChain -LiteralPath $path -AllowMissing
    if (-not $check.IsSafe) { throw '新数据盘的目录位置无法安全使用，已停止。' }
    $guards = $null
    try {
        $guards = Open-CleanerParentGuards -LiteralPath $path
        $null = [IO.Directory]::CreateDirectory($path)
    }
    catch { throw '建立分类目录失败，已停止；已完成的分区会保留。' }
    finally { if ($null -ne $guards) { foreach ($h in $guards.Handles) { $h.Dispose() } } }
}

function Write-PcPartitionLog {
    param([string]$Step, [string]$Status, [string]$Message, $Context)
    try { Write-CleanerLog -Action ('Partition:' + $Step) -Path ('DiskPartition') -Result $Status -Message $Message -Context $Context -Confirm:$false }
    catch { throw '无法记录分区操作日志，已停止；不要直接重复执行，请先检查当前布局。' }
}

function Get-PcOutputPath {
    param([string]$Path, [string]$Kind, $Context)
    if (-not $Path -and $null -eq $Context) { throw '无法确定结果保存位置，请指定普通本地文件夹中的新文件名。' }
    if (-not $Path) { $Path = Join-Path ([IO.Path]::GetDirectoryName($Context.LogPath)) ($Kind + '-' + [guid]::NewGuid().ToString('N') + '.json') }
    $Path = [IO.Path]::GetFullPath($Path)
    $check = Test-CleanerPathChain -LiteralPath $Path -AllowMissing
    if (-not $check.IsSafe -or $check.Exists) { throw '结果保存位置不可用或文件已存在，请使用普通本地文件夹中的新文件名。' }
    return $Path
}

function Write-PcJson {
    param($Value, [string]$Path)
    $check = Test-CleanerPathChain -LiteralPath $Path -AllowMissing
    if (-not $check.IsSafe -or $check.Exists) { throw '结果保存位置不可用或文件已存在，未覆盖原文件。' }
    $stream = $null; $writer = $null
    try {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.Write((ConvertTo-Json -InputObject $Value -Depth 8))
    }
    catch { throw '无法保存结果文件；请先检查磁盘实际布局，不要重复执行分区。' }
    finally { if ($null -ne $writer) { $writer.Dispose() }; if ($null -ne $stream) { $stream.Dispose() } }
}

function Read-PcJson {
    param([string]$Path)
    $check = Test-CleanerPathChain -LiteralPath $Path
    if (-not $check.IsSafe -or -not $check.Exists) { throw '方案文件不存在或位置不可用。' }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw '无法读取方案或结果文件，请重新规划。' }
}

function ConvertTo-PcLiteral {
    param([string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

function New-PcElevationCommand {
    param([string]$ScriptPath, [string]$InputPath, [string]$OutputPath, [string]$Sid, [switch]$RecoveryKeyConfirmed, [string]$LogDirectory, [string]$OriginalUserProfile)
    $confirmation = ''; if ($RecoveryKeyConfirmed) { $confirmation = ' -RecoveryKeyConfirmed' }
    # 13：换账户；12：捕获异常且尚未进入磁盘步骤；21：步骤可能已运行。其他退出码不能证明未修改。
    return ('$ErrorActionPreference = ''Stop''; $childState = @{ StepMayHaveRun = $false }; try { if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne ' + (ConvertTo-PcLiteral $Sid) + ') { exit 13 }; & ' + (ConvertTo-PcLiteral $ScriptPath) + ' -Apply -ElevatedChild -PlanPath ' + (ConvertTo-PcLiteral $InputPath) +
        ' -ResultPath ' + (ConvertTo-PcLiteral $OutputPath) + ' -OriginalUserSid ' + (ConvertTo-PcLiteral $Sid) +
        ' -OriginalUserProfile ' + (ConvertTo-PcLiteral $OriginalUserProfile) + ' -LogDirectory ' + (ConvertTo-PcLiteral $LogDirectory) + $confirmation + ' -ChildState $childState -Confirm:$false -WhatIf:$false; exit 0 } catch { if ($childState.StepMayHaveRun) { exit 21 }; exit 12 }')
}

function Get-PcElevationArguments {
    param([string]$Command)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    # 仅设置子进程策略；不修改机器或用户的执行策略。
    return @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
}

function Start-PcElevatedApply {
    param([string]$Command)
    $exe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $PSHOME 'powershell.exe' }
    $p = Start-Process -FilePath $exe -ArgumentList (Get-PcElevationArguments $Command) -Verb RunAs -Wait -PassThru -ErrorAction Stop
    try { return [int]$p.ExitCode } finally { $p.Dispose() }
}

function New-PcSkippedResult {
    param([string]$Reason, [string]$Sid, [string]$Status = 'Skipped')
    return [pscustomobject]@{ Schema = 'pc-care/partition/1'; GeneratedAt = [datetimeoffset]::Now.ToString('o'); UserSid = $Sid
        Status = $Status; StoppedAt = 'Elevation'; Reason = $Reason; Steps = @(); CreatedPartitions = @(); FinalLayout = @() }
}

function New-PcPreflightResult {
    param([string]$Sid, [string]$Reason = '无法读取方案文件或当前硬盘状态，执行前检查未完成，已停止；未修改任何分区，请重新检查并规划。')
    $r = New-PcSkippedResult $Reason $Sid 'Refused'
    $r.StoppedAt = 'Preflight'
    return $r
}

function Get-PcMissingChildResult {
    param([int]$ExitCode, [string]$Sid)
    if ($ExitCode -eq 12) { return New-PcPreflightResult $Sid '管理员窗口没有正常运行，尚未开始分区操作；未修改任何分区，请重新检查后再规划。' }
    $reason = '管理员执行结果缺失，无法确认是否完成；请先检查磁盘状态，不要重复执行。'
    if ($ExitCode -ne 0) { $reason = '管理员窗口没有正常运行，执行结果缺失，无法确认是否已修改分区；请先检查磁盘状态，不要重复执行。' }
    return New-PcSkippedResult $reason $Sid 'Failed'
}

function Invoke-PcPartitionMain {
    param([string]$ScriptPath, [bool]$Planning, [string]$LayoutJson, [string]$InputPath, [string]$OutputPath,
        [string]$ExpectedSid, [bool]$Child, [bool]$DryRun, [string]$BitLockerPolicy = $script:BitLockerShrinkPolicy, [hashtable]$ChildState, [switch]$RecoveryKeyConfirmed, [string]$LogDirectory, [string]$OriginalProfile)
    if ($DryRun) {
        if ($Planning) { Write-Host '演练：只读规划并新建方案文件；当前不会写入文件。'; return }
        try {
            $p = Read-PcJson $InputPath
            $r = Invoke-PcPartitionExecution $p $null @{ CurrentUserSid = '' } -WhatIf
        }
        catch { $r = New-PcPreflightResult '' }
        Write-Output (ConvertTo-Json -InputObject $r -Depth 8)
        # 演练不写结果；RESULT 仅指向已存在的输入方案。
        Write-Output ('RESULT: ' + [IO.Path]::GetFullPath($InputPath)); return
    }
    $context = $null
    if ($Child -and (-not $LogDirectory -or -not $OriginalProfile)) { throw '没有收到原账户的记录目录，已停止分区。' }
    $contextArgs = @{}
    if ($Child) { $contextArgs.OriginalUserSid = $ExpectedSid; $contextArgs.OriginalUserProfile = $OriginalProfile }
    if ($LogDirectory) { $contextArgs.LogDirectory = $LogDirectory }
    try { $context = Get-CleanerContext @contextArgs }
    catch { }
    if ($Planning) {
        try {
            if ($null -eq $context) { throw '无法读取当前账户信息。' }
            $state = Read-PcPartitionState $context
            $p = New-PcPartitionPlan $state $LayoutJson -BitLockerPolicy $BitLockerPolicy
        }
        catch { $p = New-PcUnavailablePlan ([string](Get-PcValue $context 'CurrentUserSid' '')) }
        $path = Get-PcOutputPath $InputPath 'partition-plan' $context
        Write-PcJson $p $path
        Write-Host $p.Summary; Write-Output ('RESULT: ' + $path); return
    }
    $path = Get-PcOutputPath $OutputPath 'partition-result' $context
    if ($null -eq $context) { $r = New-PcPreflightResult $ExpectedSid '无法读取当前账户信息，执行前检查未完成，已停止；未修改任何分区。' }
    elseif ($ExpectedSid -and $ExpectedSid -cne $context.CurrentUserSid) {
        $r = New-PcSkippedResult '提权使用了另一个账户，已跳过分区，未修改任何分区；请使用原账户确认权限。' $context.CurrentUserSid
    }
    elseif (-not $context.IsAdmin -and -not $Child) {
        $command = New-PcElevationCommand $ScriptPath ([IO.Path]::GetFullPath($InputPath)) $path $context.CurrentUserSid -RecoveryKeyConfirmed:$RecoveryKeyConfirmed -LogDirectory (Split-Path -Path $context.LogPath -Parent) -OriginalUserProfile $context.OriginalUserProfile
        try { $exitCode = Start-PcElevatedApply $command }
        catch {
            $r = New-PcSkippedResult '没有获得管理员权限，已跳过分区。' $context.CurrentUserSid
            Write-PcJson $r $path; Write-Output ('RESULT: ' + $path); return
        }
        if ($exitCode -eq 13) {
            $r = New-PcSkippedResult '提权使用了另一个账户，已跳过分区，未修改任何分区；请使用原账户确认权限。' $context.CurrentUserSid
            Write-PcJson $r $path; Write-Output ('RESULT: ' + $path); return
        }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $childResult = Read-PcJson $path
            if ($childResult.Schema -cne 'pc-care/partition/1') { throw '管理员结果无法核实，请检查磁盘状态，不要重复执行。' }
            Write-Host $childResult.Reason; Write-Output ('RESULT: ' + $path); return
        }
        $r = Get-PcMissingChildResult $exitCode $context.CurrentUserSid
    }
    elseif (-not $context.IsAdmin) { $r = New-PcSkippedResult '没有获得管理员权限，已跳过分区。' $context.CurrentUserSid }
    else {
        if ($null -eq $ChildState) { $ChildState = @{ StepMayHaveRun = $false } }
        try {
            $p = Read-PcJson $InputPath
            $state = Read-PcPartitionState $context
            $r = Invoke-PcPartitionExecution $p $state $context -BitLockerPolicy $BitLockerPolicy -ChildState $ChildState -RecoveryKeyConfirmed:$RecoveryKeyConfirmed -Confirm:$false
        }
        catch {
            if ($ChildState.StepMayHaveRun) { $r = New-PcSkippedResult '分区操作后无法完整核实结果，已停止；请先检查磁盘状态，不要重复执行。' $context.CurrentUserSid 'Failed' }
            else { $r = New-PcPreflightResult $context.CurrentUserSid }
        }
    }
    Write-PcJson $r $path
    Write-Host $r.Reason; Write-Output ('RESULT: ' + $path)
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '分区规划仅支持 Windows 10 和 Windows 11。' }
. (Join-Path $PSScriptRoot 'common.ps1')
Invoke-PcPartitionMain -ScriptPath $PSCommandPath -Planning ([bool]$Plan) -LayoutJson $Layout -InputPath $PlanPath -OutputPath $ResultPath `
    -LogDirectory $LogDirectory -OriginalProfile $OriginalUserProfile -ExpectedSid $OriginalUserSid -Child ([bool]$ElevatedChild) -DryRun ([bool]$WhatIfPreference) -BitLockerPolicy $script:BitLockerShrinkPolicy -RecoveryKeyConfirmed:$RecoveryKeyConfirmed -ChildState $ChildState
