# 实验脚本：无提权、有限时消息泵地运行真实 SoftUpdater.ps1，复现「卡在正在启动」
$ErrorActionPreference = 'Continue'
Import-Module 'D:\software\SoftUpdater\SoftUpdater-Core.psm1' -Force

$code = Get-Content 'D:\software\SoftUpdater\SoftUpdater.ps1' -Raw
$code = $code -replace '(?m)^#requires.*\r?\n', ''
$code = $code.Replace('$PSScriptRoot', "'D:\software\SoftUpdater'")
$code = $code.Replace('$PSCommandPath', "'D:\software\SoftUpdater\SoftUpdater.ps1'")
$code = $code.Replace('if (-not $isAdmin) {', 'if ($false) {')   # 跳过自提权
$code = $code.Replace('[void]$win.ShowDialog()', 'MyTestPump')   # 阻塞式对话框 → 限时泵

function MyTestPump {
    $win.Show()
    "PUMP: 窗口已显示，泵 40 秒..."
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $stopper = New-Object System.Windows.Threading.DispatcherTimer
    $stopper.Interval = [TimeSpan]::FromSeconds(40)
    $stopper.Add_Tick({ $frame.Continue = $false; $stopper.Stop() })
    $stopper.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    "PUMP: 结束"
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Invoke-Expression $code
} catch {
    "SCRIPT-ERR: $($_.Exception.ToString())"
}

"===== 实验结果 (总耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1))s) ====="
"state.json 存在: $(Test-Path 'D:\software\SoftUpdater\state.json')"
"StatusText: $($sync.StatusText)"
"Busy: $($sync.Busy)"
"ResultRows: $(if ($sync.ResultRows) { @($sync.ResultRows).Count } else { 0 })"
"Jobs 未收割: $(if ($Jobs) { $Jobs.Count } else { 0 })"
"Timer Enabled: $($timer.IsEnabled)"
"状态栏文本: [$($statusText.Text)]"
"表格行数: $($grid.Items.Count)"
"性能: 最大 tick $($sync.TickMaxMs) ms / 渲染 $($sync.RenderMs) ms"
"日志区前 600 字符:"
if ($logBox.Text.Length -gt 0) { $logBox.Text.Substring(0, [Math]::Min(600, $logBox.Text.Length)) } else { '(日志区为空!)' }
