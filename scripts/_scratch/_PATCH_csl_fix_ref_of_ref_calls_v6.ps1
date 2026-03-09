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
$before = $raw

# Fix the known nested-ref call(s): inside ref-param functions, do NOT pass ([ref]$i); pass $i.
$raw = $raw.Replace('_ParseHex4 $s ([ref]$i)','_ParseHex4 $s $i')
$raw = $raw.Replace('_ParseHex4 $s ([ref]$j)','_ParseHex4 $s $j')

if($raw -eq $before){ Write-Host 'NOTE: no ref-of-ref call sites found (no-op) — continuing' -ForegroundColor Yellow } else { Write-Host 'PATCH_APPLIED: removed ref-of-ref call site(s)' -ForegroundColor Green }

# fail if any "([ref]$i)" remains anywhere (very conservative; catches the main bad pattern)
if($raw -match '\(\s*\[ref\]\s*\$i\s*\)' ){ Die 'PATCH_INCOMPLETE: still contains ([ref]$i) pattern' }

Write-Utf8NoBomLf $Runner $raw
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner) -ForegroundColor Green
