param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}
function Parse-GateFile([string]$Path){
  $t=$null; $e=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
  if($e -and $e.Count -gt 0){ $x=$e[0]; Die ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message) }
}

$PatchPath = Join-Path $RepoRoot "scripts\_scratch\_PATCH_csl_overwrite_runner_flat_v5.ps1"
$Target    = Join-Path $RepoRoot "scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1"

# write patcher content (single here-string INSIDE the run-script, safely terminated)
$Patch = @'
param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}
function Parse-GateFile([string]$Path){
  $t=$null; $e=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
  if($e -and $e.Count -gt 0){ $x=$e[0]; Die ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message) }
}

$Target = Join-Path $RepoRoot "scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1"

# ---- overwrite runner with FLAT strict runner (v5) ----
$Runner = @'

'@

Write-Utf8NoBomLf $Target $Runner
Parse-GateFile $Target
Write-Host ("PATCH_OK+PARSE_OK: " + $Target) -ForegroundColor Green
'@

Write-Utf8NoBomLf $PatchPath $Patch
Parse-GateFile $PatchPath
Write-Host ("WROTE+PARSE_OK: " + $PatchPath) -ForegroundColor Green

$PSExe = (Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe")
if (-not (Test-Path -LiteralPath $PSExe -PathType Leaf)) { Die ("MISSING_POWERSHELL_EXE: " + $PSExe) }
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PatchPath -RepoRoot $RepoRoot | Out-Host

Parse-GateFile $Target
Write-Host ("RUNNER_PARSE_OK: " + $Target) -ForegroundColor Green
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Target -RepoRoot $RepoRoot -Mode All | Out-Host
