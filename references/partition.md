# 分区与加密规则

[partition.ps1](../scripts/partition.ps1) 先只读规划，收到用户对最终方案的第二次明确聊天确认后才执行。所有调用由 AI 完成，用户无需复制命令。总体流程见 [SKILL.md](../SKILL.md)。

## 规划

`partition.ps1 -Plan [-Layout <布局JSON>] [-PlanPath <新方案路径>]`。普通权限，不为补检查自动提权；默认使用共享日志目录和唯一文件名，不覆盖旧方案。

布局由 AI 根据用途构造。例如用户说“分成资料和游戏两个盘”，AI 可传 `{"Count":2}`；需定制时可用 `DiskNumber`、`Volumes[].Label/SizeGB/Letter/Folders`。SizeGB 可为正数或最后一项的 `"rest"`；不把 JSON、磁盘编号或实现方式交给用户选择。用途、盘数调整后重新出方案。

读 `RESULT:` 指向的 `Schema=pc-care/partition-plan/1`：

| 字段 | 含义与动作 |
| --- | --- |
| `Mode/Situation` | Mode 为 None（不改布局）、Create（使用空闲空间 / 空盘）或 Shrink（压缩 C 盘）；None 时结合 Situation 的 ExistingData / InsufficientSpace 区分已有数据盘与空间不足 |
| `Feasible/Blockers` | 不可行就解释原因并停下，不执行 |
| `Summary/Before/After/NewVolumes/PurposeMappings` | 用盘符、用途和 GB 数说明前后变化；已有合适盘直接规划搬家 |
| `Warnings` | 备份、恢复分区位置、未来扩容限制等须在确认前说明 |
| `PendingChecks` | 普通权限下未能完成的检查，由 Apply 验证；不能当作已通过 |
| `RequiresSecondChatConfirmation` | 方案须在展示后再次得到明确确认 |
| `RequiresRecoveryKeyConfirmation/RecoveryKeyHint` | 按下表处理加密与恢复密钥 |
| `NextStep/Advice` | 完成后衔接搬家；先确认实际盘符和结果 |

新建仅限系统盘上的可用空间、可安全压缩的 C 盘，或确认过的内部空硬盘；不碰已有数据的其他硬盘，不处理动态磁盘、RAID、存储空间等特殊组合。C 盘压缩后至少保留 `max(已用空间 + 60 GB, 120 GB)`，且受 Windows 最大可压缩量限制。用户要求再小也不能越过脚本边界。

## BitLocker

默认策略允许完成加密的 C 盘在确认恢复密钥后压缩；保护暂停不等于未加密。规划尽可能普通权限读取加密状态，无法读取则记待验证项。只在已加密或状态未知的压缩方案中要求密钥确认。

| 状态 | 规划与执行 |
| --- | --- |
| Off（未加密） | 无需额外密钥确认 |
| FullyEncrypted（加密完成，保护开启或暂停） | 允许规划；执行前须聊天确认能找到恢复密钥，并检查存在恢复密码保护器 |
| Converting（正在或暂停加密 / 解密） | 阻止压缩，说明“C 盘正在加密或解密，完成后才能分区” |
| Unknown（状态未知） | 规划为待检查并要求密钥确认；执行时仍未知则阻止，不猜测 |

`RequiresRecoveryKeyConfirmation=true` 时先解释 `RecoveryKeyHint`，并告知常见位置：微软账户页面 https://aka.ms/myrecoverykey、打印件、U 盘、自己保存的文件。请用户明确确认“能找到恢复密钥”，不要收集密钥本身，不把用户同意分区等同于密钥确认。用户无法找到时停止压缩。

即使已确认能找到，执行时没有恢复密码保护器或无法确认保护器列表也会拒绝。只使用未分配空间或空硬盘新建分区，不压缩 C 盘时，无需这项确认。

## 执行和失败处理

`partition.ps1 -Apply -PlanPath <方案路径> [-RecoveryKeyConfirmed] [-ResultPath <新结果路径>] [-WhatIf]`。

必须在展示最终方案后获得第二次明确聊天确认；密钥确认可以在同一回复里完成，但不能省略任一项。仅当用户已确认能找到密钥时传 RecoveryKeyConfirmed。脚本自行请求 UAC，并检查同一账户、磁盘身份、布局及未完成检查与实时状态；拒绝或换账户按结果跳过。

先创建**没有盘符**的新分区，格式化为 NTFS，再分配盘符和创建目录，避免资源管理器弹“格式化磁盘”。盘符被占用时以实际结果为准，不擅自格式化已有盘符。

实际结果 `Schema=pc-care/partition/1`：`Status/Reason/StoppedAt/Steps/CreatedPartitions/FinalLayout` 解释完成情况；完整执行结果还含 `Volumes/Warnings/NextStep`，可能报告已格式化但未分配盘符的 `UnassignedFormattedPartitions`。不是所有提前退出结果都含全部字段，缺失不能当成功。

- `Done`：按实际布局解释，重新体检后进入逐项搬家。
- `NeedsRecoveryKeyConfirmation` 且停在 Preflight：没有修改分区。请用户确认能找到密钥后加开关重跑；仍须有方案二次确认。
- `Refused/Skipped`：说明未通过的检查或没有获得权限；不能把待检查当成可绕过的提示。
- `Failed`、管理员结果缺失或不确定是否已修改：保留日志，先重新 Plan 并核实当前布局，再展示新方案、重新确认；绝不直接重跑 Apply、自动删除新分区或重新格式化。

WhatIf 不写文件、不提权、不启动外部工具。Apply 演练只读已有方案并在 stdout 给预览 JSON，`RESULT:` 指向原输入方案，不是实际执行结果，也不代表实时检查通过。

## 整理目标与限制解释

按 [按整理目标规划](goal-planning.md) 将目标项目与容量相匹配。布局可含 MigrationItems；结果新增 CapacityAssessment、MigrationAssessment 和 Actionable。只有 Actionable=true 且 Mode=Create/Shrink 才有可执行分区修改；Feasible=true、Mode=None 仍表示不改盘。现有 60 GB 余量规则是技能策略，不等于 Windows 技术极限。不要把分阶段搬家说成支持之后自动扩容。
