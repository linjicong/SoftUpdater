#requires -Version 7.0
<#
  SoftUpdater-Core.psm1 — 软件更新助手核心模块
  职责：软件枚举（winget/注册表/目录扫描）、合并、更新检测、升级执行、
        配置/日志/状态持久化、计划任务管理。
  设计约定：纯逻辑函数不触碰系统；集成函数统一通过 -OnLog/-OnOutput 回调输出，便于 UI 与无界面任务复用。
#>

$script:SuRoot = $PSScriptRoot
$script:SuTaskName = 'SoftUpdater-Auto'

# ============================================================ 纯逻辑：winget 输出解析

function Get-SuCharWidth {
    <# 控制台视觉宽度：CJK/全角等宽字符按 2 计，其余按 1（winget 表格按视觉列对齐） #>
    param([char]$Char)
    $n = [int]$Char
    if (($n -ge 0x1100 -and $n -le 0x115F) -or ($n -ge 0x2E80 -and $n -le 0xA4CF) -or
        ($n -ge 0xAC00 -and $n -le 0xD7A3) -or ($n -ge 0xF900 -and $n -le 0xFAFF) -or
        ($n -ge 0xFE30 -and $n -le 0xFE4F) -or ($n -ge 0xFF00 -and $n -le 0xFF60) -or
        ($n -ge 0xFFE0 -and $n -le 0xFFE6) -or ($n -ge 0x1F000 -and $n -le 0x1FAFF)) { return 2 }
    return 1
}

function ConvertFrom-SuWingetOutput {
    <# 解析 `winget list` / `winget upgrade` 的固定宽度文本输出，兼容中英文表头与长名截断 #>
    param([string]$OutputText)

    $result = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($OutputText)) { return $result }

    $lines = $OutputText -split "`r?`n"

    # 定位表头行：同时包含 'Id' 和 ('版本' 或 'Version')
    $headerIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '\bId\b' -and ($l.Contains('版本') -or $l.Contains('Version'))) { $headerIdx = $i; break }
    }
    if ($headerIdx -lt 0) { return $result }

    $h = $lines[$headerIdx]
    $idStart = $h.IndexOf('Id')
    $verTok = if ($h.Contains('版本')) { '版本' } else { 'Version' }
    $avTok  = if ($h.Contains('可用')) { '可用' } elseif ($h.Contains('Available')) { 'Available' } else { $null }
    $srcTok = if ($h.Contains('源'))   { '源' }   elseif ($h.Contains('Source'))   { 'Source' }   else { $null }

    if ($idStart -lt 0) {
        # winget 真机表头可能输出大写 'ID'（IndexOf 区分大小写，需两种都试）
        $idStart = $h.IndexOf('Id', [System.StringComparison]::OrdinalIgnoreCase)
    }
    $verStart = $h.IndexOf($verTok, [Math]::Max($idStart + 2, 0), [System.StringComparison]::OrdinalIgnoreCase)
    if ($verStart -lt 0) { return $result }

    $avStart = -1; $srcStart = -1
    if ($avTok) { $avStart = $h.IndexOf($avTok, $verStart + $verTok.Length, [System.StringComparison]::OrdinalIgnoreCase) }
    if ($srcTok) {
        $from = if ($avStart -ge 0) { $avStart + $avTok.Length } else { $verStart + $verTok.Length }
        $srcStart = $h.IndexOf($srcTok, $from, [System.StringComparison]::OrdinalIgnoreCase)
    }

    # ---- 视觉列切片 ----
    # winget 表格按“显示宽度”对齐（CJK 字符宽 2），数据行的列起点随行内宽字符数量变化，
    # 因此必须：表头偏移换算为视觉列 → 每行构建 视觉列→字符索引 映射 → 按视觉区间切片。
    $visualOf = {
        param([string]$Line, [int]$CharIndex)
        $v = 0
        $n = [Math]::Min($CharIndex, $Line.Length)
        for ($i = 0; $i -lt $n; $i++) { $v += Get-SuCharWidth -Char $Line[$i] }
        return $v
    }
    $buildMap = {
        param([string]$Line)
        $map = New-Object 'System.Collections.Generic.List[int]'
        for ($ci = 0; $ci -lt $Line.Length; $ci++) {
            $w = Get-SuCharWidth -Char $Line[$ci]
            for ($k = 0; $k -lt $w; $k++) { [void]$map.Add($ci) }
        }
        return $map
    }
    $vslice = {
        param([string]$Line, [System.Collections.Generic.List[int]]$Map, [int]$VisStart, [int]$VisEnd)
        if ($VisStart -lt 0 -or $VisStart -ge $Map.Count) { return '' }
        if ($VisEnd -lt 0 -or $VisEnd -gt $Map.Count) { $VisEnd = $Map.Count }
        if ($VisEnd -le $VisStart) { return '' }
        $cs = $Map[$VisStart]
        $ce = if ($VisEnd -ge $Map.Count) { $Line.Length } else { $Map[$VisEnd] }
        if ($ce -le $cs) { return '' }
        return $Line.Substring($cs, $ce - $cs).Trim()
    }

    $idVis  = & $visualOf $h $idStart
    $verVis = & $visualOf $h $verStart
    $avVis  = if ($avStart -ge 0) { & $visualOf $h $avStart } else { -1 }
    $srcVis = if ($srcStart -ge 0) { & $visualOf $h $srcStart } else { -1 }

    for ($i = $headerIdx + 2; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { break }   # 空行 = 数据结束
        $map = & $buildMap $line
        if ($map.Count -le $idVis) { continue }

        $verEndVis = if ($avVis -ge 0) { $avVis } elseif ($srcVis -ge 0) { $srcVis } else { -1 }
        $name = & $vslice $line $map 0 $idVis
        $id   = & $vslice $line $map $idVis $verVis
        $ver  = & $vslice $line $map $verVis $verEndVis
        $av   = if ($avVis -ge 0) { & $vslice $line $map $avVis $(if ($srcVis -ge 0) { $srcVis } else { -1 }) } else { '' }
        $src  = if ($srcVis -ge 0) { & $vslice $line $map $srcVis -1 } else { '' }

        if ([string]::IsNullOrEmpty($id) -and [string]::IsNullOrEmpty($name)) { continue }
        $result.Add([pscustomobject]@{ Name = $name; Id = $id; Version = $ver; Available = $av; Source = $src })
    }
    return $result
}

# ============================================================ 纯逻辑：名称/版本/排除

function ConvertTo-SuNormalizedKey {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace '[^\p{L}\p{N}]', '').ToLowerInvariant())
}

function Test-SuNameMatch {
    <# 宽松匹配：规范化后相等，或短名(≥4字符)被长名包含 #>
    param([string]$A, [string]$B)
    $ka = ConvertTo-SuNormalizedKey -Text $A
    $kb = ConvertTo-SuNormalizedKey -Text $B
    if (-not $ka -or -not $kb) { return $false }
    if ($ka -eq $kb) { return $true }
    $short = if ($ka.Length -le $kb.Length) { $ka } else { $kb }
    $long  = if ($ka.Length -le $kb.Length) { $kb } else { $ka }
    if ($short.Length -ge 4 -and $long.Contains($short)) { return $true }
    return $false
}

function Compare-SuVersion {
    <# 版本比较：数字段逐段比较；任一方非版本号格式时回退字符串比较；空版本视为最旧。返回 -1/0/1 #>
    param([string]$A, [string]$B)
    $a = if ($null -eq $A) { '' } else { $A.Trim() }
    $b = if ($null -eq $B) { '' } else { $B.Trim() }
    if ($a -eq $b) { return 0 }
    if ($a -eq '') { return -1 }
    if ($b -eq '') { return 1 }
    $aOk = $a -match '^[0-9]+(\.[0-9]+)*$'
    $bOk = $b -match '^[0-9]+(\.[0-9]+)*$'
    if ($aOk -and $bOk) {
        $as = $a.Split('.'); $bs = $b.Split('.')
        $n = [Math]::Max($as.Count, $bs.Count)
        for ($i = 0; $i -lt $n; $i++) {
            $x = if ($i -lt $as.Count) { [int]$as[$i] } else { 0 }
            $y = if ($i -lt $bs.Count) { [int]$bs[$i] } else { 0 }
            if ($x -lt $y) { return -1 }
            if ($x -gt $y) { return 1 }
        }
        return 0
    }
    return [string]::Compare($a, $b, $true)
}

function Test-SuExcluded {
    <# 排除名单通配匹配（对 Name 与 Id 都尝试 -like） #>
    param([string]$Name, [string]$Id, [string[]]$Patterns)
    if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
    foreach ($p in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($Name -and $Name -like $p) { return $true }
        if ($Id -and $Id -like $p) { return $true }
    }
    return $false
}

function Get-SuInstallDirFromUninstallEntry {
    <# 从注册表卸载项提取安装目录：优先 InstallLocation，其次 DisplayIcon / UninstallString 中的 exe 路径 #>
    param([string]$InstallLocation, [string]$DisplayIcon, [string]$UninstallString)

    $loc = ''
    if ($InstallLocation) { $loc = $InstallLocation.Trim().Trim('"').Trim() }
    if ($loc) { return $loc.TrimEnd('\') }

    foreach ($src in @($DisplayIcon, $UninstallString)) {
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        $s = $src.Trim()
        $exePath = $null
        if ($s.StartsWith('"')) {
            $end = $s.IndexOf('"', 1)
            if ($end -gt 1) { $exePath = $s.Substring(1, $end - 1) }
        }
        if (-not $exePath) {
            $m = [regex]::Match($s, '(?i)^[a-z]:\\[^"]*?\.exe')
            if ($m.Success) { $exePath = $m.Value }
        }
        if ($exePath) {
            $exePath = $exePath.Trim()
            if ($exePath -match '(?i)\.(exe|ico),\d+$') { $exePath = $exePath.Substring(0, $exePath.IndexOf(',')) }
            if ($exePath -match '(?i)\.(exe|ico)$') {
                return ([System.IO.Path]::GetDirectoryName($exePath))
            }
        }
    }
    return $null
}

function Get-SuExeNameFromUninstallEntry {
    <# 从 DisplayIcon / UninstallString 提取主程序 exe 文件名（不含扩展名），供最近使用的 ExeHint 第三重匹配 #>
    param([string]$DisplayIcon, [string]$UninstallString)
    foreach ($src in @($DisplayIcon, $UninstallString)) {
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        $s = $src.Trim()
        $exePath = $null
        if ($s.StartsWith('"')) {
            $end = $s.IndexOf('"', 1)
            if ($end -gt 1) { $exePath = $s.Substring(1, $end - 1) }
        }
        if (-not $exePath) {
            $m = [regex]::Match($s, '(?i)^[a-z]:\\[^"]*?\.exe')
            if ($m.Success) { $exePath = $m.Value }
        }
        if ($exePath) {
            $exePath = $exePath.Trim()
            if ($exePath -match '(?i)\.(exe|ico),\d+$') { $exePath = $exePath.Substring(0, $exePath.IndexOf(',')) }
            if ($exePath -match '(?i)\.exe$') { return [System.IO.Path]::GetFileNameWithoutExtension($exePath) }
        }
    }
    return $null
}

# ============================================================ 纯逻辑：合并

function Merge-SuSoftwareList {
    <#
      四路数据合并成统一列表：
      1) winget 包 → 主列表（可自动升级）
      2) 注册表卸载项 → 匹配 winget 行标注位置；匹配不上的补充为「系统」行
      3) 目录扫描候选 → 已被注册表覆盖的跳过；未被覆盖的绿色版 → 「便携」行
      4) 按 Id / 规范化名称去重
    #>
    param(
        [object[]]$WingetPackages = @(),
        [object[]]$RegistryEntries = @(),
        [object[]]$Directories = @(),
        [string[]]$ScanPaths = @()
    )
    if ($null -eq $WingetPackages) { $WingetPackages = @() }
    if ($null -eq $RegistryEntries) { $RegistryEntries = @() }
    if ($null -eq $Directories)     { $Directories = @() }
    if ($null -eq $ScanPaths)       { $ScanPaths = @() }

    function New-SuRow { param($Name, $Id, $Version, $Available, $Catalog, $Location, $Status, $ProductName = $null, $ExeHint = '')
        $hasUpdate = ($Available -and $Version -and (Compare-SuVersion -A $Available -B $Version) -gt 0)
        [pscustomobject]@{
            Selected    = $false
            Name        = $Name
            Id          = $Id
            Version     = $Version
            Available   = $Available
            Catalog     = $Catalog
            Location    = $Location
            HasUpdate   = $hasUpdate
            Status      = $Status
            ProductName = $ProductName
            ExeHint     = $ExeHint
            LastUsed    = ''
        }
    }

    # ---- 预计算：包规范化键等值字典 + 包含扫描数组（避免逐对正则/脚本块调用） ----
    $pkgCount = @($WingetPackages).Count
    $pkgNorms = New-Object 'string[]' $pkgCount
    $pkgItems = New-Object 'object[]' $pkgCount
    $pkgByNorm = @{}
    $pi = 0
    foreach ($wp in $WingetPackages) {
        $norm = ConvertTo-SuNormalizedKey -Text "$($wp.Name)"
        $pkgNorms[$pi] = $norm; $pkgItems[$pi] = $wp
        if ($norm -and -not $pkgByNorm.ContainsKey($norm)) { $pkgByNorm[$norm] = $wp }
        $pi++
    }

    function Find-BestWingetMatch { param($RegName)
        # 1) 规范化相等（含中英别名，如 微信↔WeChat、飞书↔Feishu，字典 O(1)）；2) 包含关系（裸扫）
        foreach ($key in (Get-SuAliasKeys -Name $RegName)) {
            if ($key -and $pkgByNorm.ContainsKey($key)) { return $pkgByNorm[$key] }
        }
        $kn = ConvertTo-SuNormalizedKey -Text $RegName
        for ($i = 0; $i -lt $pkgCount; $i++) {
            $a = $pkgNorms[$i]
            if (-not $a) { continue }
            if (($kn.Length -ge 4 -and $a.Contains($kn)) -or ($a.Length -ge 4 -and $kn.Contains($a))) { return $pkgItems[$i] }
        }
        return $null
    }

    function Test-PathUnder { param([string]$Child, [string]$Parent)
        if (-not $Child -or -not $Parent) { return $false }
        $c = $Child.TrimEnd('\'); $p = $Parent.TrimEnd('\')
        if ($c -eq $p) { return $true }
        return $c.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
    }

    $rows = [System.Collections.Generic.List[object]]::new()

    # 1) winget 主列表
    foreach ($wp in $WingetPackages) {
        $ver = "$($wp.Version)"
        if (-not $ver) { $ver = Get-SuVersionFromMsixId -Id "$($wp.Id)" }   # MSIX 包版本内嵌在 Id 中
        $rows.Add((New-SuRow -Name $wp.Name -Id $wp.Id -Version $ver -Available $wp.Available -Catalog 'winget' -Location '' -Status ''))
    }

    # 2) 注册表：标注位置 / 补充系统行
    $rowById = @{}
    foreach ($r in $rows) { $rid = "$($r.Id)"; if ($rid -and -not $rowById.ContainsKey($rid)) { $rowById[$rid] = $r } }
    $matchedRegNames = [System.Collections.Generic.List[string]]::new()
    foreach ($reg in $RegistryEntries) {
        $wp = Find-BestWingetMatch -RegName "$($reg.Name)"
        if ($wp) {
            $matchedRegNames.Add($reg.Name)
            $row = $rowById["$($wp.Id)"]
            if ($reg.InstallDir) {
                foreach ($scanPath in $ScanPaths) {
                    if (Test-PathUnder -Child $reg.InstallDir -Parent $scanPath) {
                        if ($row -and -not $row.Location) { $row.Location = $reg.InstallDir }
                        break
                    }
                }
            }
            # 主程序 exe 名 → 供「最近使用」ExeHint 第三重匹配（位置缺失时仍可命中）
            if ($reg.ExeHint) {
                if ($row -and -not "$($row.ExeHint)") { $row.ExeHint = "$($reg.ExeHint)" }
            }
            # 注册表是已安装版本的权威来源：winget COM 对「应用内自更新」的软件可能返回空/过期的本地版本
            if ($reg.Version) {
                if ($row) {
                    $row.Version = "$($reg.Version)"
                    $row.HasUpdate = ($row.Available -and $row.Version -and ((Compare-SuVersion -A $row.Available -B $row.Version) -gt 0))
                }
            }
        }
        else {
            $matchedRegNames.Add($reg.Name)
            $rows.Add((New-SuRow -Name $reg.Name -Id '' -Version $reg.Version -Available '' -Catalog '系统' -Location "$($reg.InstallDir)" -Status '未识别' -ExeHint "$($reg.ExeHint)"))
        }
    }

    # 3) 目录扫描：未覆盖的绿色版
    foreach ($d in $Directories) {
        $dfp = "$($d.FullPath)".TrimEnd('\')
        $covered = $false
        foreach ($reg in $RegistryEntries) {
            $rd = "$($reg.InstallDir)".TrimEnd('\')
            if (-not $rd) { continue }
            if ($dfp -eq $rd -or
                $dfp.StartsWith($rd + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                $rd.StartsWith($dfp + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $covered = $true; break }
        }
        if (-not $covered) {
            # 目录名与 winget 行匹配 → 只标注位置（等值字典 + 包含裸扫，语义同 Test-SuNameMatch）
            $leaf = Split-Path -Leaf "$($d.FullPath)"
            $kn3 = ConvertTo-SuNormalizedKey -Text $leaf
            $hit = $null
            if ($kn3 -and $pkgByNorm.ContainsKey($kn3)) { $hit = $pkgByNorm[$kn3] }
            if (-not $hit) {
                for ($i = 0; $i -lt $pkgCount; $i++) {
                    $a = $pkgNorms[$i]
                    if (-not $a) { continue }
                    if (($kn3.Length -ge 4 -and $a.Contains($kn3)) -or ($a.Length -ge 4 -and $kn3.Contains($a))) { $hit = $pkgItems[$i]; break }
                }
            }
            if ($hit) {
                $row = $rowById["$($hit.Id)"]
                if ($row -and -not $row.Location) { $row.Location = $d.FullPath }
            } else {
                $rows.Add((New-SuRow -Name $leaf -Id '' -Version $d.ExeVersion -Available '' -Catalog '便携' -Location $d.FullPath -Status '无法检测更新' -ProductName $d.ProductName))
            }
        }
    }

    # 4) 去重 + 状态
    $seen = @{}
    $final = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $rows) {
        $key = if ($r.Id) { "id:$($r.Id.ToLowerInvariant())" } else { "name:$(ConvertTo-SuNormalizedKey $r.Name)" }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if ($r.Catalog -eq 'winget') {
            if (-not $r.Version) {
                $r.Status = '版本未知'; $r.HasUpdate = $false
            } else {
                $r.Status = if ($r.HasUpdate) { '有更新' } else { '最新' }
            }
        }
        $final.Add($r)
    }
    return $final
}

# ============================================================ 纯逻辑：UserAssist 最近使用时间

function ConvertFrom-SuRot13 {
    <# UserAssist 注册表值名为 ROT13 编码的路径，解码（ROT13 自反，数字/符号不变） #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $chars = $Text.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = [int]$chars[$i]
        if     ($c -ge 65 -and $c -le 90)  { $chars[$i] = [char](($c - 65 + 13) % 26 + 65) }
        elseif ($c -ge 97 -and $c -le 122) { $chars[$i] = [char](($c - 97 + 13) % 26 + 97) }
    }
    return -join $chars
}

function Get-SuUserAssistLastRun {
    <#
      从 UserAssist 记录的二进制数据中提取最近运行时间。
      Win10/11 记录为 72 字节，LastExecution(FILETIME) 位于偏移 60（非 8 字节对齐）；
      为兼容未来布局变化，扫描所有字节偏移，取「合理」FILETIME 的最大值。
      合理 = 2015 之后（滤掉计数字段误判与 UEME 控制会话条目）且不超过明天（滤掉异常值）。
    #>
    param([byte[]]$Data, [datetime]$Now = (Get-Date))
    if (-not $Data -or $Data.Length -lt 8) { return $null }
    $minFt = [DateTime]::new(2015, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).ToFileTimeUtc()
    $maxFt = $Now.ToFileTimeUtc() + [TimeSpan]::FromDays(1).Ticks
    $bestFt = [long]0
    for ($off = 0; $off -le $Data.Length - 8; $off++) {
        $ft = [BitConverter]::ToInt64($Data, $off)
        if ($ft -ge $minFt -and $ft -le $maxFt -and $ft -gt $bestFt) { $bestFt = $ft }
    }
    if ($bestFt -gt 0) { return [DateTime]::FromFileTime($bestFt) }
    return $null
}

function Test-SuPathUnder {
    <# 子路径是否位于父目录之下（或相等），大小写不敏感 #>
    param([string]$Child, [string]$Parent)
    if (-not $Child -or -not $Parent) { return $false }
    $c = $Child.TrimEnd('\'); $p = $Parent.TrimEnd('\')
    if (-not $c -or -not $p) { return $false }
    if ($c -eq $p) { return $true }
    return $c.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

$script:SuGenericExeNames = @('setup', 'install', 'uninstall', 'unins000', 'update', 'updater', 'launcher')

function Resolve-SuLastUsedBest {
    <#
      「最近使用」核心匹配：返回 hashtable（行对象 → 最近运行 [datetime]，未命中无键）。
      匹配规则（每行取最大时间）：
        1) 记录为 .lnk 快捷方式 → 文件名与行名称宽松匹配；
        2) 记录为完整路径 → 其目录位于行的 Location 之下；未命中时回退 exe 名宽松匹配
           （跳过 setup/uninstall 等通用安装器名，避免误匹配）；
        3) 记录为裸别名（如 AlibabaCloud.Qoder）→ 名称宽松匹配；
        4) ExeHint 第三重匹配：注册表 DisplayIcon 提取的主程序 exe 名与记录名相等。
      性能：行的规范化键/别名/位置预计算 + 别名/规范名倒排索引（等值命中 O(1)，
           仅未等值命中的记录回退逐行包含扫描）。
    #>
    param([object[]]$Rows = @(), [object[]]$Entries = @())
    $rows = @($Rows | Where-Object { $null -ne $_ })
    $best = @{}
    if ($rows.Count -eq 0) { return $best }
    $genericSet = @{}
    foreach ($g in $script:SuGenericExeNames) { $genericSet[$g] = $true }
    $rowInfo = [System.Collections.Generic.List[object]]::new()
    $exactIndex = @{}
    foreach ($r in $rows) {
        $best[$r] = $null
        $rk = [pscustomobject]@{
            Row        = $r
            Norm       = (ConvertTo-SuNormalizedKey -Text "$($r.Name)")
            Alias      = @(Get-SuAliasKeys -Name "$($r.Name)")
            Loc        = ("$($r.Location)").TrimEnd('\')
            ExeHintNorm = (ConvertTo-SuNormalizedKey -Text "$(Get-PropSafe $r 'ExeHint')")
        }
        $rowInfo.Add($rk)
        foreach ($k in (@($rk.Alias) + @($rk.Norm) + @($rk.ExeHintNorm) | Where-Object { $_ } | Select-Object -Unique)) {
            if (-not $exactIndex.ContainsKey($k)) { $exactIndex[$k] = [System.Collections.Generic.List[object]]::new() }
            [void]$exactIndex[$k].Add($rk)
        }
    }
    # 包含回退扫描用的并行数组（避免内层循环的脚本块/属性访问开销）
    $n = $rowInfo.Count
    $normArr = New-Object 'string[]' $n
    $itemArr = New-Object 'object[]' $n
    $i = 0
    foreach ($rk in $rowInfo) { $normArr[$i] = $rk.Norm; $itemArr[$i] = $rk; $i++ }

    $consider = {
        param($rk, [datetime]$dt)
        $r = $rk.Row
        $cur = $best[$r]
        if ($null -eq $cur -or $dt -gt $cur) { $best[$r] = $dt }
    }
    # 名称匹配：等值（别名/规范名/ExeHint）走倒排索引 O(1)；包含回退为裸字符串循环。
    # 两路都执行（并集），与逐行完整谓词的旧语义完全一致。
    $matchByName = {
        param([string]$EntryNorm, [datetime]$dt)
        if (-not $EntryNorm) { return }
        if ($exactIndex.ContainsKey($EntryNorm)) {
            foreach ($rk in $exactIndex[$EntryNorm]) { & $consider $rk $dt }
        }
        for ($i = 0; $i -lt $n; $i++) {
            $a = $normArr[$i]
            if (-not $a) { continue }
            if (($EntryNorm.Length -ge 4 -and $a.Contains($EntryNorm)) -or
                ($a.Length -ge 4 -and $EntryNorm.Contains($a))) { & $consider $itemArr[$i] $dt }
        }
    }

    foreach ($e in $Entries) {
        $path = "$($e.Path)"
        $dt = $e.LastRun
        if (-not $dt) { continue }
        if ($path.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
            # 快捷方式条目：{GUID}\TaskBar\Xxx.lnk / 开始菜单路径 → 按文件名匹配
            $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
            $kn = ConvertTo-SuNormalizedKey -Text $name
            if ($genericSet.ContainsKey($kn)) { continue }
            & $matchByName $kn $dt
            continue
        }
        if ($path.Contains('\')) {
            # 完整 exe 路径：目录前缀匹配 Location 最准；未命中回退 exe 名（滤通用名）
            $dir = $null
            try { $dir = ([System.IO.Path]::GetDirectoryName($path)).TrimEnd('\') } catch {}
            $hit = $false
            if ($dir) {
                foreach ($rk in $rowInfo) {
                    $loc = $rk.Loc
                    if (-not $loc) { continue }
                    if ($dir -eq $loc -or $dir.StartsWith($loc + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                        & $consider $rk $dt; $hit = $true
                    }
                }
            }
            if ($hit) { continue }
            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($path)
            $kn = ConvertTo-SuNormalizedKey -Text $leaf
            if ($genericSet.ContainsKey($kn)) { continue }
            & $matchByName $kn $dt
            continue
        }
        # 裸别名条目（如 MSEdge / AlibabaCloud.Qoder）
        $kn = ConvertTo-SuNormalizedKey -Text $path
        if ($genericSet.ContainsKey($kn)) { continue }
        & $matchByName $kn $dt
    }
    return $best
}

function Update-SuRowsLastUsed {
    <# 把运行记录匹配到软件行并写入 LastUsed（"yyyy-MM-dd HH:mm"，无记录为空），返回命中的行数。 #>
    param([object[]]$Rows = @(), [object[]]$Entries = @())
    if ($null -eq $Rows) { $Rows = @() }
    if ($null -eq $Entries) { $Entries = @() }
    $rows = @($Rows | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { return 0 }
    $entries = @($Entries | Where-Object { $null -ne $_ })
    if ($entries.Count -eq 0) {
        foreach ($r in $rows) { Set-SuLastUsedCell -Row $r -Text '' }
        return 0
    }
    $best = Resolve-SuLastUsedBest -Rows $rows -Entries $entries
    $matched = 0
    foreach ($r in $rows) {
        $dt = $best[$r]
        if ($dt) { Set-SuLastUsedCell -Row $r -Text (Get-Date -Date $dt -Format 'yyyy-MM-dd HH:mm'); $matched++ }
        else { Set-SuLastUsedCell -Row $r -Text '' }
    }
    return $matched
}

function Get-SuLastUsedTextMap {
    <#
      快照 → 最近使用文本映射（键："规范名|小写安装目录"），供后台线程计算、UI 线程应用，
      避免跨线程触碰 WPF 行对象。未命中的行不产生键。
    #>
    param([object[]]$Rows = @(), [object[]]$Entries = @())
    $snap = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Rows)) {
        if ($null -ne $r) {
            $snap.Add([pscustomobject]@{
                Name     = "$($r.Name)"
                Location = "$($r.Location)"
                ExeHint  = "$(Get-PropSafe $r 'ExeHint')"
                LastUsed = ''
            })
        }
    }
    $best = Resolve-SuLastUsedBest -Rows @($snap) -Entries $Entries
    $map = @{}
    foreach ($r in $snap) {
        $dt = $best[$r]
        if ($dt) {
            $key = "$(ConvertTo-SuNormalizedKey -Text $r.Name)|$($r.Location.TrimEnd('\').ToLowerInvariant())"
            $map[$key] = (Get-Date -Date $dt -Format 'yyyy-MM-dd HH:mm')
        }
    }
    return $map
}

function Set-SuLastUsedCell {
    <# 安全写入 LastUsed：旧缓存/外部行可能没有该属性（JSON 反序列化对象直接赋值新属性不可靠，走 Add-Member） #>
    param([object]$Row, [string]$Text)
    if (-not $Row.PSObject.Properties['LastUsed']) {
        $Row | Add-Member -NotePropertyName LastUsed -NotePropertyValue $Text
        return
    }
    $Row.LastUsed = $Text
}

function Get-SuUserAssistEntries {
    <#
      集成：读取 HKCU UserAssist 运行记录（Windows 对「资源管理器/开始菜单/任务栏」启动的程序自动记录）。
      覆盖 {CEBFF5CD...}（可执行文件）与 {F4E57C4B...}（快捷方式）两个键。
      返回带有效时间的条目：{ Path = 解码后的路径或名称; LastRun = [datetime] }
    #>
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
    $guids = @(
        '{CEBFF5CD-ACE2-4F4F-9178-9926F41749EA}',
        '{F4E57C4B-2036-45F0-A9AB-443BCFE33D9F}'
    )
    $now = Get-Date
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $guids) {
        $key = Get-Item -LiteralPath (Join-Path $root "$g\Count") -ErrorAction SilentlyContinue
        if (-not $key) { continue }
        foreach ($vn in $key.GetValueNames()) {
            $path = ConvertFrom-SuRot13 -Text ("$vn".TrimEnd([char]0))
            if (-not $path) { continue }
            $data = $key.GetValue($vn)
            if ($data -isnot [byte[]]) { continue }
            $run = Get-SuUserAssistLastRun -Data $data -Now $now
            if ($run) { $out.Add([pscustomobject]@{ Path = $path; LastRun = $run }) }
        }
    }
    return $out
}

# ============================================================ 纯逻辑：MSIX 版本解析 + 中英别名

function Get-SuVersionFromMsixId {
    <# MSIX 包的版本内嵌在 Id 全名中：MSIX\<Name>_<版本>_<架构>__<发布者哈希>。
       取第一个「纯数字点分段」的 token 作为版本；包名含数字段（如 UI.Xaml.2.8）不会误取。 #>
    param([string]$Id)
    if (-not $Id -or -not $Id.StartsWith('MSIX\')) { return $null }
    foreach ($token in ($Id.Substring(5) -split '_')) {
        if ($token -match '^\d+(\.\d+)+$') { return $token }
    }
    return $null
}

$script:SuNameAliases = @{
    '微信'     = 'WeChat'
    '飞书'     = 'Feishu'
    '腾讯会议' = 'Tencent Meeting'
    '扣子'     = 'Coze'
}

function Get-SuAliasKeys {
    <# 返回名称的规范化匹配键集合：自身 + 已知中英别名 #>
    param([string]$Name)
    $keys = [System.Collections.Generic.List[string]]::new()
    $n = ConvertTo-SuNormalizedKey -Text $Name
    if ($n) { $keys.Add($n) }
    foreach ($k in $script:SuNameAliases.Keys) {
        if ((ConvertTo-SuNormalizedKey -Text $k) -eq $n) { $keys.Add((ConvertTo-SuNormalizedKey -Text $script:SuNameAliases[$k])) }
    }
    return $keys
}

# ============================================================ 集成：发现 winget / 枚举

function Find-SuWinget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    return $null
}

function Get-SuFolderCandidates {
    <# 扫描目录的顶层子目录，找主 exe（最大的根目录 exe）读版本号 #>
    param([string[]]$ScanPaths)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $ScanPaths) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $exes = @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.exe' -ErrorAction SilentlyContinue)
            if ($exes.Count -eq 0) { continue }
            $main = $exes | Sort-Object Length -Descending | Select-Object -First 1
            $ver = ''; $prodName = ''
            try {
                $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($main.FullName)
                $ver = if ($vi.ProductVersion) { [string]$vi.ProductVersion } elseif ($vi.FileVersion) { [string]$vi.FileVersion } else { '' }
                $prodName = if ($vi.ProductName) { [string]$vi.ProductName } else { '' }
            } catch { $ver = ''; $prodName = '' }
            $list.Add([pscustomobject]@{ FullPath = $dir.FullName; ExeVersion = $ver; ProductName = $prodName })
        }
    }
    return $list
}

function Get-PropSafe { param($Obj, [string]$Name)
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-SuRegistrySoftware {
    <# 读取注册表卸载项（HKLM 64/32 + HKCU），跳过系统组件，按 DisplayName 去重 #>
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $seen = @{}
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $name = Get-PropSafe $p 'DisplayName'
            if ([string]::IsNullOrWhiteSpace("$name")) { continue }
            if ((Get-PropSafe $p 'SystemComponent') -eq 1) { continue }
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            $dir = Get-SuInstallDirFromUninstallEntry `
                -InstallLocation "$(Get-PropSafe $p 'InstallLocation')" `
                -DisplayIcon   "$(Get-PropSafe $p 'DisplayIcon')" `
                -UninstallString "$(Get-PropSafe $p 'UninstallString')"
            $out.Add([pscustomobject]@{
                Name       = [string]$name
                Version    = "$(Get-PropSafe $p 'DisplayVersion')"
                InstallDir = $dir
                ExeHint    = Get-SuExeNameFromUninstallEntry `
                    -DisplayIcon   "$(Get-PropSafe $p 'DisplayIcon')" `
                    -UninstallString "$(Get-PropSafe $p 'UninstallString')"
            })
        }
    }
    return $out
}

function Get-SuWingetCatalog {
    <# 枚举 winget 包：优先 Microsoft.WinGet.Client 模块（结构化），否则降级文本解析 #>
    param([scriptblock]$OnLog = {})

    $winget = Find-SuWinget
    if (-not $winget) { & $OnLog '错误: 未找到 winget.exe（App Installer 未安装？）'; return @() }

    $mod = Get-Module -ListAvailable Microsoft.WinGet.Client | Select-Object -First 1
    if ($mod) {
        try {
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            $pkgs = @(Get-WinGetPackage -ErrorAction Stop)
            $out = [System.Collections.Generic.List[object]]::new()
            foreach ($p in $pkgs) {
                $avail = ''
                if ($p.AvailableVersions -and @($p.AvailableVersions).Count -gt 0) { $avail = [string]$p.AvailableVersions[0] }
                $out.Add([pscustomobject]@{
                    Name      = [string]$p.Name
                    Id        = [string]$p.Id
                    Version   = [string]$p.Version
                    Available = $avail
                    Source    = [string]$p.Source
                })
            }
            & $OnLog ("winget 客户端模块枚举完成: {0} 个包" -f $out.Count)
            return $out
        } catch {
            & $OnLog "Microsoft.WinGet.Client 枚举失败，降级文本解析: $($_.Exception.Message)"
        }
    } else {
        & $OnLog 'Microsoft.WinGet.Client 模块未安装，使用 winget 文本解析（可用 Install-Module Microsoft.WinGet.Client -Scope CurrentUser 获得更稳的枚举）'
    }

    $prev = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try {
        $text = (& $winget list --disable-interactivity --accept-source-agreements 2>&1 | Out-String -Width 4096)
    } finally { try { [Console]::OutputEncoding = $prev } catch {} }
    $parsed = @(ConvertFrom-SuWingetOutput -OutputText $text)
    & $OnLog ("winget 文本解析完成: {0} 个包" -f $parsed.Count)
    return $parsed
}

# ============================================================ 集成：配置 / 日志 / 状态

function Get-SuConfig {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $script:SuRoot 'config.json' }
    $defaults = @{
        scanPaths  = @('D:\software')
        exclusions = @()
        schedule   = @{ enabled = $false; time = '12:30' }
        portable   = @{ checkHours = 24; downloadDir = '' }
        cache      = @{ maxAgeHours = 6 }
    }
    if (Test-Path -LiteralPath $Path) {
        try {
            $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            if ($json -is [hashtable]) {
                if ($json['scanPaths'])  { $defaults.scanPaths  = @($json['scanPaths']) }
                if ($null -ne $json['exclusions']) { $defaults.exclusions = @($json['exclusions']) }
                if ($json['schedule'] -is [hashtable]) {
                    if ($null -ne $json['schedule']['enabled']) { $defaults.schedule.enabled = [bool]$json['schedule']['enabled'] }
                    if ($json['schedule']['time']) { $defaults.schedule.time = [string]$json['schedule']['time'] }
                }
                if ($json['portable'] -is [hashtable]) {
                    if ($json['portable']['checkHours']) { $defaults.portable.checkHours = [int]$json['portable']['checkHours'] }
                    if ($null -ne $json['portable']['downloadDir']) { $defaults.portable.downloadDir = [string]$json['portable']['downloadDir'] }
                }
                if ($json['cache'] -is [hashtable]) {
                    if ($json['cache']['maxAgeHours']) { $defaults.cache.maxAgeHours = [int]$json['cache']['maxAgeHours'] }
                }
            }
        } catch {
            Write-SuLog "配置文件解析失败，使用默认配置: $($_.Exception.Message)"
        }
    }
    return $defaults
}

function Save-SuConfig {
    param([hashtable]$Config, [string]$Path)
    if (-not $Path) { $Path = Join-Path $script:SuRoot 'config.json' }
    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-SuLog {
    param([string]$Message, [string]$LogDir)
    if (-not $LogDir) { $LogDir = Join-Path $script:SuRoot 'logs' }
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $file = Join-Path $LogDir ("{0:yyyy-MM-dd}.log" -f (Get-Date))
        Add-Content -LiteralPath $file -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message) -Encoding UTF8
    } catch {}
}

function Remove-SuOldLogs {
    <# 清理超过保留期的按天日志（yyyy-MM-dd.log），返回删除数量。挂在每次枚举开头自动滚动清理。 #>
    param([int]$RetentionDays = 30, [string]$LogDir, [datetime]$Now = (Get-Date))
    if ($RetentionDays -le 0) { return 0 }
    if (-not $LogDir) { $LogDir = Join-Path $script:SuRoot 'logs' }
    $count = 0
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { return 0 }
        $cutoff = $Now.AddDays(-$RetentionDays)
        foreach ($f in (Get-ChildItem -LiteralPath $LogDir -File -Filter '*.log' -ErrorAction SilentlyContinue)) {
            $d = $null
            if ($f.Name -match '^(\d{4}-\d{2}-\d{2})\.log$') { $d = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) }
            if ($d -and $d -lt $cutoff) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $f.FullName)) { $count++ }
            }
        }
    } catch {}
    return $count
}

function Get-SuState {
    param([string]$StatePath)
    if (-not $StatePath) { $StatePath = Join-Path $script:SuRoot 'state.json' }
    if (Test-Path -LiteralPath $StatePath) {
        try { return (Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable) } catch {}
    }
    return @{}
}

function Update-SuState {
    param([string]$StatePath, [hashtable]$Data)
    if (-not $StatePath) { $StatePath = Join-Path $script:SuRoot 'state.json' }
    $state = Get-SuState -StatePath $StatePath
    foreach ($k in $Data.Keys) { $state[$k] = $Data[$k] }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

# ============================================================ 集成：更新历史

function Get-SuHistoryPath {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $script:SuRoot 'history.json' }
    return $Path
}

function Get-SuHistory {
    <# 读取更新历史（最多 200 条），文件缺失/损坏返回空数组 #>
    param([string]$Path)
    $p = Get-SuHistoryPath -Path $Path
    if (Test-Path -LiteralPath $p) {
        try {
            $v = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $v) { return @($v) }
        } catch { Write-SuLog "更新历史解析失败，按空历史处理: $($_.Exception.Message)" }
    }
    return @()
}

function Add-SuHistoryEntry {
    <# 追加一条更新历史（自动裁剪到 200 条，保留最新） #>
    param([string]$Path, [string]$Name, [string]$Id, [string]$FromVersion, [string]$ToVersion, [string]$Result)
    $p = Get-SuHistoryPath -Path $Path
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($e in (Get-SuHistory -Path $Path)) { $list.Add($e) }
    $list.Add([pscustomobject]@{
        Time        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Name        = "$Name"
        Id          = "$Id"
        FromVersion = "$FromVersion"
        ToVersion   = "$ToVersion"
        Result      = "$Result"
    })
    while ($list.Count -gt 200) { $list.RemoveAt(0) }
    try { ConvertTo-Json -InputObject @($list.ToArray()) -Depth 5 | Set-Content -LiteralPath $p -Encoding UTF8 } catch {}
}

# ============================================================ 集成：完整枚举管线

function Get-SuInstalledSoftware {
    param([hashtable]$Config, [scriptblock]$OnLog = {})
    $pruned = Remove-SuOldLogs -RetentionDays 30
    if ($pruned -gt 0) { & $OnLog "已清理 $pruned 个超期日志文件（保留 30 天）" }
    $swAll = [System.Diagnostics.Stopwatch]::StartNew()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $wingetPkgs = Get-SuWingetCatalog -OnLog $OnLog
    $tWinget = $sw.Elapsed.TotalSeconds; $sw.Restart()
    & $OnLog '读取注册表卸载信息...'
    $reg = Get-SuRegistrySoftware
    $tReg = $sw.Elapsed.TotalSeconds; $sw.Restart()
    & $OnLog '扫描安装目录...'
    $dirs = Get-SuFolderCandidates -ScanPaths $Config.scanPaths
    $tDirs = $sw.Elapsed.TotalSeconds; $sw.Restart()
    $rows = Merge-SuSoftwareList -WingetPackages $wingetPkgs -RegistryEntries $reg -Directories $dirs -ScanPaths $Config.scanPaths
    $tMerge = $sw.Elapsed.TotalSeconds; $sw.Restart()
    & $OnLog ("合并完成: 共 {0} 个软件" -f @($rows).Count)
    & $OnLog '读取最近使用记录（UserAssist）...'
    $tLu = 0.0
    try {
        $ua = @(Get-SuUserAssistEntries)
        $matched = Update-SuRowsLastUsed -Rows @($rows) -Entries $ua
        $tLu = $sw.Elapsed.TotalSeconds
        & $OnLog ("最近使用: {0} 条运行记录, 匹配 {1} 个软件" -f $ua.Count, $matched)
    } catch {
        $tLu = $sw.Elapsed.TotalSeconds
        & $OnLog "读取最近使用记录失败（不影响列表）: $($_.Exception.Message)"
    }
    $swAll.Stop()
    & $OnLog ("阶段耗时: winget={0:N1}s 注册表={1:N1}s 目录={2:N1}s 合并={3:N1}s 最近使用={4:N1}s 总计={5:N1}s" -f `
        $tWinget, $tReg, $tDirs, $tMerge, $tLu, $swAll.Elapsed.TotalSeconds)
    return $rows
}

# ============================================================ 集成：升级执行

function Invoke-SuUpgrade {
    param([string]$Id, [string]$Name, [scriptblock]$OnOutput = {})
    $winget = Find-SuWinget
    if (-not $winget) { & $OnOutput '错误: 未找到 winget.exe，无法升级'; return -1 }

    $argList = @('upgrade', '--id', $Id, '--exact', '--silent', '--disable-interactivity',
                 '--accept-package-agreements', '--accept-source-agreements')
    & $OnOutput (">> 开始更新: $Name [$Id]")

    $prev = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try {
        & $winget @argList 2>&1 | ForEach-Object {
            $line = ("$_").TrimEnd()
            if ($line) { & $OnOutput $line }
        }
    } finally { try { [Console]::OutputEncoding = $prev } catch {} }

    $code = $LASTEXITCODE
    & $OnOutput (">> 更新结束: $Name 退出码 $code")
    return $code
}

function Resolve-SuRowUpdates {
    <#
      升级后目标行校正：用注册表（权威来源）重新取这些行的当前版本，
      返回 {Name,Id,Version,HasUpdate,Status} 快照列表——由 UI 经队列在主线程应用，避免跨线程改 WPF 对象。
      仅处理有 Id 的 winget 行（便携/系统行不参与 winget 升级）；注册表为空时返回空结果（不误改）。
    #>
    param([object[]]$Targets = @(), [object[]]$RegistryEntries = @())
    $out = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Targets -or @($Targets).Count -eq 0) { return $out }
    if ($null -eq $RegistryEntries -or @($RegistryEntries).Count -eq 0) { return $out }
    foreach ($t in @($Targets)) {
        if ($null -eq $t) { continue }
        if (-not "$($t.Id)") { continue }
        $hit = $null
        foreach ($reg in $RegistryEntries) {
            if (Test-SuNameMatch -A "$($t.Name)" -B "$($reg.Name)") { $hit = $reg; break }
        }
        $version = if ($hit -and "$($hit.Version)") { "$($hit.Version)" } else { "$($t.Version)" }
        $hasUpdate = ($t.Available -and $version -and (Compare-SuVersion -A "$($t.Available)" -B $version) -gt 0)
        $status = if (-not $version) { '版本未知' } elseif ($hasUpdate) { '有更新' } else { '最新' }
        $out.Add([pscustomobject]@{
            Name      = "$($t.Name)"
            Id        = "$($t.Id)"
            Version   = $version
            HasUpdate = [bool]$hasUpdate
            Status    = $status
        })
    }
    return $out
}

function Invoke-SuUpgradeBatch {
    param(
        [object[]]$Rows,
        [string[]]$Exclusions = @(),
        [scriptblock]$OnOutput = {},
        [scriptblock]$OnRowStatus = {}
    )
    $ok = 0; $fail = 0; $skip = 0
    foreach ($r in $Rows) {
        if (-not $r.Id) { $skip++; & $OnRowStatus $r '跳过(无winget Id)'; continue }
        if (Test-SuExcluded -Name $r.Name -Id $r.Id -Patterns $Exclusions) { $skip++; & $OnRowStatus $r '跳过(排除名单)'; continue }
        & $OnRowStatus $r '更新中...'
        $fromVersion = "$($r.Version)"
        $code = Invoke-SuUpgrade -Id $r.Id -Name $r.Name -OnOutput $OnOutput
        if ($code -eq 0) {
            $ok++;  & $OnRowStatus $r '成功'
            Add-SuHistoryEntry -Name $r.Name -Id $r.Id -FromVersion $fromVersion -ToVersion "$($r.Available)" -Result '成功'
        }
        else {
            $fail++; & $OnRowStatus $r "失败(退出码 $code)"
            Add-SuHistoryEntry -Name $r.Name -Id $r.Id -FromVersion $fromVersion -ToVersion "$($r.Available)" -Result "失败(退出码 $code)"
        }
    }
    return [pscustomobject]@{ Ok = $ok; Fail = $fail; Skip = $skip }
}

# ============================================================ 集成：便携软件更新源库

function Test-SuCatalogMatch {
    <# 目录候选打分：过滤 msstore 候选（无点 Id / Unknown 版本）；规范化相等 → exact；Test-SuNameMatch 唯一命中 → fuzzy；否则 none #>
    param([object[]]$Candidates = @(), [string]$ProductName, [string]$FolderName)
    if ($null -eq $Candidates) { $Candidates = @() }
    $Candidates = @($Candidates | Where-Object { "$($_.Id)" -match '\.' -and "$($_.Version)" -ne 'Unknown' })
    $needles = @($ProductName, $FolderName) | Where-Object { $_ -and $_.Trim() }

    foreach ($n in $needles) {
        $kn = ConvertTo-SuNormalizedKey -Text $n
        if (-not $kn) { continue }
        foreach ($c in $Candidates) {
            if ((ConvertTo-SuNormalizedKey -Text $c.Name) -eq $kn) {
                return [pscustomobject]@{ Candidate = $c; Confidence = 'exact' }
            }
        }
    }
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $needles) {
        foreach ($c in $Candidates) {
            if (Test-SuNameMatch -A $c.Name -B $n) { $hits.Add($c) }
        }
    }
    $uniqIds = @($hits | ForEach-Object { $_.Id } | Sort-Object -Unique)
    if ($uniqIds.Count -eq 1) { return [pscustomobject]@{ Candidate = $hits[0]; Confidence = 'fuzzy' } }
    return [pscustomobject]@{ Candidate = $null; Confidence = 'none' }
}

function ConvertFrom-SuWingetShowOutput {
    <# 解析 `winget show` 输出：版本 + 安装程序 URL（兼容中英文与全角冒号） #>
    param([string]$OutputText)
    $res = [pscustomobject]@{ Version = ''; InstallerUrl = '' }
    if ([string]::IsNullOrWhiteSpace($OutputText)) { return $res }
    foreach ($line in ($OutputText -split "`r?`n")) {
        if (-not $res.Version -and $line -match '^\s*(版本|Version)\s*[：:]\s*(.+?)\s*$') { $res.Version = $Matches[2] }
        if (-not $res.InstallerUrl -and $line -match '^\s*(安装程序|Installer)\s*(URL|Url|网址)\s*[：:]\s*(.+?)\s*$') { $res.InstallerUrl = $Matches[3] }
    }
    return $res
}

function Get-SuPortableDb {
    <# 读取便携软件更新源库（update-sources.json），文件缺失/损坏时返回空库 #>
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $script:SuRoot 'update-sources.json' }
    if (Test-Path -LiteralPath $Path) {
        try {
            $v = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $v) { return @($v) }
        } catch { Write-SuLog "便携源库解析失败，按空库处理: $($_.Exception.Message)" }
    }
    return @()
}

function Save-SuPortableDb {
    param([object[]]$Db = @(), [string]$Path)
    if (-not $Path) { $Path = Join-Path $script:SuRoot 'update-sources.json' }
    @($Db) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-SuSourceStale {
    param([string]$LastChecked, [int]$Hours = 24)
    if ([string]::IsNullOrWhiteSpace("$LastChecked")) { return $true }
    try { return ((Get-Date) - [datetime]::Parse($LastChecked)).TotalHours -ge $Hours } catch { return $true }
}

function Get-SuDownloadFileName {
    param([string]$Uri)
    try { $u = [uri]$Uri; $name = [System.IO.Path]::GetFileName($u.AbsolutePath); if ($name) { return $name } } catch {}
    return $null
}

function Merge-SuPortableSourceInfo {
    <# 把更新源库中的最新版本/下载页合并进便携行（按 Folder 大小写不敏感匹配） #>
    param([object[]]$Rows, [object[]]$Db = @())
    if ($null -eq $Db) { $Db = @() }
    foreach ($r in $Rows) {
        if ($r.Catalog -ne '便携') { continue }
        $entry = $null
        foreach ($e in $Db) {
            if ($e.Folder -and $r.Location -and ($e.Folder.TrimEnd('\') -ieq $r.Location.TrimEnd('\'))) { $entry = $e; break }
        }
        if (-not $entry -or -not $entry.WingetId -or [string]::IsNullOrWhiteSpace("$($entry.LatestVersion)")) { continue }
        if (-not $r.PSObject.Properties['DownloadPage']) { $r | Add-Member -NotePropertyName DownloadPage -NotePropertyValue '' }
        $r.DownloadPage = "$($entry.DownloadPage)"
        $r.Available = "$($entry.LatestVersion)"
        $r.HasUpdate = (Compare-SuVersion -A $r.Available -B $r.Version) -gt 0
        $r.Status = if ($r.HasUpdate) { '有更新(便携)' } else { '最新(便携)' }
    }
    return $Rows
}

function Find-SuWingetCatalogEntry {
    <# 在 winget 目录中为便携软件找更新源（优先 exe ProductName，其次目录名） #>
    param([string]$ProductName, [string]$FolderName, [scriptblock]$OnLog = {})
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        $searchName = if ($ProductName -and $ProductName.Trim()) { $ProductName } else { $FolderName }
        if (-not $searchName) { return [pscustomobject]@{ Candidate = $null; Confidence = 'none' } }
        $cands = @(Find-WinGetPackage -Name $searchName -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Id = [string]$_.Id; Version = "$($_.Version)" }
        })
        return Test-SuCatalogMatch -Candidates $cands -ProductName $ProductName -FolderName $FolderName
    } catch {
        & $OnLog "winget 目录查询失败: $($_.Exception.Message)"
        return [pscustomobject]@{ Candidate = $null; Confidence = 'none' }
    }
}

function Find-SuWingetCatalogEntryById {
    param([string]$Id, [scriptblock]$OnLog = {})
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        $r = @(Find-WinGetPackage -Id $Id -MatchOption Equals -ErrorAction Stop)
        if ($r.Count -gt 0 -and "$($r[0].Version)" -ne 'Unknown') {
            return [pscustomobject]@{ Id = [string]$r[0].Id; LatestVersion = "$($r[0].Version)" }
        }
    } catch { & $OnLog "winget 目录按 Id 查询失败 ($Id): $($_.Exception.Message)" }
    return $null
}

function Get-SuWingetPackageDetail {
    <# `winget show` → 版本 + 安装程序 URL #>
    param([string]$Id, [scriptblock]$OnLog = {})
    $winget = Find-SuWinget
    if (-not $winget) { return $null }
    $prev = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try {
        $text = (& $winget show $Id --exact --disable-interactivity --accept-source-agreements 2>&1 | Out-String -Width 4096)
    } finally { try { [Console]::OutputEncoding = $prev } catch {} }
    return ConvertFrom-SuWingetShowOutput -OutputText $text
}

function Update-SuPortableDbLearning {
    <# 学习管线：为每个便携行在 winget 目录中找更新源，边学边存（中断不丢） #>
    param([object[]]$Rows, [object[]]$Db = @(), [string]$DbPath, [scriptblock]$OnLog = {})
    if ($null -eq $Db) { $Db = @() }
    $dbList = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Db) { $dbList.Add($e) }
    $portable = @($Rows | Where-Object { $_.Catalog -eq '便携' -and $_.Location })
    & $OnLog ("便携软件共 {0} 个，开始学习更新源（逐个查 winget 目录，首次较慢）..." -f $portable.Count)
    $i = 0
    foreach ($r in $portable) {
        $i++
        $existing = $null
        foreach ($e in $dbList) { if ($e.Folder -and $r.Location -and ($e.Folder.TrimEnd('\') -ieq $r.Location.TrimEnd('\'))) { $existing = $e; break } }
        if ($existing -and $existing.WingetId -and "$($existing.State)" -in @('auto', 'fuzzy') -and "$($existing.WingetId)" -match '\.') {
            & $OnLog ("[{0}/{1}] {2} 已有源 {3}，跳过" -f $i, $portable.Count, $r.Name, $existing.WingetId)
            continue
        }
        $m = Find-SuWingetCatalogEntry -ProductName "$($r.ProductName)" -FolderName (Split-Path -Leaf $r.Location) -OnLog $OnLog
        $id = ''; $ver = ''; $state = '未匹配'; $page = ''
        if ($m.Confidence -ne 'none' -and $m.Candidate) {
            $id = $m.Candidate.Id; $ver = $m.Candidate.Version; $state = $m.Confidence
            $page = "https://winstall.app/apps/$id"
            & $OnLog ("[{0}/{1}] {2} → {3}（{4}，目录最新 {5}）" -f $i, $portable.Count, $r.Name, $id, $state, $ver)
        } else {
            & $OnLog ("[{0}/{1}] {2} 未匹配 → 可在 update-sources.json 手工补充" -f $i, $portable.Count, $r.Name)
        }
        if ($existing) {
            $existing.WingetId = $id; $existing.LatestVersion = $ver; $existing.State = $state
            $existing.DownloadPage = $page; $existing.LastChecked = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        } else {
            $dbList.Add([pscustomobject]@{
                Name = "$($r.Name)"; Folder = "$($r.Location)"; WingetId = $id; LatestVersion = $ver
                LocalVersion = "$($r.Version)"; DownloadPage = $page; InstallerUrl = ''
                LastChecked = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); State = $state
            })
        }
        Save-SuPortableDb -Db $dbList -Path $DbPath
    }
    & $OnLog ("学习完成: 库共 {0} 条" -f $dbList.Count)
    return $dbList
}

function Get-SuGithubRepoFromUrl {
    <# 从 GitHub 安装包/发布页地址推导 owner/repo；非 GitHub → null #>
    param([string]$Url)
    if (-not $Url) { return $null }
    $m = [regex]::Match($Url, '(?i)github\.com/([^/\s]+)/([^/\s/#\?]+)')
    if (-not $m.Success) { return $null }
    $repo = "$($m.Groups[2].Value)".TrimEnd('/')
    if (-not $repo -or $repo -ieq 'releases' -or $repo -ieq 'blob' -or $repo -ieq 'tree') { return $null }
    return "$($m.Groups[1].Value)/$repo"
}

function ConvertFrom-SuGithubRelease {
    <# 解析 GitHub releases/latest 的 JSON：tag 去 v 前缀为版本；资产优先 x64 的 .exe/.msi #>
    param([string]$JsonText)
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return $null }
    try { $j = $JsonText | ConvertFrom-Json } catch { return $null }
    if (-not $j -or [string]::IsNullOrWhiteSpace("$($j.tag_name)")) { return $null }
    $tag = "$($j.tag_name)"
    $ver = $tag -replace '^[vV]', ''
    $assetUrl = ''
    $assets = @($j.assets)
    if ($assets.Count -gt 0) {
        $pick = $null
        foreach ($a in $assets) { if ("$($a.name)" -match '(?i)x64|x86_64|win64' -and "$($a.name)" -match '(?i)\.(exe|msi)$') { $pick = $a; break } }
        if (-not $pick) { foreach ($a in $assets) { if ("$($a.name)" -match '(?i)\.(exe|msi)$') { $pick = $a; break } } }
        if (-not $pick) { $pick = $assets[0] }
        $assetUrl = "$($pick.browser_download_url)"
    }
    return [pscustomobject]@{ Tag = $tag; Version = $ver; HtmlUrl = "$($j.html_url)"; AssetUrl = $assetUrl }
}

function Get-SuGithubLatestRelease {
    <# 查询仓库最新 Release（未认证 API，60 次/时限流；调用方有 TTL 限制） #>
    param([string]$Repo, [scriptblock]$OnLog = {})
    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('SoftUpdater/1.0')
        $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
        try {
            $text = $client.GetStringAsync("https://api.github.com/repos/$Repo/releases/latest").GetAwaiter().GetResult()
        } finally { $client.Dispose() }
        return ConvertFrom-SuGithubRelease -JsonText $text
    } catch {
        & $OnLog "GitHub 查询失败 ($Repo): $($_.Exception.Message)"
        return $null
    }
}

function Invoke-SuPortableCheck {
    <# 检测管线：对库中过期条目查最新版——有 GithubRepo 的走 GitHub Release，否则按 winget Id；发现更新时取安装包地址并标记待下载 #>
    param([object[]]$Rows, [object[]]$Db = @(), [int]$StaleHours = 24, [switch]$Force, [string]$DbPath, [scriptblock]$OnLog = {})
    if ($null -eq $Db) { $Db = @() }
    $checked = 0
    foreach ($e in $Db) {
        # GitHub 源：显式 GithubRepo 字段，或从已知 github.com 安装包地址自动推导
        $repo = "$(Get-PropSafe $e 'GithubRepo')"
        if (-not $repo -and $e.InstallerUrl) { $repo = Get-SuGithubRepoFromUrl -Url "$($e.InstallerUrl)" }
        if ($repo) {
            if (-not $Force -and -not (Test-SuSourceStale -LastChecked "$($e.LastChecked)" -Hours $StaleHours)) { continue }
            $row = $null
            foreach ($r in $Rows) { if ($r.Location -and $e.Folder -and ($r.Location.TrimEnd('\') -ieq $e.Folder.TrimEnd('\'))) { $row = $r; break } }
            if (-not $row) { continue }
            $checked++
            & $OnLog ("检测便携更新(GitHub): {0} [{1}]" -f $e.Name, $repo)
            $rel = Get-SuGithubLatestRelease -Repo $repo -OnLog $OnLog
            if (-not $rel) { continue }
            if (-not "$($e.GithubRepo)") { $e | Add-Member -NotePropertyName GithubRepo -NotePropertyValue $repo -Force }
            $e.LatestVersion = $rel.Version
            $e.LastChecked = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            # JSON 反序列化的 PSCustomObject 不能直接赋值新属性，必须 Add-Member -Force
            $e | Add-Member -NotePropertyName PendingDownload -NotePropertyValue $false -Force
            if ("$($row.Version)") { $e.LocalVersion = "$($row.Version)" }
            if ($rel.Version -and "$($e.LocalVersion)" -and ((Compare-SuVersion -A $rel.Version -B "$($e.LocalVersion)") -gt 0)) {
                if ($rel.AssetUrl) { $e.InstallerUrl = $rel.AssetUrl; $e.PendingDownload = $true }
                if ($rel.HtmlUrl) { $e | Add-Member -NotePropertyName DownloadPage -NotePropertyValue "$($rel.HtmlUrl)" -Force }
                & $OnLog ("便携更新: {0}  {1} → {2}" -f $e.Name, $e.LocalVersion, $rel.Version)
            }
            Save-SuPortableDb -Db $Db -Path $DbPath
            continue
        }
        if (-not $e.WingetId) { continue }
        if (-not $Force -and -not (Test-SuSourceStale -LastChecked "$($e.LastChecked)" -Hours $StaleHours)) { continue }
        $row = $null
        foreach ($r in $Rows) { if ($r.Location -and $e.Folder -and ($r.Location.TrimEnd('\') -ieq $e.Folder.TrimEnd('\'))) { $row = $r; break } }
        if (-not $row) { continue }
        $checked++
        & $OnLog ("检测便携更新: {0} [{1}]" -f $e.Name, $e.WingetId)
        $r2 = Find-SuWingetCatalogEntryById -Id $e.WingetId -OnLog $OnLog
        if (-not $r2) { continue }
        $e.LatestVersion = $r2.LatestVersion
        $e.LastChecked = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        # JSON 反序列化的 PSCustomObject 不能直接赋值新属性，必须 Add-Member -Force
        $e | Add-Member -NotePropertyName PendingDownload -NotePropertyValue $false -Force
        if ("$($row.Version)") { $e.LocalVersion = "$($row.Version)" }
        if ($e.LatestVersion -and $e.LocalVersion -and ((Compare-SuVersion -A $e.LatestVersion -B $e.LocalVersion) -gt 0)) {
            $detail = Get-SuWingetPackageDetail -Id $e.WingetId -OnLog $OnLog
            if ($detail -and $detail.InstallerUrl) { $e.InstallerUrl = $detail.InstallerUrl; $e.PendingDownload = $true }
            & $OnLog ("便携更新: {0}  {1} → {2}" -f $e.Name, $e.LocalVersion, $e.LatestVersion)
        }
        Save-SuPortableDb -Db $Db -Path $DbPath
    }
    if ($checked -gt 0) { & $OnLog ("便携更新检测完成: 本次检测 {0} 条" -f $checked) }
    return $Db
}

function Invoke-SuPortableDownload {
    <# 下载单个便携软件的安装包到下载目录。
       HttpClient 流式下载，通过 -OnProgress received/total/destPath 实时回报进度（约每 250ms 一次）；
       先写 .part 临时文件，完成后原子改名，避免留下半截文件。 #>
    param([object]$Entry, [string]$DownloadDir, [scriptblock]$OnLog = {}, [scriptblock]$OnProgress = {})
    if (-not $Entry -or -not $Entry.InstallerUrl) { return $null }
    if (-not $DownloadDir) { $DownloadDir = Join-Path $env:USERPROFILE 'Downloads' }
    $dest = $null
    try {
        if (-not (Test-Path -LiteralPath $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null }
        $name = Get-SuDownloadFileName -Uri $Entry.InstallerUrl
        if (-not $name) { $name = ("{0}-{1}.bin" -f $Entry.Name, (Get-Date -Format 'yyyyMMddHHmmss')) }
        $dest = Join-Path $DownloadDir $name
        $partFile = "$dest.part"
        & $OnLog "下载安装包: $($Entry.InstallerUrl)"

        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(120)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('SoftUpdater/1.0')
        $resp = $client.GetAsync($Entry.InstallerUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            $httpCode = [int]$resp.StatusCode
            throw "HTTP $httpCode"
        }
        $total = $resp.Content.Headers.ContentLength
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fs = [System.IO.File]::Create($partFile)
        $buffer = New-Object byte[] (64KB)
        $received = [long]0
        $lastReport = Get-Date
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fs.Write($buffer, 0, $read)
                $received += $read
                if (((Get-Date) - $lastReport).TotalMilliseconds -ge 250) {
                    $lastReport = Get-Date
                    & $OnProgress $received $total $dest
                }
            }
        } finally {
            $fs.Dispose(); $stream.Dispose(); $client.Dispose()
        }
        Move-Item -LiteralPath $partFile -Destination $dest -Force
        $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { $received / 1MB / $sw.Elapsed.TotalSeconds } else { 0 }
        $totalText = if ($total) { "{0:N1} MB" -f ($total / 1MB) } else { "{0:N1} MB" -f ($received / 1MB) }
        & $OnLog ("已下载: {0}（{1}，平均 {2:N2} MB/s）" -f $dest, $totalText, $speed)
        & $OnProgress $received $total $dest
        return $dest
    } catch {
        if ($dest -and (Test-Path -LiteralPath "$dest.part")) { Remove-Item -LiteralPath "$dest.part" -Force -ErrorAction SilentlyContinue }
        & $OnLog "下载失败 ($($Entry.Name)): $($_.Exception.Message)"
        return $null
    }
}

# ============================================================ 集成：行缓存

function Get-SuRowCachePath {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $script:SuRoot 'cache-rows.json' }
    return $Path
}

function Save-SuRowCache {
    <# 保存最终合并后的软件行快照（含数据时间） #>
    param([object[]]$Rows = @(), [string]$Path)
    $payload = @{ savedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); rows = @($Rows) }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-SuRowCachePath -Path $Path) -Encoding UTF8
}

function Get-SuRowCache {
    <# 读取行缓存：返回 {SavedAt, Rows}；文件缺失/损坏返回 null #>
    param([string]$Path)
    $p = Get-SuRowCachePath -Path $Path
    if (Test-Path -LiteralPath $p) {
        try {
            $v = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $v -and $null -ne $v.rows) {
                return [pscustomobject]@{ SavedAt = [string]$v.savedAt; Rows = @($v.rows) }
            }
        } catch { Write-SuLog "行缓存解析失败，忽略: $($_.Exception.Message)" }
    }
    return $null
}

function Test-SuCacheFresh {
    param([string]$SavedAt, [int]$MaxAgeHours = 6)
    if ([string]::IsNullOrWhiteSpace("$SavedAt")) { return $false }
    try { return ((Get-Date) - [datetime]::Parse($SavedAt)).TotalHours -lt $MaxAgeHours } catch { return $false }
}

# ============================================================ 纯逻辑：状态分类与统计

function Get-SuStatusBucket {
    <# 把一行归入统计桶：update=有更新，ok=最新，unknown=版本未知/无法检测/未识别 #>
    param([bool]$HasUpdate, [string]$Status)
    if ($HasUpdate) { return 'update' }
    if ("$Status" -like '最新*') { return 'ok' }
    return 'unknown'
}

function Get-SuStatusCounts {
    param([object[]]$Rows = @())
    $update = 0; $ok = 0; $unknown = 0
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        switch (Get-SuStatusBucket -HasUpdate ([bool]$r.HasUpdate) -Status "$($r.Status)") {
            'update'  { $update++ }
            'ok'      { $ok++ }
            'unknown' { $unknown++ }
        }
    }
    return [pscustomobject]@{ Total = @($Rows).Count; Update = $update; Ok = $ok; Unknown = $unknown }
}

# ============================================================ 集成：计划任务

function Get-SuScheduledTask {
    param([string]$TaskName = $script:SuTaskName)
    return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Register-SuScheduledTask {
    param([string]$TaskName = $script:SuTaskName, [string]$ScriptPath, [string]$Time = '12:30')
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwshCmd) { throw '未找到 pwsh.exe，无法注册计划任务' }
    $action    = New-ScheduledTaskAction -Execute $pwshCmd.Source `
                 -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -Auto")
    $trigger   = New-ScheduledTaskTrigger -Daily -At $Time
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
                 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-SuLog "已注册计划任务 $TaskName（每天 $Time）"
}

function Unregister-SuScheduledTask {
    param([string]$TaskName = $script:SuTaskName)
    if (Get-SuScheduledTask -TaskName $TaskName) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-SuLog "已移除计划任务 $TaskName"
    }
}

Export-ModuleMember -Function @(
    'ConvertFrom-SuWingetOutput', 'ConvertTo-SuNormalizedKey', 'Test-SuNameMatch', 'Compare-SuVersion',
    'Test-SuExcluded', 'Get-SuInstallDirFromUninstallEntry', 'Merge-SuSoftwareList', 'Get-SuCharWidth',
    'Find-SuWinget', 'Get-SuFolderCandidates', 'Get-SuRegistrySoftware', 'Get-SuWingetCatalog',
    'Get-SuConfig', 'Save-SuConfig', 'Write-SuLog', 'Get-SuState', 'Update-SuState',
    'Get-SuInstalledSoftware', 'Invoke-SuUpgrade', 'Invoke-SuUpgradeBatch',
    'Get-SuScheduledTask', 'Register-SuScheduledTask', 'Unregister-SuScheduledTask',
    'Test-SuCatalogMatch', 'ConvertFrom-SuWingetShowOutput', 'Get-SuPortableDb', 'Save-SuPortableDb',
    'Test-SuSourceStale', 'Get-SuDownloadFileName', 'Merge-SuPortableSourceInfo',
    'Find-SuWingetCatalogEntry', 'Find-SuWingetCatalogEntryById', 'Get-SuWingetPackageDetail',
    'Update-SuPortableDbLearning', 'Invoke-SuPortableCheck', 'Invoke-SuPortableDownload',
    'Save-SuRowCache', 'Get-SuRowCache', 'Test-SuCacheFresh',
    'Get-SuStatusBucket', 'Get-SuStatusCounts', 'Get-SuVersionFromMsixId',
    'ConvertFrom-SuRot13', 'Get-SuUserAssistLastRun', 'Test-SuPathUnder',
    'Update-SuRowsLastUsed', 'Get-SuUserAssistEntries', 'Get-SuLastUsedTextMap',
    'Remove-SuOldLogs', 'Get-SuHistory', 'Add-SuHistoryEntry', 'Resolve-SuRowUpdates',
    'Get-SuGithubRepoFromUrl', 'ConvertFrom-SuGithubRelease', 'Get-SuGithubLatestRelease',
    'Get-SuExeNameFromUninstallEntry'
)
