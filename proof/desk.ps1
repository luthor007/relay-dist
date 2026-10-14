# Real key presses into the desk (SendInput, the desk in front): F5, Ctrl+R,
# Ctrl+N, Ctrl+Shift+T, Ctrl+T, then Alt+Space anywhere. What each did is
# read from what the page and the app say themselves: the page's address
# (UI Automation's value of the desk's document), the console's own events in
# the app's queue (screen.appear, app.launch), the app's log, and the window
# in front; and, when WebView2's debugging port is open, the page's keydown.
. "$PSScriptRoot\lib.ps1"
$deskStart = Get-Date
Expect 'K0-cdp', 'K4-f5', 'K5-ctrl-r', 'K1-ctrl-n', 'K3-ctrl-shift-t', 'K2-ctrl-t', 'K6-alt-space'

function DocUrl {
  $h = DeskWindow
  if ($h -eq [IntPtr]::Zero) { return '' }
  try {
    $w = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
    foreach ($d in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
      try { $v = $d.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value; if ($v) { return ($v -replace '(token=)[^&#]+', '$1x') } } catch {}
    }
  } catch {}
  return ''
}

# --- WebView2's debugging port, when it could be opened ---------------------
$cdpWs = $null
function CdpEval([string]$expr) {
  if ($null -eq $script:cdpWs) { return $null }
  $script:cdpId = 1 + [int]$script:cdpId
  $msg = @{ id = $script:cdpId; method = 'Runtime.evaluate'; params = @{ expression = $expr; returnByValue = $true } } | ConvertTo-Json -Depth 5 -Compress
  $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, [Text.Encoding]::UTF8.GetBytes($msg))
  $script:cdpWs.SendAsync($seg, 'Text', $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  $buf = New-Object byte[] 1048576
  $end = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $end) {
    $ms = New-Object IO.MemoryStream
    do {
      $r = $script:cdpWs.ReceiveAsync((New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)), [Threading.CancellationToken]::None).GetAwaiter().GetResult()
      $ms.Write($buf, 0, $r.Count)
    } while (-not $r.EndOfMessage)
    $o = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
    if ($o.id -eq $script:cdpId) { return $o.result.result.value }
  }
  return $null
}
function CdpConnect {
  try {
    $t = Invoke-RestMethod -TimeoutSec 3 'http://127.0.0.1:9222/json' | Where-Object { $_.type -eq 'page' -and $_.url -like 'http://127.0.0.1:8787*' } | Select-Object -First 1
    if (-not $t) { return $false }
    $script:cdpWs = New-Object System.Net.WebSockets.ClientWebSocket
    $script:cdpWs.ConnectAsync([Uri]$t.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    return $true
  } catch { Log "cdp connect: $($_.Exception.Message)"; $script:cdpWs = $null; return $false }
}
$recorder = "(function(){ if (!window.__proofKeys) { window.__proofKeys = []; addEventListener('keydown', function(e){ var r = {key:e.key, ctrl:e.ctrlKey, shift:e.shiftKey, alt:e.altKey}; window.__proofKeys.push(r); setTimeout(function(){ r.prevented = e.defaultPrevented; }, 0); }, true); } return location.href.replace(/token=[^&#]+/, 'token=x'); })()"

if ($env:PROOF_CDP -eq '1' -and (CdpConnect)) {
  Result 'K0-cdp' $true "WebView2's debugging port opened for the desk; keydowns are read from the page"
} else {
  Result 'K0-cdp' $null "the page's keydown events over WebView2's debugging port" "RelayApp.exe sets WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS itself (relayd/cmd/relayapp/main_windows.go:536, os.Setenv, no append), which hides the test's own value, and WebView2 reads the AdditionalBrowserArguments policy key only when that variable is unset; port 9222 never answered. Each key is judged by what the page did instead"
}

# --- The presses -----------------------------------------------------------
$VK = @{ CTRL = 0x11; SHIFT = 0x10; ALT = 0x12; N = 0x4E; T = 0x54; R = 0x52; F5 = 0x74; SPACE = 0x20; ESC = 0x1B }
$presses = @(
  @{ id = 'K4-f5'; name = 'F5'; keys = @($VK.F5) },
  @{ id = 'K5-ctrl-r'; name = 'Ctrl+R'; keys = @($VK.CTRL, $VK.R) },
  @{ id = 'K1-ctrl-n'; name = 'Ctrl+N'; keys = @($VK.CTRL, $VK.N) },
  @{ id = 'K3-ctrl-shift-t'; name = 'Ctrl+Shift+T'; keys = @($VK.CTRL, $VK.SHIFT, $VK.T) },
  @{ id = 'K2-ctrl-t'; name = 'Ctrl+T'; keys = @($VK.CTRL, $VK.T) }
)
$seen = @()
foreach ($p in $presses) {
  $front = BringDesk
  $deskFront = [ProofInput]::FrontProcess() -eq 'RelayApp'
  if ($cdpWs) { [void](CdpEval $recorder) }
  $urlBefore = DocUrl
  $n = (AppLogLines).Count
  $before = @(Get-Process | Select-Object -ExpandProperty Id)
  $t0 = NowMs
  $sent = [ProofInput]::Chord([uint16[]]$p.keys)
  Start-Sleep 6
  $lines = @(AppLogSince $n | Select-String 'desk:' | ForEach-Object { "$_" })
  $new = @(Get-Process | Where-Object { $before -notcontains $_.Id } | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
  $keysSeen = if ($cdpWs) { (CdpEval 'JSON.stringify(window.__proofKeys || null)') } else { '' }
  $rec = [ordered]@{
    id = $p.id; name = $p.name; t0 = $t0; t1 = (NowMs); sent = $sent; front = $front; deskFront = $deskFront
    urlBefore = $urlBefore; urlAfter = (DocUrl); reloads = @($lines | Where-Object { $_ -match 'the console loaded' }).Count
    log = $lines; newProcs = $new; frontAfter = [ProofInput]::Front(); keys = $keysSeen
  }
  Log ("press " + ($rec | ConvertTo-Json -Compress -Depth 4))
  Shot "desk-$($p.id)"
  $seen += , $rec
  if ($rec.reloads -gt 0) { [void](WaitFor { AppLogSince $n | Select-String -Quiet 'desk: the console is ready' } 30 1) }
}

# --- Alt+Space, from anywhere -----------------------------------------------
$desk = DeskWindow
$n = (AppLogLines).Count
$t0 = NowMs
$sent = [ProofInput]::Chord([uint16[]]@($VK.ALT, $VK.SPACE))
Start-Sleep 3
$frontH = [ProofInput]::GetForegroundWindow()
$composer = ([ProofInput]::FrontProcess() -eq 'RelayApp') -and ($frontH -ne $desk)
$hot = @(AppLogSince $n | Select-String 'hotkey:|composer' | ForEach-Object { "$_" })
Log "alt+space sent=$sent front=$([ProofInput]::Front()) desk=$([ProofInput]::Describe($desk)) log=$($hot -join ' | ')"
Shot 'desk-K6-alt-space'
Result 'K6-alt-space' $composer "Alt+Space (SendInput) brings the composer to the front" $(if (-not $composer) { "front is $([ProofInput]::Front()); sent=$sent" } else { '' })
[void][ProofInput]::Chord([uint16[]]@($VK.ESC))

# --- What each press did ----------------------------------------------------
Start-Sleep 10
$ev = @(AppEvents)
$ev | ForEach-Object { "$($_.at) $($_.kind) screen=$($_.screen) name=$($_.name) launch=$($_.launch)" } | Set-Content "$Out\app-events.txt" -Encoding UTF8
Log "app events read: $($ev.Count)"
function EventsIn($r) { @($ev | Where-Object { [double]$_.at -ge $r.t0 -and [double]$_.at -le ($r.t1 + 1500) }) }
foreach ($r in $seen) {
  $in = EventsIn $r
  $appear = @($in | Where-Object { $_.kind -eq 'screen.appear' } | ForEach-Object { "$($_.screen)" })
  $launch = @($in | Where-Object { $_.kind -eq 'app.launch' }).Count
  $u = "$($r.urlAfter)"
  $evidence = "url '$($r.urlBefore)' -> '$u'; screens [$($appear -join ',')]; reloads $($r.reloads); launches $launch; new processes [$($r.newProcs -join ',')]"
  if ($r.keys) { $evidence += "; page keydowns $($r.keys)" }
  if (-not $r.deskFront) {
    Result $r.id $false "$($r.name) reaches the desk" "the desk was not in front before the press ($($r.front)); $evidence"
    continue
  }
  switch ($r.id) {
    { $_ -in 'K4-f5', 'K5-ctrl-r' } {
      $reloaded = ($r.reloads -gt 0) -or ($launch -gt 0)
      Result $r.id (-not $reloaded) "$($r.name) leaves the desk as it is, as a Mac's WKWebView does (no browser reload)" $(if ($reloaded) { "the desk reloaded (audit N11: WebView2's browser keys are on in the desk); $evidence" } else { '' })
    }
    'K1-ctrl-n' {
      $ok = ($u -match 'grid\?[^#]*tab=') -or ($appear -contains 'grid')
      Result $r.id $ok "Ctrl+N opens a new tab of the split view" $(if (-not $ok) { $evidence } else { '' })
    }
    'K3-ctrl-shift-t' {
      $ok = ($u -match 'chat\?[^#]*where=relay') -or ($appear -contains 'chat')
      Result $r.id $ok "Ctrl+Shift+T opens a new job for Relay in the cloud" $(if (-not $ok) { $evidence } else { '' })
    }
    'K2-ctrl-t' {
      $ok = ($u -match 'grid\?[^#]*new=') -or ($appear -contains 'grid') -or ($r.newProcs -match 'claude|node|WindowsTerminal|powershell|OpenConsole')
      Result $r.id $ok "Ctrl+T starts Claude Code on this PC in a pane of the split view" $(if (-not $ok) { $evidence } else { '' })
    }
  }
}
# A Claude Code that Ctrl+T started is not part of what follows: its window
# ends (the stub, started before, is left alone).
Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(node|claude)\.exe$' -and $_.CommandLine -match 'claude' -and $_.CommandLine -notmatch 'stub\.js' -and $_.CreationDate -gt $deskStart } | ForEach-Object {
  Log "closing the Claude Code Ctrl+T started: $($_.ProcessId) $($_.CommandLine)"
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
