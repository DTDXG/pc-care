# 体检与清理参考

供 AI 读取；向用户用普通中文解释，不展示字段名。入口约定见 [SKILL.md](../SKILL.md)，检测项目来自 [checkup-locations.psd1](../scripts/checkup-locations.psd1)，删除仍受 [targets.psd1](../scripts/targets.psd1) 与 [common.ps1](../scripts/common.ps1) 校验。

## 体检入口与报告

[checkup.ps1](../scripts/checkup.ps1) 的公开参数：

| 参数 | 含义 |
| --- | --- |
| `-ReportPath` | 可选的新 JSON 文件路径；不覆盖已有文件，默认在共享日志目录生成唯一名称 |
| `-LocationTimeoutSeconds` | 每个合并扫描根的预算，默认 15 秒，范围 1–60 |
| `-TotalTimeoutSeconds` | 总预算，默认 45 秒，范围 1–60；内部预留收尾时间 |
| `-WhatIf` | 演练，不执行检查、不写报告，不能作为体检结果 |

普通权限调用，不为补全大小而提权。不扫描整个 C 盘，不触发云文件下载，不展开链接；超时、读取失败可能只得到下限。测量是文件长度之和，不保证等于释放空间。

实际执行读 `RESULT:` 指向的 `Schema=pc-care/checkup/1`：

| 字段 | AI 的处理 |
| --- | --- |
| `SystemDrive.TotalBytes/FreeBytes/Level` | 告知容量；剩余低于 10% 为紧张、低于 5% 为严重；容量未知时不要只靠 Level 判断正常 |
| `Items[].Id/Group/Title/Detail` | 稳定项目 Id 供脚本使用；展示名优先 `Detail.Name`，否则 `Title` |
| `Items[].Bytes/IsLowerBound` | 项目大小；下限用“至少”，不夸大收益 |
| `Items[].Loss/NeedsAdmin` | 确认项目须完整解释损失；管理员项目提前解释 UAC |
| `Items[].Paths` | 检测线索，不能当成删除命令或扩大白名单 |
| `Totals.SafeBytes/SafeIsLowerBound` | 放心清总数，不能再加确认项、搬家大小或软件估算 |
| `DataVolumes` | 用 Letter、FreeBytes、FileSystem、IsFixed 选择搬家盘；OnSystemDisk 表示是否同一物理盘 |
| `Backup` | NeedsReminder 为真就提醒独立备份；null 表示未知，不是 false |
| `NextStep` | 有适合的数据盘及搬家项时 move；没有合适盘时 partition；否则有放心清项时 clean，再否则 none |
| `Issues/Timings` | 把影响判断的未完成检查如实说明；时间用于排查，不用宣称真机性能达标 |

只发出正大小条目；搬家项目须超过 100 MB。没有条目不一定表示没有占用，应结合下限标志和 Issues。聊天数据在文档文件夹内时，体检会排除重复计量的子路径；搬家时先处理聊天项，再重新检查父文件夹。

## 项目与边界

| 分组 | Id | 内容与处理 |
| --- | --- | --- |
| 放心清 `safe` | `cache:UserTemp/WindowsTemp`（分别为两个 Id） | 用户 / 系统临时文件；被占用、过新或系统忙时可能跳过 |
| 放心清 `safe` | `cache:ThumbnailCache`、`cache:BrowserCache`、`cache:InetCache`、`cache:AppCache`、`cache:ShaderCache` | 可再生成的缓存，不含浏览器密码、书签、Cookie、会话和站点数据 |
| 放心清 `safe` | `system:UpdateCache`、`system:DeliveryOptimization`、`system:CrashDumps` | 更新缓存、传递优化缓存、崩溃报告；崩溃报告在 V1 属放心清 |
| 点名才清 `confirm` | `system:RecycleBin` | “清空后，里面已删除的文件将无法再从回收站恢复。” |
| 点名才清 `confirm` | `system:Hibernate` | “关闭后将不能使用休眠和快速启动；以后可以重新开启。” |
| 点名才清 `confirm` | `system:WindowsOld` | “删除后，将无法回退到之前的 Windows 版本。” |
| 搬家 `move` | `move:KnownFolder:Desktop/Documents/Downloads/Pictures/Videos`（各自独立 Id） | 桌面、文档、下载、图片、视频，交给搬家入口 |
| 搬家 `move` | `move:WeChat`、`move:QQ` | 仅可识别并通过检查的微信 / QQ 数据；不把整个 AppData 搬走 |
| 仅提示 `info` | `info:LargeApps` | C 盘超过 1 GB 软件的登记估算，`Detail.Apps` 为明细；不代表可释放量，不执行卸载 |

WindowsTemp、更新缓存和部分系统项目需要管理员权限，以本地定义及结果为准。默认检测路径与自定义位置识别有边界，不凭猜测扩展到其他应用或任意聊天文件位置。

## 清理入口与结果

[clean.ps1](../scripts/clean.ps1)：`-ReportPath <体检JSON> [-Mode Quick|Full] [-CacheBudgetSeconds 15] [-Include <确认项Id数组>] [-ResultPath <新文件>] [-WhatIf]`。

- `Quick` 是默认清理模式：每个 `clean-cache.ps1` 缓存项目默认 15 秒预算，可用 `CacheBudgetSeconds` 调整为 1–600 秒。到安全检查点停止处理剩余内容，结果为部分完成或跳过并带原因；枚举、正在进行的单步操作及系统工具/UAC 耗时另计，不是硬性全程超时。`Full` 不设缓存预算，两种模式的删除安全规则相同。结果新增 `Mode/CacheBudgetSeconds`；完整模式预算记为 0。

- 报告须是 `pc-care/checkup/1`、同一原用户、生成不超过 24 小时。未知的新 Id 忽略；已知 Id 的分组和处理器必须合法。脚本重新解析实际目标，不信报告给出的命令、路径或权限。
- 自动运行报告中的全部 safe 项。Include 只接受报告中存在且用户点名的 confirm 项；不传则全部确认项不选。不能用 Include 选择单个放心清项目。
- 普通项目先执行，其余管理员项目合并一次 UAC；拒绝或切换账户只跳过管理员部分。AI 不直接调用底层系统处理器代替入口。
- WhatIf 只显示计划，不执行处理器、不写文件或日志；没有新结果文件。
- 实际读取 `Schema=pc-care/clean/1`。`Items` 逐项含 `Id/Title/Status/Reason/FreedBytes/FreeBefore/FreeAfter/Timings`；状态为 Done、Partial、Skipped、Failed。未点名的确认项也可能列为 Skipped（你没有选择），不要当作故障。
- 总 `FreedBytes` 与项目值均为 C 盘空闲变化估算，`FreedBytesIsEstimate=true`；后台活动会干扰，不能加总项目值代替总值。负值为可用空间减少，null 为无法测量。所有未完成项解释 Reason，不把部分成功说成全部完成。

V1 不启用底层旧处理器的开发者缓存、组件存储、还原点存储、保留存储或页面文件能力。不要直接调用底层脚本的默认“全部”范围来绕过 V1 范围。

## 跨客户端记录位置

默认使用从已核实的原用户配置推导的 `%USERPROFILE%\.pc-care\Logs`，不依赖宿主品牌、应用包身份、安装目录或当前工作目录。普通进程、后台进程和 UAC 子进程保持同一个记录目录；日志与结果文件仍执行原有重解析点、禁止目录、最终路径与句柄校验。路径不可用即报告原因，不能通过关闭校验来适配客户端。

已有记录不自动迁移。为续传旧搬家，先按已知记录路径核实原目录，再在本次调用及后续状态查询中设置 `CLEANER_LOG_PATH=<原目录中的新唯一文件名>.jsonl`，结束后恢复环境变量。允许的旧记录目录为原用户 LocalAppData 下的 `CDriveCleaner\Logs` 和 `Packages\<合法包名>\LocalCache\Local\CDriveCleaner\Logs`；不得猜测另一个用户或应用的目录。新位置找不到记录时，先查旧记录而不是发起新的搬家。
