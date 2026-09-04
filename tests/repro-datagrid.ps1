# 二分实验：定位 DataGrid + DataTable 绑定崩溃的触发条件
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework

$rows = 1..300 | ForEach-Object {
    [pscustomobject]@{ Name = "软件$_"; Id = "id.$_"; Version = '1.0'; Available = '2.0'; Catalog = 'winget'; Location = 'D:\x'; Status = '有更新'; HasUpdate = $true }
}

function New-Table {
    $t = New-Object System.Data.DataTable
    'Selected','Name','Id','Version','Available','Catalog','Location','Status','HasUpdate' | ForEach-Object {
        [void]$t.Columns.Add($_, $(if ($_ -in 'Selected','HasUpdate') { [bool] } else { [string] }))
    }
    foreach ($r in $rows) { [void]$t.Rows.Add(@($false, $r.Name, $r.Id, $r.Version, $r.Available, $r.Catalog, $r.Location, $r.Status, $r.HasUpdate)) }
    return $t
}

$xamlTemplate = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="T" Height="400" Width="800" WindowStyle="ToolWindow" ShowInTaskbar="False">
  <DataGrid x:Name="Grid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
            EnableRowVirtualization="False" EnableColumnVirtualization="False" RowHeight="26">
    <DataGrid.Columns>
      <DataGridCheckBoxColumn Header="选" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="42"/>
      <DataGridTextColumn Header="名称" Binding="{Binding Name}" Width="200" IsReadOnly="True"/>
      <DataGridTextColumn Header="状态" Binding="{Binding Status}" Width="100" IsReadOnly="True"/>
    </DataGrid.Columns>
  </DataGrid>
</Window>
'@

function Test-Variant {
    param([string]$Name, [scriptblock]$Setup)
    try {
        $win = [Windows.Markup.XamlReader]::Parse($xamlTemplate)
        $grid = $win.FindName('Grid')
        & $Setup $grid
        $win.Show()
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds(4)
        $t.Add_Tick({ $frame.Continue = $false; $t.Stop() })
        $t.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        $win.Close()
        "[$Name] OK（渲染无异常, Items=$($grid.Items.Count)）"
    } catch {
        "[$Name] 崩溃: $($_.Exception.InnerException.InnerException.Message)"
    }
}

Test-Variant -Name 'A: DefaultView' { param($g) $g.ItemsSource = (New-Table).DefaultView }
Test-Variant -Name 'B: DataTable 本体' { param($g) $g.ItemsSource = New-Table }
Test-Variant -Name 'C: ObservableCollection[pscustomobject]' {
    param($g)
    $oc = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($r in $rows) { [void]$oc.Add($r) }
    $g.ItemsSource = $oc
}
