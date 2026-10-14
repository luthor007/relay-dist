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
  $why = "GET /v1/terminals answered $($script:LastApiError)"
  foreach ($id in $all) {
    if ($script:LastApiError -match '^501') { Result $id $null 'a job Relay holds, in Windows Terminal' "this build holds no jobs on a PC ($why); held jobs are on desktop/windows-terminal-20261013: run this on a draft built from it or from the integration" }
    else { Result $id $false 'a job Relay holds, in Windows Terminal' $why }
  }
  exit 0
}
$open = Api POST '/v1/sessions' @{ folder = "$WorkDir\held"; text = 'hello from the proof'; view = 'terminal'; name = 'proof-held'; runtime = 'claude-code' } 60
Log "open: $($open | ConvertTo-Json -Compress -Depth 5)"
if ($null -eq $open -and $script:LastApiError -match 'holds no terminal') {
  foreach ($id in $all) { Result $id $null 'a job Relay holds, in Windows Terminal' "this build holds no jobs on a PC (POST /v1/sessions view=terminal answered $($script:LastApiError)); held jobs are on desktop/windows-terminal-20261013: run this on a draft built from it or from the integration" }
  exit 0
}
$job = WaitFor { (Api GET '/v1/terminals').terminals | Where-Object { -not $_.ended -and ($_.name -eq 'proof-held' -or $_.dir -like '*proof*held*') } | Select-Object -First 1 } 60 2
if (-not $job) { $job = (Api GET '/v1/terminals').terminals | Where-Object { -not $_.ended } | Select-Object -First 1 }
$screen = ''
if ($job) {
  $since = 0
  $end = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $end -and $screen -notmatch 'for shortcuts|ok') {
    $sr = Api GET "/v1/terminals/$($job.id)/screen?since=$since&wait=5" $null 30
    if ($sr -and $sr.data) { $screen += Clean ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($sr.data))); $since = $sr.next }
    elseif (-not $sr) { Start-Sleep 2 }
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
# desk in front: the right to the front is the desk's to pass on. The split
# view's new tab (Ctrl+N) fills itself with the open jobs, each pane with its
# "Open in Windows Terminal"; else the job is opened from Work. WebView2 can
# take a while to put a page's controls in the UI Automation tree (Windows
# Server 2025 drew the control and the tree had not got it 6 s later), so the
# job's own page is given 30 s, polled, and a fallback says what it saw.
$OpenLike = '*Open in*Terminal*'
function WaitOpen([string]$where, [int]$secs) {
  $t = Get-Date
  $e = FindLike $OpenLike $secs
  $took = [Math]::Round(((Get-Date) - $t).TotalSeconds, 1)
  if ($e) { Log "desk: '$($e.Current.Name)' found on $where after $took s" }
  else { Log "desk: no '$OpenLike' on $where after $took s" }
  return $e
}
function FindOpen {
  $e = WaitOpen 'the screen shown' 4
  if ($e) { return $e }
  # Work, then its Split view: a pane for each open job, each with its tools.
  foreach ($step in @(@('Work', 'Split view'), @('Work', '*done today*'))) {
    foreach ($name in $step) {
      $el = FindLike $name 4
      if ($el) { Log "desk: clicking '$($el.Current.Name)'"; [void](ClickElement $el); Start-Sleep 3 } else { Log "desk: no '$name' to click" }
    }
    Shot "wt-find-$($step[-1] -replace '\W', '')"
    $e = WaitOpen "'$($step[-1])'" 8
    if ($e) { return $e }
    foreach ($way in '*proof-held*', '*hello from the proof*') {
      $row = FindLike $way 10
      if ($row) {
        Log "desk: clicking '$($row.Current.Name)'"; [void](ClickElement $row); Start-Sleep 2
        $e = WaitOpen "the job's page" 30
        Shot 'wt-find-job'
        if ($e) { return $e }
        # What the tree does hold there, for the log.
        $names = @(foreach ($w in RelayWindows) { foreach ($x in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { try { $x.Current.Name } catch {} } }) |
          Where-Object { $_ -match 'Open|Terminal|proof' } | Select-Object -Unique -First 15
        Log "desk: the job's page in UI Automation holds: $($names -join ' | ')"
        break
      }
    }
  }
  return $null
}
# What a Windows Terminal window shows, through UI Automation's text pattern.
function WtText($h) {
  try {
    $w = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    # The terminal's own text: the longest a text pattern gives (a tab's
    # title gives a line).
    $best = ''
    foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
      try {
        $tp = $e.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        if ($tp) { $t = ([regex]::Replace($tp.DocumentRange.GetText(40000), '\s+', ' ')).Trim(); if ($t.Length -gt $best.Length) { $best = $t } }
      } catch {}
    }
    return $best
  } catch {}
  return ''
}
# A window is the job's when its own text is the held job's: its prompt, its
# name, or Claude Code's screen. Any other window that turns up (the ARM
# image's WSL prompt, say) is logged and left out of the judgement.
$JobText = 'hello from the proof|proof-held|for shortcuts|Claude Code'
function OpenOnce([string]$tag, $known) {
  foreach ($d in QuietWsl) { Log "wsl (before open $tag): $d" }
  $front = BringDesk
  $btn = FindOpen
  $via = 'desk'
  if ($btn) {
    Log "desk control: '$($btn.Current.Name)' at $($btn.Current.BoundingRectangle)"
    [void](ClickElement $btn)
  } else {
    # The control was not found: relayd's own call, the desk in front.
    $via = 'api'
    Log "desk: falling back to relayd's own call (POST /v1/terminals/$($job.id)/outside); T2 fails and T4 cannot be judged"
    Shot "wt-$tag-no-control"
    [void](Api POST "/v1/terminals/$($job.id)/outside" @{})
  }
  # Up to 25 s for a window that shows the job; once one does, 3 s more for
  # the front to settle.
  $jobs = @(); $others = @{}; $seenAt = $null
  $end = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $end) {
    foreach ($d in QuietWsl) { Log "wsl (open $tag): $d" }
    $jobs = @()
    foreach ($h in @([ProofInput]::WindowsOf('WindowsTerminal') | Where-Object { $known -notcontains $_ })) {
      $t = WtText $h
      if ($t -match $JobText) { $jobs += , @{ h = $h; text = $t } } else { $others["$h"] = "$([ProofInput]::Describe($h)) shows '$($t.Substring([Math]::Max(0, $t.Length - 160)))'" }
    }
    if ($jobs.Count -and -not $seenAt) { $seenAt = Get-Date; $end = $seenAt.AddSeconds(3) }
    Start-Sleep -Milliseconds 700
  }
  foreach ($k in $others.Keys) { if (-not ($jobs | Where-Object { "$($_.h)" -eq $k })) { Log "open ${tag}: left out (not the job's): $($others[$k])" } }
  $o = [ordered]@{
    via = $via; found = [bool]$btn; control = $(if ($btn) { $btn.Current.Name } else { '' }); deskFront = $front
    new = @($jobs | ForEach-Object { [ProofInput]::Describe($_.h) }); newHandles = @($jobs | ForEach-Object { $_.h })
    others = @($others.Keys | Where-Object { $k = $_; -not ($jobs | Where-Object { "$($_.h)" -eq $k }) } | ForEach-Object { [IntPtr][long]$_ })
    text = @($jobs | ForEach-Object { $_.text.Substring([Math]::Max(0, $_.text.Length - 400)) })
    front = [ProofInput]::Front(); frontHandle = [ProofInput]::GetForegroundWindow()
  }
  Log "open ${tag}: $(($o | ConvertTo-Json -Compress -Depth 3))"
  Shot "wt-$tag"
  return $o
}

# Every Windows Terminal window there before (the runner keeps one of its own).
foreach ($d in QuietWsl) { Log "wsl (before T2): $d" }
$known = @([ProofInput]::WindowsOf('WindowsTerminal'))
Log "Windows Terminal windows before: $(@($known | ForEach-Object { [ProofInput]::Describe($_) }) -join '; ')"
$first = OpenOnce 'first' $known
$named = if ($first.found) { $first.control } else { '' }
Result 'T2-desk-control' ($first.found -and $named -like '*Windows Terminal*') "the desk shows 'Open in Windows Terminal' for the held job$(if ($named) { " ('$named')" })" $(if (-not $first.found) { "no 'Open in ... Terminal' control in the desk's UI Automation tree (looked on the screen shown, Work's Split view, and 30 s on the job's page from Work); relayd's own call was used for the rest" } elseif ($named -notlike '*Windows Terminal*') { "the control is named '$named', a Mac's word" } else { '' })
$opened = $first.newHandles.Count -gt 0
Result 'T3-wt-opens' $opened "a new Windows Terminal window opens on the job (via the $($first.via)): $($first.new -join '; ')" $(if (-not $opened) { "no new Windows Terminal window showed the job 25 s after the press$(if ($first.others.Count) { " (other new windows, not the job's: $($first.others.Count), in out\proof.log)" })$(if ($script:LastApiError) { "; last API error: $($script:LastApiError)" })" } else { '' })
$inFront = $opened -and ($first.newHandles -contains $first.frontHandle)
if ($first.via -eq 'api') {
  Result 'T4-wt-in-front' $null "the new Windows Terminal window is in front" "the desk's control was not found (T2), so the window was opened by relayd's own call, which has no front to pass on; only a press on the desk can show this (in front: $($first.front))"
} else {
  Result 'T4-wt-in-front' $inFront "the new Windows Terminal window is in front" $(if (-not $inFront) { "in front: $($first.front)" } else { '' })
}

# Something else in front, then Open again: the same window comes forward.
Start-Process notepad; Start-Sleep 3
$again = OpenOnce 'again' ($known + $first.newHandles + $first.others)
Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force
$same = $opened -and ($again.newHandles.Count -eq 0) -and ($first.newHandles -contains $again.frontHandle)
Result 'T5-wt-again-same-window' $same "Open again brings the same Windows Terminal window forward, no second one (via the $($again.via))" $(if (-not $opened) { 'no window was opened the first time (T3)' } elseif (-not $same) { "new windows showing the job the second time: $($again.newHandles.Count); in front: $($again.front)" } else { '' })
