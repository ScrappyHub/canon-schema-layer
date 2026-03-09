param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ Die 'EnsureDir: empty path' }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){ $dir = Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $t = $Text.Replace("`r`n","`n").Replace("`r","`n"); if(-not $t.EndsWith("`n")){ $t += "`n" }; $enc = New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }
function Parse-GateFile([string]$Path){ $t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e); if($e -and $e.Count -gt 0){ $x=$e[0]; Die ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message) } }

$Runner = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
$raw = [System.IO.File]::ReadAllText($Runner,[System.Text.UTF8Encoding]::new($false))
$raw = $raw.Replace("`r`n","`n").Replace("`r","`n")

# Replace literal double-quoted group tokens with single-quoted literals, without embedding "$1" in this script.
$before = $raw
for($n=1;$n -le 9;$n++){
  $dq = [string]([char]34) + '$' + [string]$n + [string]([char]34)   # "$n"
  $sq = [string]([char]39) + '$' + [string]$n + [string]([char]39)   # '$n'
  $raw = $raw.Replace($dq,$sq)
}

if($raw -ne $before){
  Write-Host 'PATCH_APPLIED: replaced double-quoted $N tokens with single-quoted literals' -ForegroundColor Green
} else {
  Write-Host 'NOTE: no double-quoted $N tokens found (no-op) — continuing' -ForegroundColor Yellow
}

# Fail if any "$N" remain
if($raw -match '"\$[1-9]"'){ Die 'PATCH_INCOMPLETE: still contains a "$N" token' }

Write-Utf8NoBomLf $Runner $raw
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner) -ForegroundColor Green
