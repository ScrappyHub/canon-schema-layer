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
for($i=0; $i -lt $lines.Count; $i++){
  $ln = $lines[$i]
  if($ln -like '*"*' -and ($ln -match '\$\{[1-9]\}' -or $ln -match '\$[1-9]\b')){
    $before = $ln
    # Escape $1..$9 so PS does NOT treat them as variables inside double-quoted strings.
    for($n=1;$n -le 9;$n++){
      $tok = '$' + [string]$n
      $esc = '`$' + [string]$n
      $ln = $ln.Replace($tok,$esc)
      $tok2 = '${' + [string]$n + '}'
      $esc2 = '`$' + '{' + [string]$n + '}'
      $ln = $ln.Replace($tok2,$esc2)
    }
    if($ln -ne $before){ $lines[$i] = $ln; $changed++ }
  }
}
Write-Utf8NoBomLf $Runner ((@($lines) -join "`n") + "`n")
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner + " lines_changed=" + $changed) -ForegroundColor Green
