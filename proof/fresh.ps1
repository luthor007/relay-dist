# A fresh PC with no coding tools at all (run=fresh): Relay for Windows puts
# Claude Code and Codex on it by itself (0.1.4, internal/runtimesetup), and a
# job started from the desk then runs that Claude Code and registers, with no
# step by the person and no restart. The Windows customer of 2026-10-14
# pressed + eight times and got nothing; this is the whole road from install
# to a job, on a machine that never had Claude Code.
#
# F0: relayd answers, on a PC with no claude and no codex.
# F1: Relay installs Claude Code (its own download, checked, then
#     `claude install`) and says so on GET /v1/runtimes/setup.
# F2: Relay installs Codex as well.
# F3: the desk is offered both: GET /v1/terminals' starts say installed.
# F4: a Claude Code job started from the desk runs that Claude Code to its
#     prompt in Relay's terminal, without relayd being restarted.
# F5: the job registers: its id reaches relayd's sessions (Claude Code's own
#     hooks, added by Relay once it arrived).

param([Parameter(Mandatory = $true)][string]$Tag, [string]$Repo = 'luthor007/relay-dist')
. "$PSScriptRoot\lib.ps1"
Expect 'F0-engine', 'F1-claude-installed', 'F2-codex-installed', 'F3-desk-offers-both', 'F4-desk-job-runs', 'F5-job-registers'

# Screen is what a held job's terminal showed, cleaned (as late.ps1's).
function Screen($id) {
  $sr = Api GET "/v1/terminals/$id/screen?since=0&wait=0" $null 20
  if ($sr -and $sr.data) { return Clean ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($sr.data))) }
  return ''
}
function Tail([string]$s, [int]$n = 300) { if (-not $s) { return '' }; return $s.Substring([Math]::Max(0, $s.Length - $n)) }

Log "os=$([Environment]::OSVersion.VersionString) arch=$env:PROCESSOR_ARCHITECTURE tag=$Tag"
Get-Process WWAHost -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($d in QuietWsl) { Log "wsl: $d" }
Add-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Value "`r`n127.0.0.1 relay.glass"
ipconfig /flushdns | Out-Null

$preClaude = (Get-Command claude -ErrorAction SilentlyContinue).Source
$preCodex = (Get-Command codex -ErrorAction SilentlyContinue).Source
Log "before Relay: claude=$(if ($preClaude) { $preClaude } else { 'none' }) codex=$(if ($preCodex) { $preCodex } else { 'none' })"

gh release download $Tag -R $Repo -p 'RelaySetup*.exe' -D dl 2>&1 | ForEach-Object { Log "gh: $_" }
$exe = Get-ChildItem dl\RelaySetup*.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$p = Start-Process $exe.FullName -ArgumentList '/S' -PassThru
[void]$p.WaitForExit(180000)
& "$InstallDir\relay.exe" service install *> "$Out\service-install.txt"
$up = [bool](WaitFor { Healthy } 90 1)
try { [IO.File]::WriteAllText($TokenKeep, [IO.File]::ReadAllText("$RelayDir\api-token").Trim()) } catch {}
foreach ($half in 'read', 'write') { [void](Api POST '/v1/connectors/claude_code/grant' @{ half = $half }) }
$rd = Get-Process relayd -ErrorAction SilentlyContinue | Select-Object -First 1
$relaydStart = $rd.StartTime
Log "relayd pid $($rd.Id) started $($relaydStart.ToString('HH:mm:ss'))"
$bare = (-not $preClaude) -and (-not $preCodex)
Result 'F0-engine' ($up -and $bare) "relayd answers on a PC with no Claude Code and no Codex ($($exe.Name))" $(if (-not $up) { 'relayd never answered' } elseif (-not $bare) { "this runner already had claude=$preClaude codex=$preCodex" } else { '' })

# --- F1, F2: Relay puts them on the PC --------------------------------------
$snap = $null
$item = { param($s, $rt) @($s.items) | Where-Object { $_.runtime -eq $rt } | Select-Object -First 1 }
$settled = 'ready|theirs|failed|removed|not_needed'
$end = (Get-Date).AddMinutes(12)
while ((Get-Date) -lt $end) {
  $snap = Api GET '/v1/runtimes/setup'
  $c = & $item $snap 'claude-code'; $x = & $item $snap 'codex'
  if ($c -and $x -and $c.state -match $settled -and $x.state -match $settled) { break }
  Start-Sleep 5
}
Log "setup: $(if ($snap) { $snap | ConvertTo-Json -Compress -Depth 5 } else { "unanswered: $($script:LastApiError)" })"
$c = & $item $snap 'claude-code'; $x = & $item $snap 'codex'
$f1 = [bool]($c -and $c.state -eq 'ready' -and $c.path -and (Test-Path $c.path))
Result 'F1-claude-installed' $f1 "Relay installed Claude Code by itself ($($c.version) at $($c.path))" $(if (-not $c) { 'no claude-code item' } elseif (-not $f1) { "state $($c.state): $($c.why)" } else { '' })
$f2 = [bool]($x -and $x.state -eq 'ready' -and $x.path -and (Test-Path $x.path))
Result 'F2-codex-installed' $f2 "Relay installed Codex by itself ($($x.version) at $($x.path))" $(if (-not $x) { 'no codex item' } elseif (-not $f2) { "state $($x.state): $($x.why)" } else { '' })
$o = & $item $snap 'opencode'
Log "opencode: $(if ($o) { "$($o.state) $($o.path) $($o.why)" } else { 'no item' })"

# --- F3: what the desk is offered --------------------------------------------
$script:starts = $null
$offered = WaitFor {
  $t = Api GET '/v1/terminals'
  $script:starts = @($t.starts)
  $cc = $script:starts | Where-Object { $_.runtime -eq 'claude-code' -and $_.installed }
  $cx = $script:starts | Where-Object { $_.runtime -eq 'codex' -and $_.installed }
  if ($cc -and $cx) { $true } else { $null }
} 40 2
Log "starts: $($script:starts | ConvertTo-Json -Compress -Depth 4)"
Result 'F3-desk-offers-both' ([bool]$offered) 'the desk is offered a Claude Code job and a Codex job on this PC' $(if (-not $offered) { "starts: $($script:starts | ConvertTo-Json -Compress -Depth 4)" } else { '' })

# --- F4: a job from the desk runs the Claude Code Relay installed ------------
# Its first run asks nothing, as the other proofs set it: onboarding done,
# the folder trusted, a stand-in key pointed at a port nobody listens on (the
# prompt is drawn before anything is sent).
New-Item -ItemType Directory -Force 'C:\fresh', 'C:\fresh\job' | Out-Null
$ver = ''
if ($c -and $c.path) { $ver = (& $c.path --version 2>&1 | Select-Object -First 1) }
$v = ($ver -replace '\s.*$', '')
Log "claude --version: $ver"
$trusted = @{}
foreach ($d in 'C:/', 'C:\', 'C:/fresh', 'C:\fresh', 'C:/fresh/job', 'C:\fresh\job') { $trusted[$d] = @{ hasTrustDialogAccepted = $true; hasCompletedProjectOnboarding = $true; allowedTools = @(); projectOnboardingSeenCount = 1 } }
$key = 'sk-ant-api03-proof' + ('x' * 76) + 'AAAAProofHarness0001'
$state = [ordered]@{ hasCompletedOnboarding = $true; lastOnboardingVersion = $v; lastReleaseNotesSeen = $v; hasSeenAutoDefaultNudge = $true; hasResetAutoModeOptInForDefaultOffer = $true; theme = 'dark'; numStartups = 5; autoUpdates = $false; customApiKeyResponses = @{ approved = @($key.Substring($key.Length - 20)); rejected = @() }; projects = $trusted }
New-Item -ItemType Directory -Force "$HOME\.claude" | Out-Null
$old = $null
try { $old = Get-Content "$HOME\.claude.json" -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
if ($old) { foreach ($p in $old.PSObject.Properties) { if (-not $state.Contains($p.Name)) { $state[$p.Name] = $p.Value } } }
[IO.File]::WriteAllText("$HOME\.claude.json", ($state | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
$envs = @{ ANTHROPIC_BASE_URL = "http://127.0.0.1:$StubPort"; ANTHROPIC_API_KEY = $key; CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'; DISABLE_AUTOUPDATER = '1' }
$settings = @{}
try { $prev = Get-Content "$HOME\.claude\settings.json" -Raw -ErrorAction Stop | ConvertFrom-Json; foreach ($p in $prev.PSObject.Properties) { $settings[$p.Name] = $p.Value } } catch {}
$settings['env'] = $envs
[IO.File]::WriteAllText("$HOME\.claude\settings.json", ($settings | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $false))
# Relay's hooks come with Relay, added once Claude Code arrived; wait for them
# before the job, as a person's first job would find them.
$hooked = WaitFor { $j = Get-Content "$HOME\.claude\settings.json" -Raw -ErrorAction SilentlyContinue; if ($j -and $j -match 'session-hook') { $j } else { $null } } 40 1
Log "hooks before the job: $([bool]$hooked)"

$t0 = Get-Date
$open = Api POST '/v1/sessions' @{ folder = 'C:\fresh\job'; view = 'terminal'; name = 'fresh-job'; runtime = 'claude-code' } 60
$took = [int]((Get-Date) - $t0).TotalMilliseconds
Log "F4 open ($took ms): $(if ($open) { $open | ConvertTo-Json -Compress -Depth 5 } else { "refused: $($script:LastApiError)" })"
$id = if ($open) { $open.opened.native_id } else { '' }
if (-not $id -and $open) { $id = $open.opened.session -replace '^claude-code/', '' }
$ready = 'for shortcuts|shift\+tab to cycle'
$screen = ''
$job = $null
if ($open) {
  $end = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $end) {
    $job = @((Api GET '/v1/terminals').terminals) | Where-Object { $_.name -eq 'fresh-job' -or $_.dir -like '*fresh*job*' } | Select-Object -First 1
    if ($job) { $screen = Screen $job.id }
    if (($job -and $job.ended) -or $screen -match $ready) { break }
    Start-Sleep 2
  }
}
$rd2 = Get-Process relayd -ErrorAction SilentlyContinue | Select-Object -First 1
$same = [bool]($rd2 -and $rd2.StartTime -eq $relaydStart)
Log "F4 job: $(if ($job) { "$($job.id) ended=$($job.ended)" } else { 'none' }) relayd same run: $same screen: $(Tail $screen)"
$f4 = [bool]($job -and -not $job.ended -and $screen -match $ready -and $same)
Result 'F4-desk-job-runs' $f4 'a job from the desk runs the Claude Code Relay installed, with no restart' $(if (-not $open) { "refused: $($script:LastApiError)" } elseif (-not $job) { 'no job listed' } elseif ($job.ended) { "the job ended at once; its terminal: '$(Tail $screen 200)'" } elseif (-not $same) { 'relayd was restarted on the way' } elseif (-not $f4) { "never showed Claude Code ready: '$(Tail $screen 200)'" } else { '' })

# --- F5: it registers ------------------------------------------------------
$reg = $null
if ($id) {
  $reg = WaitFor { $s = Api GET '/v1/sessions'; $j = if ($s) { $s | ConvertTo-Json -Compress -Depth 8 } else { '' }; if ($j -match [regex]::Escape($id)) { $j } else { $null } } 60 2
}
Log "F5 sessions: $(if ($reg) { Tail $reg 600 } else { 'id not listed' })"
Result 'F5-job-registers' ([bool]$reg) "the job's id ($id) is listed in relayd's sessions" $(if (-not $id) { 'the open gave no id' } elseif (-not $reg) { 'not listed 60 s after it started' } else { '' })

Copy-Item "$HOME\.claude\settings.json" "$Out\claude-settings-end.json" -ErrorAction SilentlyContinue
Copy-Item "$RelayDir\Logs\*" $Out -ErrorAction SilentlyContinue
