param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ Die 'EnsureDir: empty path' }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){ $dir = Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $t = $Text.Replace("`r`n","`n").Replace("`r","`n"); if(-not $t.EndsWith("`n")){ $t += "`n" }; $enc = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }
function Parse-GateFile([string]$Path){ $t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e); if($e -and $e.Count -gt 0){ $x=$e[0]; Die ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message) } }

$Runner = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
$lines = Get-Content -LiteralPath $Runner -Encoding UTF8
$changed = 0

for($n=0;$n -lt $lines.Count;$n++){
  $ln = $lines[$n]
  $before = $ln

  # Dictionary[string,object]([System.StringComparer]::Ordinal) -> -TypeName/-ArgumentList
  $ln = [regex]::Replace($ln, '^\s*New-Object\s+System\.Collections\.Generic\.Dictionary\[string,object\]\s*\(\s*\[System\.StringComparer\]::Ordinal\s*\)\s*$', 'New-Object -TypeName '''System.Collections.Generic.Dictionary[string,object]''' -ArgumentList @([System.StringComparer]::Ordinal)' )

  # HashSet[string]([System.StringComparer]::Ordinal) -> -TypeName/-ArgumentList (if present)
  $ln = [regex]::Replace($ln, '^\s*New-Object\s+System\.Collections\.Generic\.HashSet\[string\]\s*\(\s*\[System\.StringComparer\]::Ordinal\s*\)\s*$', 'New-Object -TypeName '''System.Collections.Generic.HashSet[string]''' -ArgumentList @([System.StringComparer]::Ordinal)' )

  if($ln -ne $before){ $lines[$n] = $ln; $changed++ }
}

if($changed -eq 0){ Die 'REPLACE_NOOP: no generic New-Object constructor lines rewritten' }

Write-Utf8NoBomLf $Runner ((@($lines) -join "`n") + "`n")
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner + " newobject_fixes=" + $changed) -ForegroundColor Green
