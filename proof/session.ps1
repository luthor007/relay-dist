# A real Claude Code session, interactive, in a pseudo console as a terminal
# app runs it, against the stub: Relay's hooks must reach relayd, a prompt
# must wait for the phone while nobody is at the PC (two minutes without a key
# or the pointer, as Windows counts them), be answerable from there, be the
# terminal's own again the moment the person is back, leave when Claude Code
# ends, and a helper Claude Code it starts must fold under it.
. "$PSScriptRoot\lib.ps1"
Expect 'C1-session-start', 'C2-prompt-submit', 'C3-permission-present', 'C4-stop', 'C5-helper-fold', 'C6-session-end',
       'A1-away-held', 'A2-away-answer-reaches-claude', 'A3-back-lets-go', 'A4-held-leaves-when-claude-ends'

$claude = $env:PROOF_CLAUDE
if (-not $claude -or -not (Healthy)) {
  foreach ($id in 'C1-session-start', 'C2-prompt-submit', 'C3-permission-present', 'C4-stop', 'C5-helper-fold', 'C6-session-end', 'A1-away-held', 'A2-away-answer-reaches-claude', 'A3-back-lets-go', 'A4-held-leaves-when-claude-ends') {
    Result $id $false 'the Claude Code session' "setup left no Claude Code or no relayd (claude='$claude' relayd=$(Healthy))"
  }
  exit 0
}
Remove-Item "$Work\*.txt" -Force -ErrorAction SilentlyContinue

function Recs($native) { @(HookRecords | Where-Object { $_.session -eq "claude-code/$native" }) }
function Row($native) { SessionRows | Where-Object { $_.id -eq "claude-code/$native" -or $_.native_id -eq $native } | Select-Object -First 1 }
function HeldAway($native) {
  $row = Row $native
  if ($row -and $row.pending) { return (@($row.pending) | Where-Object { $_.away } | Select-Object -First 1) }
  return $null
}
function Screen([int]$from) { Clean ($pty.Since($from)) }
function Say([string]$s) { $pty.Write($s); Start-Sleep -Milliseconds 400; $pty.Write("`r") }
function WaitIdle([int]$ms) {
  $ok = WaitFor { [ProofInput]::IdleMs() -ge $ms } 260 2
  Log "idle now $([ProofInput]::IdleMs()) ms (wanted $ms): $([bool]$ok)"
  return [bool]$ok
}
function Dump($tag) {
  HookRecords | ConvertTo-Json -Depth 6 | Set-Content "$Out\hook-records-$tag.json" -Encoding UTF8
  SessionRows | ConvertTo-Json -Depth 6 | Set-Content "$Out\sessions-$tag.json" -Encoding UTF8
}

# --- Claude Code starts in a terminal ----------------------------------------
[void][ProofInput]::Nudge()
$t0 = NowMs
# Sessions relayd already knows (a Claude Code the desk's Ctrl+T started)
# are not this one.
$known = @(HookRecords | ForEach-Object { $_.session } | Sort-Object -Unique)
$pty = New-Object ProofPty -ArgumentList "cmd.exe /d /c `"$claude`"", $Work, 120, 40, "$Out\pty-session.txt"
Log "claude started in a pseudo console, pid $($pty.Pid)"
$ready = $false
$end = (Get-Date).AddSeconds(90)
$answered = @{}
# A question at start is answered as a person would, at most twice each,
# judged on what the terminal shows now (its last screenful), never on
# what it showed before.
function Answer($what, [string]$keys) {
  if ($answered[$what] -ge 2) { return $false }
  $answered[$what] = 1 + [int]$answered[$what]
  Log "start: answered '$what'"
  Start-Sleep 2
  $pty.Write($keys)
  Start-Sleep 2
  return $true
}
while ((Get-Date) -lt $end -and -not $ready) {
  Start-Sleep 1
  $all = Screen 0
  $s = $all.Substring([Math]::Max(0, $all.Length - 2500))
  if ($s -match 'Select login method|Login with|Log in with') { Log 'Claude Code asked to log in: the stub key was not taken'; break }
  if ($s -notmatch 'for shortcuts') {
    if ($s -match 'trust the files|Do you trust|Yes, proceed') { if (Answer 'trust' "`r") { continue } }
    if ($s -match 'Do you want to use this API key') { if (Answer 'api key' "$([char]27)[A`r") { continue } }
    if ($s -match 'Choose the text style') { if (Answer 'theme' "`r") { continue } }
    if ($s -match 'Make auto mode your default|Switch your default effort|No, keep') { if (Answer 'nudge' "$([char]27)") { continue } }
  }
  $ready = ($s -match 'for shortcuts|Try "') -and @(HookRecords | Where-Object { $_.kind -eq 'opened' -and $known -notcontains $_.session }).Count -gt 0
}
Shot 'session-started'
$opened = @(HookRecords | Where-Object { $_.kind -eq 'opened' -and $known -notcontains $_.session }) | Select-Object -First 1
$native = if ($opened) { ($opened.session -replace '^claude-code/', '') } else { '' }
Log "ready=$ready session=$native screen: $((Screen 0).Substring([Math]::Max(0, (Screen 0).Length - 400)))"
Result 'C1-session-start' ([bool]$opened) "SessionStart from a real Claude Code reached relayd ($(if ($native) { "claude-code/$native" } else { 'none' }))" $(if (-not $opened) { "no 'opened' record in /v1/session-events; terminal: $((Screen 0) -replace '^.*(.{300})$', '$1')" } else { '' })

if (-not $native) {
  foreach ($id in 'C2-prompt-submit', 'C3-permission-present', 'C4-stop', 'C5-helper-fold', 'C6-session-end', 'A1-away-held', 'A2-away-answer-reaches-claude', 'A3-back-lets-go', 'A4-held-leaves-when-claude-ends') {
    Result $id $false 'needs a session relayd heard of' 'no SessionStart reached relayd (C1)'
  }
  Dump 'end'; $pty.Dispose(); exit 0
}

# --- Turn A: the person is here; the prompt is the terminal's own ------------
[void][ProofInput]::Nudge()
$off = $pty.Length
$n0 = (Recs $native).Count
Say 'PROOF-WRITE C:/proof/present.txt'
$asked = WaitFor { if ((Screen $off) -match 'Do you want') { $true } else { $null } } 40
$heldHere = HeldAway $native
$rs = Recs $native
$started = @($rs | Where-Object { $_.kind -eq 'started' -and $_.prompt -match 'PROOF-WRITE' }).Count -gt 0
$request = @($rs | Where-Object { $_.kind -eq 'request' -and $_.tool.name -eq 'Write' }) | Select-Object -Last 1
Result 'C2-prompt-submit' $started 'UserPromptSubmit reached relayd with the prompt typed'
Result 'C3-permission-present' ([bool]($request -and -not $request.away -and $asked -and -not $heldHere)) "PermissionRequest reached relayd and, the person at the PC, the terminal asked at once" $(if (-not $request) { 'no request record for the Write' } elseif ($heldHere -or $request.away) { "held as away though input was $([ProofInput]::IdleMs()) ms ago" } elseif (-not $asked) { "the terminal showed no permission question in 40 s" } else { '' })
Shot 'session-turn-a'
if ($heldHere) { [void](Api POST "/v1/sessions/claude-code/$native/answer" @{ question = $heldHere.id; decision = 'allow' }) } else { $pty.Write("`r") }
$wrote = [bool](WaitFor { Test-Path "$Work\present.txt" } 30)
$stopped = [bool](WaitFor { if (@(Recs $native | Where-Object { $_.kind -eq 'completed' }).Count -gt 0) { $true } else { $null } } 30)
Result 'C4-stop' ($stopped -and $wrote) 'Stop reached relayd when the turn ended (and Claude Code made the file it was allowed to)' $(if (-not $wrote) { 'present.txt was not written' } elseif (-not $stopped) { "no 'completed' record" } else { '' })

# --- Turn B: a helper Claude Code started from this session ------------------
$off = $pty.Length
# CLAUDECODE is unset for it, as a workflow's script does: Claude Code
# refuses to start inside another Claude Code session that left it set.
Say 'PROOF-BASH env -u CLAUDECODE claude -p PROOF-HELPER'
$script:helperAsked = $false
$helper = WaitFor {
  if (-not $script:helperAsked -and (Screen $off) -match 'Do you want') { Log 'the helper command asked for permission; allowed it in the terminal'; $script:helperAsked = $true; $pty.Write("`r") }
  SessionRows | Where-Object { $_.parent -eq "claude-code/$native" } | Select-Object -First 1
} 60 2
$rows = SessionRows
$rows | ForEach-Object { Log "row $($_.id) parent=$($_.parent) state=$($_.state) title=$($_.title)" }
Get-ChildItem "$HOME\.claude\sessions" -ErrorAction SilentlyContinue | ForEach-Object { Log "registry $($_.Name): $((Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ')" }
$helperRecs = @(HookRecords | Where-Object { $_.session -ne "claude-code/$native" -and $_.kind -eq 'opened' -and [double]$_.at -ge $t0 })
$why = ''
if (-not $helper) {
  $why = "no /v1/sessions row names claude-code/$native as its parent; helper sessions heard by hooks: $($helperRecs.Count); registry entries: $(@(Get-ChildItem "$HOME\.claude\sessions" -Filter *.json -ErrorAction SilentlyContinue).Count)"
}
Result 'C5-helper-fold' ([bool]$helper) "a claude -p started from the session folds under it (parent=claude-code/$native)" $why
$done = WaitFor { if (@(Recs $native | Where-Object { $_.kind -eq 'completed' }).Count -ge 2) { $true } else { $null } } 100 2
$hs = if ($helperRecs) { $helperRecs[0].session } else { '' }
$closed = $hs -and (@(HookRecords | Where-Object { $_.session -eq $hs -and $_.kind -eq 'closed' }).Count -gt 0)
Result 'C6-session-end' ([bool]$closed) "SessionEnd reached relayd when the helper Claude Code ended ($hs)" $(if (-not $hs) { 'no helper session was heard of' } elseif (-not $closed) { "no 'closed' record for it (turn done=$([bool]$done))" } else { '' })
Dump 'after-helper'

# --- Turn C: away; held for the phone; the phone's Allow reaches Claude Code -
$idleOk = WaitIdle 125000
$off = $pty.Length
Say 'PROOF-WRITE C:/proof/away.txt'
$held = WaitFor { HeldAway $native } 30
$shownWhileHeld = (Screen $off) -match 'Do you want'
Shot 'session-turn-c-held'
Result 'A1-away-held' ([bool]$held) "with no key or pointer for $([int]([ProofInput]::IdleMs() / 1000)) s, the prompt waits on the desk and the phone (pending, away)" $(if (-not $held) { "nothing held as away in 30 s (idle reached=$idleOk; relayd's .pending files: $(@(Get-ChildItem "$R\session-hooks" -Filter *.pending -ErrorAction SilentlyContinue).Count))" } elseif ($shownWhileHeld) { 'note: the terminal drew its own question while held' } else { '' })
if ($held) {
  $a = Api POST "/v1/sessions/claude-code/$native/answer" @{ question = $held.id; decision = 'allow' }
  $wrote = [bool](WaitFor { Test-Path "$Work\away.txt" } 30)
  Result 'A2-away-answer-reaches-claude' $wrote "an Allow sent to relayd (as the phone's) reaches Claude Code, which makes the file" $(if (-not $wrote) { "away.txt not written in 30 s (answer reply: $($a | ConvertTo-Json -Compress))" } else { '' })
} else {
  Result 'A2-away-answer-reaches-claude' $false 'an Allow sent to relayd reaches Claude Code' 'nothing was held to answer (A1)'
  $pty.Write("`r")
}
[void](WaitFor { if (@(Recs $native | Where-Object { $_.kind -eq 'completed' }).Count -ge 3) { $true } else { $null } } 30)

# --- Turn D: away, then back: the terminal's own question again -------------
if ([ProofInput]::IdleMs() -lt 125000) { [void](WaitIdle 125000) }
Say 'PROOF-WRITE C:/proof/back.txt'
$held = WaitFor { HeldAway $native } 30
if ($held) {
  $off = $pty.Length
  $tb = Get-Date
  $sent = [ProofInput]::Nudge()
  $gone = WaitFor { if (-not (HeldAway $native)) { $true } else { $null } } 15 0.2
  $goneAfter = ((Get-Date) - $tb).TotalSeconds
  $asked = WaitFor { if ((Screen $off) -match 'Do you want') { $true } else { $null } } 15
  Shot 'session-turn-d-back'
  Result 'A3-back-lets-go' ([bool]($gone -and $goneAfter -le 5 -and $asked)) "a pointer move (SendInput) lets the held prompt go in $([Math]::Round($goneAfter, 1)) s and the terminal asks itself" $(if (-not $gone) { "still held 15 s after the move (SendInput took $sent events)" } elseif ($goneAfter -gt 5) { "let go only after $([Math]::Round($goneAfter, 1)) s" } elseif (-not $asked) { 'the terminal showed no question after the hold let go' } else { '' })
  $pty.Write("`r")
  [void](WaitFor { Test-Path "$Work\back.txt" } 20)
} else {
  Result 'A3-back-lets-go' $false 'the held prompt lets go when the person is back' 'nothing was held as away (A1)'
  $pty.Write("`r")
}
[void](WaitFor { if (@(Recs $native | Where-Object { $_.kind -eq 'completed' }).Count -ge 4) { $true } else { $null } } 30)

# --- Turn E: held, then Claude Code ends with its terminal still open --------
[void](WaitIdle 125000)
Say 'PROOF-WRITE C:/proof/killed.txt'
$held = WaitFor { HeldAway $native } 30
if ($held) {
  $pid0 = $null
  foreach ($f in Get-ChildItem "$HOME\.claude\sessions" -Filter *.json -ErrorAction SilentlyContinue) {
    $j = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if ($j -and $j -match [regex]::Escape($native)) { $pid0 = [int]($f.BaseName) }
  }
  if (-not $pid0) {
    # No registry entry names it: Claude Code's process under this terminal's cmd.exe.
    $pid0 = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$($pty.Pid)" | Where-Object { $_.Name -ne 'conhost.exe' } | Select-Object -First 1).ProcessId
  }
  Log "ending Claude Code's process $pid0 ($((Get-Process -Id $pid0 -ErrorAction SilentlyContinue).ProcessName)), its terminal left open"
  $tk = Get-Date
  Stop-Process -Id $pid0 -Force -ErrorAction SilentlyContinue
  $gone = WaitFor { if (-not (HeldAway $native)) { $true } else { $null } } 40 0.5
  $after = ((Get-Date) - $tk).TotalSeconds
  Result 'A4-held-leaves-when-claude-ends' ([bool]($gone -and $after -le 5)) "the held prompt leaves the desk and the phone when Claude Code ends ($([Math]::Round($after, 1)) s)" $(if (-not $gone) { "still held 40 s after Claude Code (pid $pid0) ended (on a Mac it leaves within a second; fixed on desktop/windows-next-20261013 in 51d3588d)" } elseif ($after -gt 5) { "left only after $([Math]::Round($after, 1)) s" } else { '' })
} else {
  Result 'A4-held-leaves-when-claude-ends' $false 'the held prompt leaves when Claude Code ends' 'nothing was held as away'
}
Dump 'end'
Shot 'session-end'
Start-Process taskkill -ArgumentList "/T /F /PID $($pty.Pid)" -WindowStyle Hidden -Wait
$pty.Dispose()
