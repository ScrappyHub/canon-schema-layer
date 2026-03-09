param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ Die 'EnsureDir: empty path' }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){ $dir = Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $t = $Text.Replace("`r`n","`n").Replace("`r","`n"); if(-not $t.EndsWith("`n")){ $t += "`n" }; $enc = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }
function Parse-GateFile([string]$Path){ $t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e); if($e -and $e.Count -gt 0){ $x=$e[0]; Die ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message) } }

$Runner = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
$bak = $Runner + '.bak_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
Copy-Item -LiteralPath $Runner -Destination $bak -Force
$lines = Get-Content -LiteralPath $Runner -Encoding UTF8
$changed = 0

for($n=0;$n -lt $lines.Count;$n++){
  $ln = $lines[$n]
  $before = $ln
  # Fix StrictMode crash: $seen is undefined, but $set (HashSet) is the intended dup-key tracker
  $ln = [regex]::Replace($ln, '\$\s*seen\s*\.Add\s*\(\s*\$k\s*\)', '$set.Add($k)')
  if($ln -ne $before){ $lines[$n] = $ln; $changed++ }
}

if($changed -lt 1){ Die 'REPLACE_NOOP: did not find $seen.Add($k) to rewrite' }
$t = (@($lines) -join "`n")
$t = $t.Replace("`r`n","`n").Replace("`r","`n")
if(-not $t.EndsWith("`n")){ $t += "`n" }
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllBytes($Runner, $enc.GetBytes($t))
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner + " changes=" + $changed) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
