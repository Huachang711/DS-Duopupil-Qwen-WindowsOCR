# ============================================================
# DuoPupil Tray v2.0 (resident background hotkey)
# - dot-sources 双瞳截图.ps1 (reuses all capture/hotkey logic)
# - hotkey combo comes from 工具\hotkey.cfg, polled every 1s
# - no autostart, no desktop lnk hotkey; quit via tray menu
# - panel auto-skips hotkey registration while the tray runs
# ============================================================
$ErrorActionPreference = 'Stop'
try {
$toolDir = Split-Path -Parent $PSCommandPath
$mainName = (-join @([char]0x53CC, [char]0x77B3, [char]0x622A, [char]0x56FE)) + '.ps1'   # 双瞳截图.ps1
. (Join-Path $toolDir $mainName) -DotSource
$script:logPath = Join-Path $toolDir 'tray-timing.log'

# ---- single instance lock (PID-based) ----
$lockFile = Join-Path $toolDir 'tray.lock'
if (Test-Path $lockFile) {
  $alive = $false
  try {
    $pidStr = ([IO.File]::ReadAllText($lockFile, [Text.Encoding]::UTF8)).Trim()
    $p = Get-Process -Id ([int]$pidStr) -ErrorAction Stop
    if ($p) { $alive = $true }
  } catch { }
  if ($alive) { [System.Windows.Forms.MessageBox]::Show((U 'TRAY_RUNNING'), (U 'PANEL_TITLE')); exit 0 }
  Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}
Set-Content -Path $lockFile -Value ([string]$PID) -Encoding utf8

if (-not (Test-Path $script:cfgPath)) {
  [IO.File]::WriteAllText($script:cfgPath, 'CTRL+ALT+S', (New-Object Text.UTF8Encoding($false)))
}

# ---- hidden window + hotkey registration (reuses main-script code) ----
$hk = New-Object HotkeyForm
$hk.ShowInTaskbar = $false
$hk.Opacity = 0
$hk.WindowState = 'Minimized'
$script:phase = 'idle'
$hk.Handler = {
  try {
    Log-Timing 'HOTKEY_RECEIVED'
    if ($script:phase -eq 'idle') {
      Invoke-Capture
      $script:phase = 'idle'
    } elseif ($script:focusMe) {
      $script:focusMe.TopMost = $true
      $script:focusMe.TopMost = $false
      $script:focusMe.Activate()
      Log-Timing 'HOTKEY_FOCUS_BLOCKED_WINDOW'
    } else {
      Log-Timing ('HOTKEY_IGNORED phase=' + $script:phase + ' focus=' + [bool]$script:focusMe)
    }
  } catch {
    Log-Timing 'HOTKEY_HANDLER_ERROR'
    $script:phase = 'idle'
  }
}
Sync-HotkeyFromCfg
$cfgWant = ''
if (Test-Path $script:cfgPath) { $cfgWant = ([IO.File]::ReadAllText($script:cfgPath, [Text.Encoding]::UTF8)).Trim() }
if ($cfgWant -and -not $script:regCombo) {
  [System.Windows.Forms.MessageBox]::Show((U 'HW_REGFAIL') + ' [' + $cfgWant + ']', (U 'HW_TITLE'), 'OK', 'Warning')
}
$script:poll = New-Object System.Windows.Forms.Timer
$script:poll.Interval = 1000
$script:poll.Add_Tick({ Sync-HotkeyFromCfg })
$script:poll.Start()

# ---- tray icon + menu ----
$iconName = (-join @([char]0x53CC, [char]0x77B3)) + '.ico'   # 双瞳.ico
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-Object System.Drawing.Icon (Join-Path $toolDir $iconName)
$tray.Text = (U 'PANEL_TITLE')
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-MenuItem($text, $action) {
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem
  $mi.Text = $text
  $mi.Tag = $action
  $mi.Add_Click({ & $this.Tag })
  $menu.Items.Add($mi) | Out-Null
}
Add-MenuItem (U 'BTN_REGION') { Invoke-Capture; $script:phase = 'idle' }
Add-MenuItem (U 'BTN_FULL')   { Invoke-CaptureFull; $script:phase = 'idle' }
Add-MenuItem (U 'BTN_FOLDER') { Start-Process explorer.exe -ArgumentList $imgDir }
Add-MenuItem (U 'BTN_HOTKEY') { Show-HotkeyWindow }
Add-MenuItem (U 'BTN_EXIT') {
  if ($script:regCombo -and $hk) { [HotkeyForm]::UnregisterHotKey($hk.Handle, 1) | Out-Null }
  if ($script:poll) { $script:poll.Stop(); $script:poll.Dispose() }
  $tray.Visible = $false
  Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
  [System.Windows.Forms.Application]::Exit()
}
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ Invoke-Capture; $script:phase = 'idle' })

Log-Timing 'TRAY_START'
Show-Toast (U 'TRAY_STARTED')
[System.Windows.Forms.Application]::Run()
} catch {
  try {
    [IO.File]::WriteAllText((Join-Path $toolDir 'tray-error.log'), ($_.Exception | Out-String), (New-Object Text.UTF8Encoding($false)))
  } catch { }
  exit 1
}
