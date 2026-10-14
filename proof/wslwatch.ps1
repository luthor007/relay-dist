# Started by setup.ps1 before Relay is installed, hidden, and left running for
# the whole job (the runner ends it with the job): every WSL prompt the image
# opens is minimized within a second (QuietWsl), and who started it is kept in
# out\wsl-watch.log, so a window of the image's never stands in for one of
# Relay's. A wsl.exe started by Relay or Claude Code would show here by its
# parents, and that would be Relay's to answer for, not the harness's.
param([int]$Minutes = 90)
. "$PSScriptRoot\lib.ps1"
$file = "$Out\wsl-watch.log"
function W($s) { try { Add-Content -Path $file -Value "$(Get-Date -Format 'HH:mm:ss.fff') $s" -Encoding UTF8 } catch {} }
W "watching (pid $PID); wsl.exe on this PC: $(@(Get-Command wsl.exe -ErrorAction SilentlyContinue).Source)"
$end = (Get-Date).AddMinutes($Minutes)
while ((Get-Date) -lt $end) {
  try { foreach ($d in QuietWsl) { W $d } } catch { W "error: $($_.Exception.Message)" }
  Start-Sleep -Milliseconds 1000
}
W 'done'
