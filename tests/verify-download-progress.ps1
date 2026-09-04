# 验证下载进度回调：采样单调性、回调次数、.part 清理、最终文件
$ErrorActionPreference = 'Continue'
Import-Module 'D:\software\SoftUpdater\SoftUpdater-Core.psm1' -Force

$dbPath = 'D:\software\SoftUpdater\update-sources.json'
$db = @(Get-SuPortableDb -Path $dbPath)
$e = @($db | Where-Object { $_.Name -like 'Everything*' })[0]
"目标: $($e.Name)  URL: $($e.InstallerUrl)"

$samples = [System.Collections.Generic.List[double]]::new()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dest = Invoke-SuPortableDownload -Entry $e -DownloadDir "$env:TEMP\su-dl-prog" `
    -OnLog { param($m) Write-Host "[log] $m" } `
    -OnProgress { param($rec, $tot, $p)
        $v = if ($tot -gt 0) { [math]::Round(100.0 * $rec / $tot, 1) } else { $rec }
        $samples.Add($v)
    }
$sw.Stop()

"回调次数: $($samples.Count)"
if ($samples.Count -ge 2) {
    "首采样: $($samples[0])%   末采样: $($samples[$samples.Count - 1])%"
    $sorted = @($samples | Sort-Object)
    $monotonic = $true
    for ($i = 0; $i -lt $samples.Count; $i++) { if ($sorted[$i] -ne $samples[$i]) { $monotonic = $false; break } }
    "单调不减: $monotonic"
    "到达 100%: $($samples[$samples.Count - 1] -ge 100)"
}
"总耗时: $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
"最终文件: $dest"
"文件存在: $(if ($dest) { Test-Path $dest } else { $false })  大小MB: $(if ($dest -and (Test-Path $dest)) { [math]::Round((Get-Item $dest).Length/1MB,1) } else { 0 })"
".part 残留: $(if ($dest) { Test-Path "$dest.part" } else { '?' })"
