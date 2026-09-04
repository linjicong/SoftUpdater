# 测量刷新管线期间的全系统 CPU 消耗分布
$ErrorActionPreference = 'Continue'
Import-Module 'D:\software\SoftUpdater\SoftUpdater-Core.psm1' -Force

$sync2 = [hashtable]::Synchronized(@{})
$sync2.Log = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$sync2.Busy = $false; $sync2.StatusText = ''; $sync2.ResultRows = $null
$sync2.RowUpdates = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

$jobText = @'
param($Root, $Config, $Sync)
Import-Module (Join-Path $Root 'SoftUpdater-Core.psm1') -Force
try {
    $onLog = { param($m) $Sync.Log.Enqueue([string]$m) }
    $rows = @(Get-SuInstalledSoftware -Config $Config -OnLog $onLog)
    $Sync.ResultRows = $rows
    $Sync.StatusText = "done: $($rows.Count)"
} catch { $Sync.StatusText = "ERR: $($_.Exception.Message)" }
'@

$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript($jobText)
[void]$ps.AddArgument('D:\software\SoftUpdater')
[void]$ps.AddArgument((Get-SuConfig -Path 'D:\software\SoftUpdater\config.json'))
[void]$ps.AddArgument($sync2)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$h = $ps.BeginInvoke()

$timeline = [System.Collections.Generic.List[string]]::new()
$prev = @{}
foreach ($p in (Get-Process)) { $prev[$p.Id] = @{ N = $p.ProcessName; C = $p.TotalProcessorTime.TotalSeconds } }

while (-not $h.AsyncWaitHandle.WaitOne(1000)) {
    $t = $sw.Elapsed.TotalSeconds
    $snap = @{}
    foreach ($p in (Get-Process)) { $snap[$p.Id] = @{ N = $p.ProcessName; C = $p.TotalProcessorTime.TotalSeconds } }
    $deltas = foreach ($id in $snap.Keys) {
        if ($prev.ContainsKey($id)) {
            $d = $snap[$id].C - $prev[$id].C
            if ($d -gt 0.2) { [pscustomobject]@{ Name = $snap[$id].N; CPUs = [math]::Round($d, 2) } }
        }
    }
    $prev = $snap
    $top = ($deltas | Sort-Object CPUs -Descending | Select-Object -First 4 | ForEach-Object { "$($_.Name)=$($_.CPUs)s" }) -join '  '
    $timeline.Add(("{0,5:N1}s  {1}" -f $t, $(if ($top) { $top } else { '(idle)' })))
}
$sw.Stop()
try { [void]$ps.EndInvoke($h) } catch {}
$ps.Dispose(); $rs.Close(); $rs.Dispose()

"===== 刷新期间每秒 CPU 增量 top4（秒） ====="
$timeline
""
"总耗时: $([math]::Round($sw.Elapsed.TotalSeconds,1))s   状态: $($sync2.StatusText)"
"核心数: $([Environment]::ProcessorCount)   逻辑核单秒=1s CPU"
"--- 任务日志 ---"
$l = $null; while ($sync2.Log.TryDequeue([ref]$l)) { $l }
