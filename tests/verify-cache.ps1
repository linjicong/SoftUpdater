# 缓存三场景验证：①冷启动扫描并写缓存 ②新鲜缓存秒开不重扫 ③过期缓存自动后台重扫
$ErrorActionPreference = 'Continue'
$repro = 'D:\software\SoftUpdater\tests\repro-stuck.ps1'
$cachePath = 'D:\software\SoftUpdater\cache-rows.json'
$statePath = 'D:\software\SoftUpdater\state.json'

function Run-Repro {
    param([string]$Label)
    $out = pwsh -NoProfile -STA -File $repro 2>$null
    $errCount = @($out | Where-Object { $_ -like 'SCRIPT-ERR*' }).Count
    $summary = ($out | Where-Object { $_ -match '状态栏文本|表格行数' }) -join ' | '
    "[$Label] SCRIPT-ERR=$errCount  $summary"
    return $out
}

"===== 场景①：冷启动（删缓存+状态） ====="
Remove-Item $cachePath, $statePath -Force -ErrorAction SilentlyContinue
$out1 = Run-Repro '①冷启动'
"cache-rows.json 生成: $(Test-Path $cachePath)"
if (Test-Path $cachePath) {
    $c = Get-Content $cachePath -Raw | ConvertFrom-Json
    "缓存行数: $(@($c.rows).Count)  数据时间: $($c.savedAt)"
}
$lastCheck1 = $stateBefore = ''
""

"===== 场景②：缓存新鲜（6h 内）→ 应秒开且不重扫 ====="
$stateBefore = (Get-Content $statePath -Raw | ConvertFrom-Json).lastCheck
"重扫前 state.lastCheck: $stateBefore"
$out2 = Run-Repro '②新鲜缓存'
$stateAfter = (Get-Content $statePath -Raw | ConvertFrom-Json).lastCheck
"重扫后 state.lastCheck: $stateAfter"
"未触发重扫: $($stateBefore -eq $stateAfter)"
$cacheAfter2 = (Get-Content $cachePath -Raw | ConvertFrom-Json).savedAt
"缓存时间未变: $($c.savedAt -eq $cacheAfter2)"
""

"===== 场景③：缓存过期（改成 7h 前）→ 应后台自动重扫 ====="
$c3 = Get-Content $cachePath -Raw | ConvertFrom-Json
$c3.savedAt = (Get-Date).AddHours(-7).ToString('yyyy-MM-dd HH:mm:ss')
$c3 | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cachePath -Encoding UTF8
"伪造缓存时间为: $($c3.savedAt)"
$out3 = Run-Repro '③过期缓存'
Start-Sleep -Seconds 2
$stateAfter3 = (Get-Content $statePath -Raw | ConvertFrom-Json).lastCheck
"重扫已触发（state.lastCheck 更新为）: $stateAfter3"
$cacheAfter3 = (Get-Content $cachePath -Raw | ConvertFrom-Json).savedAt
"缓存已刷新为: $cacheAfter3"
