# ============================================================
# DuoPupil VL caller (deterministic DashScope request builder)
# - input : image path + question file (UTF-8) + slot A/B/C
# - output: answer file (UTF-8), raw response file, ASCII status on stdout
# - never prints the key, never prints Chinese to the console
# - run with: powershell -NoProfile -ExecutionPolicy Bypass -File <this script> ...
# ============================================================
param(
  [Parameter(Mandatory = $true)][string]$ImagePath,
  [Parameter(Mandatory = $true)][string]$QuestionFile,
  [ValidateSet('A', 'B', 'C')][string]$Slot = 'A',
  [string]$KeyFile = '',
  [string]$SlotFile = '',
  [string]$AnswerFile = '',
  [string]$RawFile = '',
  [string]$ReqFile = '',
  [int]$TimeoutSec = 120,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
$rootDir = Split-Path -Parent $toolDir
# Chinese file names are built from char codes: this source must stay 100% ASCII
# (a UTF-8 ps1 without BOM is read as GBK by Windows PowerShell 5.1, which corrupts literals)
$keyName  = -join @([char]0x6A21, [char]0x578B) + '.txt'
$slotName = -join @([char]0x69FD, [char]0x4F4D, [char]0x914D, [char]0x7F6E) + '.txt'
if (-not $KeyFile)    { $KeyFile    = Join-Path $rootDir $keyName }
if (-not $SlotFile)   { $SlotFile   = Join-Path $rootDir $slotName }
if (-not $AnswerFile) { $AnswerFile = Join-Path $toolDir 'answer.txt' }
if (-not $RawFile)    { $RawFile    = Join-Path $toolDir 'resp.json' }
if (-not $ReqFile)    { $ReqFile    = Join-Path $toolDir 'req.json' }
$errFile = Join-Path $toolDir 'err-last.txt'

function Fail($code) {
  Write-Output ('STATUS=ERR CODE=' + $code)
  exit 1
}

# ---- read API key (first line that looks like a key; never echoed) ----
try {
  $key = ''
  if (Test-Path $KeyFile) {
    $lines = [IO.File]::ReadAllLines($KeyFile, [Text.Encoding]::UTF8)
    foreach ($ln in $lines) {
      $t = $ln.Trim()
      if ($t -match '^sk-\S{8,}$') { $key = $t; break }
    }
  }
  if (-not $key) { Fail 'NO_KEY' }
} catch { Fail 'NO_KEY' }

# ---- resolve slot model code (placeholder lines are skipped) ----
try {
  $model = ''
  if (Test-Path $SlotFile) {
    $lines = [IO.File]::ReadAllLines($SlotFile, [Text.Encoding]::UTF8)
    foreach ($ln in $lines) {
      $m = [regex]::Match($ln.Trim(), '^\s*' + $Slot + '\s*=\s*(.+?)\s*$')
      if ($m.Success) {
        $v = $m.Groups[1].Value
        if ($v -match '^[A-Za-z0-9][A-Za-z0-9._\-:]*$') { $model = $v; break }
      }
    }
  }
  if (-not $model) { Fail ('NO_SLOT_' + $Slot) }
} catch { Fail ('NO_SLOT_' + $Slot) }

# ---- question from UTF-8 file ----
try {
  if (-not (Test-Path $QuestionFile)) { Fail 'NO_QUESTION_FILE' }
  $question = [IO.File]::ReadAllText($QuestionFile, [Text.Encoding]::UTF8)
  if (-not $question.Trim()) { Fail 'EMPTY_QUESTION' }
} catch { Fail 'EMPTY_QUESTION' }

# ---- image to data URL ----
try {
  if (-not (Test-Path $ImagePath)) { Fail 'NO_IMAGE' }
  $ext = [IO.Path]::GetExtension($ImagePath).ToLower()
  $mime = 'image/png'
  if ($ext -in @('.jpg', '.jpeg')) { $mime = 'image/jpeg' }
  elseif ($ext -eq '.webp') { $mime = 'image/webp' }
  elseif ($ext -eq '.gif') { $mime = 'image/gif' }
  elseif ($ext -eq '.bmp') { $mime = 'image/bmp' }
  $imgB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ImagePath))
  $dataUrl = 'data:' + $mime + ';base64,' + $imgB64
} catch { Fail 'NO_IMAGE' }

# ---- build request (hashtable -> JSON -> UTF-8 bytes) ----
$body = @{
  model      = $model
  modalities = @('text')
  messages   = @(
    @{
      role    = 'user'
      content = @(
        @{ type = 'image_url'; image_url = @{ url = $dataUrl } },
        @{ type = 'text';      text      = $question }
      )
    }
  )
}
$json = $body | ConvertTo-Json -Depth 10 -Compress
$jsonBytes = [Text.Encoding]::UTF8.GetBytes($json)

if ($DryRun) {
  [IO.File]::WriteAllBytes($ReqFile, $jsonBytes)
  Write-Output ('STATUS=DRYRUN MODEL=' + $model + ' REQ_FILE=' + [IO.Path]::GetFileName($ReqFile) + ' BYTES=' + $jsonBytes.Length)
  exit 0
}

# ---- send (TLS 1.2, UTF-8 bytes, raw response to disk) ----
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $r = Invoke-WebRequest -UseBasicParsing -Uri 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions' `
    -Method Post -Headers @{ Authorization = ('Bearer ' + $key) } `
    -ContentType 'application/json; charset=utf-8' -Body $jsonBytes -TimeoutSec $TimeoutSec
  $respBytes = $r.RawContentStream.ToArray()
  [IO.File]::WriteAllBytes($RawFile, $respBytes)
} catch {
  try { [IO.File]::WriteAllText($errFile, ($_ | Out-String), (New-Object Text.UTF8Encoding($false))) } catch { }
  Write-Output 'STATUS=ERR CODE=HTTP_ERR DETAIL_FILE=err-last.txt'
  exit 1
}

# ---- parse answer + usage ----
try {
  $rj = [Text.Encoding]::UTF8.GetString($respBytes) | ConvertFrom-Json
  $content = $rj.choices[0].message.content
  if ($content -is [System.Array]) {
    $parts = @($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
    $content = $parts -join "`n"
  }
  if ($null -eq $content) { $content = '' }
  $u = $rj.usage
  $ti = if ($null -ne $u.input_tokens) { $u.input_tokens } else { $u.prompt_tokens }
  $to = if ($null -ne $u.output_tokens) { $u.output_tokens } else { $u.completion_tokens }
  $tt = $u.total_tokens
  [IO.File]::WriteAllText($AnswerFile, ([string]$content), (New-Object Text.UTF8Encoding($false)))
  Write-Output ('STATUS=OK MODEL=' + $model + ' TOKENS_IN=' + $ti + ' TOKENS_OUT=' + $to + ' TOKENS_TOTAL=' + $tt + ' ANSWER_FILE=answer.txt RAW_FILE=resp.json')
} catch {
  try { [IO.File]::WriteAllText($errFile, ($_ | Out-String), (New-Object Text.UTF8Encoding($false))) } catch { }
  Write-Output 'STATUS=ERR CODE=JSON_ERR DETAIL_FILE=err-last.txt'
  exit 1
}
