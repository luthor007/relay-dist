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
# "Open in Windows Terminal"; else the job is opened from Work.
function FindOpen {
  $e = FindLike '*Open in*Terminal*' 4
  if ($e) { return $e }
  # Work, then its Split view: a pane for each open job, each with its tools.
  foreach ($step in @(@('Work', 'Split view'), @('Work', '*done today*'))) {
    foreach ($name in $step) {
      $el = FindLike $name 4
      if ($el) { Log "desk: clicking '$($el.Current.Name)'"; [void](ClickElement $el); Start-Sleep 3 } else { Log "desk: no '$name' to click" }
    }
    Shot "wt-find-$($step[-1] -replace '\W', '')"
    $e = FindLike '*Open in*Terminal*' 5
    if ($e) { return $e }
    foreach ($way in '*hello from the proof*', '*proof-held*') {
      $row = FindLike $way 3
      if ($row) {
        Log "desk: clicking '$($row.Current.Name)'"; [void](ClickElement $row); Start-Sleep 4
        Shot 'wt-find-job'
        $e = FindLike '*Open in*Terminal*' 6
        if ($e) { return $e }
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
    foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
      try {
        $tp = $e.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        if ($tp) { $t = $tp.DocumentRange.GetText(20000); if ($t) { return ([regex]::Replace($t, '\s+', ' ')).Trim() } }
      } catch {}
    }
  } catch {}
  return ''
}
function OpenOnce([string]$tag, $known) {
  $front = BringDesk
  $btn = FindOpen
  $via = 'desk'
  if ($btn) {
    Log "desk control: '$($btn.Current.Name)' at $($btn.Current.BoundingRectangle)"
    [void](ClickElement $btn)
  } else {
    # The control was not found: relayd's own call, the desk in front.
    $via = 'api'
    Shot "wt-$tag-no-control"
    [void](Api POST "/v1/terminals/$($job.id)/outside" @{})
  }
  $new = WaitFor { $n = @([ProofInput]::WindowsOf('WindowsTerminal') | Where-Object { $known -notcontains $_ }); if ($n.Count -gt 0) { $n } else { $null } } 20 0.5
  Start-Sleep 2
  $new = if ($new) { @($new) } else { @() }
  Start-Sleep 3
  $texts = @($new | ForEach-Object { WtText $_ })
  $o = [ordered]@{ via = $via; found = [bool]$btn; control = $(if ($btn) { $btn.Current.Name } else { '' }); deskFront = $front; new = @($new | ForEach-Object { [ProofInput]::Describe($_) }); newHandles = $new; text = @($texts | ForEach-Object { $_.Substring([Math]::Max(0, $_.Length - 400)) }); front = [ProofInput]::Front(); frontHandle = [ProofInput]::GetForegroundWindow() }
  Log "open ${tag}: $(($o | ConvertTo-Json -Compress -Depth 3))"
  Shot "wt-$tag"
  return $o
}

# Every Windows Terminal window there before (the runner keeps one of its own).
$known = @([ProofInput]::WindowsOf('WindowsTerminal'))
Log "Windows Terminal windows before: $(@($known | ForEach-Object { [ProofInput]::Describe($_) }) -join '; ')"
$first = OpenOnce 'first' $known
$named = if ($first.found) { $first.control } else { '' }
Result 'T2-desk-control' ($first.found -and $named -like '*Windows Terminal*') "the desk shows 'Open in Windows Terminal' for the held job$(if ($named) { " ('$named')" })" $(if (-not $first.found) { "no 'Open in … Terminal' control in the desk's UI Automation tree (looked on the screen shown, Work's Split view, and the job from Work); relayd's own call was used for the rest" } elseif ($named -notlike '*Windows Terminal*') { "the control is named '$named', a Mac's word" } else { '' })
$opened = $first.newHandles.Count -gt 0
$showsJob = @($first.text | Where-Object { $_ -match 'hello from the proof|for shortcuts|Claude Code' }).Count -gt 0
Result 'T3-wt-opens' ($opened -and $showsJob) "a new Windows Terminal window opens on the job (via the $($first.via)): $($first.new -join '; ')" $(if (-not $opened) { "no new WindowsTerminal window 20 s after the press$(if ($script:LastApiError) { "; last API error: $($script:LastApiError)" })" } elseif (-not $showsJob) { "the new window does not show the job; it shows: '$(($first.text -join ' | ') -replace '^.*(.{250})$', '$1')'" } else { '' })
$inFront = $opened -and ($first.newHandles -contains $first.frontHandle)
Result 'T4-wt-in-front' $inFront "the new Windows Terminal window is in front" $(if (-not $inFront) { "in front: $($first.front)" } else { '' })

# Something else in front, then Open again: the same window comes forward.
Start-Process notepad; Start-Sleep 3
$again = OpenOnce 'again' ($known + $first.newHandles)
Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force
$same = $opened -and ($again.newHandles.Count -eq 0) -and ($first.newHandles -contains $again.frontHandle)
Result 'T5-wt-again-same-window' $same "Open again brings the same Windows Terminal window forward, no second one" $(if (-not $opened) { 'no window was opened the first time (T3)' } elseif (-not $same) { "new windows the second time: $($again.newHandles.Count); in front: $($again.front)" } else { '' })
