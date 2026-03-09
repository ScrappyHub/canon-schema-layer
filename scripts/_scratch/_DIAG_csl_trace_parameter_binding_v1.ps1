param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
$Runner = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
$ts = (Get-Date -Format 'yyyyMMdd_HHmmss')
$TracePath = Join-Path (Join-Path $RepoRoot 'scripts\_scratch') ("csl_parambind_trace_" + $ts + ".log")
Write-Host ("TRACE_START: " + $Runner) -ForegroundColor Yellow
Write-Host ("TRACE_OUT:   " + $TracePath) -ForegroundColor Yellow
try {
  Trace-Command -Name ParameterBinding -FilePath $TracePath -Expression {
    & $Runner -RepoRoot $RepoRoot -Mode All | Out-Host
  } | Out-Null
  Write-Host "TRACE_RUNNER_OK" -ForegroundColor Green
} catch {
  Write-Host "TRACE_RUNNER_FAIL" -ForegroundColor Red
  Write-Host ("ERR_TYPE: " + $_.Exception.GetType().FullName) -ForegroundColor Red
  Write-Host ("ERR_MSG:  " + $_.Exception.Message) -ForegroundColor Red
}

# Print the most relevant tail of the trace (last 200 lines)
if(Test-Path -LiteralPath $TracePath -PathType Leaf){
  $all = Get-Content -LiteralPath $TracePath -Encoding UTF8
  $take = 200; if($all.Count -lt $take){ $take = $all.Count }
  Write-Host ("TRACE_TAIL_LINES: " + $take) -ForegroundColor Yellow
  for($i=($all.Count-$take); $i -lt $all.Count; $i++){ if($i -ge 0){ $all[$i] } }
} else {
  Write-Host "TRACE_MISSING: no trace file produced" -ForegroundColor Red
}
