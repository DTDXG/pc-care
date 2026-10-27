# pc-care

pc-care 是面向普通中文 Windows 10 / 11 用户的电脑空间保养 skill。用户说“C 盘满了”“把文件搬到 D 盘”“想分区”，AI 负责检查、解释和执行；用户只在聊天里确认，并在系统权限提示出现时点“是”，无需复制命令。

## 四项能力

| 能力 | 做什么 | 入口 |
| --- | --- | --- |
| 体检 | 检查已知占用位置，给出放心清总量、有损失项目、搬家建议和备份提醒 | [checkup.ps1](scripts/checkup.ps1) |
| 清理 | 一次确认清理放心清项目；回收站、休眠文件、旧版系统文件须用户点名 | [clean.ps1](scripts/clean.ps1) |
| 搬家 | 把桌面、文档、下载、图片、视频及微信 / QQ 数据搬到数据盘；搬家、释放、还原均默认后台执行并查询进度，试用后释放原件，开始释放前可还原 | [move.ps1](scripts/move.ps1) |
| 分区 | 先生成前后布局方案，二次确认后使用空闲空间、空硬盘或安全压缩 C 盘新建数据分区 | [partition.ps1](scripts/partition.ps1) |

体检只统计已知位置，目标 30 秒内给结论；当前脚本默认总预算 45 秒、上限 60 秒，真实耗时待测。统计不全时说“至少”，未知不当成零；清理释放量按 C 盘空闲变化估算，可能受其他程序影响。

清理现在有两个模式：默认 `Quick` 对每个缓存项目设置 15 秒预算，在安全检查点停止并报告保留的内容；`Full` 不设缓存预算。二者使用相同的删除安全规则。预算不包含系统工具、UAC 等待及无法中断的单步操作，不能理解为整个清理固定 15 秒完成。旧版 `c-drive-cleaner` 的 `-Quick` 是扫描参数，与此处清理模式不同。

## 安全原则

- 不杀进程。需要退出软件时由 AI 请用户正常关闭，文件被占用就跳过或停止当前项。
- 搬家先复制、校验、切换，保留 C 盘原件。用户正常试用并确认后才释放；目标新增文件允许保留，原文件大小或修改时间变化时须修改时间晚于启用时刻，变化数量不限。目标缺失的原文件数及字节数分别不得超过基线的 2%，旧原件也须通过校验。开始释放后不能自动还原；还原不会合并试用后的新数据。
- AI 在原用户普通会话运行，脚本按需弹 UAC；清理的管理员项目合并为一次提示。拒绝授权或换账户时按结果跳过，不绕过权限检查。
- 压缩后的 C 盘至少保留 `max(已用空间 + 60 GB, 120 GB)`；不移动、删除、合并已有分区，不扩容 C 盘。
- 加密 C 盘仅在用户明确确认能找到 BitLocker 恢复密钥后允许压缩。AI 提示微软账户页面、打印件、U 盘或保存的文件，用户无需交出密钥；正在加密 / 解密、没有恢复密码保护器或无法核实时停止。
- 新分区先不分配盘符，格式化完成再分配，避免出现“格式化磁盘”弹窗。可能已改布局的失败必须重新规划，不能直接重跑执行。
- 同一硬盘的 D 盘不算备份。只提醒备份，不擅自修改备份设置；重要数据仍应另存到移动硬盘或云端。
- 白名单与删除前检查由脚本执行，不处理同步数据、浏览器登录信息或任意系统目录。V1 不做开发者缓存、WSL、Docker、还原点存储、保留存储、页面文件、组件存储、注册表清理和软件卸载。

## 安装与要求

把完整文件夹复制到所用 agent 的 skills 目录，文件夹名用 `pc-care`，保留 `SKILL.md`、`scripts/` 和 `references/` 的相对位置。让 agent 发现并加载 [SKILL.md](SKILL.md)；目录位置按宿主的安装约定，不要求专有界面操作或后台任务功能。

实际操作需要 Windows 10 / 11 和 Windows PowerShell 5.1 或 PowerShell 7，宿主能在原用户会话运行 PowerShell、读取本地结果文件。系统操作需要用户允许 UAC；搬家需要容量足够的本地固定 NTFS 数据盘。新建分区使用 Windows 自带磁盘管理接口。

默认记录目录为原用户的 `%USERPROFILE%\.pc-care\Logs`，不依赖客户端包身份或安装位置。同一用户换用支持本地执行的客户端时仍可使用该目录。保留对旧日志目录的显式支持；已有未完成搬家须按原记录位置继续，不能因新目录为空就重复搬家。具体规则见 [体检与清理参考](references/targets.md)。

用户流程：描述问题 → AI 体检并给建议 → 聊天确认清理或某一项搬家 → AI 执行并解释结果。搬家原件要等用户试用后另行确认释放；分区须先看方案，再明确二次确认。所有命令都由 AI 执行。

## 当前状态

**测试覆盖说明（供维护者与评估者参考，不是用户运行前置条件）：** 本次优化已在 Windows 11 的 Windows PowerShell 5.1 和 PowerShell 7 上验证隔离样本删除、近期/只读/白名单外文件保护、预算停止和默认日志写入。尚未完成 Windows 10 / 11 的全流程验证，不能据此宣称 UAC、系统服务、真实搬家和分区全流程已验证。完整测试矩阵属于维护者的发布验收工作，不要求使用者先准备虚拟机或完成验收。用户授权相应范围后，按 SKILL.md 调用脚本，以本机运行检查和实际结果决定继续、跳过或停止。

当前分支已包含体检、清理、搬家和分区入口，以及搬家模拟测试。搬家、释放和还原返回 `Running` 时，AI 用 `move.ps1 -Status -Id <记录Id>` 每 30 秒查询；`Stalled` 时按原操作续传，搬家也可用 `-ResumeId <记录Id>`。`Done` 须按操作区分搬好待试用、已释放或已还原；`NeedsAppExit` 请用户正常退出软件，`NotEnoughSpace` 先解决空间不足，`AlreadyMoved` 不重复搬家，`Failed` 按原因处理并保留数据，释放失败可能已删部分原件。字段、子项结果及续传规则见 [搬家参考](references/migration.md)。

[体检与清理参考](references/targets.md) 说明项目和结果字段；[分区参考](references/partition.md) 说明布局、加密和失败处理；[产品需求](PRD-pc-care.md) 保留产品背景和演进记录。底层 `common.ps1`、`clean-cache.ps1`、`clean-system.ps1`、`migrate.ps1` 和白名单仍保留复用能力，不代表 V1 启用其全部旧功能。

## 在 Linux 上验证

仅运行语法检查和模拟测试，不在 Linux 执行 Windows 入口。以下是仓库维护者使用的命令，面向用户的操作仍由 AI 代办。

安装本地 PowerShell 7 后，在仓库根目录以 Bash 运行；按实际位置调整可执行文件：

```bash
pc_care_pwsh=/home/wangcheng/.local/opt/pwsh/pwsh
"$pc_care_pwsh" -NoProfile -Command '
$failed = 0
Get-ChildItem -LiteralPath ./scripts -Filter *.ps1 | Sort-Object Name | ForEach-Object {
    $tokens = $null; $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { $parseErrors; $failed += $parseErrors.Count }
}
if ($failed) { exit 1 }
Write-Output "PASS: all scripts parse with zero errors"
'
```

运行所有现存测试（普通断言脚本，不需要 Pester）：

```bash
for pc_care_test in tests/*.tests.ps1; do
  "$pc_care_pwsh" -NoProfile -File "$pc_care_test" || exit 1
done
git diff --check
```

测试只从语法树加载逻辑函数并模拟系统状态，不执行脚本的 Windows 主体；上述命令已包含 `tests/t6-move.tests.ps1`。

Windows 原生隔离测试另行运行 `tests/t10-windows-smoke.ps1 -FixtureParent <已存在的测试目录绝对路径>`。它只创建、处理本次生成的样本，保留近期/只读/白名单外样本供检查，不扫描真实缓存；默认记录目录会新增一条自检日志。分别用 Windows PowerShell 5.1 和 PowerShell 7 验证。

## 按整理目标规划

分区结果提供策略与 Windows 可压缩限制的独立说明，并可通过布局 MigrationItems 估算新数据盘能容纳全部还是部分目标。估算仅供方案解释，不授权分区或搬家；分区后仍需重新体检。默认保留策略未放宽，不支持后续移动或扩容已有分区。详见 [规划参考](references/goal-planning.md)。
