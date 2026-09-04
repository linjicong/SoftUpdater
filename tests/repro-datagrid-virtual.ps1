# 变体 D：ObservableCollection + 行虚拟化开启 → 是否还崩 + 渲染耗时
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework

$rows = 1..300 | ForEach-Object {
    [pscustomobject]@{ Name = "软件$_"; Id = "id.$_"; Version = '1.0'; Available = ''; Catalog = 'winget'; Location = 'D:\x'; Status = '最新'; HasUpdate = $false; Selected = $false; DownloadPage = ''; ProductName = '' }
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="T" Height="400" Width="800" WindowStyle="ToolWindow" ShowInTaskbar="False">
  <DataGrid x:Name="Grid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
            EnableRowVirtualization="True" EnableColumnVirtualization="True" RowHeight="26">
    <DataGrid.Columns>
      <DataGridCheckBoxColumn Header="选" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="42"/>
      <DataGridTextColumn Header="名称" Binding="{Binding Name}" Width="200" IsReadOnly="True"/>
      <DataGridTextColumn Header="状态" Binding="{Binding Status}" Width="100" IsReadOnly="True"/>
    </DataGrid.Columns>
  </DataGrid>
</Window>
'@

try {
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    $grid = $win.FindName('Grid')
    $oc = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($r in $rows) { [void]$oc.Add($r) }
    $win.Show()
    $grid.ItemsSource = $oc
    $win.UpdateLayout()
    "虚拟化开启 + ObservableCollection: OK，可见行 $($grid.Items.Count)"
} catch {
    "崩溃: $($_.Exception.Message)"
}
