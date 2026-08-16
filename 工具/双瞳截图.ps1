# ============================================================
# DuoPupil v2.1 (100% ASCII, pure PS)
# - panel mode: tool owns the global hotkey while open
# - tray mode (optional): resident tray keeps the hotkey alive
# - hotkey combo in 工具\hotkey.cfg, polled every 1s
# - WeChat-style capture: green box, dim outside, movable,
#   size label, 3-button toolbar; DP- image codes on clipboard
# ============================================================
param([string]$Mode = 'panel', [switch]$DotSource)
$ErrorActionPreference = 'Stop'

# ---- DPI awareness (compile only when scaling > 100%, saves startup time) ----
$appliedDpi = 120
try {
  $wm = Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction Stop
  $appliedDpi = [int]$wm.AppliedDPI
} catch { }
if ($appliedDpi -gt 96) {
  try {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class DpiAware {
  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();
}
'@
    $null = [DpiAware]::SetProcessDPIAware()
  } catch { }
}

# ---- locate package folders (folder name built from char codes) ----
$scriptPath = $MyInvocation.MyCommand.Path
if (-not $scriptPath) { $scriptPath = $PSCommandPath }
$toolDir = Split-Path -Parent $scriptPath
$pkgRoot = Split-Path -Parent $toolDir
$imgName = -join @([char]0x56FE, [char]0x7247)          # "图片"
$imgDir  = Join-Path $pkgRoot $imgName
if (-not (Test-Path $imgDir)) { New-Item -ItemType Directory -Path $imgDir | Out-Null }

# ---- load UI strings (UTF-8 file, explicit read) ----
$uiFile = Join-Path $toolDir 'ui.txt'
$ui = @{}
if (Test-Path $uiFile) {
  $uiLines = [IO.File]::ReadAllLines($uiFile, [Text.Encoding]::UTF8)
  foreach ($l in $uiLines) {
    if ($l -match '^([A-Za-z0-9_]+)=(.*)$') { $ui[$Matches[1]] = $Matches[2] }
  }
}
function U($k) { if ($ui.ContainsKey($k)) { return $ui[$k] }; return $k }

# ---- assemblies ----
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- colors (must come after Drawing assembly is loaded) ----
$C_GREEN  = [System.Drawing.Color]::FromArgb(7, 193, 96)    # 07C160
$C_DARK   = [System.Drawing.Color]::FromArgb(31, 31, 31)
$C_BAR    = [System.Drawing.Color]::FromArgb(30, 30, 30)
$C_GRAY   = [System.Drawing.Color]::FromArgb(58, 58, 58)
$C_WHITE  = [System.Drawing.Color]::White
$C_BLACK  = [System.Drawing.Color]::Black

# ---- timing log + single instance lock ----
$script:lockFile = Join-Path $toolDir 'tool.lock'
function Log-Timing($msg) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + ' | ' + $msg
  try {
    $lp = if ($script:logPath) { $script:logPath } else { (Join-Path $toolDir 'timing.log') }
    [IO.File]::AppendAllText($lp, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    # bounded: keep only the last 200 lines
    $lines = [IO.File]::ReadAllLines($lp, [Text.Encoding]::UTF8)
    if ($lines.Count -gt 200) {
      [IO.File]::WriteAllLines($lp, $lines[($lines.Count - 200)..($lines.Count - 1)], (New-Object Text.UTF8Encoding($false)))
    }
  } catch { }
}
function Stop-LockedProcess($lockPath) {
  if (-not (Test-Path $lockPath)) { return }
  try {
    $pidStr = ([IO.File]::ReadAllText($lockPath, [Text.Encoding]::UTF8)).Trim()
    $id = [int]$pidStr
    $p = Get-Process -Id $id -ErrorAction Stop
    if ($p) {
      $ok = $false
      # kill only when this PID really is a DuoPupil process (name + command line),
      # otherwise the stale lock is cleared without touching anything (PID reuse safety)
      if ($p.ProcessName -in @('powershell', 'pwsh')) {
        try {
          $cl = (Get-CimInstance Win32_Process -Filter "ProcessId = $id" -ErrorAction Stop).CommandLine
          $nShot = -join @([char]0x53CC, [char]0x77B3, [char]0x622A, [char]0x56FE)  # screenshot script name
          $nTray = -join @([char]0x53CC, [char]0x77B3, [char]0x6258, [char]0x76D8)  # tray script name
          if ($cl -and ($cl.Contains($nShot) -or $cl.Contains($nTray))) { $ok = $true }
        } catch { }
      }
      if ($ok) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
  } catch { }
  Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

# ---- C# hidden window that receives WM_HOTKEY ----
$refs = @([System.Windows.Forms.Form].Assembly.Location, [System.Drawing.Bitmap].Assembly.Location)
Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class HotkeyForm : Form {
  public const int WM_HOTKEY = 0x0312;
  public const uint MOD_CONTROL = 0x2;
  public const uint MOD_ALT = 0x1;
  public const uint MOD_SHIFT = 0x4;
  public delegate void HotkeyHandler();
  public HotkeyHandler Handler;
  [DllImport("user32.dll")]
  public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll")]
  public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  protected override void WndProc(ref Message m) {
    if (m.Msg == WM_HOTKEY && Handler != null) { Handler(); }
    base.WndProc(ref m);
  }
}
'@

# ---- helpers (handler state via $this / Tag, never function locals) ----
function New-FlatButton($text, $back) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.BackColor = $back
  $b.ForeColor = $C_WHITE
  $b.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 9
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  return $b
}

function Add-WindowButtons($form) {
  $lblPin = New-Object System.Windows.Forms.Label
  $lblPin.Text = ([char]0x25B3)
  $lblPin.ForeColor = $C_WHITE
  $lblPin.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 9
  $lblPin.AutoSize = $true
  $lblPin.Cursor = [System.Windows.Forms.Cursors]::Hand
  $lblPin.Location = New-Object System.Drawing.Point ($form.ClientSize.Width - 96), 5
  $lblPin.Tag = $form
  $lblPin.Add_Click({
    $f = $this.Tag
    if ($f.TopMost) {
      $f.TopMost = $false
      $this.Text = ([char]0x25B3)
    } else {
      $f.TopMost = $true
      $this.Text = ([char]0x25B2)
    }
  })
  $form.Controls.Add($lblPin)

  $lblMin = New-Object System.Windows.Forms.Label
  $lblMin.Text = '-'
  $lblMin.ForeColor = $C_WHITE
  $lblMin.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 12, $([System.Drawing.FontStyle]::Bold), $([System.Drawing.GraphicsUnit]::Pixel), 0
  $lblMin.AutoSize = $true
  $lblMin.Cursor = [System.Windows.Forms.Cursors]::Hand
  $lblMin.Location = New-Object System.Drawing.Point ($form.ClientSize.Width - 62), 2
  $lblMin.Tag = $form
  $lblMin.Add_Click({ $this.Tag.WindowState = 'Minimized' })
  $form.Controls.Add($lblMin)

  $lblX = New-Object System.Windows.Forms.Label
  $lblX.Text = (U 'CLOSE_X')
  $lblX.ForeColor = $C_WHITE
  $lblX.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 12, $([System.Drawing.FontStyle]::Bold), $([System.Drawing.GraphicsUnit]::Pixel), 0
  $lblX.AutoSize = $true
  $lblX.Cursor = [System.Windows.Forms.Cursors]::Hand
  $lblX.Location = New-Object System.Drawing.Point ($form.ClientSize.Width - 32), 2
  $lblX.Tag = $form
  $lblX.Add_Click({ $this.Tag.Close() })
  $form.Controls.Add($lblX)
}

function Enable-Drag($form) {
  $script:dragOn = $false
  $script:dragOff = @(0, 0)
  $form.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:dragOn = $true
      $script:dragOff = @($_.X, $_.Y)
    }
  })
  $form.Add_MouseMove({
    if ($script:dragOn) {
      $this.Location = New-Object System.Drawing.Point(($this.Location.X + $_.X - $script:dragOff[0]), ($this.Location.Y + $_.Y - $script:dragOff[1]))
    }
  })
  $form.Add_MouseUp({ $script:dragOn = $false })
}

function New-CaptureForm {
  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = 'None'
  $f.ShowInTaskbar = $false
  $f.KeyPreview = $true
  $f.Cursor = [System.Windows.Forms.Cursors]::Cross
  $style = [System.Windows.Forms.ControlStyles]::UserPaint -bor `
           [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
           [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
           [System.Windows.Forms.ControlStyles]::ResizeRedraw
  $setStyle = [System.Windows.Forms.Control].GetMethod('SetStyle', [System.Reflection.BindingFlags]'Instance,NonPublic')
  $null = $setStyle.Invoke($f, @($style, $true))
  return $f
}

# ---- position the 3 tool buttons near the current selection ----
function Place-ToolButtons {
  $sel = $script:capSel
  $barW = 276; $barH = 42
  $x = $sel.Right - $barW - 4
  $y = $sel.Bottom - $barH - 4
  if ($sel.Width -lt ($barW + 16) -or $sel.Height -lt ($barH + 16)) {
    $x = $sel.Right - $barW
    $y = $sel.Bottom + 6
    if ($y + $barH -gt $script:capH) { $y = $sel.Bottom - $barH - 6 }
  }
  if ($x -lt 0) { $x = $sel.X }
  if ($y -lt 0) { $y = $sel.Y + 4 }
  if ($y + $barH -gt $script:capH) { $y = $script:capH - $barH - 4 }
  $script:capBtns[0].Location = New-Object System.Drawing.Point ($x + 6), ($y + 6)
  $script:capBtns[1].Location = New-Object System.Drawing.Point ($x + 106), ($y + 6)
  $script:capBtns[2].Location = New-Object System.Drawing.Point ($x + 206), ($y + 6)
}

# ---- OCR function (Windows built-in, local) ----
function Get-OcrText($pngPath) {
  $script:lastOcrStatus = 'ERR'
  $text = ''
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Await-Ocr($WinRtTask, $ResultType) {
      $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
      $netTask = $asTask.Invoke($null, @($WinRtTask))
      $netTask.Wait(-1) | Out-Null
      $netTask.Result
    }
    $f = Await-Ocr ([Windows.Storage.StorageFile]::GetFileFromPathAsync($pngPath)) ([Windows.Storage.StorageFile])
    $s = Await-Ocr ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $d = Await-Ocr ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bmp2 = Await-Ocr ($d.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $engine) {
      $lang = New-Object Windows.Globalization.Language 'zh-Hans'
      $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    }
    if ($engine) {
      $res = Await-Ocr ($engine.RecognizeAsync($bmp2)) ([Windows.Media.Ocr.OcrResult])
      $text = ($res.Lines | ForEach-Object { $_.Text }) -join "`r`n"
      $script:lastOcrStatus = 'OK'
    }
  } catch { $text = '' }
  return $text
}

# ---- save png + ocr txt ----
function Save-Capture($bmp) {
  $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss_fff'
  $pngPath = Join-Path $imgDir ("ScreenShot_$stamp.png")
  if (Test-Path $pngPath) {
    $n = 2
    while (Test-Path (Join-Path $imgDir ("ScreenShot_${stamp}_$n.png"))) { $n++ }
    $stamp = "${stamp}_$n"
    $pngPath = Join-Path $imgDir ("ScreenShot_$stamp.png")
  }
  $bmp.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $text = Get-OcrText $pngPath
  $txtPath = Join-Path $imgDir ("ScreenShot_$stamp.txt")
  [IO.File]::WriteAllText($txtPath, $text, (New-Object Text.UTF8Encoding($false)))
  $lineCount = @($text -split "`r?`n" | Where-Object { $_.Trim() }).Count
  $ocrStatus = 'ERR'
  if ($script:lastOcrStatus -eq 'OK') { if ($lineCount -gt 0) { $ocrStatus = 'OK' } else { $ocrStatus = 'EMPTY' } }
  $status = @(
    ('TIME=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('PNG=ScreenShot_' + $stamp + '.png'),
    ('TXT=ScreenShot_' + $stamp + '.txt'),
    ('OCR_LINES=' + $lineCount),
    ('OCR_STATUS=' + $ocrStatus)
  )
  [IO.File]::WriteAllText((Join-Path $toolDir 'latest.txt'), ($status -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
  # image-code: single mode (1) or multi mode (custom count), per 工具\code.cfg
  $compact = $stamp -replace '[-_]', ''          # 20260816084146
  $code = 'DP-' + $compact.Substring(0,8) + '-' + $compact.Substring(8,6)   # DP-20260816-084146 (same timestamp as filename)
  $pendPath = Join-Path $toolDir 'pending.txt'
  $cc = Get-CodeCfg
  if ($cc.Mode -eq 'single') {
    [IO.File]::WriteAllText($pendPath, $code, (New-Object Text.UTF8Encoding($false)))
    try { Set-Clipboard -Value $code } catch { }
  } else {
    $old = @()
    if (Test-Path $pendPath) {
      $old = @([IO.File]::ReadAllLines($pendPath, [Text.Encoding]::UTF8) | Where-Object { $_ -and $_ -match '^DP-' })
    }
    $queue = @($old) + $code
    if ($queue.Count -gt $cc.Count) { $queue = $queue[($queue.Count - $cc.Count)..($queue.Count - 1)] }
    [IO.File]::WriteAllText($pendPath, ($queue -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    try { Set-Clipboard -Value ($queue -join "`r`n") } catch { }
  }
  # rotation: keep only the latest 50 screenshots (PNG + same-name txt)
  try {
    $shots = @(Get-ChildItem $imgDir -Filter 'ScreenShot_*.png' | Sort-Object Name -Descending)
    if ($shots.Count -gt 50) {
      $shots[50..($shots.Count - 1)] | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        $t = [IO.Path]::ChangeExtension($_.FullName, '.txt')
        if (Test-Path $t) { Remove-Item $t -Force -ErrorAction SilentlyContinue }
      }
    }
  } catch { }
  return @{ Png = $pngPath; Txt = $txtPath; Text = $text }
}

# ---- toast (dark card, bottom-right, auto-close) ----
function Show-Toast($msg) {
  $toast = New-Object System.Windows.Forms.Form
  $toast.FormBorderStyle = 'None'
  $toast.StartPosition = 'Manual'
  $toast.TopMost = $true
  $toast.BackColor = $C_DARK
  $toast.Opacity = 0.95
  $toast.ShowInTaskbar = $false
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = ([char]0x2713) + '  ' + $msg
  $lbl.ForeColor = $C_GREEN
  $lbl.AutoSize = $true
  $lbl.Padding = New-Object System.Windows.Forms.Padding 18, 12, 18, 12
  $lbl.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 10
  $toast.Controls.Add($lbl)
  $toast.ClientSize = New-Object System.Drawing.Size ($lbl.PreferredSize.Width + 36), ($lbl.PreferredSize.Height + 24)
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $toast.SetDesktopLocation($wa.Right - $toast.Width - 24, $wa.Bottom - $toast.Height - 48)
  $tm = New-Object System.Windows.Forms.Timer
  $tm.Interval = 2500
  $tm.Tag = $toast
  $tm.Add_Tick({ $this.Stop(); $this.Tag.Close() })
  $toast.Tag = $tm
  $toast.Show()
  $tm.Start()
}

# ---- OCR result window (dark flat) ----
function Show-OcrWindow($text) {
  $of = New-Object System.Windows.Forms.Form
  $of.Text = (U 'OCR_TITLE')
  $of.FormBorderStyle = 'None'
  $of.StartPosition = 'CenterScreen'
  $of.BackColor = $C_DARK
  $of.ClientSize = New-Object System.Drawing.Size 640, 500
  if ($script:panelRef) { $of.TopMost = $script:panelRef.TopMost }
  $script:focusMe = $of
  Enable-Drag $of
  Add-WindowButtons $of

  $title = New-Object System.Windows.Forms.Label
  $title.Text = (U 'OCR_TITLE')
  $title.ForeColor = $C_WHITE
  $title.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 11, $([System.Drawing.FontStyle]::Bold), $([System.Drawing.GraphicsUnit]::Pixel), 0
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point 14, 10
  $of.Controls.Add($title)

  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Multiline = $true
  $tb.ScrollBars = 'Vertical'
  $tb.ReadOnly = $true
  $tb.BackColor = [System.Drawing.Color]::FromArgb(37, 37, 37)
  $tb.ForeColor = $C_WHITE
  $tb.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 10
  $tb.Location = New-Object System.Drawing.Point 12, 40
  $tb.Size = New-Object System.Drawing.Size 616, 404
  if ($text) { $tb.Text = $text } else { $tb.Text = (U 'OCR_NONE') }
  $of.Controls.Add($tb)

  $btnCopy = New-FlatButton (U 'BTN_COPY') $C_GREEN
  $btnCopy.Location = New-Object System.Drawing.Point 12, 456
  $btnCopy.Size = New-Object System.Drawing.Size 110, 32
  $btnCopy.Tag = $tb
  $btnCopy.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($this.Tag.Text); Show-Toast (U 'BTN_COPY') })
  $btnClose = New-FlatButton (U 'BTN_CLOSE') $C_GRAY
  $btnClose.Location = New-Object System.Drawing.Point 132, 456
  $btnClose.Size = New-Object System.Drawing.Size 90, 32
  $btnClose.Tag = $of
  $btnClose.Add_Click({ $this.Tag.Close() })
  $of.Controls.Add($btnCopy)
  $of.Controls.Add($btnClose)

  $of.ShowDialog() | Out-Null
  $script:focusMe = $null
}

# ---- hotkey config + dynamic registration (tool-owned) ----
$script:cfgPath = Join-Path $toolDir 'hotkey.cfg'
$script:regCombo = $null

function Get-VkCode($token) {
  if ($token -match '^[A-Z]$') { return 65 + ([int][char]$token - 65) }
  if ($token -match '^[0-9]$') { return 48 + [int]$token }
  if ($token -match '^F([1-9]|1[0-2])$') { return 112 + ([int]($token.Substring(1)) - 1) }
  return 0
}

function Register-Combo($combo) {
  if ($script:regCombo) {
    [HotkeyForm]::UnregisterHotKey($hk.Handle, 1) | Out-Null
    $script:regCombo = $null
  }
  if (-not $combo) { return }
  $mods = [uint32]0
  $vk = 0
  foreach ($t in ($combo -split '\+')) {
    switch ($t.Trim()) {
      'CTRL' { $mods = $mods -bor [HotkeyForm]::MOD_CONTROL }
      'ALT' { $mods = $mods -bor [HotkeyForm]::MOD_ALT }
      'SHIFT' { $mods = $mods -bor [HotkeyForm]::MOD_SHIFT }
      default {
        $v = Get-VkCode $t.Trim()
        if ($v) { $vk = $v }
      }
    }
  }
  if ($vk -eq 0) { return }
  if ([HotkeyForm]::RegisterHotKey($hk.Handle, 1, $mods, [uint32]$vk)) {
    $script:regCombo = $combo
    Log-Timing ('HOTKEY_REGISTERED ' + $combo)
  } else {
    Log-Timing ('HOTKEY_REGISTER_FAILED ' + $combo)
  }
}

function Sync-HotkeyFromCfg {
  $want = ''
  if (Test-Path $script:cfgPath) { $want = ([IO.File]::ReadAllText($script:cfgPath, [Text.Encoding]::UTF8)).Trim() }
  if ($want -ne $script:regCombo) { Register-Combo $want }
}

function Set-HotkeyCfg($hotkey) {
  [IO.File]::WriteAllText($script:cfgPath, [string]$hotkey, (New-Object Text.UTF8Encoding($false)))
}

function Refresh-HwStatus($st) {
  $want = ''
  if (Test-Path $script:cfgPath) { $want = ([IO.File]::ReadAllText($script:cfgPath, [Text.Encoding]::UTF8)).Trim() }
  if ($want) { $st.Status.Text = (U 'HW_CURRENT') + ': ' + $want }
  else { $st.Status.Text = (U 'HW_NONE') }
}

# ---- image-code settings (mode + count in 工具\code.cfg) ----
function Get-CodeCfg {
  $cfg = @{ Mode = 'single'; Count = 10 }
  $cp = Join-Path $toolDir 'code.cfg'
  if (Test-Path $cp) {
    try {
      foreach ($l in [IO.File]::ReadAllLines($cp, [Text.Encoding]::UTF8)) {
        if ($l -match '^MODE=(.*)$') { $cfg.Mode = $Matches[1] }
        if ($l -match '^COUNT=(\d+)$') { $cfg.Count = [int]$Matches[1] }
      }
    } catch { }
  }
  if ($cfg.Mode -ne 'single') { $cfg.Mode = 'multi' }
  if ($cfg.Count -lt 1) { $cfg.Count = 1 }
  if ($cfg.Count -gt 50) { $cfg.Count = 50 }
  return $cfg
}
function Set-CodeCfg($mode, $count) {
  $cp = Join-Path $toolDir 'code.cfg'
  [IO.File]::WriteAllText($cp, ('MODE=' + $mode + "`r`nCOUNT=" + $count), (New-Object Text.UTF8Encoding($false)))
}
function Refresh-CdStatus($st) {
  $cc = Get-CodeCfg
  if ($cc.Mode -eq 'single') { $st.Status.Text = (U 'CD_OFF') }
  else { $st.Status.Text = (U 'CD_ON') + ' ' + $cc.Count }
  $st.Input.Text = [string]$cc.Count
}
function Show-CodeWindow {
  $cw = New-Object System.Windows.Forms.Form
  $cw.Text = (U 'CD_TITLE')
  $cw.FormBorderStyle = 'None'
  $cw.StartPosition = 'CenterScreen'
  $cw.BackColor = $C_DARK
  $cw.ClientSize = New-Object System.Drawing.Size 380, 240
  if ($script:panelRef) { $cw.TopMost = $script:panelRef.TopMost }
  Enable-Drag $cw
  Add-WindowButtons $cw

  $title = New-Object System.Windows.Forms.Label
  $title.Text = (U 'CD_TITLE')
  $title.ForeColor = $C_WHITE
  $title.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 11, $([System.Drawing.FontStyle]::Bold), $([System.Drawing.GraphicsUnit]::Pixel), 0
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point 14, 10
  $cw.Controls.Add($title)

  $lblStatus = New-Object System.Windows.Forms.Label
  $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
  $lblStatus.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 9
  $lblStatus.AutoSize = $true
  $lblStatus.Location = New-Object System.Drawing.Point 14, 44
  $cw.Controls.Add($lblStatus)

  $tb = New-Object System.Windows.Forms.TextBox
  $tb.BackColor = [System.Drawing.Color]::FromArgb(37, 37, 37)
  $tb.ForeColor = $C_WHITE
  $tb.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 9
  $tb.Location = New-Object System.Drawing.Point 14, 78
  $tb.Size = New-Object System.Drawing.Size 90, 26
  $cw.Controls.Add($tb)

  $st = @{ Form = $cw; Status = $lblStatus; Input = $tb }
  $cw.Tag = $st

  $btnApply = New-FlatButton (U 'CD_APPLY') $C_GREEN
  $btnApply.Location = New-Object System.Drawing.Point 112, 77
  $btnApply.Size = New-Object System.Drawing.Size 100, 28
  $btnApply.Tag = $st
  $btnApply.Add_Click({
    $n = 10
    try { $n = [int]$this.Tag.Input.Text } catch { }
    if ($n -lt 1) { $n = 1 }
    if ($n -gt 50) { $n = 50 }
    Set-CodeCfg 'multi' $n
    Refresh-CdStatus $this.Tag
    Show-Toast (U 'CD_UPDATED')
  })
  $cw.Controls.Add($btnApply)

  $btnToggle = New-FlatButton (U 'CD_TOGGLE') $C_GRAY
  $btnToggle.Location = New-Object System.Drawing.Point 14, 116
  $btnToggle.Size = New-Object System.Drawing.Size 140, 30
  $btnToggle.Tag = $st
  $btnToggle.Add_Click({
    $cc = Get-CodeCfg
    if ($cc.Mode -eq 'single') { Set-CodeCfg 'multi' $cc.Count } else { Set-CodeCfg 'single' $cc.Count }
    Refresh-CdStatus $this.Tag
    Show-Toast (U 'CD_UPDATED')
  })
  $cw.Controls.Add($btnToggle)

  $btnClear = New-FlatButton (U 'HW_CLEAR') $C_GRAY
  $btnClear.Location = New-Object System.Drawing.Point 162, 116
  $btnClear.Size = New-Object System.Drawing.Size 100, 30
  $btnClear.Tag = $st
  $btnClear.Add_Click({
    [IO.File]::WriteAllText((Join-Path $toolDir 'pending.txt'), '', (New-Object Text.UTF8Encoding($false)))
    try { Set-Clipboard -Value '' } catch { }
    Show-Toast (U 'HW_CLEARED')
  })
  $cw.Controls.Add($btnClear)

  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = (U 'CD_HINT')
  $hint.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
  $hint.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 8
  $hint.AutoSize = $true
  $hint.Location = New-Object System.Drawing.Point 14, 160
  $cw.Controls.Add($hint)

  Refresh-CdStatus $st
  $cw.ShowDialog() | Out-Null
}

# ---- hotkey settings window (press-to-capture) ----
function Show-HotkeyWindow {
  $hw = New-Object System.Windows.Forms.Form
  $hw.Text = (U 'HW_TITLE')
  $hw.FormBorderStyle = 'None'
  $hw.StartPosition = 'CenterScreen'
  $hw.BackColor = $C_DARK
  $hw.ClientSize = New-Object System.Drawing.Size 380, 240
  if ($script:panelRef) { $hw.TopMost = $script:panelRef.TopMost }
  Enable-Drag $hw
  Add-WindowButtons $hw
  $hw.KeyPreview = $true
  $hw.Add_KeyDown({
    if (-not $script:hwCapture) { return }
    $_.SuppressKeyPress = $true
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
      $script:hwCapture = $false
      $this.Tag.Status.Text = (U 'HW_CANCEL_CAPTURE')
      return
    }
    $parts = @()
    if ($_.Control) { $parts += 'CTRL' }
    if ($_.Alt) { $parts += 'ALT' }
    if ($_.Shift) { $parts += 'SHIFT' }
    $k = $_.KeyCode
    $keyStr = $null
    if ($k -ge [System.Windows.Forms.Keys]::A -and $k -le [System.Windows.Forms.Keys]::Z) { $keyStr = [string]$k }
    elseif ($k -ge [System.Windows.Forms.Keys]::D0 -and $k -le [System.Windows.Forms.Keys]::D9) { $keyStr = ([int]$k - [int][System.Windows.Forms.Keys]::D0).ToString() }
    elseif ($k -ge [System.Windows.Forms.Keys]::F1 -and $k -le [System.Windows.Forms.Keys]::F24) { $keyStr = 'F' + ([int]$k - [int][System.Windows.Forms.Keys]::F1 + 1) }
    if (-not $keyStr) { $this.Tag.Status.Text = (U 'HW_BADKEY'); return }
    if (($parts -notcontains 'CTRL') -and ($parts -notcontains 'ALT')) { $this.Tag.Status.Text = (U 'HW_BADKEY'); return }
    $combo = ($parts + $keyStr) -join '+'
    Set-HotkeyCfg $combo
    $script:hwCapture = $false
    Refresh-HwStatus $this.Tag
    Show-Toast (U 'HW_OK')
  })

  $title = New-Object System.Windows.Forms.Label
  $title.Text = (U 'HW_TITLE')
  $title.ForeColor = $C_WHITE
  $title.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 11, $([System.Drawing.FontStyle]::Bold), $([System.Drawing.GraphicsUnit]::Pixel), 0
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point 14, 10
  $hw.Controls.Add($title)

  $lblStatus = New-Object System.Windows.Forms.Label
  $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
  $lblStatus.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 9
  $lblStatus.AutoSize = $true
  $lblStatus.Location = New-Object System.Drawing.Point 14, 44
  $hw.Controls.Add($lblStatus)

  $st = @{ Form = $hw; Status = $lblStatus }
  $hw.Tag = $st

  $btnCapture = New-FlatButton (U 'HW_PRESS') $C_GREEN
  $btnCapture.Location = New-Object System.Drawing.Point 14, 78
  $btnCapture.Size = New-Object System.Drawing.Size 240, 30
  $btnCapture.Tag = $st
  $btnCapture.Add_Click({
    $script:hwCapture = $true
    $this.Tag.Status.Text = (U 'HW_LISTEN')
    $this.Tag.Form.Focus()
  })
  $hw.Controls.Add($btnCapture)

  $btnEnable = New-FlatButton (U 'HW_ENABLE') $C_GRAY
  $btnEnable.Location = New-Object System.Drawing.Point 14, 116
  $btnEnable.Size = New-Object System.Drawing.Size 110, 30
  $btnEnable.Tag = $st
  $btnEnable.Add_Click({ Set-HotkeyCfg 'CTRL+ALT+S'; Refresh-HwStatus $this.Tag; Show-Toast (U 'HW_OK') })
  $hw.Controls.Add($btnEnable)

  $btnDisable = New-FlatButton (U 'HW_DISABLE') $C_GRAY
  $btnDisable.Location = New-Object System.Drawing.Point 132, 116
  $btnDisable.Size = New-Object System.Drawing.Size 110, 30
  $btnDisable.Tag = $st
  $btnDisable.Add_Click({ Set-HotkeyCfg ''; Refresh-HwStatus $this.Tag; Show-Toast (U 'HW_OK') })
  $hw.Controls.Add($btnDisable)

  $btnCode = New-FlatButton (U 'BTN_CODE_SET') $C_GRAY
  $btnCode.Location = New-Object System.Drawing.Point 14, 154
  $btnCode.Size = New-Object System.Drawing.Size 240, 30
  $btnCode.Tag = $st
  $btnCode.Add_Click({ Show-CodeWindow })
  $hw.Controls.Add($btnCode)

  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = (U 'HW_HINT')
  $hint.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
  $hint.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 8
  $hint.AutoSize = $true
  $hint.Location = New-Object System.Drawing.Point 14, 196
  $hw.Controls.Add($hint)

  Refresh-HwStatus $st
  $hw.ShowDialog() | Out-Null
}

# ---- capture flow (WeChat-style, movable selection) ----
function Invoke-Capture {
  try {
  Log-Timing 'CAPTURE_ENTER'
  $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $script:capH = $bounds.Height
  $script:capBg = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  $gfx = [System.Drawing.Graphics]::FromImage($script:capBg)
  $gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $gfx.Dispose()

  $script:capDimBg = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  $dg = [System.Drawing.Graphics]::FromImage($script:capDimBg)
  $dg.DrawImage($script:capBg, 0, 0, $bounds.Width, $bounds.Height)
  $dimBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 0, 0, 0))
  $dg.FillRectangle($dimBrush, 0, 0, $bounds.Width, $bounds.Height)
  $dimBrush.Dispose()
  $dg.Dispose()

  $script:phase = 'idle'
  $script:capSel = $null
  $script:origSel = $null
  $script:startPt = New-Object System.Drawing.Point 0, 0

  $cap = New-CaptureForm
  $cap.Bounds = $bounds
  $cap.TopMost = $true
  $script:focusMe = $cap

  $script:capBtns = @(
    (New-FlatButton (U 'BTN_SAVE') $C_GREEN),
    (New-FlatButton (U 'BTN_EXTRACT') $C_GRAY),
    (New-FlatButton (U 'BTN_EXIT') $C_GRAY)
  )
  $script:capBtns[0].Size = New-Object System.Drawing.Size 96, 30
  $script:capBtns[0].DialogResult = 'Yes'
  $script:capBtns[1].Size = New-Object System.Drawing.Size 96, 30
  $script:capBtns[1].DialogResult = 'No'
  $script:capBtns[2].Size = New-Object System.Drawing.Size 64, 30
  $script:capBtns[2].DialogResult = 'Abort'
  foreach ($b in $script:capBtns) { $b.Visible = $false; $cap.Controls.Add($b) }

  $cap.Add_MouseDown({
    if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:phase -eq 'done' -and $script:capSel.Contains($_.Location)) {
      $script:phase = 'moving'
      $script:origSel = $script:capSel
      $script:startPt = $_.Location
      foreach ($b in $script:capBtns) { $b.Visible = $false }
    } else {
      $script:phase = 'drawing'
      $script:startPt = $_.Location
      foreach ($b in $script:capBtns) { $b.Visible = $false }
    }
  })
  $cap.Add_MouseMove({
    if ($script:phase -eq 'drawing' -or $script:phase -eq 'moving') {
      if ($script:phase -eq 'moving') {
        $cur = $this.PointToClient([System.Windows.Forms.Cursor]::Position)
        $dx = $cur.X - $script:startPt.X
        $dy = $cur.Y - $script:startPt.Y
        $nx = $script:origSel.X + $dx
        $ny = $script:origSel.Y + $dy
        if ($nx -lt 0) { $nx = 0 }
        if ($ny -lt 0) { $ny = 0 }
        if ($nx + $script:origSel.Width -gt $this.Width) { $nx = $this.Width - $script:origSel.Width }
        if ($ny + $script:origSel.Height -gt $this.Height) { $ny = $this.Height - $script:origSel.Height }
        $script:capSel = New-Object System.Drawing.Rectangle $nx, $ny, $script:origSel.Width, $script:origSel.Height
      }
      $this.Invalidate()
    }
  })
  $cap.Add_Paint({
    $g = $_.Graphics
    $g.DrawImage($script:capDimBg, 0, 0, $this.Width, $this.Height)
    $rect = $null
    if ($script:phase -eq 'drawing') {
      $cur = $this.PointToClient([System.Windows.Forms.Cursor]::Position)
      $rect = New-Object System.Drawing.Rectangle(
        [Math]::Min($script:startPt.X, $cur.X),
        [Math]::Min($script:startPt.Y, $cur.Y),
        [Math]::Abs($cur.X - $script:startPt.X),
        [Math]::Abs($cur.Y - $script:startPt.Y))
    } elseif ($script:phase -eq 'done' -or $script:phase -eq 'moving') {
      $rect = $script:capSel
    }
    if ($rect) {
      $g.DrawImage($script:capBg, $rect, $rect, $([System.Drawing.GraphicsUnit]::Pixel))
      $pen = New-Object System.Drawing.Pen($C_GREEN, 2)
      $g.DrawRectangle($pen, $rect.X, $rect.Y, $rect.Width - 1, $rect.Height - 1)
      $pen.Dispose()
      $fnt = New-Object System.Drawing.Font 'Microsoft YaHei', 9
      $txt = "$($rect.Width) x $($rect.Height)"
      $sz = $g.MeasureString($txt, $fnt)
      $lx = $rect.Right - $sz.Width - 10
      $ly = $rect.Y - $sz.Height - 8
      if ($ly -lt 0) { $ly = $rect.Y + 4 }
      $g.FillRectangle((New-Object System.Drawing.SolidBrush($C_BLACK)), $lx - 5, $ly, $sz.Width + 10, $sz.Height + 4)
      $g.DrawString($txt, $fnt, [System.Drawing.Brushes]::White, $lx, $ly + 2)
      $fnt.Dispose()
    } else {
      $fnt = New-Object System.Drawing.Font 'Microsoft YaHei', 10
      $hint = (U 'HINT_CAPTURE')
      $sz = $g.MeasureString($hint, $fnt)
      $hx = [Math]::Max(0, [int](($this.Width - $sz.Width) / 2))
      $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(160, 0, 0, 0))), $hx - 10, 14, $sz.Width + 20, $sz.Height + 10)
      $g.DrawString($hint, $fnt, [System.Drawing.Brushes]::White, $hx, 19)
      $fnt.Dispose()
    }
  })
  $cap.Add_MouseUp({
    if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:phase -eq 'drawing') {
      $cur = $this.PointToClient([System.Windows.Forms.Cursor]::Position)
      $w = [Math]::Abs($cur.X - $script:startPt.X)
      $h = [Math]::Abs($cur.Y - $script:startPt.Y)
      if ($w -lt 5 -or $h -lt 5) {
        $script:capSel = $this.ClientRectangle
      } else {
        $script:capSel = New-Object System.Drawing.Rectangle(
          [Math]::Min($script:startPt.X, $cur.X),
          [Math]::Min($script:startPt.Y, $cur.Y), $w, $h)
      }
      $script:phase = 'done'
      Place-ToolButtons
      foreach ($b in $script:capBtns) { $b.Visible = $true }
      $this.Invalidate()
    } elseif ($script:phase -eq 'moving') {
      $script:phase = 'done'
      Place-ToolButtons
      foreach ($b in $script:capBtns) { $b.Visible = $true }
      $this.Invalidate()
    }
  })
  $cap.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
      $this.DialogResult = 'Abort'; $this.Close()
    }
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
      if ($script:phase -eq 'idle' -or $script:phase -eq 'drawing') {
        $script:capSel = $this.ClientRectangle
        $script:phase = 'done'
        Place-ToolButtons
        foreach ($b in $script:capBtns) { $b.Visible = $true }
        $this.Invalidate()
      } else {
        $this.DialogResult = 'Yes'; $this.Close()
      }
    }
  })

  Log-Timing 'OVERLAY_SHOWING'
  $r = $cap.ShowDialog()
  $script:focusMe = $null
  $cap.Dispose()
  $script:capDimBg.Dispose()
  if ($r -ne 'Yes' -and $r -ne 'No') { $script:capBg.Dispose(); return }

  $sel = $script:capSel
  $crop = New-Object System.Drawing.Bitmap $sel.Width, $sel.Height
  $cg = [System.Drawing.Graphics]::FromImage($crop)
  $cg.DrawImage($script:capBg, (New-Object System.Drawing.Rectangle 0, 0, $sel.Width, $sel.Height), $sel, $([System.Drawing.GraphicsUnit]::Pixel))
  $cg.Dispose()
  $script:capBg.Dispose()

  $saved = Save-Capture $crop
  $crop.Dispose()
  if ($r -eq 'No') { Show-OcrWindow $saved.Text } else { Show-Toast (U 'TOAST_SAVED') }
  } finally {
    $script:phase = 'idle'
    $script:focusMe = $null
  }
}

# ---- instant fullscreen capture (whole virtual desktop, no selection UI) ----
function Invoke-CaptureFull {
  try {
    Log-Timing 'CAPTURE_FULL_ENTER'
    $script:phase = 'busy'
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $script:capH = $bounds.Height
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $gfx.Dispose()
    $saved = Save-Capture $bmp
    $bmp.Dispose()
    Show-Toast (U 'TOAST_SAVED')
  } finally {
    $script:phase = 'idle'
    $script:focusMe = $null
  }
}

# ---- main ----
if (-not $DotSource) {
if ($Mode -eq 'capture') {
  Invoke-Capture
  exit 0
}

# overwrite-style single instance: kill any old panel/tray, then start fresh
Stop-LockedProcess $script:lockFile
Stop-LockedProcess (Join-Path $toolDir 'tray.lock')
Set-Content -Path $script:lockFile -Value ([string]$PID) -Encoding utf8
Log-Timing 'PANEL_START'

$panel = New-Object System.Windows.Forms.Form
$script:panelRef = $panel
$panel.FormBorderStyle = 'None'
$panel.StartPosition = 'CenterScreen'
$panel.BackColor = $C_DARK
$panel.ClientSize = New-Object System.Drawing.Size 300, 360
Enable-Drag $panel
Add-WindowButtons $panel

$title = New-Object System.Windows.Forms.Label
$title.Text = (U 'PANEL_TITLE')
$title.ForeColor = $C_WHITE
$title.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 14, $([System.Drawing.FontStyle]::Bold), $([System.Drawing.GraphicsUnit]::Pixel), 0
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point 16, 12
$panel.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = (U 'SUB_PANEL')
$sub.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
$sub.Font = New-Object System.Drawing.Font 'Microsoft YaHei', 8
$sub.AutoSize = $true
$sub.Location = New-Object System.Drawing.Point 18, 44
$panel.Controls.Add($sub)

# ---- hotkey: tray owns it when running, otherwise the panel registers ----
if (-not (Test-Path $script:cfgPath)) {
  [IO.File]::WriteAllText($script:cfgPath, 'CTRL+ALT+S', (New-Object Text.UTF8Encoding($false)))
}
$hk = $null
$trayActive = $false
try {
  $tl = Join-Path $toolDir 'tray.lock'
  if (Test-Path $tl) {
    $tp = [int](([IO.File]::ReadAllText($tl, [Text.Encoding]::UTF8)).Trim())
    $trayActive = ($null -ne (Get-Process -Id $tp -ErrorAction SilentlyContinue))
  }
} catch { }
if (-not $trayActive) {
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
        if ($script:panelRef) { $script:panelRef.Activate() }
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
  $script:trayHandover = $false
  $script:poll = New-Object System.Windows.Forms.Timer
  $script:poll.Interval = 1000
  $script:poll.Add_Tick({ if (-not $script:trayHandover) { Sync-HotkeyFromCfg } })
  $script:poll.Start()
} else {
  Log-Timing 'PANEL_SKIP_HOTKEY_TRAY_ACTIVE'
}
$panel.Add_FormClosed({
  if ($script:regCombo -and $hk) { [HotkeyForm]::UnregisterHotKey($hk.Handle, 1) | Out-Null }
  if ($script:poll) { $script:poll.Stop(); $script:poll.Dispose() }
  if ($hk) { $hk.Dispose() }
  Log-Timing 'PANEL_CLOSED'
  Remove-Item $script:lockFile -Force -ErrorAction SilentlyContinue
})

$specs = @(
  @{ T = (U 'BTN_REGION'); C = $C_GRAY;  A = { Invoke-Capture; if ($script:panelRef) { $script:panelRef.Activate() } } },
  @{ T = (U 'BTN_FULL');   C = $C_GRAY;  A = { Invoke-CaptureFull; if ($script:panelRef) { $script:panelRef.Activate() } } },
  @{ T = (U 'BTN_TRAY');   C = $C_GRAY;  A = {
        $script:trayHandover = $true
        if ($script:poll) { $script:poll.Stop(); $script:poll.Dispose(); $script:poll = $null }
        if ($script:regCombo -and $hk) {
          [HotkeyForm]::UnregisterHotKey($hk.Handle, 1) | Out-Null
          $script:regCombo = $null
          Log-Timing 'PANEL_RELEASED_HOTKEY_FOR_TRAY'
        }
        $tn = (-join @([char]0x53CC, [char]0x77B3, [char]0x6258, [char]0x76D8)) + '.ps1'   # 双瞳托盘.ps1
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-File', ('"' + (Join-Path $toolDir $tn) + '"')
      } },
  @{ T = (U 'BTN_FOLDER'); C = $C_GRAY;  A = { Start-Process explorer.exe -ArgumentList $imgDir } },
  @{ T = (U 'BTN_HELP');   C = $C_GRAY;  A = { [System.Windows.Forms.MessageBox]::Show((U 'HELP_TEXT'), (U 'BTN_HELP')) } },
  @{ T = (U 'BTN_HOTKEY'); C = $C_GRAY;  A = { Show-HotkeyWindow } }
)
$y = 72
foreach ($s in $specs) {
  $btn = New-FlatButton $s.T $s.C
  $btn.Width = 268
  $btn.Height = 40
  $btn.Location = New-Object System.Drawing.Point 16, $y
  $btn.Add_Click($s.A)
  $panel.Controls.Add($btn)
  $y += 48
}
$panel.ShowDialog() | Out-Null
}
