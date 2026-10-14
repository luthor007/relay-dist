# The run's verdict: every check's line, then a failure for each FAIL and for
# each check a step promised and never reported (a step that died early).
$Out = Join-Path (Get-Location) 'out'
$results = @(Get-Content "$Out\results.txt" -ErrorAction SilentlyContinue)
$expected = @(Get-Content "$Out\expected.txt" -ErrorAction SilentlyContinue | Sort-Object -Unique)
$results | ForEach-Object { $_ }
$bad = @($results | Where-Object { $_ -like 'FAIL *' }).Count
foreach ($id in $expected) {
  if (-not ($results | Where-Object { $_ -match "^(PASS|FAIL|N/A) +$([regex]::Escape($id)) " })) { "FAIL $id never reported (its step stopped before it)"; $bad++ }
}
"pass=$(@($results | Where-Object { $_ -like 'PASS *' }).Count) fail=$bad n/a=$(@($results | Where-Object { $_ -like 'N/A *' }).Count)"
exit $bad
