# 启动阶段耗时测量（无窗口，逐阶段计时）
$ErrorActionPreference = 'Continue'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
function Mark($name) { "{0,8:N0} ms  {1}" -f $sw.Elapsed.TotalMilliseconds, $name }

Mark '脚本启动'
Import-Module 'D:\software\SoftUpdater\SoftUpdater-Core.psm1' -Force
Mark 'Import-Module Core'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Mark 'Add-Type WPF 程序集'
$script:Root = 'D:\software\SoftUpdater'
Import-Module (Join-Path $script:Root 'SoftUpdater-Core.psm1') -Force
Mark '重复 Import（幂等代价）'

$code = Get-Content 'D:\software\SoftUpdater\SoftUpdater.ps1' -Raw
$m = [regex]::Match($code, '(?s)-TypeDefinition @"(.*?)"@')
if ($m.Success) {
    Add-Type -TypeDefinition $m.Groups[1].Value
    Mark 'Add-Type 编译 SuRow（关键嫌疑）'
} else { Mark '未提取到 SuRow 定义' }

$config = Get-SuConfig
Mark 'Get-SuConfig'
$null = Get-SuState
$null = Get-SuRowCache
$null = Get-SuPortableDb
Mark '读 state/cache/portableDb 三个 JSON'

$xaml = [regex]::Match($code, "(?s)\`$xamlText = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
Add-Type -AssemblyName PresentationFramework | Out-Null
$win = [Windows.Markup.XamlReader]::Parse($xaml)
Mark 'XAML Parse 主窗口'
foreach ($n in 'BtnRefresh','Grid','LogBox','StatusText','DlProgress') { [void]$win.FindName($n) }
Mark 'FindName ×5'
""
"合计到可显示: $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
