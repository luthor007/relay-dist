# A job started from the desk on a PC where Claude Code is missing, then
# installed while Relay runs (run=late). A Windows customer (2026-10-14)
# pressed + eight times: each POST /v1/sessions answered 201 and no job ever
# came up, while a `claude` they typed in a new window worked. A program
# started before an install keeps the Path it was given, so relayd's jobs
# never see a folder an installer adds to the person's Path afterwards.
#
# L1: with no Claude Code on the PC, the desk is told so in words, and no job
#     is left to die unseen.
# L2: Claude Code installed into a new folder on the person's Path after
#     relayd started: a job started from the desk runs it.
# L3: a job that cannot start says why, with what its terminal showed.
# L4: Claude Code's hooks are added once it is on the PC, so its prompts
#     reach the desk and the phone.
# -Start folder: Claude Code's folder (~/.claude) is there when Relay starts,
# as on a PC where it ran once from a window whose Path relayd never got, or
# where the Claude app made it: the customer's shape (each + answered 201).
# -Start none: nothing of Claude Code's is there.
param([Parameter(Mandatory = $true)][string]$Tag, [string]$Repo = 'luthor007/relay-dist', [ValidateSet('folder', 'none')][string]$Start = 'none')
. "$PSScriptRoot\lib.ps1"
Expect 'L0-engine', 'L1-missing-said', 'L2-installed-late-runs', 'L3-why-said', 'L4-hooks-late'

Log "os=$([Environment]::OSVersion.VersionString) arch=$env:PROCESSOR_ARCHITECTURE tag=$Tag"
Get-Process WWAHost -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($d in QuietWsl) { Log "wsl: $d" }
Add-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Value "`r`n127.0.0.1 relay.glass"
ipconfig /flushdns | Out-Null
# Relay for Windows 0.1.4 installs Claude Code by itself; this proof is about
# one the person installs while Relay runs, so Relay's own is off here
# (run=fresh proves that one). An older build has no such setup and reads
# nothing of this.
$env:RELAY_RUNTIME_SETUP = '0'
[Environment]::SetEnvironmentVariable('RELAY_RUNTIME_SETUP', '0', 'User')

$pre = (Get-Command claude -ErrorAction SilentlyContinue).Source
Log "claude before anything: $(if ($pre) { $pre } else { 'none' })"

Log "start=$Start"
if ($Start -eq 'folder') { New-Item -ItemType Directory -Force "$HOME\.claude" | Out-Null }
gh release download $Tag -R $Repo -p 'RelaySetup*.exe' -D dl 2>&1 | ForEach-Object { Log "gh: $_" }
$exe = Get-ChildItem dl\RelaySetup*.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$p = Start-Process $exe.FullName -ArgumentList '/S' -PassThru
[void]$p.WaitForExit(180000)
& "$InstallDir\relay.exe" service install *> "$Out\service-install.txt"
$up = [bool](WaitFor { Healthy } 90 1)
try { [IO.File]::WriteAllText($TokenKeep, [IO.File]::ReadAllText("$RelayDir\api-token").Trim()) } catch {}
foreach ($half in 'read', 'write') { [void](Api POST '/v1/connectors/claude_code/grant' @{ half = $half }) }
$rd = Get-Process relayd -ErrorAction SilentlyContinue | Select-Object -First 1
Log "relayd pid $($rd.Id) started $($rd.StartTime.ToString('HH:mm:ss'))"
Result 'L0-engine' $up "relayd answers, started before Claude Code is on this PC ($($exe.Name))"

New-Item -ItemType Directory -Force 'C:\late', 'C:\late\none', 'C:\late\held' | Out-Null

# Screen is what a held job's terminal showed, cleaned.
function Screen($id) {
  $sr = Api GET "/v1/terminals/$id/screen?since=0&wait=0" $null 20
  if ($sr -and $sr.data) { return Clean ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($sr.data))) }
  return ''
}
function Tail([string]$s, [int]$n = 300) { if (-not $s) { return '' }; return $s.Substring([Math]::Max(0, $s.Length - $n)) }

# --- L1: no Claude Code at all ----------------------------------------------
$t0 = Get-Date
$open = Api POST '/v1/sessions' @{ folder = 'C:\late\none'; view = 'terminal'; name = 'late-none'; runtime = 'claude-code' } 60
$took = [int]((Get-Date) - $t0).TotalMilliseconds
$said = $script:LastApiError
Log "L1 open ($took ms): $(if ($open) { $open | ConvertTo-Json -Compress -Depth 5 } else { "refused: $said" })"
Start-Sleep 8
$jobs = @((Api GET '/v1/terminals').terminals)
$none = $jobs | Where-Object { $_.name -eq 'late-none' -or $_.dir -like '*late*none*' } | Select-Object -First 1
$noneScreen = if ($none) { Screen $none.id } else { '' }
Log "L1 job: $(if ($none) { "$($none.id) ended=$($none.ended)" } else { 'none listed' }) screen: $(Tail $noneScreen)"
$l1 = [bool]((-not $open) -and $said -match 'Claude Code' -and $said -match 'install')
Result 'L1-missing-said' $l1 'with no Claude Code on the PC, the desk is told so in words' $(if ($open) { "answered 201 ($took ms); its job $(if ($none -and $none.ended) { 'ended at once' } else { 'was left' }), its terminal showing: '$(Tail $noneScreen 200)'" } elseif (-not $l1) { "refused, but not in words that say Claude Code is missing: $said" } else { '' })

# --- Claude Code arrives while relayd runs -----------------------------------
# Into a folder of its own, put on the person's Path the way an installer
# puts it (the user's Environment key, then the settings broadcast): every
# program started from now on finds it; relayd was started before.
npm install -g --prefix 'C:\late-npm' '@anthropic-ai/claude-code' *> "$Out\npm-install.txt"
$claude = @('C:\late-npm\claude.cmd', 'C:\late-npm\claude.ps1', 'C:\late-npm\claude.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
$ver = if ($claude) { (& $claude --version 2>&1 | Select-Object -First 1) } else { '' }
Log "claude installed late: $claude ($ver)"
# Its first run asks nothing (as the proof's setup does).
New-Item -ItemType Directory -Force "$HOME\.claude" | Out-Null
$v = ($ver -replace '\s.*$', '')
$trusted = @{}
foreach ($d in 'C:/', 'C:\', 'C:/late', 'C:\late', 'C:/late/held', 'C:\late\held') { $trusted[$d] = @{ hasTrustDialogAccepted = $true; hasCompletedProjectOnboarding = $true; allowedTools = @(); projectOnboardingSeenCount = 1 } }
$key = 'sk-ant-api03-proof' + ('x' * 76) + 'AAAAProofHarness0001'
$state = [ordered]@{ hasCompletedOnboarding = $true; lastOnboardingVersion = $v; lastReleaseNotesSeen = $v; hasSeenAutoDefaultNudge = $true; hasResetAutoModeOptInForDefaultOffer = $true; theme = 'dark'; numStartups = 5; autoUpdates = $false; customApiKeyResponses = @{ approved = @($key.Substring($key.Length - 20)); rejected = @() }; projects = $trusted }
[IO.File]::WriteAllText("$HOME\.claude.json", ($state | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
$envs = @{ ANTHROPIC_BASE_URL = "http://127.0.0.1:$StubPort"; ANTHROPIC_API_KEY = $key; CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'; DISABLE_AUTOUPDATER = '1' }
# Into the settings there may be already (hooks Relay added at its start).
$settings = @{}
try { $old = Get-Content "$HOME\.claude\settings.json" -Raw -ErrorAction Stop | ConvertFrom-Json; foreach ($p in $old.PSObject.Properties) { $settings[$p.Name] = $p.Value } } catch {}
$settings['env'] = $envs
[IO.File]::WriteAllText("$HOME\.claude\settings.json", ($settings | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $false))

# Then onto the person's Path, as the installer's last step.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', (@($userPath, 'C:\late-npm') | Where-Object { $_ }) -join ';', 'User')

# --- L2: a job from the desk runs the Claude Code installed late ------------
$t0 = Get-Date
$open = Api POST '/v1/sessions' @{ folder = 'C:\late\held'; view = 'terminal'; name = 'late-held'; runtime = 'claude-code' } 60
$took = [int]((Get-Date) - $t0).TotalMilliseconds
Log "L2 open ($took ms): $(if ($open) { $open | ConvertTo-Json -Compress -Depth 5 } else { "refused: $($script:LastApiError)" })"
$id = if ($open) { $open.opened.native_id } else { '' }
if (-not $id -and $open) { $id = $open.opened.session -replace '^claude-code/', '' }
# Claude Code ready at its prompt: older ones say "? for shortcuts", 2.1 says its
# mode ("shift+tab to cycle") under the prompt.
$ready = 'for shortcuts|shift\+tab to cycle'
$screen = ''
$job = $null
if ($open) {
  $end = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $end) {
    $job = @((Api GET '/v1/terminals').terminals) | Where-Object { $_.name -eq 'late-held' -or $_.dir -like '*late*held*' } | Select-Object -First 1
    if ($job) { $screen = Screen $job.id }
    if (($job -and $job.ended) -or $screen -match $ready) { break }
    Start-Sleep 2
  }
}
Log "L2 job: $(if ($job) { "$($job.id) ended=$($job.ended)" } else { 'none' }) screen: $(Tail $screen)"
$l2 = [bool]($job -and -not $job.ended -and $screen -match $ready)
Result 'L2-installed-late-runs' $l2 'Claude Code installed after relayd started runs in a job started from the desk' $(if (-not $open) { "refused: $($script:LastApiError)" } elseif (-not $job) { 'no job listed' } elseif ($job.ended) { "the job ended at once; its terminal: '$(Tail $screen 200)'" } elseif (-not $l2) { "never showed Claude Code ready: '$(Tail $screen 200)'" } else { '' })

# --- L3: a job that cannot start says why -------------------------------------
# Claude Code there but unable to start (its settings file is not JSON): the
# desk is told what its terminal said, not handed an id that never comes up.
Copy-Item "$HOME\.claude\settings.json" "$HOME\.claude\settings.good" -Force
$bad = "C:\late-npm\node_modules\@anthropic-ai\claude-code"
$broke = "$bad.away"
Rename-Item $bad $broke -ErrorAction SilentlyContinue
$open3 = Api POST '/v1/sessions' @{ folder = 'C:\late\held'; view = 'terminal'; name = 'late-broken'; runtime = 'claude-code' } 60
$said3 = $script:LastApiError
Rename-Item $broke $bad -ErrorAction SilentlyContinue
Log "L3 open: $(if ($open3) { $open3 | ConvertTo-Json -Compress -Depth 5 } else { "refused: $said3" })"
$l3 = [bool]((-not $open3) -and $said3 -match 'did not start|didn.t start|n.a pas d.marr')
Result 'L3-why-said' $l3 'a job whose Claude Code ends as it starts is refused with what its terminal said' $(if ($open3) { 'answered 201 for a Claude Code that cannot run' } elseif (-not $l3) { "refused, but not saying it did not start: $said3" } else { '' })

# --- L4: its hooks, added once it arrived --------------------------------------
$hooks = WaitFor { $j = Get-Content "$HOME\.claude\settings.json" -Raw -ErrorAction SilentlyContinue; if ($j -and $j -match 'session-hook') { $j } else { $null } } 40 1
Copy-Item "$HOME\.claude\settings.json" "$Out\claude-settings-end.json" -ErrorAction SilentlyContinue
Result 'L4-hooks-late' ([bool]$hooks) "Claude Code's hooks were added after it arrived on the PC" $(if (-not $hooks) { 'no session-hook in ~/.claude/settings.json 40 s after the last job' } else { '' })

Copy-Item "$RelayDir\Logs\*" $Out -ErrorAction SilentlyContinue
