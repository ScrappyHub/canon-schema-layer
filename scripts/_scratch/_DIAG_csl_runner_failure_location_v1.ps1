param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
$Runner = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
Write-Host ("DIAG_START: " + $Runner) -ForegroundColor Yellow
try {
  & $Runner -RepoRoot $RepoRoot -Mode All | Out-Host
  Write-Host "DIAG_RUNNER_OK" -ForegroundColor Green
} catch {
  $ex = $_.Exception
  $ii = $_.InvocationInfo
  Write-Host "DIAG_RUNNER_FAIL" -ForegroundColor Red
  Write-Host ("TYPE: " + $ex.GetType().FullName) -ForegroundColor Red
  Write-Host ("MSG:  " + $ex.Message) -ForegroundColor Red
  if($ii){
    Write-Host ("AT:   " + $ii.ScriptName + ":" + $ii.ScriptLineNumber + ":" + $ii.OffsetInLine) -ForegroundColor Yellow
    if($ii.Line){ Write-Host ("LINE: " + $ii.Line) -ForegroundColor Yellow }
    if($ii.PositionMessage){ Write-Host $ii.PositionMessage -ForegroundColor Yellow }
  }
  throw
}
