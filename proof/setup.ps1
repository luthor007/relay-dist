# The proof's setup, signed out: Relay from the draft's installer, real
# Claude Code from npm pointed at the local stub, the engine, Relay's hooks in
# Claude Code's settings, and the desk open on this PC's console.
param([Parameter(Mandatory = $true)][string]$Tag, [string]$Repo = 'luthor007/relay-dist')
. "$PSScriptRoot\lib.ps1"
Expect 'S1-install', 'S2-engine', 'S3-claude-code', 'S4-stub', 'H1-hooks-installed', 'D0-desk-console'

Log "os=$([Environment]::OSVersion.VersionString) arch=$env:PROCESSOR_ARCHITECTURE tag=$Tag"
$wv = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
Log "webview2=$($wv.pv) node=$(node --version) git=$(git --version) user=$env:USERNAME"
Log "session: $((quser 2>&1) -join ' | ')"
# The ARM image's Microsoft account window takes the foreground from everything.
Get-Process WWAHost -ErrorAction SilentlyContinue | Stop-Process -Force
# A test PC never reaches Relay's servers or counts as a customer.
Add-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Value "`r`n127.0.0.1 relay.glass"
ipconfig /flushdns | Out-Null

# --- Relay, from the draft, as a standard user installs it ----------------
gh release download $Tag -R $Repo -p 'RelaySetup*.exe' -D dl 2>&1 | ForEach-Object { Log "gh: $_" }
$exe = Get-ChildItem dl\RelaySetup*.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $exe) {
  Result 'S1-install' $false "Relay installed from $Tag" "the release holds no RelaySetup*.exe"
  exit 0
}
Log "installer $($exe.Name) $($exe.Length) bytes"
$p = Start-Process $exe.FullName -ArgumentList '/S' -PassThru
$done = $p.WaitForExit(180000)
$missing = @('relay.exe', 'relayd.exe', 'relayw.exe', 'RelayApp.exe') | Where-Object { -not (Test-Path "$Dir\$_") }
Result 'S1-install' ([bool]($done -and $p.ExitCode -eq 0 -and -not $missing)) "Relay installed from $Tag ($($exe.Name))" $(if ($missing) { "missing: $($missing -join ', ')" } elseif (-not $done) { 'installer did not finish in 3 min' } else { '' })

# --- Claude Code, real, pointed at the stub --------------------------------
$key = 'sk-ant-api03-proof' + ('x' * 76) + 'AAAAProofHarness0001'
$envs = [ordered]@{
  ANTHROPIC_BASE_URL                       = "http://127.0.0.1:$StubPort"
  ANTHROPIC_API_KEY                        = $key
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
  DISABLE_AUTOUPDATER                      = '1'
  DISABLE_TELEMETRY                        = '1'
  DISABLE_ERROR_REPORTING                  = '1'
  CLAUDE_CODE_ENABLE_TELEMETRY             = '0'
}
foreach ($k in $envs.Keys) {
  Set-Item "env:$k" $envs[$k]
  [Environment]::SetEnvironmentVariable($k, $envs[$k], 'User')
  Add-Content -Path $env:GITHUB_ENV -Value "$k=$($envs[$k])"
}
npm install -g '@anthropic-ai/claude-code' *> "$Out\npm-install.txt"
$claude = (Get-Command claude.cmd -ErrorAction SilentlyContinue).Source
if (-not $claude) { $claude = (Get-Command claude -ErrorAction SilentlyContinue).Source }
$ver = if ($claude) { (& $claude --version 2>&1 | Select-Object -First 1) } else { '' }
Log "claude=$claude version=$ver"
Add-Content -Path $env:GITHUB_ENV -Value "PROOF_CLAUDE=$claude"
Result 'S3-claude-code' ([bool]($claude -and $ver -match '\d+\.\d+')) "Claude Code installed from npm ($ver)" $(if (-not $claude) { 'no claude on PATH after npm install -g (out\npm-install.txt)' } else { '' })

# Its first run asks nothing: onboarding done, these folders trusted, the
# stub's key approved, the stub in its settings too (which Claude Code
# applies to itself and to everything it runs).
New-Item -ItemType Directory -Force "$HOME\.claude", $Work, "$Work\held", "$Work\.claude" | Out-Null
$trusted = @{}
foreach ($d in 'C:/', 'C:\', 'C:/proof', 'C:\proof', 'C:/proof/held', 'C:\proof\held') {
  $trusted[$d] = @{ hasTrustDialogAccepted = $true; hasCompletedProjectOnboarding = $true; allowedTools = @(); projectOnboardingSeenCount = 1 }
}
$state = [ordered]@{
  hasCompletedOnboarding  = $true
  lastOnboardingVersion   = ($ver -replace '\s.*$', '')
  theme                   = 'dark'
  numStartups             = 5
  autoUpdates             = $false
  customApiKeyResponses   = @{ approved = @($key.Substring($key.Length - 20)); rejected = @() }
  projects                = $trusted
}
[IO.File]::WriteAllText("$HOME\.claude.json", ($state | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
# "manual": every edit asks, as a person's default (Claude Code 2.1's name
# for "default"); without it a fresh 2.1 offers auto mode and asks nothing.
$settings = @{ env = $envs; permissions = @{ defaultMode = 'manual' } }
[IO.File]::WriteAllText("$HOME\.claude\settings.json", ($settings | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
# The helper the proof session starts is allowed in that folder, so no
# prompt but the ones under test is ever raised.
$local = @{ permissions = @{ allow = @('Bash(env -u CLAUDECODE claude -p:*)', 'Bash(env:*)', 'Bash(claude -p:*)', 'Bash(claude:*)') } }
[IO.File]::WriteAllText("$Work\.claude\settings.local.json", ($local | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))

# --- The stub --------------------------------------------------------------
$stub = Start-Process node -ArgumentList "`"$PSScriptRoot\stub.js`" $StubPort `"$Out\stub.log`"" -WindowStyle Hidden -PassThru
Add-Content -Path $env:GITHUB_ENV -Value "PROOF_STUB_PID=$($stub.Id)"
$ans = WaitFor {
  try {
    $b = '{"model":"m","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'
    (Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$StubPort/v1/messages" -ContentType 'application/json' -Body $b -TimeoutSec 3).content[0].text
  } catch { $null }
} 20
Result 'S4-stub' ([bool]($ans -eq 'ok')) "the Messages API stub answers on 127.0.0.1:$StubPort"

# --- The engine, started with Claude Code there ----------------------------
& "$Dir\relay.exe" service install *> "$Out\service-install.txt"
$up = [bool](WaitFor { Healthy } 90 1)
Result 'S2-engine' $up 'relayd answers on 127.0.0.1:8787 (signed out, not joined)' $(if (-not $up) { 'no /healthz in 90 s (out\service-install.txt)' } else { '' })

# Claude Code connected, both halves, as a person turns it on in the
# console's Connectors (a joined PC's phone does the same): Relay's held jobs
# and its sessions list answer only for a connected Claude Code.
foreach ($half in 'read', 'write') {
  $g = Api POST '/v1/connectors/claude_code/grant' @{ half = $half }
  Log "grant claude_code $half -> $($g | ConvertTo-Json -Compress) $(if ($null -eq $g) { $script:LastApiError })"
}

# relayd adds Claude Code's hooks as it starts (mendSessionHooks): the seven
# events, each running this install's relayd.exe session-hook.
$hooksOk = WaitFor {
  $j = Get-Content "$HOME\.claude\settings.json" -Raw -ErrorAction SilentlyContinue
  if ($j -and $j -match 'session-hook') { $j } else { $null }
} 60 1
Copy-Item "$HOME\.claude\settings.json" "$Out\claude-settings.json" -ErrorAction SilentlyContinue
$events = @()
$cmds = @()
if ($hooksOk) {
  $s = $hooksOk | ConvertFrom-Json
  foreach ($p in $s.hooks.PSObject.Properties) {
    foreach ($g in @($p.Value)) { foreach ($h in @($g.hooks)) {
      if ($h.command -match 'session-hook') { $events += $p.Name; $cmds += "$($p.Name): $($h.command) shell=$($h.shell) timeout=$($h.timeout)" }
    } }
  }
}
$cmds | ForEach-Object { Log "hook $_" }
Get-Content $RelaydLog -ErrorAction SilentlyContinue | Select-String 'session hooks' | ForEach-Object { Log "relayd.log: $_" }
$want = 'SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd'
$lack = $want | Where-Object { $events -notcontains $_ }
$form = if ($cmds) { ($cmds[0] -replace '^[^:]+: ', '') } else { '' }
Result 'H1-hooks-installed' ([bool]($hooksOk -and -not $lack)) "relayd added its Claude Code hooks to settings.json ($form)" $(if (-not $hooksOk) { 'no session-hook in ~/.claude/settings.json 60 s after relayd started' } elseif ($lack) { "missing events: $($lack -join ', ')" } else { '' })

# --- The desk, on this PC's console ----------------------------------------
# First run done as a person would, then the app as a joined PC's: the desk
# opens on the local relayd's console (RELAY_APP_NO_SIGN_IN stands in for a
# signed-in app, as in the smoke run).
Start-Sleep 8
$gs = FindLike 'Get started' 15
if ($gs) { try { $gs.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch {} ; Start-Sleep 3 }
if (Procs) { Start-Process $App -ArgumentList '--quit'; [void](WaitFor { -not (Procs) } 30 1) }
Get-Process RelayApp -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
$saved = @{}
if (Test-Path "$R\app.json") { (Get-Content "$R\app.json" -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $saved[$_.Name] = $_.Value } }
$saved['joined'] = $true; $saved['finished'] = $true
[IO.File]::WriteAllText("$R\app.json", ($saved | ConvertTo-Json -Compress))
[Environment]::SetEnvironmentVariable('RELAY_APP_NO_SIGN_IN', '1', 'User')
$env:RELAY_APP_NO_SIGN_IN = '1'
Add-Content -Path $env:GITHUB_ENV -Value 'RELAY_APP_NO_SIGN_IN=1'

# The brief asked for WebView2's remote debugging through
# WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS; RelayApp.exe sets that variable
# itself, so the policy key is tried too, and the result recorded.
$args9222 = '--remote-debugging-port=9222 --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows --disable-features=CalculateNativeWinOcclusion,IntensiveWakeUpThrottling'
foreach ($root in 'HKCU:', 'HKLM:') {
  $k = "$root\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments"
  New-Item -Path $k -Force -ErrorAction SilentlyContinue | Out-Null
  New-ItemProperty -Path $k -Name 'RelayApp.exe' -Value $args9222 -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
}
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = $args9222
$n = (AppLogLines).Count
Start-Process $App
$loaded = [bool](WaitFor { AppLogSince $n | Select-String -Quiet 'desk: the console loaded' } 60 1)
Start-Sleep 3
# Windows Server 2025 and the ARM image leave Search's flyout over everything.
if ([ProofInput]::FrontProcess() -eq 'SearchHost') { [void][ProofInput]::Chord([uint16[]]@(0x1B)); Start-Sleep 1; Log "closed Windows Search's flyout" }
AppLogSince $n | Select-String 'desk:' | ForEach-Object { Log "app: $_" }
Shot 'setup-desk'
Result 'D0-desk-console' $loaded "the desk opened this PC's console ($([ProofInput]::Front()))"
$cdp = $null
try { $cdp = Invoke-RestMethod -TimeoutSec 3 'http://127.0.0.1:9222/json/version' } catch {}
Log "cdp=$([bool]$cdp) $($cdp.Browser)"
Add-Content -Path $env:GITHUB_ENV -Value "PROOF_CDP=$([int][bool]$cdp)"
