#requires -Version 7.0
<#
  SoftUpdater-Task.ps1 — 定时任务无界面入口
  由计划任务 SoftUpdater-Auto 调用：pwsh -NoProfile -WindowStyle Hidden -File SoftUpdater-Task.ps1 -Auto
  行为：读取 config.json；schedule.enabled 为 false 时直接退出（开关在图形界面设置里控制）；
        枚举 -> 找出有更新的软件（排除名单生效）-> 逐个静默升级 -> 写日志与 state.json。
#>
param([switch]$Auto)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
Import-Module (Join-Path $root 'SoftUpdater-Core.psm1') -Force

$onLog   = { param($m) Write-SuLog -Message ([string]$m) }
$onRow   = { param($row, $s) Write-SuLog -Message ("{0}: {1}" -f $row.Name, $s) }

try {
    if (-not $Auto) {
        Write-Host '用法: SoftUpdater-Task.ps1 -Auto'
        Write-Host '  本脚本供 Windows 计划任务静默调用；手动更新请双击 启动软件更新助手.vbs 打开图形界面。'
        exit 0
    }

    $config = Get-SuConfig
    if (-not $config.schedule.enabled) {
        & $onLog '定时自动更新未启用（设置中「启用定时自动更新」未勾选），本次跳过。'
        exit 0
    }

    & $onLog '===== 定时自动更新开始 ====='
    $rows = @(Get-SuInstalledSoftware -Config $config -OnLog $onLog)
    $targets = @($rows | Where-Object { $_.HasUpdate -and $_.Id })
    & $onLog ("发现 {0} 个可更新项" -f $targets.Count)

    $summary = '无更新'
    if ($targets.Count -gt 0) {
        $result = Invoke-SuUpgradeBatch -Rows $targets -Exclusions $config.exclusions -OnOutput $onLog -OnRowStatus $onRow
        $summary = "成功 $($result.Ok) / 失败 $($result.Fail) / 跳过 $($result.Skip)"
    }

    Update-SuState -Data @{
        lastAutoRun    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        lastAutoResult = $summary
    }
    & $onLog "===== 定时自动更新结束: $summary ====="
    exit 0
} catch {
    Write-SuLog -Message ("定时自动更新异常: " + $_.Exception.Message)
    exit 1
}
