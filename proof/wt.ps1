# A job Relay holds on this PC, opened in real Windows Terminal from the
# desk: the window must appear and be in front, and Open again must bring the
# same window forward, not a second one.
. "$PSScriptRoot\lib.ps1"
Expect 'T0-wt-there', 'T1-held-job', 'T2-desk-control', 'T3-wt-opens', 'T4-wt-in-front', 'T5-wt-again-same-window'
$all = 'T1-held-job', 'T2-desk-control', 'T3-wt-opens', 'T4-wt-in-front', 'T5-wt-again-same-window'

function WtPath {
  $c = Get-Command wt.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $p = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
  if (Test-Path $p) { return $p }
  return ''
}

# --- Windows Terminal itself ---------------------------------------------------
$wt = WtPath
$how = 'on the image'
if (-not $wt) {
  $how = 'installed from microsoft/terminal'
  try {
    gh release download -R microsoft/terminal -p '*PreinstallKit.zip' -D wtkit 2>&1 | ForEach-Object { Log "gh: $_" }
    $zip = Get-ChildItem wtkit\*.zip | Select-Object -First 1
    Expand-Archive $zip.FullName wtkit\x -Force
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $deps = @(Get-ChildItem wtkit\x -Recurse -Include *.appx | Where-Object { $_.Name -match "_$arch[_.]" } | ForEach-Object { $_.FullName })
    $bundle = (Get-ChildItem wtkit\x -Recurse -Include *.msixbundle | Select-Object -First 1).FullName
    Log "wt kit: bundle=$bundle deps=$($deps -join ';')"
    Add-AppxPackage -Path $bundle -DependencyPath $deps -ErrorAction Stop
  } catch { Log "wt install: $($_.Exception.Message)" }
  $wt = WtPath
}
Log "wt=$wt ($how) version=$((Get-AppxPackage Microsoft.WindowsTerminal* -ErrorAction SilentlyContinue | Select-Object -First 1).Version)"
Result 'T0-wt-there' ([bool]$wt) "Windows Terminal is on this PC ($how)" $(if (-not $wt) { 'not on the image and the install from microsoft/terminal failed (out\proof.log)' } else { '' })

# --- A job Relay holds ---------------------------------------------------------
$list = Api GET '/v1/terminals'
if ($null -eq $list) {
  foreach ($id in $all) { Result $id $null 'a job Relay holds, in Windows Terminal' "this build has no held jobs (GET /v1/terminals answered no list); they are on desktop/windows-terminal-20261013, so run this on a draft built from it or from the integration" }
  exit 0
}
$open = Api POST '/v1/sessions' @{ folder = "$Work\held"; text = 'hello from the proof'; view = 'terminal'; name = 'proof-held'; runtime = 'claude-code' } 60
Log "open: $($open | ConvertTo-Json -Compress -Depth 5)"
$job = WaitFor { (Api GET '/v1/terminals').terminals | Where-Object { -not $_.ended -and ($_.name -eq 'proof-held' -or $_.dir -like '*proof*held*') } | Select-Object -First 1 } 60 2
if (-not $job) { $job = (Api GET '/v1/terminals').terminals | Where-Object { -not $_.ended } | Select-Object -First 1 }
$screen = ''
if ($job) {
  $since = 0
  $end = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $end -and $screen -notmatch 'for shortcuts|ok') {
    $r = Api GET "/v1/terminals/$($job.id)/screen?since=$since&wait=5" $null 30
    if ($r -and $r.data) { $screen += Clean ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($r.data))); $since = $r.next }
  }
}
Log "held job $($job.id): $($screen.Substring([Math]::Max(0, $screen.Length - 300)))"
Result 'T1-held-job' ([bool]($job -and $screen -match 'for shortcuts|ok')) "a Claude Code job Relay holds runs, and its screen reads back ($($job.id))" $(if (-not $job) { "no held job listed 60 s after POST /v1/sessions view=terminal" } elseif ($screen -notmatch 'for shortcuts|ok') { "its screen never showed Claude Code ready: '$($screen.Substring([Math]::Max(0, $screen.Length - 200)))'" } else { '' })
if (-not $job) {
  foreach ($id in 'T2-desk-control', 'T3-wt-opens', 'T4-wt-in-front', 'T5-wt-again-same-window') { Result $id $false 'needs a held job' 'no held job (T1)' }
  exit 0
}

# --- Open in Windows Terminal, pressed on the desk ----------------------------
# Found by its name through UI Automation and clicked with a real click, the
# desk in front: the right to the front is the desk's to pass on.
function FindOpen {
  $e = FindLike '*Open in Windows Terminal*' 5
  if ($e) { return $e }
  foreach ($way in '*Split view*', '*proof-held*', '*hello from the proof*') {
    $nav = FindLike $way 3
    if ($nav) { Log "desk: clicking '$($nav.Current.Name)' to reach the job"; [void](ClickElement $nav); Start-Sleep 3 }
    $e = FindLike '*Open in Windows Terminal*' 5
    if ($e) { return $e }
  }
  return $null
}
function OpenOnce([string]$tag) {
  $front = BringDesk
  $before = @([ProofInput]::WindowsOf('WindowsTerminal'))
  $btn = FindOpen
  $via = 'desk'
  if ($btn) {
    Log "desk control: '$($btn.Current.Name)' $($btn.Current.BoundingRectangle)"
    [void](ClickElement $btn)
  } else {
    # The control was not found: relayd's own call, the desk in front, so
    # the window still gets its chance to come to the front.
    $via = 'api'
    Shot "wt-$tag-no-control"
    [void](Api POST "/v1/terminals/$($job.id)/outside" @{})
  }
  $win = WaitFor { $w = @([ProofInput]::WindowsOf('WindowsTerminal')); if ($w.Count -gt 0) { $w } else { $null } } 20 0.5
  Start-Sleep 2
  $after = @([ProofInput]::WindowsOf('WindowsTerminal'))
  $o = [ordered]@{ via = $via; found = [bool]$btn; deskFront = $front; before = $before.Count; after = $after.Count; front = [ProofInput]::Front(); frontProc = [ProofInput]::FrontProcess() }
  Log "open ${tag}: $($o | ConvertTo-Json -Compress)"
  Shot "wt-$tag"
  return $o
}

$first = OpenOnce 'first'
Result 'T2-desk-control' $first.found "the desk shows 'Open in Windows Terminal' for the held job" $(if (-not $first.found) { "no control by that name in the desk's UI Automation tree (looked on the screen shown, Split view, and the job's row); relayd's own call was used for the rest" } else { '' })
Result 'T3-wt-opens' ($first.after -gt 0) "a Windows Terminal window opens on the job (via the $($first.via))" $(if ($first.after -eq 0) { "no WindowsTerminal window 20 s after the press" } else { '' })
$inFront = $first.frontProc -eq 'WindowsTerminal'
Result 'T4-wt-in-front' $inFront "the Windows Terminal window is in front" $(if (-not $inFront) { "in front: $($first.front)" } else { '' })

# Something else in front, then Open again: the same window comes forward.
Start-Process notepad; Start-Sleep 3
$again = OpenOnce 'again'
Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force
$same = ($again.after -eq $first.after) -and ($again.frontProc -eq 'WindowsTerminal')
Result 'T5-wt-again-same-window' $same "Open again brings the same Windows Terminal window forward, no second one" $(if (-not $same) { "windows before $($first.after), after $($again.after); in front: $($again.front)" } else { '' })
