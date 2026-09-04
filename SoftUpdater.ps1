#requires -Version 7.0
<#
  SoftUpdater.ps1 — 软件更新助手 桌面界面（WPF）
  功能：已安装软件列表（winget + 注册表 + D:\software 目录扫描合并）、更新检测、
        手动更新（勾选/右键）、一键全部更新、设置（扫描路径/排除名单/定时任务）。
  启动：双击 启动软件更新助手.vbs（内部会请求一次管理员权限）。
#>

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:TaskScriptPath = Join-Path $script:Root 'SoftUpdater-Task.ps1'

# ---------- 管理员自提升（winget 升级机器级软件需要） ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        Start-Process -FilePath 'pwsh.exe' -Verb RunAs -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        exit 0
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show('已取消管理员授权，软件更新助手需要管理员权限才能升级软件。', '软件更新助手', 'OK', 'Warning') | Out-Null
        exit 1
    }
}

Import-Module (Join-Path $script:Root 'SoftUpdater-Core.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------- 行数据类型：CLR 属性 + INotifyPropertyChanged（DataTable/DataView 绑定在本环境不稳定，弃用） ----------
if (-not ('SU.SuRow' -as [type])) {
    Add-Type -TypeDefinition @"
using System.ComponentModel;
namespace SU {
    public class SuRow : INotifyPropertyChanged {
        bool _selected; string _name, _id, _version, _available, _catalog, _location, _status, _downloadPage, _productName, _lastUsed; bool _hasUpdate;
        public bool Selected { get { return _selected; } set { _selected = value; Notify("Selected"); } }
        public string Name { get { return _name; } set { _name = value; Notify("Name"); } }
        public string Id { get { return _id; } set { _id = value; Notify("Id"); } }
        public string Version { get { return _version; } set { _version = value; Notify("Version"); } }
        public string Available { get { return _available; } set { _available = value; Notify("Available"); } }
        public string Catalog { get { return _catalog; } set { _catalog = value; Notify("Catalog"); } }
        public string Location { get { return _location; } set { _location = value; Notify("Location"); } }
        public string Status { get { return _status; } set { _status = value; Notify("Status"); } }
        public bool HasUpdate { get { return _hasUpdate; } set { _hasUpdate = value; Notify("HasUpdate"); } }
        public string DownloadPage { get { return _downloadPage; } set { _downloadPage = value; Notify("DownloadPage"); } }
        public string ProductName { get { return _productName; } set { _productName = value; Notify("ProductName"); } }
        public string LastUsed { get { return _lastUsed; } set { _lastUsed = value; Notify("LastUsed"); } }
        public event PropertyChangedEventHandler PropertyChanged;
        void Notify(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
    }
}
"@
}

$script:Config = Get-SuConfig
$wingetPath = Find-SuWinget

# ---------- 跨线程同步状态 ----------
$sync = [hashtable]::Synchronized(@{})
$sync.Log         = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$sync.RowUpdates  = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$sync.ResultRows  = $null
$sync.StatusText  = '正在启动...'
$sync.Busy        = $false
$sync.DlPct       = -1   # >=0 时状态栏显示下载进度条

$sync.Log.Enqueue("软件更新助手已启动（管理员: $isAdmin）")
if ($wingetPath) { $sync.Log.Enqueue("winget: $wingetPath") } else { $sync.Log.Enqueue('警告: 未找到 winget.exe，更新功能不可用') }
$sync.Log.Enqueue("扫描路径: $($script:Config.scanPaths -join '; ')  排除名单: $(if ($script:Config.exclusions.Count) { $script:Config.exclusions -join '; ' } else { '(空,全量检测)' })")

# ---------- 降低对系统的影响：整进程树低于正常优先级（winget/COM 子进程继承） ----------
try {
    (Get-Process -Id $PID).PriorityClass = 'BelowNormal'
    $sync.Log.Enqueue('已设为「低于正常」优先级：刷新/更新时把 CPU 让给前台应用，耗时略增')
    Write-SuLog -Message '进程优先级已设为 BelowNormal'
} catch {
    Write-SuLog -Message "设置进程优先级失败: $($_.Exception.Message)"
}

# ---------- 后台任务脚本（在新 Runspace 中执行，避免卡 UI） ----------
$refreshScriptText = @'
param($Root, $Config, $Sync)
Import-Module (Join-Path $Root 'SoftUpdater-Core.psm1') -Force
$Sync.Busy = $true
$Sync.StatusText = '正在枚举已安装软件（winget + 注册表 + 目录扫描）...'
try {
    $onLog = { param($m) $Sync.Log.Enqueue([string]$m); Write-SuLog -Message ([string]$m) }
    $onProgress = {
        param($received, $total, $destPath)
        $n = [System.IO.Path]::GetFileName("$destPath")
        if ($total -gt 0) {
            $pct = [math]::Round(100.0 * $received / $total, 1)
            $Sync.DlPct = $pct
            $Sync.StatusText = ("下载 {0}: {1}%（{2:N1}/{3:N1} MB）" -f $n, $pct, ($received / 1MB), ($total / 1MB))
        } else {
            $Sync.DlPct = -1
            $Sync.StatusText = ("下载 {0}: 已下载 {1:N1} MB" -f $n, ($received / 1MB))
        }
    }
    $rows = @(Get-SuInstalledSoftware -Config $Config -OnLog $onLog)

    # 便携软件源库（有源才检查，带 TTL 缓存，平时几乎零开销）
    $dbPath = Join-Path $Root 'update-sources.json'
    $db = @(Get-SuPortableDb -Path $dbPath)
    if (@($db | Where-Object { $_.WingetId }).Count -gt 0) {
        $checkHours = 24
        if ($Config.portable -and $Config.portable.checkHours) { $checkHours = [int]$Config.portable.checkHours }
        $Sync.StatusText = '检查便携软件更新源...'
        $db = @(Invoke-SuPortableCheck -Rows $rows -Db $db -StaleHours $checkHours -DbPath $dbPath -OnLog $onLog)
        $rows = @(Merge-SuPortableSourceInfo -Rows $rows -Db $db)
        $dlDir = if ($Config.portable -and $Config.portable.downloadDir) { [string]$Config.portable.downloadDir } else { '' }
        $pending = @($db | Where-Object { $_.PendingDownload -and $_.InstallerUrl })
        for ($i = 0; $i -lt $pending.Count; $i++) {
            $e = $pending[$i]
            $Sync.StatusText = "（$($i + 1)/$($pending.Count)）自动下载安装包: $($e.Name)..."
            [void](Invoke-SuPortableDownload -Entry $e -DownloadDir $dlDir -OnLog $onLog -OnProgress $onProgress)
            $Sync.DlPct = -1
            $e.PendingDownload = $false
            Save-SuPortableDb -Db $db -Path $dbPath
        }
    }

    $Sync.ResultRows = $rows
    $updCount = @($rows | Where-Object { $_.HasUpdate }).Count
    $Sync.StatusText = "刷新完成: 共 $($rows.Count) 个软件, $updCount 个有更新"
    Update-SuState -Data @{ lastCheck = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); lastCount = $rows.Count; lastUpdates = $updCount }
    Save-SuRowCache -Rows $rows
} catch {
    $Sync.Log.Enqueue("刷新错误: $($_.Exception.Message)")
    $Sync.StatusText = '刷新失败，详见日志'
} finally {
    $Sync.Busy = $false
}
'@

$upgradeScriptText = @'
param($Root, $Config, $Sync, $Targets)
Import-Module (Join-Path $Root 'SoftUpdater-Core.psm1') -Force
$Sync.Busy = $true
try {
    $onOutput = { param($m) $Sync.Log.Enqueue([string]$m); Write-SuLog -Message ([string]$m) }
    $onRow = { param($row, $s) $Sync.RowUpdates.Enqueue(@{ Name = [string]$row.Name; Id = [string]$row.Id; Status = [string]$s }) }
    $Sync.StatusText = "正在更新 $($Targets.Count) 个软件..."
    $Sync.DlPct = -2   # 不定态进度条（winget 升级无细粒度进度）
    $r = Invoke-SuUpgradeBatch -Rows $Targets -Exclusions $Config.exclusions -OnOutput $onOutput -OnRowStatus $onRow
    $Sync.StatusText = "更新结束: 成功 $($r.Ok) / 失败 $($r.Fail) / 跳过 $($r.Skip)，正在刷新列表..."
    $rows = @(Get-SuInstalledSoftware -Config $Config -OnLog $onOutput)
    $Sync.ResultRows = $rows
    $updCount = @($rows | Where-Object { $_.HasUpdate }).Count
    $Sync.DlPct = -1
    $Sync.StatusText = "更新结束: 成功 $($r.Ok) / 失败 $($r.Fail) / 跳过 $($r.Skip);  共 $($rows.Count) 个软件, $updCount 个有更新"
    Update-SuState -Data @{ lastCheck = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); lastCount = $rows.Count; lastUpdates = $updCount }
} catch {
    $Sync.Log.Enqueue("更新错误: $($_.Exception.Message)")
    $Sync.StatusText = '更新失败，详见日志'
} finally {
    $Sync.Busy = $false
}
'@

$learnJobText = @'
param($Root, $Config, $Sync)
Import-Module (Join-Path $Root 'SoftUpdater-Core.psm1') -Force
$Sync.Busy = $true
try {
    $onLog = { param($m) $Sync.Log.Enqueue([string]$m); Write-SuLog -Message ([string]$m) }
    $Sync.StatusText = '学习便携软件更新源：先枚举列表...'
    $rows = @(Get-SuInstalledSoftware -Config $Config -OnLog $onLog)
    $dbPath = Join-Path $Root 'update-sources.json'
    $db = @(Update-SuPortableDbLearning -Rows $rows -Db (Get-SuPortableDb -Path $dbPath) -DbPath $dbPath -OnLog $onLog)
    $rows = @(Merge-SuPortableSourceInfo -Rows $rows -Db $db)
    $Sync.ResultRows = $rows
    $updCount = @($rows | Where-Object { $_.HasUpdate }).Count
    $Sync.StatusText = "学习完成: 更新源库 $($db.Count) 条; 共 $($rows.Count) 个软件, $updCount 个有更新"
    Save-SuRowCache -Rows $rows
} catch {
    $Sync.Log.Enqueue("学习错误: $($_.Exception.Message)")
    $Sync.StatusText = '学习失败，详见日志'
} finally {
    $Sync.Busy = $false
}
'@

$checkPortableJobText = @'
param($Root, $Config, $Sync)
Import-Module (Join-Path $Root 'SoftUpdater-Core.psm1') -Force
$Sync.Busy = $true
try {
    $onLog = { param($m) $Sync.Log.Enqueue([string]$m); Write-SuLog -Message ([string]$m) }
    $onProgress = {
        param($received, $total, $destPath)
        $n = [System.IO.Path]::GetFileName("$destPath")
        if ($total -gt 0) {
            $pct = [math]::Round(100.0 * $received / $total, 1)
            $Sync.DlPct = $pct
            $Sync.StatusText = ("下载 {0}: {1}%（{2:N1}/{3:N1} MB）" -f $n, $pct, ($received / 1MB), ($total / 1MB))
        } else {
            $Sync.DlPct = -1
            $Sync.StatusText = ("下载 {0}: 已下载 {1:N1} MB" -f $n, ($received / 1MB))
        }
    }
    $Sync.StatusText = '强制检测便携软件更新（逐个查目录）...'
    $rows = @(Get-SuInstalledSoftware -Config $Config -OnLog $onLog)
    $dbPath = Join-Path $Root 'update-sources.json'
    $db = @(Invoke-SuPortableCheck -Rows $rows -Db (Get-SuPortableDb -Path $dbPath) -StaleHours 24 -Force -DbPath $dbPath -OnLog $onLog)
    $rows = @(Merge-SuPortableSourceInfo -Rows $rows -Db $db)
    $dlDir = if ($Config.portable -and $Config.portable.downloadDir) { [string]$Config.portable.downloadDir } else { '' }
    $pending = @($db | Where-Object { $_.PendingDownload -and $_.InstallerUrl })
    for ($i = 0; $i -lt $pending.Count; $i++) {
        $e = $pending[$i]
        $Sync.StatusText = "（$($i + 1)/$($pending.Count)）自动下载安装包: $($e.Name)..."
        [void](Invoke-SuPortableDownload -Entry $e -DownloadDir $dlDir -OnLog $onLog -OnProgress $onProgress)
        $Sync.DlPct = -1
        $e.PendingDownload = $false
        Save-SuPortableDb -Db $db -Path $dbPath
    }
    $Sync.ResultRows = $rows
    $Sync.StatusText = "检测完成: 共 $($rows.Count) 个软件, $(@($rows | Where-Object { $_.HasUpdate }).Count) 个有更新"
    Save-SuRowCache -Rows $rows
} catch {
    $Sync.Log.Enqueue("检测错误: $($_.Exception.Message)")
    $Sync.StatusText = '检测失败，详见日志'
} finally {
    $Sync.Busy = $false
}
'@

$downloadPortableJobText = @'
param($Root, $Config, $Sync, $Folder)
Import-Module (Join-Path $Root 'SoftUpdater-Core.psm1') -Force
$Sync.Busy = $true
try {
    $onLog = { param($m) $Sync.Log.Enqueue([string]$m); Write-SuLog -Message ([string]$m) }
    $onProgress = {
        param($received, $total, $destPath)
        $n = [System.IO.Path]::GetFileName("$destPath")
        if ($total -gt 0) {
            $pct = [math]::Round(100.0 * $received / $total, 1)
            $Sync.DlPct = $pct
            $Sync.StatusText = ("下载 {0}: {1}%（{2:N1}/{3:N1} MB）" -f $n, $pct, ($received / 1MB), ($total / 1MB))
        } else {
            $Sync.DlPct = -1
            $Sync.StatusText = ("下载 {0}: 已下载 {1:N1} MB" -f $n, ($received / 1MB))
        }
    }
    $dbPath = Join-Path $Root 'update-sources.json'
    $db = @(Get-SuPortableDb -Path $dbPath)
    $entry = $null
    foreach ($e in $db) { if ($e.Folder -and $Folder -and ($e.Folder.TrimEnd('\') -ieq $Folder.TrimEnd('\'))) { $entry = $e; break } }
    if (-not $entry) { $Sync.StatusText = '未找到该软件的更新源记录'; return }
    if (-not $entry.InstallerUrl) {
        $Sync.StatusText = "查询 $($entry.Name) 的安装包地址..."
        $detail = Get-SuWingetPackageDetail -Id $entry.WingetId -OnLog $onLog
        if ($detail -and $detail.InstallerUrl) { $entry.InstallerUrl = $detail.InstallerUrl; Save-SuPortableDb -Db $db -Path $dbPath }
    }
    $dlDir = if ($Config.portable -and $Config.portable.downloadDir) { [string]$Config.portable.downloadDir } else { '' }
    $Sync.StatusText = "下载 $($entry.Name) 安装包..."
    [void](Invoke-SuPortableDownload -Entry $entry -DownloadDir $dlDir -OnLog $onLog -OnProgress $onProgress)
    $Sync.DlPct = -1
    $Sync.StatusText = "下载结束: $($entry.Name)"
} catch {
    $Sync.Log.Enqueue("下载错误: $($_.Exception.Message)")
    $Sync.StatusText = '下载失败，详见日志'
} finally {
    $Sync.Busy = $false
}
'@
$script:Jobs = [System.Collections.ArrayList]::new()
function Start-SuJob {
    param([string]$Text, [object[]]$JobArgs)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Text)
    foreach ($a in $JobArgs) { [void]$ps.AddArgument($a) }
    $h = $ps.BeginInvoke()
    [void]$script:Jobs.Add(@{ PS = $ps; RS = $rs; H = $h })
}

# ---------- 数据表格 ----------
function ConvertTo-SuRowCollection {
    param([object[]]$Rows)
    $oc = [System.Collections.ObjectModel.ObservableCollection[SU.SuRow]]::new()
    foreach ($r in $Rows) {
        if ($null -eq $r) { continue }
        $row = New-Object SU.SuRow
        $row.Name      = [string]$r.Name
        $row.Id        = [string]$r.Id
        $row.Version   = [string]$r.Version
        $row.Available = [string]$r.Available
        $row.Catalog   = [string]$r.Catalog
        $row.Location  = [string]$r.Location
        $row.Status    = [string]$r.Status
        $row.HasUpdate = [bool]$r.HasUpdate
        $row.DownloadPage = [string]$r.DownloadPage
        $row.ProductName  = [string]$r.ProductName
        $row.LastUsed     = [string]$r.LastUsed
        $row.Selected  = $false
        [void]$oc.Add($row)
    }
    return ,$oc
}

function Apply-SuFilter {
    if ($null -eq $grid.ItemsSource) { return }
    $view = [System.ComponentModel.ICollectionView]$grid.Items
    $view.Filter = switch ($script:FilterMode) {
        'update'  { [Predicate[object]] { param($it) (Get-SuStatusBucket -HasUpdate ([bool]$it.HasUpdate) -Status "$($it.Status)") -eq 'update' } }
        'ok'      { [Predicate[object]] { param($it) (Get-SuStatusBucket -HasUpdate ([bool]$it.HasUpdate) -Status "$($it.Status)") -eq 'ok' } }
        'unknown' { [Predicate[object]] { param($it) (Get-SuStatusBucket -HasUpdate ([bool]$it.HasUpdate) -Status "$($it.Status)") -eq 'unknown' } }
        default   { $null }
    }
}

$script:FilterMode = 'all'
function Update-SuStats {
    $c = Get-SuStatusCounts -Rows $(if ($script:Rows) { @($script:Rows) } else { @() })
    $btnStAll.Content     = "全部 $($c.Total)"
    $btnStUpdate.Content  = "有更新 $($c.Update)"
    $btnStOk.Content      = "最新 $($c.Ok)"
    $btnStUnknown.Content = "版本未知 $($c.Unknown)"
}

function Set-SuFilterMode {
    param([string]$Mode)
    $script:FilterMode = $Mode
    $normal = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
    $active = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#D6E7FF'))
    foreach ($pair in @(@('all', $btnStAll), @('update', $btnStUpdate), @('ok', $btnStOk), @('unknown', $btnStUnknown))) {
        $pair[1].Background = if ($pair[0] -eq $Mode) { $active } else { $normal }
    }
    Apply-SuFilter
}

# ---------- XAML ----------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="软件更新助手" Height="680" Width="1160"
        WindowStartupLocation="CenterScreen" Background="#F5F6F8"
        FontFamily="Microsoft YaHei UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#1F2328"/>
      <Setter Property="BorderBrush" Value="#C9CED6"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E2E6EB"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#1F2328"/>
    </Style>
  </Window.Resources>

  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="190"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0">
      <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
        <Button x:Name="BtnRefresh" Content="🔄 刷新列表" MinWidth="110"/>
        <Button x:Name="BtnUpdateSelected" Content="⬆ 更新选中" MinWidth="110" Margin="8,0,0,0"/>
        <Button x:Name="BtnUpdateAll" Content="⬆⬆ 全部更新" MinWidth="110" Margin="8,0,0,0"/>
        <Button x:Name="BtnLearnPortable" Content="📚 学习便携源" MinWidth="120" Margin="12,0,0,0"/>
        <Button x:Name="BtnCheckPortable" Content="⬇ 检测便携更新" MinWidth="130" Margin="8,0,0,0"/>
        <Button x:Name="BtnSettings" Content="⚙ 设置" MinWidth="90" Margin="12,0,0,0" HorizontalAlignment="Right"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
        <Button x:Name="StAll"      Content="全部 0"     MinWidth="96"  Padding="8,3"/>
        <Button x:Name="StUpdate"   Content="有更新 0"   MinWidth="96"  Margin="6,0,0,0" Padding="8,3"/>
        <Button x:Name="StOk"       Content="最新 0"     MinWidth="96"  Margin="6,0,0,0" Padding="8,3"/>
        <Button x:Name="StUnknown"  Content="版本未知 0" MinWidth="110" Margin="6,0,0,0" Padding="8,3"/>
        <TextBlock Text="点击分类筛选，再点取消" Foreground="#57606A" VerticalAlignment="Center" Margin="12,0,0,0"/>
      </StackPanel>
    </StackPanel>

    <DataGrid x:Name="Grid" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
              Background="#FFFFFF" RowBackground="#FFFFFF" AlternatingRowBackground="#F3F5F8"
              BorderBrush="#C9CED6" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#E4E7EC" VerticalGridLinesBrush="#E4E7EC"
              HeadersVisibility="Column" SelectionMode="Extended" SelectionUnit="FullRow"
              EnableRowVirtualization="True" EnableColumnVirtualization="True"
              FontFamily="Microsoft YaHei UI" FontSize="13" RowHeight="26">
      <DataGrid.ColumnHeaderStyle>
        <Style TargetType="DataGridColumnHeader">
          <Setter Property="Background" Value="#EEF1F4"/>
          <Setter Property="Foreground" Value="#57606A"/>
          <Setter Property="FontWeight" Value="SemiBold"/>
          <Setter Property="Padding" Value="6,5"/>
          <Setter Property="BorderBrush" Value="#C9CED6"/>
          <Setter Property="BorderThickness" Value="0,0,1,1"/>
        </Style>
      </DataGrid.ColumnHeaderStyle>
      <DataGrid.RowStyle>
        <Style TargetType="DataGridRow">
          <Setter Property="Background" Value="#FFFFFF"/>
          <Style.Triggers>
            <Trigger Property="IsSelected" Value="True">
              <Setter Property="Background" Value="#D6E7FF"/>
            </Trigger>
          </Style.Triggers>
        </Style>
      </DataGrid.RowStyle>
      <DataGrid.CellStyle>
        <Style TargetType="DataGridCell">
          <Setter Property="BorderThickness" Value="0"/>
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Padding" Value="4,2"/>
          <Setter Property="TextElement.Foreground" Value="#1F2328"/>
        </Style>
      </DataGrid.CellStyle>
      <DataGrid.Columns>
        <DataGridCheckBoxColumn Header="选" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="42"/>
        <DataGridTextColumn Header="名称"     Binding="{Binding Name}"      Width="230" IsReadOnly="True"/>
        <DataGridTextColumn Header="ID"       Binding="{Binding Id}"        Width="175" IsReadOnly="True"/>
        <DataGridTextColumn Header="当前版本" Binding="{Binding Version}"   Width="95"  IsReadOnly="True"/>
        <DataGridTextColumn Header="可用版本" Binding="{Binding Available}" Width="95"  IsReadOnly="True"/>
        <DataGridTextColumn Header="来源"     Binding="{Binding Catalog}"   Width="62"  IsReadOnly="True"/>
        <DataGridTextColumn Header="位置"     Binding="{Binding Location}"  Width="*"   IsReadOnly="True"/>
        <DataGridTextColumn Header="最近使用" Binding="{Binding LastUsed}"  Width="118" IsReadOnly="True"/>
        <DataGridTextColumn Header="状态"     Binding="{Binding Status}"    Width="105" IsReadOnly="True"/>
      </DataGrid.Columns>
      <DataGrid.ContextMenu>
        <ContextMenu>
          <MenuItem Header="更新此软件"          x:Name="MenuUpdateRow"/>
          <MenuItem Header="⬇ 下载此更新（便携）" x:Name="MenuDownloadPortable"/>
          <MenuItem Header="🌐 打开下载页"        x:Name="MenuOpenPage"/>
          <MenuItem Header="打开所在位置"         x:Name="MenuOpenLocation"/>
        </ContextMenu>
      </DataGrid.ContextMenu>
    </DataGrid>

    <GroupBox Grid.Row="2" Header="日志" Foreground="#57606A" BorderBrush="#C9CED6" Margin="0,8,0,0">
      <TextBox x:Name="LogBox" IsReadOnly="True" Background="#EEF1F4" Foreground="#1A7F37" BorderBrush="#C9CED6"
               FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
               TextWrapping="NoWrap"/>
    </GroupBox>

    <StatusBar Grid.Row="3" Background="#EEF1F4" Foreground="#1F2328" BorderBrush="#C9CED6" BorderThickness="0,1,0,0">
      <StatusBarItem>
        <TextBlock x:Name="StatusText" Text="就绪" Foreground="#1F2328"/>
      </StatusBarItem>
      <StatusBarItem HorizontalAlignment="Right">
        <ProgressBar x:Name="DlProgress" Width="240" Height="14" Visibility="Collapsed"/>
      </StatusBarItem>
    </StatusBar>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($xamlText)
$btnRefresh      = $win.FindName('BtnRefresh')
$btnUpdateSel    = $win.FindName('BtnUpdateSelected')
$btnUpdateAll    = $win.FindName('BtnUpdateAll')
$btnSettings     = $win.FindName('BtnSettings')
$btnStAll        = $win.FindName('StAll')
$btnStUpdate     = $win.FindName('StUpdate')
$btnStOk         = $win.FindName('StOk')
$btnStUnknown    = $win.FindName('StUnknown')
$grid            = $win.FindName('Grid')
$logBox          = $win.FindName('LogBox')
$statusText      = $win.FindName('StatusText')
$menuUpdateRow   = $win.FindName('MenuUpdateRow')
$menuOpenLoc     = $win.FindName('MenuOpenLocation')
$menuDownloadP   = $win.FindName('MenuDownloadPortable')
$menuOpenPage    = $win.FindName('MenuOpenPage')
$btnLearn        = $win.FindName('BtnLearnPortable')
$btnCheckP       = $win.FindName('BtnCheckPortable')
$dlProgress      = $win.FindName('DlProgress')
$script:Rows     = $null
Update-SuStats
Set-SuFilterMode 'all'

# ---------- 事件 ----------
$btnRefresh.Add_Click({
    if ($sync.Busy) { return }
    $sync.StatusText = '正在刷新...'
    Start-SuJob -Text $refreshScriptText -JobArgs @($script:Root, $script:Config, $sync)
})

$btnUpdateSel.Add_Click({
    if ($sync.Busy -or -not $script:Rows) { return }
    $targets = @($script:Rows | Where-Object { $_.Selected -and $_.Id })
    $noId = @($script:Rows | Where-Object { $_.Selected -and -not $_.Id })
    if (-not $targets) {
        [System.Windows.MessageBox]::Show($win, "请先勾选要更新的软件。`n（没有 winget ID 的系统/便携软件无法自动更新）", '软件更新助手', 'OK', 'Information') | Out-Null
        return
    }
    $msg = "确定更新选中的 $($targets.Count) 个软件？"
    if ($noId.Count -gt 0) { $msg += "`n（另有 $($noId.Count) 个无 winget ID 的项将被忽略）" }
    if ([System.Windows.MessageBox]::Show($win, $msg, '确认更新', 'YesNo', 'Question') -eq 'Yes') {
        Start-SuJob -Text $upgradeScriptText -JobArgs @($script:Root, $script:Config, $sync, $targets)
    }
})

$btnUpdateAll.Add_Click({
    if ($sync.Busy -or -not $script:Rows) { return }
    $targets = @($script:Rows | Where-Object { $_.HasUpdate -and $_.Id })
    if (-not $targets) {
        [System.Windows.MessageBox]::Show($win, '当前没有可更新的软件。', '软件更新助手', 'OK', 'Information') | Out-Null
        return
    }
    if ([System.Windows.MessageBox]::Show($win, "确定更新全部 $($targets.Count) 个有新版本的软件？", '确认全部更新', 'YesNo', 'Question') -eq 'Yes') {
        Start-SuJob -Text $upgradeScriptText -JobArgs @($script:Root, $script:Config, $sync, $targets)
    }
})

$btnStAll.Add_Click({ Set-SuFilterMode 'all' })
$btnStUpdate.Add_Click({ Set-SuFilterMode 'update' })
$btnStOk.Add_Click({ Set-SuFilterMode 'ok' })
$btnStUnknown.Add_Click({ Set-SuFilterMode 'unknown' })

$btnLearn.Add_Click({
    if ($sync.Busy) { return }
    if ([System.Windows.MessageBox]::Show($win, "开始学习便携软件更新源？`n将逐个查询 winget 目录（约 1~3 分钟），结果存入 update-sources.json。", '学习便携源', 'YesNo', 'Question') -eq 'Yes') {
        Start-SuJob -Text $learnJobText -JobArgs @($script:Root, $script:Config, $sync)
    }
})

$btnCheckP.Add_Click({
    if ($sync.Busy) { return }
    Start-SuJob -Text $checkPortableJobText -JobArgs @($script:Root, $script:Config, $sync)
})

$menuDownloadPortableHandler = {
    if ($sync.Busy -or -not $grid.SelectedItem) { return }
    $target = $grid.SelectedItem
    if ($target.Catalog -ne '便携') {
        [System.Windows.MessageBox]::Show($win, '该行不是便携软件（winget 软件请用「更新此软件」）。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    if (-not $target.HasUpdate) {
        [System.Windows.MessageBox]::Show($win, '该软件当前没有检测到新版本。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    Start-SuJob -Text $downloadPortableJobText -JobArgs @($script:Root, $script:Config, $sync, [string]$target.Location)
}
$menuDownloadP.Add_Click($menuDownloadPortableHandler)

$menuOpenPage.Add_Click({
    if (-not $grid.SelectedItem) { return }
    $target = $grid.SelectedItem
    $page = [string]$target.DownloadPage
    if (-not $page -and $target.Id) { $page = "https://winstall.app/apps/$($target.Id)" }
    if ($page) { Start-Process $page } else {
        [System.Windows.MessageBox]::Show($win, "该软件没有已知下载页。`n可在 update-sources.json 里手工补充 DownloadPage。", '提示', 'OK', 'Information') | Out-Null
    }
})

$menuUpdateRow.Add_Click({
    if ($sync.Busy -or -not $grid.SelectedItem) { return }
    $target = $grid.SelectedItem
    if (-not $target.Id) {
        [System.Windows.MessageBox]::Show($win, '该软件没有 winget ID，无法自动更新。', '提示', 'OK', 'Warning') | Out-Null
        return
    }
    Start-SuJob -Text $upgradeScriptText -JobArgs @($script:Root, $script:Config, $sync, @($target))
})

$menuOpenLoc.Add_Click({
    if (-not $grid.SelectedItem) { return }
    $target = $grid.SelectedItem
    if ($target.Location -and (Test-Path -LiteralPath $target.Location)) {
        Start-Process explorer.exe -ArgumentList "`"$($target.Location)`""
    } else {
        [System.Windows.MessageBox]::Show($win, '该软件没有记录安装位置。', '提示', 'OK', 'Information') | Out-Null
    }
})

# ---------- 设置窗口 ----------
$btnSettings.Add_Click({
    $sxaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="设置 - 软件更新助手" Height="540" Width="600"
        WindowStartupLocation="CenterOwner" Background="#F5F6F8"
        FontFamily="Microsoft YaHei UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#1F2328"/></Style>
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#1F2328"/>
      <Setter Property="BorderBrush" Value="#C9CED6"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
    </Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="64"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="92"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="扫描路径（每行一个，用于识别安装在其中的软件）" Margin="0,0,0,4"/>
    <TextBox x:Name="TxtScanPaths" Grid.Row="1" Style="{StaticResource Input}" AcceptsReturn="True"/>

    <TextBlock Grid.Row="2" Text="排除名单（每行一个，支持通配符如 WXWork*；留空 = 全量检测不排除任何软件）" Margin="0,10,0,4"/>
    <TextBox x:Name="TxtExclusions" Grid.Row="3" Style="{StaticResource Input}" AcceptsReturn="True"/>

    <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,12,0,0">
      <CheckBox x:Name="ChkSchedule" Content="启用定时自动更新（计划任务执行时检查此开关）" Foreground="#1F2328" VerticalAlignment="Center"/>
      <TextBlock Text="  每天" Foreground="#1F2328" VerticalAlignment="Center"/>
      <TextBox x:Name="TxtTime" Width="70" Style="{StaticResource Input}" Margin="6,0,0,0" VerticalContentAlignment="Center"/>
      <TextBlock Text="（HH:mm）" Foreground="#57606A" VerticalAlignment="Center"/>
    </StackPanel>

    <TextBlock x:Name="LblTaskStatus" Grid.Row="5" Foreground="#57606A" Margin="0,10,0,0"/>

    <StackPanel Grid.Row="7" Orientation="Horizontal" Margin="0,16,0,0" VerticalAlignment="Bottom">
      <Button x:Name="BtnSave" Content="保存配置" MinWidth="100"/>
      <Button x:Name="BtnRegisterTask" Content="注册/更新定时任务" MinWidth="150" Margin="10,0,0,0"/>
      <Button x:Name="BtnRemoveTask" Content="移除定时任务" MinWidth="120" Margin="10,0,0,0"/>
      <Button x:Name="BtnClose" Content="关闭" MinWidth="80" Margin="10,0,0,0"/>
    </StackPanel>
  </Grid>
</Window>
'@
    try {
        $swin = [Windows.Markup.XamlReader]::Parse($sxaml)
        $swin.Owner = $win
        $txtScan   = $swin.FindName('TxtScanPaths')
        $txtExcl   = $swin.FindName('TxtExclusions')
        $chkSched  = $swin.FindName('ChkSchedule')
        $txtTime   = $swin.FindName('TxtTime')
        $lblTask   = $swin.FindName('LblTaskStatus')

        function Update-SuTaskLabel {
            $task = Get-SuScheduledTask
            $lblTask.Text = if ($task) { "计划任务 SoftUpdater-Auto: 已注册（状态: $($task.State)）" } else { '计划任务 SoftUpdater-Auto: 未注册' }
        }
        $txtScan.Text = ($script:Config.scanPaths -join "`r`n")
        $txtExcl.Text = ($script:Config.exclusions -join "`r`n")
        $chkSched.IsChecked = [bool]$script:Config.schedule.enabled
        $txtTime.Text = [string]$script:Config.schedule.time
        Update-SuTaskLabel

        $swin.FindName('BtnSave').Add_Click({
            $scanPaths = @($txtScan.Text -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
            if (-not $scanPaths) { [System.Windows.MessageBox]::Show($swin, '扫描路径不能为空', '提示', 'OK', 'Warning') | Out-Null; return }
            $exclusions = @($txtExcl.Text -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
            $newCfg = @{
                scanPaths  = $scanPaths
                exclusions = $exclusions
                schedule   = @{ enabled = [bool]$chkSched.IsChecked; time = $txtTime.Text.Trim() }
            }
            if ($script:Config.portable) { $newCfg.portable = $script:Config.portable }
            if ($script:Config.cache) { $newCfg.cache = $script:Config.cache }
            $script:Config = $newCfg
            Save-SuConfig -Config $script:Config
            $sync.Log.Enqueue('配置已保存')
            [System.Windows.MessageBox]::Show($swin, '配置已保存。扫描路径与排除名单立即生效；定时开关保存后由计划任务在下次触发时读取。', '设置', 'OK', 'Information') | Out-Null
        })

        $swin.FindName('BtnRegisterTask').Add_Click({
            $t = $txtTime.Text.Trim()
            if ($t -notmatch '^\d{1,2}:\d{2}$') {
                [System.Windows.MessageBox]::Show($swin, "时间格式不正确：$t（应为 HH:mm，例如 12:30）", '提示', 'OK', 'Warning') | Out-Null
                return
            }
            try {
                # 注册前先把时间与开关写入配置
                $chkSchedValue = [bool]$chkSched.IsChecked
                $script:Config.schedule.time = $t
                $script:Config.schedule.enabled = $chkSchedValue
                Save-SuConfig -Config $script:Config
                Register-SuScheduledTask -ScriptPath $script:TaskScriptPath -Time $t
                Update-SuTaskLabel
                $sync.Log.Enqueue("定时任务已注册（每天 $t，开关: $chkSchedValue）")
                [System.Windows.MessageBox]::Show($swin, "定时任务已注册：每天 $t 执行。`n注意：执行时会检查「启用定时自动更新」开关。", '设置', 'OK', 'Information') | Out-Null
            } catch {
                [System.Windows.MessageBox]::Show($swin, "注册失败: $($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
            }
        })

        $swin.FindName('BtnRemoveTask').Add_Click({
            try {
                Unregister-SuScheduledTask
                Update-SuTaskLabel
                $sync.Log.Enqueue('定时任务已移除')
            } catch {
                [System.Windows.MessageBox]::Show($swin, "移除失败: $($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
            }
        })

        $swin.FindName('BtnClose').Add_Click({ $swin.Close() })

        [void]$swin.ShowDialog()
    } catch {
        [System.Windows.MessageBox]::Show($win, "设置窗口打开失败: $($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
    }
})

# ---------- 关闭保护 ----------
$win.Add_Closing({
    param($s, $e)
    if ($sync.Busy) {
        [System.Windows.MessageBox]::Show($win, '有任务正在进行中（可能正在升级软件），请等待完成后再关闭。', '软件更新助手', 'OK', 'Warning') | Out-Null
        $e.Cancel = $true
    }
})

# ---------- UI 定时器：收割后台任务 / 排队日志 / 行状态 / 结果表 ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    $tickSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # 后台任务清理
        for ($i = $script:Jobs.Count - 1; $i -ge 0; $i--) {
            $j = $script:Jobs[$i]
            if ($j.H.IsCompleted) {
                try { [void]$j.PS.EndInvoke($j.H) } catch { $logBox.AppendText("后台任务异常: $($_.Exception.Message)`n") }
                $j.PS.Dispose(); $j.RS.Close(); $j.RS.Dispose()
                $script:Jobs.RemoveAt($i)
            }
        }
        # 日志
        $sb = New-Object System.Text.StringBuilder
        $line = $null
        while ($sync.Log.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
        if ($sb.Length -gt 0) {
            if ($logBox.Text.Length -gt 150000) { $logBox.Text = $logBox.Text.Substring(70000) }
            $logBox.AppendText($sb.ToString())
            $logBox.ScrollToEnd()
        }
        # 行状态（更新进度）
        $u = $null
        while ($sync.RowUpdates.TryDequeue([ref]$u)) {
            if ($script:Rows) {
                foreach ($r in $script:Rows) {
                    $match = if ($u['Id']) { $r.Id -eq $u['Id'] } else { $r.Name -eq $u['Name'] }
                    if ($match) { $r.Status = $u['Status']; break }
                }
            }
        }
        # 新结果
        if ($sync.ResultRows) {
            $rows = $sync.ResultRows
            $sync.ResultRows = $null
            $renderSw = [System.Diagnostics.Stopwatch]::StartNew()
            $script:Rows = ConvertTo-SuRowCollection -Rows @($rows)
            $grid.ItemsSource = $script:Rows
            Apply-SuFilter
            $sync.RenderMs = [math]::Round($renderSw.Elapsed.TotalMilliseconds)
            if ($sync.RenderMs -gt 500) { Write-SuLog -Message ("UI 渲染耗时偏高: {0} ms（{1} 行）" -f $sync.RenderMs, @($rows).Count) }
            Update-SuStats
        }
        # 状态栏与按钮
        if ($sync.StatusText) { $statusText.Text = $sync.StatusText }
        # 下载/更新进度条：-1 隐藏，-2 不定态滚动，>=0 百分比
        $pct = $sync.DlPct
        if ($null -ne $pct -and ($pct -ge 0 -or $pct -eq -2)) {
            $dlProgress.Visibility = 'Visible'
            if ($pct -eq -2) {
                if (-not $dlProgress.IsIndeterminate) { $dlProgress.IsIndeterminate = $true }
            } else {
                if ($dlProgress.IsIndeterminate) { $dlProgress.IsIndeterminate = $false }
                if ($pct -gt 100) { $pct = 100 }
                if ($pct -lt 0) { $pct = 0 }
                $dlProgress.Value = $pct
            }
        } else {
            $dlProgress.Visibility = 'Collapsed'
            if ($dlProgress.IsIndeterminate) { $dlProgress.IsIndeterminate = $false }
        }
        $isBusy = [bool]$sync.Busy
        $btnRefresh.IsEnabled = -not $isBusy
        $btnUpdateSel.IsEnabled = -not $isBusy
        $btnUpdateAll.IsEnabled = -not $isBusy
        $btnLearn.IsEnabled = -not $isBusy
        $btnCheckP.IsEnabled = -not $isBusy
        $btnSettings.IsEnabled = -not $isBusy
    } catch {
        Write-SuLog -Message ("TICK 异常: $($_.Exception.Message)")
    }
    if ($tickSw.Elapsed.TotalMilliseconds -gt ([double]($sync.TickMaxMs ?? 0))) { $sync.TickMaxMs = [math]::Round($tickSw.Elapsed.TotalMilliseconds) }
})

# ---------- 启动：秒开缓存，按新鲜度决定是否后台重扫 ----------
$state = Get-SuState
$cache = Get-SuRowCache
$maxAge = 6
if ($script:Config.cache -and $script:Config.cache.maxAgeHours) { $maxAge = [int]$script:Config.cache.maxAgeHours }
$doScan = $true
if ($cache -and @($cache.Rows).Count -gt 0) {
    # 缓存秒开
    $script:Rows = ConvertTo-SuRowCollection -Rows @($cache.Rows)
    $grid.ItemsSource = $script:Rows
    Update-SuStats
    $fresh = Test-SuCacheFresh -SavedAt $cache.SavedAt -MaxAgeHours $maxAge
    $doScan = -not $fresh
    $startMsg = "已从缓存加载 $(@($cache.Rows).Count) 个软件（数据时间 $($cache.SavedAt)）" + $(if ($fresh) { '，数据较新未自动重扫；点「刷新列表」可强制' } else { '，缓存已过期，后台自动刷新中...' })
    $sync.StatusText = $startMsg
    $sync.Log.Enqueue($startMsg)
} elseif ($state['lastCheck']) {
    $sync.StatusText = "上次检测: $($state['lastCheck'])（共 $($state['lastCount']) 个软件, $($state['lastUpdates']) 个有更新）"
}
$timer.Start()
if ($doScan) {
    Start-SuJob -Text $refreshScriptText -JobArgs @($script:Root, $script:Config, $sync)
}

[void]$win.ShowDialog()
