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

    function New-SuRow { param($Name, $Id, $Version, $Available, $Catalog, $Location, $Status, $ProductName = $null)
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
        }
    }

    function Find-BestWingetMatch { param($RegName, $Packages)
        # 先找规范化相等的，再找包含关系的
        foreach ($wp in $Packages) { if (Test-SuNameMatch -A $wp.Name -B $RegName) { if ((ConvertTo-SuNormalizedKey $wp.Name) -eq (ConvertTo-SuNormalizedKey $RegName)) { return $wp } } }
        foreach ($wp in $Packages) { if (Test-SuNameMatch -A $wp.Name -B $RegName) { return $wp } }
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
        $rows.Add((New-SuRow -Name $wp.Name -Id $wp.Id -Version $wp.Version -Available $wp.Available -Catalog 'winget' -Location '' -Status ''))
    }

    # 2) 注册表：标注位置 / 补充系统行
    $matchedRegNames = [System.Collections.Generic.List[string]]::new()
    foreach ($reg in $RegistryEntries) {
        $wp = Find-BestWingetMatch -RegName $reg.Name -Packages $WingetPackages
        if ($wp) {
            $matchedRegNames.Add($reg.Name)
            if ($reg.InstallDir) {
                foreach ($scanPath in $ScanPaths) {
                    if (Test-PathUnder -Child $reg.InstallDir -Parent $scanPath) {
                        $row = $rows | Where-Object { $_.Id -eq $wp.Id } | Select-Object -First 1
                        if ($row -and -not $row.Location) { $row.Location = $reg.InstallDir }
                        break
                    }
                }
            }
            # 注册表是已安装版本的权威来源：winget COM 对「应用内自更新」的软件可能返回空/过期的本地版本
            if ($reg.Version) {
                $row = $rows | Where-Object { $_.Id -eq $wp.Id } | Select-Object -First 1
                if ($row) {
                    $row.Version = "$($reg.Version)"
                    $row.HasUpdate = ($row.Available -and $row.Version -and ((Compare-SuVersion -A $row.Available -B $row.Version) -gt 0))
                }
            }
        }
        else {
            $matchedRegNames.Add($reg.Name)
            $rows.Add((New-SuRow -Name $reg.Name -Id '' -Version $reg.Version -Available '' -Catalog '系统' -Location "$($reg.InstallDir)" -Status '未识别'))
        }
    }

    # 3) 目录扫描：未覆盖的绿色版
    foreach ($d in $Directories) {
        $covered = $false
        foreach ($reg in $RegistryEntries) {
            if ($reg.InstallDir -and (Test-PathUnder -Child $d.FullPath -Parent $reg.InstallDir -or (Test-PathUnder -Child $reg.InstallDir -Parent $d.FullPath))) { $covered = $true; break }
        }
        if (-not $covered) {
            # 目录名与 winget 行匹配 → 只标注位置
            $hit = $null
            foreach ($wp in $WingetPackages) { if (Test-SuNameMatch -A $wp.Name -B (Split-Path -Leaf $d.FullPath)) { $hit = $wp; break } }
            if ($hit) {
                $row = $rows | Where-Object { $_.Id -eq $hit.Id } | Select-Object -First 1
                if ($row -and -not $row.Location) { $row.Location = $d.FullPath }
            } else {
                $rows.Add((New-SuRow -Name (Split-Path -Leaf $d.FullPath) -Id '' -Version $d.ExeVersion -Available '' -Catalog '便携' -Location $d.FullPath -Status '无法检测更新' -ProductName $d.ProductName))
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

# ============================================================ 集成：完整枚举管线

function Get-SuInstalledSoftware {
    param([hashtable]$Config, [scriptblock]$OnLog = {})
    $wingetPkgs = Get-SuWingetCatalog -OnLog $OnLog
    & $OnLog '读取注册表卸载信息...'
    $reg = Get-SuRegistrySoftware
    & $OnLog '扫描安装目录...'
    $dirs = Get-SuFolderCandidates -ScanPaths $Config.scanPaths
    $rows = Merge-SuSoftwareList -WingetPackages $wingetPkgs -RegistryEntries $reg -Directories $dirs -ScanPaths $Config.scanPaths
    & $OnLog ("合并完成: 共 {0} 个软件" -f @($rows).Count)
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
        $code = Invoke-SuUpgrade -Id $r.Id -Name $r.Name -OnOutput $OnOutput
        if ($code -eq 0) { $ok++;  & $OnRowStatus $r '成功' }
        else             { $fail++; & $OnRowStatus $r "失败(退出码 $code)" }
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

function Invoke-SuPortableCheck {
    <# 检测管线：对库中过期条目按 Id 查最新版；发现更新时取安装包地址并标记待下载 #>
    param([object[]]$Rows, [object[]]$Db = @(), [int]$StaleHours = 24, [switch]$Force, [string]$DbPath, [scriptblock]$OnLog = {})
    if ($null -eq $Db) { $Db = @() }
    $checked = 0
    foreach ($e in $Db) {
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
    'Save-SuRowCache', 'Get-SuRowCache', 'Test-SuCacheFresh'
)
