# Keeps what the run saw: Relay's logs (the local console's token blanked,
# for the artifacts are readable by anyone), the hook files, the queue of
# app events, Claude Code's settings and registry, and the processes left.
. "$PSScriptRoot\lib.ps1"
New-Item -ItemType Directory -Force "$Out\logs", "$Out\session-hooks", "$Out\claude-sessions" | Out-Null
Copy-Item "$RelayDir\Logs\*" "$Out\logs" -Recurse -ErrorAction SilentlyContinue
Copy-Item "$RelayDir\session-hooks\*" "$Out\session-hooks" -ErrorAction SilentlyContinue
Copy-Item "$HOME\.claude\sessions\*.json" "$Out\claude-sessions" -ErrorAction SilentlyContinue
Copy-Item "$HOME\.claude\settings.json" "$Out\claude-settings-end.json" -ErrorAction SilentlyContinue
# The sessions' transcripts: what each tool call returned (the helper's run).
New-Item -ItemType Directory -Force "$Out\transcripts" | Out-Null
Get-ChildItem "$HOME\.claude\projects" -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName "$Out\transcripts\$($_.Directory.Name)-$($_.Name)" -ErrorAction SilentlyContinue }
icacls "$RelayDir" 2>&1 | Set-Content "$Out\icacls-relay.txt"
icacls "$RelayDir\api-token" 2>&1 | Add-Content "$Out\icacls-relay.txt"
foreach ($f in 'app.json', 'app-settings.json', 'consent.json', 'config.toml') { Copy-Item "$RelayDir\$f" "$Out\" -ErrorAction SilentlyContinue }
$tok = Token
Get-ChildItem $Out -Recurse -File -Include *.log, *.txt, *.json, *.toml -ErrorAction SilentlyContinue | ForEach-Object {
  $t = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
  if (-not $t) { return }
  $u = $t -replace '(token[=\s":]+)[A-Za-z0-9_\-]{8,}', '$1x'
  if ($tok) { $u = $u.Replace($tok, 'x') }
  if ($u -ne $t) { [IO.File]::WriteAllText($_.FullName, $u) }
}
Get-Process | Where-Object { $_.ProcessName -match 'Relay|relay|claude|node|WindowsTerminal|OpenConsole|bash|msedgewebview2' } |
  Select-Object ProcessName, Id, StartTime, MainWindowTitle | Format-Table -AutoSize | Out-String -Width 220 | Set-Content "$Out\processes.txt"
