# 真机验证：学习便携源 → 强制检测 → 真下载一个安装包 → 合并展示
$ErrorActionPreference = 'Continue'
Import-Module 'D:\software\SoftUpdater\SoftUpdater-Core.psm1' -Force
$onLog = { param($m) Write-Host "[log] $m" }

$rows = @(Get-SuInstalledSoftware -Config (Get-SuConfig) -OnLog $onLog)
"便携行: $(@($rows | Where-Object Catalog -eq '便携').Count)"

$dbPath = 'D:\software\SoftUpdater\update-sources.json'
$db = @(Update-SuPortableDbLearning -Rows $rows -Db (Get-SuPortableDb -Path $dbPath) -DbPath $dbPath -OnLog $onLog)
""
"===== 学习结果 ====="
"库条目总数: $(@($db).Count)"
"auto: $(@($db | Where-Object State -eq 'auto').Count)  fuzzy: $(@($db | Where-Object State -eq 'fuzzy').Count)  未匹配: $(@($db | Where-Object State -eq '未匹配').Count)"
"未匹配清单: $(@($db | Where-Object State -eq '未匹配' | ForEach-Object Name) -join ', ')"

""
"===== 强制检测（逐个查目录，含安装包地址） ====="
$db = @(Invoke-SuPortableCheck -Rows $rows -Db $db -StaleHours 24 -Force -DbPath $dbPath -OnLog $onLog)
$pending = @($db | Where-Object { $_.PendingDownload })
"待下载: $($pending.Count)  ($(($pending | ForEach-Object Name) -join ', '))"

""
"===== 真实下载验证（第一个待下载项 → 临时目录） ====="
if ($pending.Count -gt 0) {
    $e = $pending[0]
    $dest = Invoke-SuPortableDownload -Entry $e -DownloadDir "$env:TEMP\su-dl-test" -OnLog $onLog
    "下载结果: $dest"
    if ($dest -and (Test-Path $dest)) { "文件存在: True  大小: $([math]::Round((Get-Item $dest).Length/1MB,1)) MB" } else { "文件存在: False" }
    $e | Add-Member -NotePropertyName PendingDownload -NotePropertyValue $false -Force
    Save-SuPortableDb -Db $db -Path $dbPath
} else {
    "（没有待下载项）"
}

""
"===== 合并进列表的最终效果 ====="
$merged = @(Merge-SuPortableSourceInfo -Rows $rows -Db $db)
$upP = @($merged | Where-Object Status -eq '有更新(便携)')
$okP = @($merged | Where-Object Status -eq '最新(便携)')
"便携有更新: $($upP.Count)  ($(($upP | Select-Object -First 6 -ExpandProperty Name) -join ', '))"
"便携最新:   $($okP.Count)"
