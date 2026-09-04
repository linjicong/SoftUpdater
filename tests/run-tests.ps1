#requires -Version 7.0
<#
  SoftUpdater 核心逻辑测试套件（无 Pester 依赖，直接运行）
  运行: pwsh -NoProfile -File tests\run-tests.ps1
  只覆盖纯逻辑（解析/匹配/合并/版本比较）；winget 调用与 UI 属集成层，真机验收。
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'SoftUpdater-Core.psm1') -Force -ErrorAction Stop

$script:PassCount = 0
$script:FailCount = 0
$script:Failures  = [System.Collections.Generic.List[string]]::new()

function Assert-True  { param([object]$Condition, [string]$Name)
    if ($Condition) { $script:PassCount++ } else { $script:FailCount++; $script:Failures.Add($Name) ; Write-Host "  FAIL: $Name" -ForegroundColor Red }
}
function Assert-Equal { param([object]$Expected, [object]$Actual, [string]$Name)
    Assert-True ("$Expected" -eq "$Actual") "$Name (expected='$Expected', actual='$Actual')"
}
function Assert-Null  { param([object]$Actual, [string]$Name)
    Assert-True ($null -eq $Actual) "$Name (expected null, actual='$Actual')"
}

# ---------- 测试辅助：构造模拟 winget 固定宽度表格输出 ----------
function New-WingetTable {
    param([string]$NameHeader,[string]$IdHeader,[string]$VersionHeader,[string]$AvailableHeader,[string]$SourceHeader,[object[]]$Rows)
    $wName = 32; $wId = 34; $wVer = 12; $wAv = 12
    function Pad([string]$s, [int]$w) {
        # 按视觉宽度填充（CJK 字符宽 2），与 winget 真机对齐方式一致
        $vis = 0
        $out = New-Object System.Text.StringBuilder
        foreach ($ch in $s.ToCharArray()) {
            $cw = Get-SuCharWidth -Char $ch
            if ($vis + $cw -ge $w) { [void]$out.Append('…'); $vis += 1; break }
            [void]$out.Append($ch); $vis += $cw
        }
        while ($vis -lt $w) { [void]$out.Append(' '); $vis++ }
        return $out.ToString()
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Pad $NameHeader $wName) + (Pad $IdHeader $wId) + (Pad $VersionHeader $wVer) + (Pad $AvailableHeader $wAv) + $SourceHeader)
    $lines.Add(('-' * ($wName + $wId + $wVer + $wAv + 10)))
    foreach ($r in $Rows) {
        $lines.Add((Pad $r.Name $wName) + (Pad $r.Id $wId) + (Pad $r.Version $wVer) + (Pad $r.Available $wAv) + $r.Source)
    }
    return ($lines -join "`n")
}

# ========== 1. winget 输出解析（中文表头） ==========
Write-Host "`n[1] ConvertFrom-SuWingetOutput 中文表头" -ForegroundColor Cyan
$zhText = New-WingetTable -NameHeader '名称' -IdHeader 'Id' -VersionHeader '版本' -AvailableHeader '可用' -SourceHeader '源' -Rows @(
    [pscustomobject]@{ Name = '7-Zip 24.08 (x64)';   Id = '7zip.7zip';           Version = '24.08';       Available = '';           Source = 'winget' },
    [pscustomobject]@{ Name = 'Everything';          Id = 'voidtools.Everything';Version = '1.4.1.1026';  Available = '1.4.1.1028'; Source = 'winget' },
    [pscustomobject]@{ Name = '腾讯微信 WeChat';      Id = 'Tencent.WeChat';      Version = '4.0.6.20';    Available = '';           Source = 'winget' }
)
$zhParsed = ConvertFrom-SuWingetOutput -OutputText $zhText
Assert-Equal 3 @($zhParsed).Count "1.1 解析出 3 行"
Assert-Equal '7zip.7zip'            $zhParsed[0].Id        "1.2 Id 列正确"
Assert-Equal '1.4.1.1028'           $zhParsed[1].Available "1.3 可用列正确"
Assert-Equal ''                     $zhParsed[0].Available "1.4 无更新时可用列为空"
Assert-Equal '腾讯微信 WeChat'       $zhParsed[2].Name      "1.5 中文名不乱码"
Assert-Equal '24.08'                $zhParsed[0].Version   "1.6 版本列正确"
Assert-Equal 'Tencent.WeChat'       $zhParsed[2].Id        "1.7 中文名行的 Id 按视觉列对齐切片"

# ========== 2. winget 输出解析（英文表头 + 长名截断） ==========
Write-Host "`n[2] ConvertFrom-SuWingetOutput 英文表头" -ForegroundColor Cyan
$enText = New-WingetTable -NameHeader 'Name' -IdHeader 'Id' -VersionHeader 'Version' -AvailableHeader 'Available' -SourceHeader 'Source' -Rows @(
    [pscustomobject]@{ Name = 'Git'; Id = 'Git.Git'; Version = '2.50.1'; Available = '2.51.0'; Source = 'winget' }
)
$enParsed = ConvertFrom-SuWingetOutput -OutputText $enText
Assert-Equal 1 @($enParsed).Count          "2.1 解析出 1 行"
Assert-Equal 'Git.Git' $enParsed[0].Id     "2.2 Id 正确"
Assert-Equal '2.51.0'  $enParsed[0].Available "2.3 Available 正确"

# ========== 3. 空输出/垃圾输出容错 ==========
Write-Host "`n[3] 解析容错" -ForegroundColor Cyan
Assert-Equal 0 @(ConvertFrom-SuWingetOutput -OutputText "").Count        "3.1 空文本 → 0 行"
Assert-Equal 0 @(ConvertFrom-SuWingetOutput -OutputText "随便什么没有表头").Count "3.2 无表头 → 0 行"

# ========== 3b. 大写 ID 表头（winget 真机实际输出形态） ==========
Write-Host "`n[3b] 大写 ID 表头" -ForegroundColor Cyan
$idUpperText = New-WingetTable -NameHeader '名称' -IdHeader 'ID' -VersionHeader '版本' -AvailableHeader '可用' -SourceHeader '源' -Rows @(
    [pscustomobject]@{ Name = 'Antigravity 2.0.6'; Id = 'Google.Antigravity'; Version = '2.0.6'; Available = '2.12.0'; Source = 'winget' },
    [pscustomobject]@{ Name = 'Apifox 2.8.21';     Id = 'Ruihu.Apifox';      Version = '2.8.21'; Available = '';          Source = 'winget' }
)
$parsedUpper = @(ConvertFrom-SuWingetOutput -OutputText $idUpperText)
Assert-Equal 2 @($parsedUpper).Count              "3.3 大写 ID 表头 → 解析出 2 行"
Assert-Equal 'Google.Antigravity' $parsedUpper[0].Id        "3.4 大写表头 Id 列正确"
Assert-Equal '2.12.0'             $parsedUpper[0].Available "3.5 大写表头可用列正确"

# ========== 4. 名称规范化与宽松匹配 ==========
Write-Host "`n[4] 名称规范化与匹配" -ForegroundColor Cyan
Assert-Equal 'microsoftvscode' (ConvertTo-SuNormalizedKey -Text 'Microsoft VS Code') "4.1 规范化去空格/符号"
Assert-True  (Test-SuNameMatch -A 'Everything' -B 'Everything 1.4.1.1028') "4.2 包含匹配（短名≥4字符）"
Assert-True  (Test-SuNameMatch -A '7zip'       -B '7-Zip 24.08 (x64)')    "4.3 去符号后包含匹配"
Assert-True  (-not (Test-SuNameMatch -A 'Git' -B 'GitHub CLI'))            "4.4 短名(<4)不参与包含匹配"
Assert-True  (Test-SuNameMatch -A 'WXWork' -B 'WXWork')                    "4.5 完全相等匹配"

# ========== 5. 版本比较 ==========
Write-Host "`n[5] Compare-SuVersion" -ForegroundColor Cyan
Assert-Equal -1 (Compare-SuVersion -A '1.2.3' -B '1.10.0')    "5.1 数字段比较 1.2.3 < 1.10.0"
Assert-Equal  0 (Compare-SuVersion -A '2.0'   -B '2.0')       "5.2 相等"
Assert-Equal  1 (Compare-SuVersion -A '1.10'  -B '1.9')       "5.3 1.10 > 1.9"
Assert-Equal -1 (Compare-SuVersion -A '2025.1.1' -B '2025.1.1.1') "5.4 段数少且前缀相等 → 旧"
Assert-Equal -1 (Compare-SuVersion -A 'abc' -B 'abd')         "5.5 非版本号字符串回退比较"
Assert-Equal -1 (Compare-SuVersion -A ''    -B '1.0')         "5.6 空版本视为最旧"

# ========== 6. 排除名单通配匹配 ==========
Write-Host "`n[6] Test-SuExcluded" -ForegroundColor Cyan
Assert-True  (Test-SuExcluded -Name 'WXWork' -Id 'Tencent.WXWork' -Patterns @('WXWork*')) "6.1 按名称通配排除"
Assert-True  (Test-SuExcluded -Name 'Everything' -Id 'voidtools.Everything' -Patterns @('voidtools*')) "6.2 按 Id 通配排除"
Assert-True  (-not (Test-SuExcluded -Name 'Git' -Id 'Git.Git' -Patterns @('WXWork*'))) "6.3 不匹配的软件不受影响"
Assert-True  (-not (Test-SuExcluded -Name 'Git' -Id 'Git.Git' -Patterns @())) "6.4 空排除名单 → 全量检测"

# ========== 7. 从卸载信息解析安装目录 ==========
Write-Host "`n[7] Get-SuInstallDirFromUninstallEntry" -ForegroundColor Cyan
Assert-Equal 'D:\software\Git' (Get-SuInstallDirFromUninstallEntry -InstallLocation 'D:\software\Git\' -DisplayIcon '' -UninstallString '') "7.1 优先 InstallLocation"
Assert-Equal 'C:\Program Files\Everything' (Get-SuInstallDirFromUninstallEntry -InstallLocation '' -DisplayIcon '' -UninstallString '"C:\Program Files\Everything\unins000.exe"') "7.2 带引号的卸载程序路径"
Assert-Equal 'D:\software\PotPlayer' (Get-SuInstallDirFromUninstallEntry -InstallLocation '' -DisplayIcon 'D:\software\PotPlayer\PotPlayerMini64.exe,0' -UninstallString '') "7.3 DisplayIcon 带资源索引"
Assert-Equal 'D:\software\XTool' (Get-SuInstallDirFromUninstallEntry -InstallLocation '' -DisplayIcon '' -UninstallString 'D:\software\XTool\setup.exe /uninstall') "7.4 未加引号+带参数"
Assert-Null (Get-SuInstallDirFromUninstallEntry -InstallLocation '' -DisplayIcon '' -UninstallString 'MsiExec.exe /I{12345678-1234-1234-1234-123456789012}') "7.5 MsiExec 无目录信息 → null"
Assert-Null (Get-SuInstallDirFromUninstallEntry -InstallLocation '' -DisplayIcon '' -UninstallString '') "7.6 全空 → null"

# ========== 8. 合并逻辑 ==========
Write-Host "`n[8] Merge-SuSoftwareList" -ForegroundColor Cyan
$mgWinget = @(
    [pscustomobject]@{ Name = 'Everything'; Id = 'voidtools.Everything'; Version = '1.4.1.1026'; Available = '1.4.1.1032'; Source = 'winget' },
    [pscustomobject]@{ Name = 'Git';        Id = 'Git.Git';              Version = '2.50.1';       Available = '';           Source = 'winget' }
)
$mgReg = @(
    [pscustomobject]@{ Name = 'Everything 1.4.1.1028'; Version = '1.4.1.1028'; InstallDir = 'D:\software\Everything-1.4.1.1028.x64' },
    [pscustomobject]@{ Name = 'FooBar Suite';          Version = '3.2';        InstallDir = 'C:\Program Files\FooBar' }
)
$mgDirs = @(
    [pscustomobject]@{ FullPath = 'D:\software\Everything-1.4.1.1028.x64'; ExeVersion = '1.4.1.1028' },
    [pscustomobject]@{ FullPath = 'D:\software\Snipaste-2.10.5-x64';       ExeVersion = '2.10.5' }
)
$merged = Merge-SuSoftwareList -WingetPackages $mgWinget -RegistryEntries $mgReg -Directories $mgDirs -ScanPaths @('D:\software')
Assert-Equal 4 @($merged).Count "8.1 合并后共 4 行（无重复）"
$evRows = @($merged | Where-Object { $_.Name -like 'Everything*' })
Assert-Equal 1 @($evRows).Count "8.2 Everything 只出现一次（winget+注册表+目录合并）"
Assert-Equal 'D:\software\Everything-1.4.1.1028.x64' $evRows[0].Location "8.3 位置标注来自注册表匹配"
Assert-Equal '1.4.1.1028' $evRows[0].Version "8.4a 注册表版本覆盖 winget 报告的本地版本（权威来源）"
Assert-True $evRows[0].HasUpdate "8.4 目录最新 1032 > 实装 1028 → 有更新"
$snip = @($merged | Where-Object { $_.Name -like '*Snipaste*' })
Assert-Equal 1 @($snip).Count "8.5 绿色版目录进入列表"
Assert-Equal '便携' $snip[0].Catalog "8.6 绿色版来源=便携"
Assert-Equal '无法检测更新' $snip[0].Status "8.7 绿色版状态"
$foo = @($merged | Where-Object { $_.Name -eq 'FooBar Suite' })
Assert-Equal 1 @($foo).Count "8.8 winget 未覆盖的注册表软件补充进列表"
Assert-Equal '系统' $foo[0].Catalog "8.9 来源=系统"
Assert-Equal '' $foo[0].Id "8.10 无 Id（无法自动升级）"

# ========== 9. 合并：注册表匹配目录但 winget 无对应 → 系统来源而非便携 ==========
Write-Host "`n[9] 合并去重：目录已匹配注册表" -ForegroundColor Cyan
$m9 = Merge-SuSoftwareList -WingetPackages @(
    [pscustomobject]@{ Name = 'Everything'; Id = 'voidtools.Everything'; Version = '1.4.1'; Available = ''; Source = 'winget' }
) -RegistryEntries @(
    [pscustomobject]@{ Name = 'RG-WorkSpace'; Version = '2.0'; InstallDir = 'D:\software\RG-WorkSpace_V2.0_R1Q2.264_Setup' }
) -Directories @(
    [pscustomobject]@{ FullPath = 'D:\software\RG-WorkSpace_V2.0_R1Q2.264_Setup'; ExeVersion = '2.0' }
) -ScanPaths @('D:\software')
$rg = @($m9 | Where-Object { $_.Name -like '*RG-WorkSpace*' })
Assert-Equal 1 @($rg).Count "9.1 只出现一次"
Assert-Equal '系统' $rg[0].Catalog "9.2 已匹配注册表 → 系统（而非便携）"
Assert-Equal 'D:\software\RG-WorkSpace_V2.0_R1Q2.264_Setup' $rg[0].Location "9.3 位置正确"

# ========== 10. 目录扫描候选（真实文件系统，临时目录） ==========
Write-Host "`n[10] Get-SuFolderCandidates" -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sutest_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'AppWithExe') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'DataOnly')  | Out-Null
New-Item -ItemType File     -Path (Join-Path $tmp 'AppWithExe\app.exe') -Value ('x' * 100) | Out-Null
New-Item -ItemType File     -Path (Join-Path $tmp 'DataOnly\note.txt') | Out-Null
$cands = Get-SuFolderCandidates -ScanPaths @($tmp)
$withExe = @($cands | Where-Object { $_.FullPath -like '*AppWithExe' })
Assert-Equal 1 @($withExe).Count "10.1 有 exe 的目录成为候选"
Assert-True ($null -ne $withExe[0].PSObject.Properties['ProductName']) "10.3 候选携带 ProductName 字段"
$dataOnly = @($cands | Where-Object { $_.FullPath -like '*DataOnly' })
Assert-Equal 0 @($dataOnly).Count "10.2 无 exe 的数据目录跳过"
Remove-Item -Recurse -Force $tmp

# ========== 11. 便携源：winget 目录匹配打分 ==========
Write-Host "`n[11] Test-SuCatalogMatch" -ForegroundColor Cyan
$cands11 = @(
    [pscustomobject]@{ Name = 'Everything'; Id = 'voidtools.Everything'; Version = '1.4.1.1032' },
    [pscustomobject]@{ Name = '小智搜搜：Everything文件搜索软件'; Id = 'XP8BR85ZLFQ54Z'; Version = '4.0.6.60' }
)
$m11 = Test-SuCatalogMatch -Candidates $cands11 -ProductName 'Everything' -FolderName 'Everything-1.4.1.1028.x64'
Assert-Equal 'exact' $m11.Confidence "11.1 精确匹配优先"
Assert-Equal 'voidtools.Everything' $m11.Candidate.Id "11.2 命中正确 Id"
$mAmb = Test-SuCatalogMatch -Candidates @(
    [pscustomobject]@{ Name = 'PotPlayer Mini'; Id = 'a.b'; Version = '1' },
    [pscustomobject]@{ Name = 'PotPlayer Setup'; Id = 'c.d'; Version = '2' }
) -ProductName 'PotPlayer' -FolderName ''
Assert-Equal 'none' $mAmb.Confidence "11.3 多个模糊命中 → 交给人（待确认）"
$mFz = Test-SuCatalogMatch -Candidates @(
    [pscustomobject]@{ Name = 'Snipaste'; Id = 'LeTan.Snipaste'; Version = '2.10.6' }
) -ProductName '' -FolderName 'Snipaste-2.10.5-x64'
Assert-Equal 'fuzzy' $mFz.Confidence "11.4 目录名含版本号也能模糊命中"
$mNo = Test-SuCatalogMatch -Candidates @(
    [pscustomobject]@{ Name = 'Totally Different'; Id = 'x.y'; Version = '1' }
) -ProductName 'Everything' -FolderName 'Everything-x64'
Assert-Equal 'none' $mNo.Confidence "11.5 不相关候选 → none"

# ========== 12. winget show 输出解析 ==========
Write-Host "`n[12] ConvertFrom-SuWingetShowOutput" -ForegroundColor Cyan
$showZh = @'
已找到 Everything [voidtools.Everything]
版本: 1.4.1.1032
发布服务器 URL: https://www.voidtools.com/zh-cn/
  安装程序类型： wix
  安装程序 URL： https://www.voidtools.com/Everything-1.4.1.1032.x64.msi
  安装程序 SHA256： 4e7a8088
'@
$showParsed = ConvertFrom-SuWingetShowOutput -OutputText $showZh
Assert-Equal '1.4.1.1032' $showParsed.Version "12.1 中文版本行"
Assert-Equal 'https://www.voidtools.com/Everything-1.4.1.1032.x64.msi' $showParsed.InstallerUrl "12.2 全角冒号安装包地址"
$showEn = @'
Version: 2.0.0
  Installer Type: wix
  Installer Url: https://example.com/app-2.0.0.exe
'@
$showEnParsed = ConvertFrom-SuWingetShowOutput -OutputText $showEn
Assert-Equal 'https://example.com/app-2.0.0.exe' $showEnParsed.InstallerUrl "12.3 英文安装包地址"
$showNone = ConvertFrom-SuWingetShowOutput -OutputText '随便一段没有安装程序信息的文本'
Assert-Equal '' $showNone.InstallerUrl "12.4 无安装包行 → 空"

# ========== 13. 便携源库读写 + 过期判断 ==========
Write-Host "`n[13] 便携源库" -ForegroundColor Cyan
$tmpdb = "$env:TEMP\su-test-db-$PID.json"
if (Test-Path $tmpdb) { Remove-Item $tmpdb -Force }
Assert-Equal 0 @(Get-SuPortableDb -Path $tmpdb).Count "13.1 无库文件 → 空库"
$entries13 = @([pscustomobject]@{
    Name = 'Everything'; Folder = 'D:\software\EV'; WingetId = 'voidtools.Everything'
    LatestVersion = '1.4.1.1032'; LocalVersion = '1.4.1.1028'
    DownloadPage = 'https://winstall.app/apps/voidtools.Everything'; InstallerUrl = ''
    LastChecked = '2026-09-03 16:00:00'; State = 'auto'
})
Save-SuPortableDb -Db $entries13 -Path $tmpdb
$loaded13 = @(Get-SuPortableDb -Path $tmpdb)
Assert-Equal 1 @($loaded13).Count "13.2 保存后可读回"
Assert-Equal 'voidtools.Everything' $loaded13[0].WingetId "13.3 字段保真"
Remove-Item $tmpdb -Force
Assert-True (Test-SuSourceStale -LastChecked $null -Hours 24) "13.4 空时间 → 过期"
Assert-True (Test-SuSourceStale -LastChecked (Get-Date).AddHours(-25).ToString('yyyy-MM-dd HH:mm:ss') -Hours 24) "13.5 超 24h → 过期"
Assert-True (-not (Test-SuSourceStale -LastChecked (Get-Date).AddHours(-1).ToString('yyyy-MM-dd HH:mm:ss') -Hours 24)) "13.6 1h 内 → 新鲜"

# ========== 14. 便携源合并到行 ==========
Write-Host "`n[14] Merge-SuPortableSourceInfo" -ForegroundColor Cyan
$rows14 = @(
    [pscustomobject]@{ Name = 'Everything'; Id = ''; Version = '1.4.1.1028'; Available = ''; Catalog = '便携'; Location = 'D:\software\EV'; HasUpdate = $false; Status = '无法检测更新' },
    [pscustomobject]@{ Name = 'Snipaste'; Id = ''; Version = '2.10.5'; Available = ''; Catalog = '便携'; Location = 'D:\software\Snipaste-x64'; HasUpdate = $false; Status = '无法检测更新' },
    [pscustomobject]@{ Name = 'Ditto'; Id = ''; Version = '1.4.1.1032'; Available = ''; Catalog = '便携'; Location = 'D:\software\Ditto'; HasUpdate = $false; Status = '无法检测更新' },
    [pscustomobject]@{ Name = 'Git'; Id = 'Git.Git'; Version = '2.50'; Available = ''; Catalog = 'winget'; Location = ''; HasUpdate = $false; Status = '最新' }
)
$db14 = @(
    [pscustomobject]@{ Name = 'Everything'; Folder = 'D:\software\EV'; WingetId = 'voidtools.Everything'; LatestVersion = '1.4.1.1032'; DownloadPage = 'https://winstall.app/apps/voidtools.Everything'; InstallerUrl = ''; LastChecked = 'x'; State = 'auto' },
    [pscustomobject]@{ Name = 'Ditto'; Folder = 'D:\software\Ditto'; WingetId = 'Ditto.Ditto'; LatestVersion = '1.4.1.1032'; DownloadPage = 'https://winstall.app/apps/Ditto.Ditto'; InstallerUrl = ''; LastChecked = 'x'; State = 'auto' }
)
$m14 = @(Merge-SuPortableSourceInfo -Rows $rows14 -Db $db14)
$ev14 = @($m14 | Where-Object Name -eq 'Everything')[0]
Assert-Equal '1.4.1.1032' $ev14.Available "14.1 便携行补上目录最新版"
Assert-Equal '有更新(便携)' $ev14.Status "14.2 有更新(便携) 状态"
Assert-True $ev14.HasUpdate "14.3 HasUpdate 置位"
Assert-Equal 'https://winstall.app/apps/voidtools.Everything' $ev14.DownloadPage "14.4 下载页注入"
$snip14 = @($m14 | Where-Object Name -eq 'Snipaste')[0]
Assert-Equal '无法检测更新' $snip14.Status "14.5 无源便携行状态不变"
$ditto14 = @($m14 | Where-Object Name -eq 'Ditto')[0]
Assert-Equal '最新(便携)' $ditto14.Status "14.6 版本相同 → 最新(便携)"
$git14 = @($m14 | Where-Object Name -eq 'Git')[0]
Assert-Equal '最新' $git14.Status "14.7 winget 行不受影响"

# ========== 15. 下载文件名提取 ==========
Write-Host "`n[15] Get-SuDownloadFileName" -ForegroundColor Cyan
Assert-Equal 'App-1.2.exe' (Get-SuDownloadFileName -Uri 'https://x.com/a/App-1.2.exe?token=1') "15.1 去查询串"
Assert-Equal 'setup.msi' (Get-SuDownloadFileName -Uri 'https://x.com/setup.msi') "15.2 纯路径"
Assert-Null (Get-SuDownloadFileName -Uri 'not a url') "15.3 非法 URL → null"

# ========== 16. msstore 候选过滤 + 检测返回形状契约 ==========
Write-Host "`n[16] msstore 过滤与返回契约" -ForegroundColor Cyan
$mStore = Test-SuCatalogMatch -Candidates @(
    [pscustomobject]@{ Name = 'Snipaste'; Id = '9P1WXPKB68KX'; Version = 'Unknown' },
    [pscustomobject]@{ Name = 'Snipaste'; Id = 'LeTan.Snipaste'; Version = '2.10.6' }
) -ProductName 'Snipaste' -FolderName ''
Assert-Equal 'LeTan.Snipaste' $mStore.Candidate.Id "16.1 msstore 候选（纯字母数字 Id/Unknown 版本）被过滤"
$mStore2 = Test-SuCatalogMatch -Candidates @(
    [pscustomobject]@{ Name = 'Snipaste'; Id = '9P1WXPKB68KX'; Version = 'Unknown' }
) -ProductName 'Snipaste' -FolderName ''
Assert-Equal 'none' $mStore2.Confidence "16.2 仅剩 msstore 候选 → none"
$dbTwo16 = @(
    $entries13[0],
    [pscustomobject]@{ Name = 'Ditto'; Folder = 'D:\software\Ditto'; WingetId = 'Ditto.Ditto'; LatestVersion = '3.0'; LocalVersion = '2.0'; DownloadPage = ''; InstallerUrl = ''; LastChecked = '2026-09-03 16:00:00'; State = 'auto' }
)
$dbChk16 = @(Invoke-SuPortableCheck -Rows @() -Db $dbTwo16 -StaleHours 24 -Force)
Assert-Equal 2 @($dbChk16).Count "16.3 check 返回后库计数保持（返回形状契约）"

# ========== 17. 行缓存 ==========
Write-Host "`n[17] 行缓存" -ForegroundColor Cyan
$cachePath17 = "$env:TEMP\su-row-cache-$PID.json"
if (Test-Path $cachePath17) { Remove-Item $cachePath17 -Force }
$none17 = Get-SuRowCache -Path $cachePath17
Assert-Null $none17 "17.1 无缓存文件 → null"
$rows17 = @(
    [pscustomobject]@{ Name = 'Everything'; Id = ''; Version = '1.4.1.1028'; Available = '1.4.1.1032'; Catalog = '便携'; Location = 'D:\software\EV'; HasUpdate = $true; Status = '有更新(便携)'; ProductName = 'Everything' },
    [pscustomobject]@{ Name = 'Git'; Id = 'Git.Git'; Version = '2.50'; Available = ''; Catalog = 'winget'; Location = ''; HasUpdate = $false; Status = '最新'; ProductName = $null }
)
Save-SuRowCache -Rows $rows17 -Path $cachePath17
$loaded17 = Get-SuRowCache -Path $cachePath17
Assert-True ($null -ne $loaded17) "17.2 保存后可读回"
Assert-Equal 2 @($loaded17.Rows).Count "17.3 行数保真"
Assert-Equal 'Git.Git' $loaded17.Rows[1].Id "17.4 字段保真"
Assert-True (-not [string]::IsNullOrEmpty($loaded17.SavedAt)) "17.5 记录数据时间"
Set-Content -LiteralPath $cachePath17 -Value '{ 这不是合法 JSON' -Encoding UTF8
Assert-Null (Get-SuRowCache -Path $cachePath17) "17.6 损坏文件 → null 容错"
Remove-Item $cachePath17 -Force
Assert-True (Test-SuCacheFresh -SavedAt (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') -MaxAgeHours 6) "17.7 刚写入 → 新鲜"
Assert-True (-not (Test-SuCacheFresh -SavedAt (Get-Date).AddHours(-7).ToString('yyyy-MM-dd HH:mm:ss') -MaxAgeHours 6)) "17.8 超 6h → 过期"
Assert-True (-not (Test-SuCacheFresh -SavedAt $null -MaxAgeHours 6)) "17.9 空时间 → 过期"

# ========== 18/19. COM 空本地版本的修复（注册表兜底 + 版本未知不误报） ==========
Write-Host "`n[18/19] 空本地版本修复" -ForegroundColor Cyan
$mg18 = Merge-SuSoftwareList -WingetPackages @(
    [pscustomobject]@{ Name = 'Cherry Studio'; Id = 'kangfenmao.CherryStudio'; Version = ''; Available = '2.0.11'; Source = 'winget' }
) -RegistryEntries @(
    [pscustomobject]@{ Name = 'Cherry Studio'; Version = '2.0.11'; InstallDir = 'D:\software\Cherry Studio' }
) -Directories @() -ScanPaths @('D:\software')
$cherry = @($mg18 | Where-Object Name -eq 'Cherry Studio')[0]
Assert-Equal '2.0.11' $cherry.Version "18.1 注册表版本覆盖 COM 空版本"
Assert-True (-not $cherry.HasUpdate) "18.2 本地=目录最新 → 不再有更新"
Assert-Equal '最新' $cherry.Status "18.3 状态为最新"
$mg19 = Merge-SuSoftwareList -WingetPackages @(
    [pscustomobject]@{ Name = 'Mystery App'; Id = 'x.Mystery'; Version = ''; Available = '9.9'; Source = 'winget' }
) -RegistryEntries @() -Directories @() -ScanPaths @()
$mys = @($mg19 | Where-Object Name -eq 'Mystery App')[0]
Assert-True (-not $mys.HasUpdate) "19.1 空版本且无注册表兜底 → 不误报有更新"
Assert-Equal '版本未知' $mys.Status "19.2 状态=版本未知"

# ========== 21. MSIX Id 版本解析 + 中英别名合并 ==========
Write-Host "`n[21] MSIX 版本解析与别名合并" -ForegroundColor Cyan
Assert-Equal '1.14.9.29743' (Get-SuVersionFromMsixId -Id 'MSIX\3A48D7FC-AEE2-4CBC-91D1-0007951B8006_1.14.9.29743_x64__yyj3t4bx8qhke') "21.1 标准全名提取"
Assert-Equal '8.2511.26001.0' (Get-SuVersionFromMsixId -Id 'MSIX\Microsoft.UI.Xaml.2.8_8.2511.26001.0_x64__8wekyb3d8bbwe') "21.2 包名含数字段不误取"
Assert-Equal '26.26.2459.0' (Get-SuVersionFromMsixId -Id 'MSIX\AppUp.IntelArcSoftware_26.26.2459.0_x64__8j3eq9eme6ctt') "21.3 Intel 驱动包"
Assert-Null (Get-SuVersionFromMsixId -Id 'MSIX\NoVersionSegment') "21.4 无版本段 → null"
Assert-Null (Get-SuVersionFromMsixId -Id 'Git.Git') "21.5 非 MSIX Id → null"
$mg21 = Merge-SuSoftwareList -WingetPackages @(
    [pscustomobject]@{ Name = 'Intel Arc Software'; Id = 'MSIX\AppUp.IntelArcSoftware_26.26.2459.0_x64__8j3eq9eme6ctt'; Version = ''; Available = ''; Source = 'winget' }
) -RegistryEntries @() -Directories @() -ScanPaths @()
$intel = @($mg21 | Where-Object Name -eq 'Intel Arc Software')[0]
Assert-Equal '26.26.2459.0' $intel.Version "21.6 MSIX 行版本从 Id 填充"
Assert-Equal '最新' $intel.Status "21.7 填充后归入最新"
$mg22 = Merge-SuSoftwareList -WingetPackages @(
    [pscustomobject]@{ Name = 'WeChat'; Id = 'Tencent.WeChat.Universal'; Version = ''; Available = '4.1.13.12'; Source = 'winget' }
) -RegistryEntries @(
    [pscustomobject]@{ Name = '微信'; Version = '4.1.0.14'; InstallDir = 'D:\software\Tencent\Weixin' }
) -Directories @() -ScanPaths @('D:\software')
Assert-Equal 1 @($mg22).Count "22.1 中英别名合并 → 只剩一行"
$wx = @($mg22 | Where-Object Name -eq 'WeChat')[0]
Assert-Equal '4.1.0.14' $wx.Version "22.2 别名命中后注册表版本覆盖"
Assert-True $wx.HasUpdate "22.3 微信 4.1.0.14 → 4.1.13.12 有更新"

# ========== 20. 状态分类与统计 ==========
Write-Host "`n[20] 状态分类与统计" -ForegroundColor Cyan
Assert-Equal 'update'  (Get-SuStatusBucket -HasUpdate $true  -Status '有更新')       "20.1 winget 有更新"
Assert-Equal 'ok'      (Get-SuStatusBucket -HasUpdate $false -Status '最新')         "20.2 winget 最新"
Assert-Equal 'unknown' (Get-SuStatusBucket -HasUpdate $false -Status '版本未知')     "20.3 winget 版本未知"
Assert-Equal 'update'  (Get-SuStatusBucket -HasUpdate $true  -Status '有更新(便携)') "20.4 便携有更新"
Assert-Equal 'ok'      (Get-SuStatusBucket -HasUpdate $false -Status '最新(便携)')   "20.5 便携最新"
Assert-Equal 'unknown' (Get-SuStatusBucket -HasUpdate $false -Status '无法检测更新')  "20.6 便携无法检测"
Assert-Equal 'unknown' (Get-SuStatusBucket -HasUpdate $false -Status '未识别')        "20.7 系统未识别"
$rows20 = @(
    [pscustomobject]@{ Name = 'A'; HasUpdate = $true;  Status = '有更新' },
    [pscustomobject]@{ Name = 'B'; HasUpdate = $true;  Status = '有更新(便携)' },
    [pscustomobject]@{ Name = 'C'; HasUpdate = $false; Status = '最新' },
    [pscustomobject]@{ Name = 'D'; HasUpdate = $false; Status = '版本未知' },
    [pscustomobject]@{ Name = 'E'; HasUpdate = $false; Status = '无法检测更新' }
)
$cnt20 = Get-SuStatusCounts -Rows $rows20
Assert-Equal 5 $cnt20.Total   "20.8 总数"
Assert-Equal 2 $cnt20.Update  "20.9 有更新计数"
Assert-Equal 1 $cnt20.Ok      "20.10 最新计数"
Assert-Equal 2 $cnt20.Unknown "20.11 版本未知计数"
Assert-Equal 0 (Get-SuStatusCounts -Rows @()).Total "20.12 空行集 → 全 0"

# ========== 23. UserAssist 最近使用时间 ==========
Write-Host "`n[23] UserAssist 最近使用时间" -ForegroundColor Cyan

# --- ROT13 解码 ---
Assert-Equal 'Qoder' (ConvertFrom-SuRot13 -Text 'Dbqre') "23.1 ROT13 解码字母"
$rt23 = 'D:\software\Qoder\Qoder.exe'
Assert-Equal $rt23 (ConvertFrom-SuRot13 -Text (ConvertFrom-SuRot13 -Text $rt23)) "23.2 ROT13 自反（二次应用不变，数字/符号不动）"

# --- 时间戳提取（Win10/11 72字节布局，偏移60 = LastExecution FILETIME；扫描所有偏移取合理值） ---
$now23 = Get-Date '2026-09-04 12:00:00'
$ft23  = (Get-Date '2026-09-04 09:53:49').ToFileTime()
function New-UaData { param([long]$FileTime = 0, [int]$Offset = 60, [int]$Length = 72)
    $b = New-Object byte[] $Length
    if ($FileTime -gt 0) { [BitConverter]::GetBytes($FileTime).CopyTo($b, $Offset) }
    return $b
}
$r23 = Get-SuUserAssistLastRun -Data (New-UaData -FileTime $ft23) -Now $now23
Assert-Equal '2026-09-04 09:53' (Get-Date -Date $r23 -Format 'yyyy-MM-dd HH:mm') "23.3 偏移60的 FILETIME 提取（非8字节对齐）"
$b23a = New-UaData -FileTime ((Get-Date '2039-09-16 17:33:02').ToFileTime()) -Offset 8
[BitConverter]::GetBytes($ft23).CopyTo($b23a, 60)
$r23a = Get-SuUserAssistLastRun -Data $b23a -Now $now23
Assert-Equal '2026-09-04 09:53' (Get-Date -Date $r23a -Format 'yyyy-MM-dd HH:mm') "23.4 未来时间戳（2039）被排除"
$b23b = New-UaData -FileTime ((Get-Date '2026-08-01 10:00:00').ToFileTime()) -Offset 8
[BitConverter]::GetBytes($ft23).CopyTo($b23b, 60)
$r23b = Get-SuUserAssistLastRun -Data $b23b -Now $now23
Assert-Equal '2026-09-04 09:53' (Get-Date -Date $r23b -Format 'yyyy-MM-dd HH:mm') "23.5 多个合理时间戳取最大"
Assert-Null (Get-SuUserAssistLastRun -Data (New-UaData -FileTime ((Get-Date '2009-06-01 08:00:00').ToFileTime())) -Now $now23) "23.6 2015 前的旧时间戳视为无效"
Assert-Null (Get-SuUserAssistLastRun -Data (New-Object byte[] 4) -Now $now23) "23.7 数据过短 → null"

# --- 行匹配（目录前缀 / 别名 / 快捷方式名，取最大时间） ---
$rows23 = @(
    [pscustomobject]@{ Name = 'Qoder';        Location = 'D:\software\Qoder\Qoder';           LastUsed = '' },
    [pscustomobject]@{ Name = '微信';          Location = 'C:\Program Files\Tencent\WeChat';   LastUsed = '' },
    [pscustomobject]@{ Name = 'Everything';   Location = 'D:\software\Everything';            LastUsed = '' },
    [pscustomobject]@{ Name = 'Feishu';       Location = '';                                  LastUsed = '' },
    [pscustomobject]@{ Name = 'Update Master'; Location = '';                                 LastUsed = '' },
    [pscustomobject]@{ Name = 'Ghost App';    Location = '';                                  LastUsed = '' }
)
$ents23 = @(
    [pscustomobject]@{ Path = 'D:\software\Qoder\Qoder\Qoder.exe'; LastRun = (Get-Date '2026-09-02 11:37:00') },
    [pscustomobject]@{ Path = 'AlibabaCloud.Qoder';                LastRun = (Get-Date '2026-08-01 10:00:00') },
    [pscustomobject]@{ Path = 'C:\Program Files\Tencent\WeChat\WeChat.exe'; LastRun = (Get-Date '2026-09-04 08:30:00') },
    [pscustomobject]@{ Path = '{9E3995AB-1F9C-4F13-B827-48B24B6C7174}\TaskBar\Everything.lnk'; LastRun = (Get-Date '2026-09-03 21:00:00') },
    [pscustomobject]@{ Path = 'Feishu';                            LastRun = (Get-Date '2026-09-01 18:00:00') },
    [pscustomobject]@{ Path = 'C:\Windows\sysprep\update.exe';     LastRun = (Get-Date '2026-09-04 07:00:00') },
    [pscustomobject]@{ Path = 'MSEdge';                            LastRun = (Get-Date '2026-09-04 09:53:00') },
    [pscustomobject]@{ Path = 'X';                                 LastRun = $null }
)
$matched23 = Update-SuRowsLastUsed -Rows $rows23 -Entries $ents23
$qoder23 = @($rows23 | Where-Object Name -eq 'Qoder')[0]
$wx23    = @($rows23 | Where-Object Name -eq '微信')[0]
$ev23    = @($rows23 | Where-Object Name -eq 'Everything')[0]
$fs23    = @($rows23 | Where-Object Name -eq 'Feishu')[0]
$um23    = @($rows23 | Where-Object Name -eq 'Update Master')[0]
$gh23    = @($rows23 | Where-Object Name -eq 'Ghost App')[0]
Assert-Equal 4 $matched23 "23.8 匹配计数（4 行命中）"
Assert-Equal '2026-09-02 11:37' $qoder23.LastUsed "23.9 目录前缀匹配 Location，且取最大时间（晚于别名条目）"
Assert-Equal '2026-09-04 08:30' $wx23.LastUsed    "23.10 中文名行按安装目录匹配"
Assert-Equal '2026-09-03 21:00' $ev23.LastUsed    "23.11 快捷方式条目按名称匹配"
Assert-Equal '2026-09-01 18:00' $fs23.LastUsed    "23.12 别名条目匹配（无安装位置行）"
Assert-Equal '' $um23.LastUsed  "23.13 通用安装器名（update.exe）不参与名称匹配"
Assert-Equal '' $gh23.LastUsed  "23.14 无匹配行保持为空"

# --- 行缓存保留 LastUsed ---
$cachePath23 = "$env:TEMP\su-row-cache-lu-$PID.json"
if (Test-Path $cachePath23) { Remove-Item $cachePath23 -Force }
Save-SuRowCache -Rows $rows23 -Path $cachePath23
$loaded23 = Get-SuRowCache -Path $cachePath23
Assert-Equal '2026-09-02 11:37' $loaded23.Rows[0].LastUsed "23.15 行缓存 LastUsed 字段保真"
Remove-Item $cachePath23 -Force

# --- 合并行携带 LastUsed 字段契约 ---
$mg23 = Merge-SuSoftwareList -WingetPackages @(
    [pscustomobject]@{ Name = 'Git'; Id = 'Git.Git'; Version = '2.50'; Available = ''; Source = 'winget' }
) -RegistryEntries @() -Directories @() -ScanPaths @()
Assert-True ($null -ne $mg23[0].PSObject.Properties['LastUsed']) "23.16 合并行携带 LastUsed 字段"
Assert-Equal '' $mg23[0].LastUsed "23.17 初始为空（待枚举管线填充）"

# ========== 汇总 ==========
Write-Host ""
Write-Host ("=" * 50)
if ($script:FailCount -eq 0) {
    Write-Host "全部通过: $($script:PassCount) 个断言" -ForegroundColor Green
    exit 0
} else {
    Write-Host "失败 $($script:FailCount) 个 / 通过 $($script:PassCount) 个:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
