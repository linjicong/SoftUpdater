# 软件更新助手 (SoftUpdater)

Windows 桌面工具：枚举本机已安装软件、检测可用更新，支持**手动更新**（勾选/右键/一键全部）与**定时自动更新**（Windows 计划任务）。基于 PowerShell 7 + WPF，零构建、零第三方运行时依赖，核心检测走系统自带的 winget。

## 文件结构

```
D:\software\SoftUpdater\
├── 启动软件更新助手.vbs     # 双击启动（隐藏控制台，内部自动 UAC 提权）
├── SoftUpdater.ps1          # 桌面界面（WPF，深色主题）
├── SoftUpdater-Task.ps1     # 无界面入口，供计划任务调用（-Auto）
├── SoftUpdater-Core.psm1    # 核心模块：枚举/合并/检测/升级/配置/计划任务
├── config.json              # 配置：扫描路径、排除名单、定时开关与时间
├── state.json               # 上次检测/自动更新时间与结果（自动生成）
├── logs\                    # 按天滚动日志（UI 与定时任务共用）
└── tests\run-tests.ps1      # 核心逻辑测试套件（51 断言，无 Pester 依赖）
```

## 使用

| 操作 | 方式 |
|---|---|
| 启动 | 双击 `启动软件更新助手.vbs` → UAC 弹窗点「是」 |
| 刷新列表 | 启动时自动刷新；或点「🔄 刷新列表」 |
| 手动更新 | 勾选后点「⬆ 更新选中」，或右键某行「更新此软件」 |
| 一键全部更新 | 点「⬆⬆ 全部更新」（所有有新版本且有 winget ID 的项） |
| 只看有更新 | 勾选「只看有更新」 |
| 设置 | 「⚙ 设置」：扫描路径 / 排除名单 / 定时任务注册与开关 |

> 首次启动 winget 需要刷新源，枚举约需 10~60 秒，之后较快（实测全量 300 项约 8~18 秒）。

## 软件列表的来源（四路合并）

1. **winget**（`winget list` 文本解析，兼容中英文表头与 CJK 视觉宽度对齐）→ 主列表，含可用新版本，可自动升级；
2. **注册表卸载项**（HKLM 64/32 + HKCU）→ 为 winget 条目标注安装位置；winget 未覆盖的补充为「系统」行（无 ID，仅展示）；
3. **D:\software 顶层目录扫描** → 已被注册表覆盖的合并；绿色版读主 exe 版本号，标记「便携 · 无法检测更新」；
4. 按 winget ID / 规范化名称去重。

更新检测：`可用版本 > 当前版本`（数字段比较，兼容任意格式回退）。升级执行：`winget upgrade --id <Id> --exact --silent --accept-package-agreements --accept-source-agreements`，逐个串行、单条失败不影响后续，实时输出到日志区。

## 配置（config.json）

```json
{
  "scanPaths":  [ "D:\\software" ],   // 目录扫描范围，用于识别装在这些目录里的软件
  "exclusions": [],                    // 排除名单，支持通配符（对名称和 ID 匹配）；留空 = 全量检测
  "schedule": { "enabled": false, "time": "12:30" }   // 定时自动更新开关与时间
}
```

示例：排除企业微信与零信任客户端 → `"exclusions": [ "Tencent.WeCom*", "*TrustCyberLink*" ]`

## 定时自动更新

1. 「⚙ 设置」→ 设定时间 → 点「注册/更新定时任务」（注册的是计划任务 `SoftUpdater-Auto`，每天定时、最高权限运行）；
2. 勾选「启用定时自动更新」并保存——**计划任务每次触发都会检查这个开关**，不勾选时任务只会记一条日志就退出；
3. 触发行为：枚举 → 升级所有有更新且不在排除名单的软件 → 结果写 `logs\` 与 `state.json`；
4. 随时可在设置里「移除定时任务」，或用系统「任务计划程序」查看。

## 状态栏与日志

- 状态栏显示上次检测时间与有更新数量（存于 `state.json`）；
- 日志区实时显示 winget 输出；磁盘日志在 `logs\yyyy-MM-dd.log`。

## 测试

```
pwsh -NoProfile -File tests\run-tests.ps1
```

覆盖：winget 中英文表头解析、大写 `ID` 表头、CJK 视觉宽度对齐切片、空输出容错、名称规范化/宽松匹配、版本比较、通配排除、注册表卸载项目录解析、四路合并去重、目录扫描候选。winget 调用与 UI 为集成层，靠真机验收。

## 已知边界（v1 设计取舍）

- **便携/绿色版软件**（无注册表项）只能显示版本，无法自动检测更新（升级需逐个对接发布源，后续可扩展 GitHub Release 检查）；
- `MSIX\...` / `ARP\Machine...` 形态的 ID 来自系统组件，winget 通常无更新源，仅展示；
- 微软商店（msix）类应用建议走商店自带更新；
- 枚举依赖 `winget.exe`（路径未配进 PATH 时自动用 `%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe` 兜底）；
- 想要更稳的结构化枚举，可执行 `Install-Module Microsoft.WinGet.Client -Scope CurrentUser`，核心模块会自动优先使用它。

## 性能与资源占用

- 程序启动即把自己设为**「低于正常」进程优先级**，winget/COM 子进程继承——刷新、更新时的 CPU 让给前台应用，整机不卡，代价是刷新本身略慢；
- **启动秒开**：列表走缓存渲染；表格开启行虚拟化，300+ 行只物化可见行；
- 典型耗时：脚本自身启动 ~1s；winget 枚举 ~14s（后台线程，不阻塞界面）；注册表 ~0.5s；目录扫描 ~0.3s；
- 自带性能自检：UI tick 最大耗时、列表渲染耗时自动记录，渲染超 500ms 或 tick 异常会写入当天日志；
- 各阶段耗时自动写入 `logs\` 时间戳日志，卡顿/失败时打开当天日志即可定位慢在哪一步；
- 枚举优先走 `Microsoft.WinGet.Client` 模块（COM），未安装时自动降级 `winget list` 文本解析。

## 启动缓存（cache-rows.json）

每次成功枚举（刷新/学习/检测）后自动把**最终合并的软件表**写入 `cache-rows.json`：

- **打开工具秒开**：直接从缓存渲染列表，不再等 14 秒枚举；
- **自动重扫策略**：缓存超过 `cache.maxAgeHours`（默认 6 小时）才在后台自动重扫；数据较新则直接使用缓存，想强制新鲜数据点「刷新列表」（它永远真扫）；
- 缓存损坏/缺失时自动走完整扫描，无感知降级。

## 便携软件更新源库（update-sources.json）

绿色版/便携软件通过 **winget 官方目录**自动获得更新源，存入 `update-sources.json`：

```json
[ { "Name": "Everything", "Folder": "D:\\software\\Everything-1.4.1.1028.x64",
    "WingetId": "voidtools.Everything", "LatestVersion": "1.4.1.1032", "LocalVersion": "1.4.1.1028",
    "DownloadPage": "https://winstall.app/apps/voidtools.Everything",
    "InstallerUrl": "https://www.voidtools.com/Everything-1.4.1.1032.x64.msi",
    "LastChecked": "2026-09-03 17:30:00", "State": "auto" } ]
```

- **学习**：工具栏「📚 学习便携源」→ 对每个便携目录取主 exe 的 ProductName 在 winget 目录中匹配（唯一命中 auto；多候选 fuzzy 需人工瞄一眼；查不到 未匹配），边学边存、中断不丢；
- **检测**：刷新时自动检查超过 `checkHours`（默认 24h）未查的条目；「⬇ 检测便携更新」强制全查；
- **自动下载**：检测到新版本自动抓取 `winget show` 的安装包地址并下载到下载目录（`portable.downloadDir` 可改，空=用户 Downloads），安装/替换由你手动进行；下载为 HttpClient 流式下载，**状态栏右侧有实时进度条**（百分比+已下载/总量，每 250ms 刷新；先写 `.part` 临时文件，完成后原子改名，不留半截文件）；
- **手工补充**：winget 查不到的（未匹配）直接在 json 里给条目填 `DownloadPage`，右键即可打开；
- msstore 商店条目（纯字母数字 Id、Unknown 版本）会被自动过滤，不会误匹配。

## 故障排查

| 现象 | 处理 |
|---|---|
| 列表为空 / 很少 | 看日志区首行是否「未找到 winget.exe」；手动跑 `winget list` 确认 winget 可用 |
| 更新失败（退出码非 0） | 日志区有 winget 原始输出；常见为网络/源问题或该包需交互安装，可改用手动更新 |
| 计划任务没执行 | 检查「任务计划程序」里 `SoftUpdater-Auto` 是否存在、config 的 `schedule.enabled` 是否为 true |
| UAC 弹窗 | 每次启动会请求一次管理员权限（升级机器级软件需要）；取消则工具以只读模式运行（当前实现会直接退出） |
