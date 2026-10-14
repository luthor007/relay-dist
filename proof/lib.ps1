# What every proof step shares. Dot-source it: . .\proof\lib.ps1
#
# A step prints only its checks' result lines (PASS / FAIL / N/A, one per
# check); everything it saw goes to out\proof.log and the other files in out\,
# which the workflow keeps as an artifact.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
if (-not ('ProofInput' -as [type])) {
  Add-Type -TypeDefinition (Get-Content -Raw "$PSScriptRoot\native.cs") -Language CSharp
}

$Out = Join-Path (Get-Location) 'out'
New-Item -ItemType Directory -Force $Out | Out-Null
$RelayDir = "$env:LOCALAPPDATA\Relay"
$InstallDir = "$env:LOCALAPPDATA\Programs\Relay"
$App = "$InstallDir\RelayApp.exe"
$AppLog = "$RelayDir\Logs\relayapp.log"
$RelaydLog = "$RelayDir\Logs\relayd.log"
$Base = 'http://127.0.0.1:8787'
$StubPort = 4545
$WorkDir = 'C:\proof'

function Log($s) {
  $line = "$(Get-Date -Format 'HH:mm:ss.fff') $s"
  Add-Content -Path "$Out\proof.log" -Value $line -Encoding UTF8
}

# Expect names the checks a step will report, so the verdict can tell a
# check that never reported from one that passed.
function Expect([string[]]$ids) {
  foreach ($id in $ids) { Add-Content -Path "$Out\expected.txt" -Value $id -Encoding UTF8 }
}

# Result reports one check: $ok $true (PASS), $false (FAIL) or $null (N/A:
# it cannot be proven here, and $why says exactly what and why).
function Result([string]$id, $ok, [string]$what, [string]$why = '') {
  $tag = if ($ok -eq $true) { 'PASS' } elseif ($ok -eq $false) { 'FAIL' } else { 'N/A ' }
  $line = "$tag $id $what"
  if ($why) { $line += " -- $why" }
  Write-Output $line
  Add-Content -Path "$Out\results.txt" -Value $line -Encoding UTF8
  Log $line
}

function Shot($name) {
  try {
    $s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $s.Width, $s.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($s.Location, [System.Drawing.Point]::Empty, $s.Size)
    $bmp.Save("$Out\$name.png"); $g.Dispose(); $bmp.Dispose()
  } catch { Log "screenshot $name failed: $($_.Exception.Message)" }
}

# relayd's token, from its file each time (as the desk reads it), and the
# copy setup kept outside the artifacts when the file cannot be read.
$TokenKeep = "$env:RUNNER_TEMP\proof-api-token"
function Token {
  try { $t = [IO.File]::ReadAllText("$RelayDir\api-token").Trim(); if ($t) { return $t } }
  catch { if (-not $script:TokenReadLogged) { $script:TokenReadLogged = $true; Log "api-token unreadable: $($_.Exception.Message)" } }
  if (Test-Path $TokenKeep) { return (Get-Content $TokenKeep -Raw).Trim() }
  return ''
}
# Why a call was refused, once: the token file's state against the copy kept
# at setup, and its folder's access list.
function TokenDiagnosis {
  if ($script:TokenDiagnosed) { return }
  $script:TokenDiagnosed = $true
  $now = ''; try { $now = [IO.File]::ReadAllText("$RelayDir\api-token").Trim() } catch { $now = "unreadable: $($_.Exception.Message)" }
  $kept = if (Test-Path $TokenKeep) { (Get-Content $TokenKeep -Raw).Trim() } else { '' }
  $same = ($now -eq $kept)
  Log "401 diagnosis: api-token length $($now.Length), same as at setup: $same, written $((Get-Item "$RelayDir\api-token" -ErrorAction SilentlyContinue).LastWriteTimeUtc.ToString('o'))"
  (icacls "$RelayDir\api-token" 2>&1) + (icacls "$RelayDir" 2>&1) | ForEach-Object { Log "  icacls: $_" }
  Get-Process relayd -ErrorAction SilentlyContinue | ForEach-Object { Log "  relayd pid $($_.Id) started $($_.StartTime.ToUniversalTime().ToString('o'))" }
}

# Api calls this PC's relayd with its own token. Returns the decoded body, or
# $null with the failure logged.
function Api([string]$method, [string]$path, $body = $null, [int]$timeout = 20) {
  $h = @{ Authorization = "Bearer $(Token)" }
  try {
    if ($null -ne $body) {
      $json = $body | ConvertTo-Json -Depth 8 -Compress
      return Invoke-RestMethod -Method $method -Uri "$Base$path" -Headers $h -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $timeout
    }
    return Invoke-RestMethod -Method $method -Uri "$Base$path" -Headers $h -TimeoutSec $timeout
  } catch {
    $code = ''; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    $msg = $_.ErrorDetails.Message; if (-not $msg) { $msg = $_.Exception.Message }
    Log "api $method $path -> $code $msg"
    $script:LastApiError = "$code $msg"
    if ($code -eq 401) {
      TokenDiagnosis
      # Once more with the token as it was at setup, when that differs.
      $kept = if (Test-Path $TokenKeep) { (Get-Content $TokenKeep -Raw).Trim() } else { '' }
      if ($kept -and $kept -ne (Token)) {
        try {
          $h = @{ Authorization = "Bearer $kept" }
          if ($null -ne $body) { return Invoke-RestMethod -Method $method -Uri "$Base$path" -Headers $h -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8 -Compress))) -TimeoutSec $timeout }
          return Invoke-RestMethod -Method $method -Uri "$Base$path" -Headers $h -TimeoutSec $timeout
        } catch { Log "api $method $path with the setup token -> $($_.Exception.Message)" }
      }
    }
    return $null
  }
}

function Healthy { try { return (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "$Base/healthz").StatusCode -eq 200 } catch { return $false } }

function WaitFor([scriptblock]$cond, [double]$secs, [double]$every = 0.5) {
  $end = (Get-Date).AddSeconds($secs)
  do { $v = & $cond; if ($v) { return $v }; Start-Sleep -Milliseconds ([int]($every * 1000)) } while ((Get-Date) -lt $end)
  return $null
}

function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# What relayd heard from session hooks: its supervision records, oldest first.
function HookRecords {
  $r = Api GET '/v1/session-events?after=0'
  if ($null -eq $r) { return @() }
  return @($r)
}

function SessionRows {
  $r = Api GET '/v1/sessions'
  if ($null -eq $r -or $null -eq $r.sessions) { return @() }
  return @($r.sessions)
}

# The app's own log, and the lines it gained since a count.
function AppLogLines { if (Test-Path $AppLog) { @(Get-Content $AppLog) } else { @() } }
function AppLogSince($n) { $l = AppLogLines; if ($l.Count -gt $n) { $l[$n..($l.Count - 1)] } else { @() } }

# The events the console and the app queued (%LOCALAPPDATA%\Relay\app-events):
# every object with a kind, wherever it sits in a file.
function AppEvents {
  $found = New-Object System.Collections.ArrayList
  $q = "$RelayDir\app-events"
  if (-not (Test-Path $q)) { return @() }
  foreach ($f in Get-ChildItem $q -Recurse -File -ErrorAction SilentlyContinue) {
    $raw = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { continue }
    $docs = @()
    try { $docs = @($raw | ConvertFrom-Json) } catch {
      foreach ($line in ($raw -split "`n")) { if ($line.Trim()) { try { $docs += ($line | ConvertFrom-Json) } catch {} } }
    }
    foreach ($d in $docs) { WalkEvents $d $found }
  }
  return @($found | Sort-Object { [double]$_.at })
}

function WalkEvents($o, $found) {
  if ($null -eq $o) { return }
  if ($o -is [System.Array]) { foreach ($x in $o) { WalkEvents $x $found }; return }
  if ($o -isnot [System.Management.Automation.PSCustomObject]) { return }
  $names = $o.PSObject.Properties.Name
  if (($names -contains 'kind') -and ($names -contains 'at')) { [void]$found.Add($o) }
  foreach ($p in $o.PSObject.Properties) {
    if ($p.Value -is [System.Array] -or $p.Value -is [System.Management.Automation.PSCustomObject]) { WalkEvents $p.Value $found }
  }
}

# What a terminal shows, from the raw stream a pseudo console wrote: cursor
# moves to the right become spaces, every other control sequence goes, and
# runs of white space are one space.
function Clean([string]$s) {
  if (-not $s) { return '' }
  $e = [char]27
  $s = [regex]::Replace($s, "$e\[(\d*)C", { param($m) ' ' * [Math]::Max(1, [int]('0' + $m.Groups[1].Value)) })
  $s = [regex]::Replace($s, "$e\][^\a$e]*(\a|$e\\)", '')
  $s = [regex]::Replace($s, "$e\[[0-9;?<>=!]*[ -/]*[@-~]", ' ')
  $s = [regex]::Replace($s, "$e[@-Z\\-_]", '')
  $s = [regex]::Replace($s, '[\x00-\x08\x0b-\x1f\x7f]', ' ')
  return ([regex]::Replace($s, '\s+', ' '))
}

# UI Automation over the app's windows (WebView2's pages included).
function Procs { @(Get-Process RelayApp -ErrorAction SilentlyContinue) }
function RelayWindows {
  $ids = (Procs).Id
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { $ids -contains $_.Current.ProcessId }
}
function FindLike($pattern, $secs = 10) {
  $end = (Get-Date).AddSeconds($secs)
  do {
    foreach ($w in RelayWindows) {
      foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        try { if ($e.Current.Name -like $pattern) { return $e } } catch {}
      }
    }
    Start-Sleep 1
  } while ((Get-Date) -lt $end)
  return $null
}

# Click presses an element with a real mouse click at its centre.
function ClickElement($e) {
  $r = $e.Current.BoundingRectangle
  if ($r.Width -le 0 -or $r.Height -le 0) { return 0 }
  return [ProofInput]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
}

# The desk's window: RelayApp's largest visible top-level window (the
# composer and the dialogs are small).
function DeskWindow {
  $best = [IntPtr]::Zero; $area = 0
  foreach ($h in [ProofInput]::WindowsOf('RelayApp')) {
    $r = [ProofInput]::Rect($h)
    $a = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
    if ($a -gt $area) { $best = $h; $area = $a }
  }
  return $best
}

# BringDesk asks the app for its desk the way a second launch does (the
# app brings it forward and gives its page the keyboard); only when that
# leaves another window in front is the desk's title bar clicked.
function BringDesk {
  Start-Process $App
  Start-Sleep 3
  $h = DeskWindow
  if ($h -ne [IntPtr]::Zero -and [ProofInput]::GetForegroundWindow() -ne $h) {
    $r = [ProofInput]::Rect($h)
    [void][ProofInput]::Click([int](($r.Left + $r.Right) / 2), $r.Top + 12)
    Log "desk was not in front after a second launch; clicked its title bar"
    Start-Sleep 1
  }
  return [ProofInput]::Front()
}

# The windows-11-arm image's WSL is its inbox stub: whatever starts wsl.exe
# there gets "Windows Subsystem for Linux must be updated ... Press any key to
# install" in a window of its own (Windows Terminal hosts it), which can take
# the front and is no window of Relay's. QuietWsl records who started it (its
# chain of parents, as Windows has them), closes its window and stops it, and
# returns one line per thing it did. Git Bash's bash.exe is left alone; only
# System32's (WSL's launcher) is stopped.
function WslPrompts {
  @(foreach ($p in 'WindowsTerminal', 'wsl', 'bash', 'conhost', 'OpenConsole') {
      [ProofInput]::WindowsOf($p) | Where-Object { [ProofInput]::Title($_) -match '\\system32\\(wsl|bash)\.exe$|^wsl(\.exe)?$' }
    })
}
function QuietWsl {
  $did = @()
  $ps = @(Get-Process wsl -ErrorAction SilentlyContinue) +
    @(Get-Process bash -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$env:SystemRoot\System32\*" })
  if ($ps.Count) {
    $all = @{}; Get-CimInstance Win32_Process | ForEach-Object { $all[[int]$_.ProcessId] = $_ }
    foreach ($p in $ps) {
      $chain = @(); $c = $all[[int]$p.Id]; $k = 0
      while ($c -and $k -lt 6) { $chain += "$($c.Name)[$($c.ProcessId)] $((("$($c.CommandLine)") -replace '\s+', ' ').Trim())"; $c = $all[[int]$c.ParentProcessId]; $k++ }
      $did += "$($p.ProcessName) pid $($p.Id) started $(try { $p.StartTime.ToString('HH:mm:ss.fff') } catch { '?' }): $($chain -join ' <- ')"
    }
  }
  foreach ($h in WslPrompts) { $did += "closed $([ProofInput]::Describe($h))"; [void][ProofInput]::Close($h) }
  foreach ($p in $ps) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  if ($did.Count) {
    Start-Sleep 1
    foreach ($h in WslPrompts) { $did += "closed again $([ProofInput]::Describe($h))"; [void][ProofInput]::Close($h) }
  }
  return $did
}
