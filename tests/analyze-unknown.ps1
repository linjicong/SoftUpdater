# 版本未知归因分析：缓存 → 分型 → 注册表/便携源库交叉验证
$ErrorActionPreference = 'Continue'
Import-Module 'D:\software\SoftUpdater\SoftUpdater-Core.psm1' -Force

$c = Get-SuRowCache
$all = @($c.Rows)
$unk = @($all | Where-Object { (Get-SuStatusBucket -HasUpdate ([bool]$_.HasUpdate) -Status "$($_.Status)") -eq 'unknown' })
"缓存时间: $($c.SavedAt)   总行: $($all.Count)   版本未知: $($unk.Count)"

# 分型
$typed = foreach ($r in $unk) {
    $id = "$($r.Id)"
    $type = if ($r.Catalog -eq '便携') { 'A-便携(无源)' }
            elseif ($r.Catalog -eq '系统') { 'B-系统(注册表有但winget没有)' }
            elseif ($id -match '^MSIX\\') { 'C-winget·MSIX商店/系统组件' }
            elseif ($id -match '^ARP\\') { 'D-winget·ARP原始条目' }
            elseif ($id) { 'E-winget·普通包但版本空' }
            else { 'F-无Id' }
    [pscustomobject]@{ Type = $type; Name = $r.Name; Id = $id; Version = "$($r.Version)"; Available = "$($r.Available)"; Status = "$($r.Status)"; Location = "$($r.Location)" }
}
""
"===== 分型统计 ====="
$typed | Group-Object Type | Sort-Object Count -Descending | ForEach-Object { "{0,4}  {1}" -f $_.Count, $_.Name }

# 各类型明细（大组取前 12 个示例）
""
foreach ($g in ($typed | Group-Object Type | Sort-Object Count -Descending)) {
    "===== 明细: $($g.Name)（$($g.Count) 个） ====="
    $g.Group | Select-Object -First 12 | ForEach-Object {
        $loc = if ($_.Location.Length -gt 45) { $_.Location.Substring(0, 45) + '…' } else { $_.Location }
        "  [{0}]  id={1}  ver='{2}'  loc={3}" -f $_.Name, $_.Id, $_.Version, $loc
    }
    if ($g.Count -gt 12) { "  ...（其余 $($g.Count - 12) 个略）" }
    ""
}

# ===== 深挖 E 类：普通 winget 包版本为空 → 注册表里到底有没有它 =====
$eGroup = @($typed | Where-Object Type -eq 'E-winget·普通包但版本空')
if ($eGroup.Count -gt 0) {
    "===== E 类深挖：注册表交叉验证 ====="
    $reg = Get-SuRegistrySoftware
    $fixable = 0; $nover = 0; $nomatch = 0
    foreach ($r in $eGroup) {
        $hit = $null
        foreach ($e in $reg) { if (Test-SuNameMatch -A $e.Name -B $r.Name) { $hit = $e; break } }
        if ($hit) {
            if ("$($hit.Version)") { $fixable++; "  [可修复-注册表有版本] $($r.Name)  ←→  注册表: '$($hit.Name)' ver=$($hit.Version)" }
            else { $nover++; "  [注册表无版本] $($r.Name)  ←→  注册表: '$($hit.Name)' DisplayVersion 为空" }
        } else { $nomatch++; "  [注册表无匹配] $($r.Name)" }
    }
    "E 类小结: 可修复(名称能对上+注册表有版本)=$fixable  注册表也没版本=$nover  注册表对不上=$nomatch"
    ""
}

# ===== A 类深挖：便携无源 vs 源库状态 =====
$aGroup = @($typed | Where-Object Type -eq 'A-便携(无源)')
if ($aGroup.Count -gt 0) {
    "===== A 类深挖：便携源库状态 ====="
    $db = @(Get-SuPortableDb)
    foreach ($r in $aGroup) {
        $e = $db | Where-Object { "$($_.Folder)" -ieq $r.Location } | Select-Object -First 1
        $state = if ($e) { "$($e.State) (Id=$($e.WingetId))" } else { '不在源库中' }
        "  $($r.Name)  →  源库状态: $state"
    }
    ""
}
