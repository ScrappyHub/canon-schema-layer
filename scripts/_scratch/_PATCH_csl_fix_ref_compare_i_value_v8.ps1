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

# Function block detection: patch only inside functions with signature containing [ref]$i
$funcStarts = New-Object System.Collections.Generic.List[int]
for($n=0;$n -lt $lines.Count;$n++){ if($lines[$n] -match '^function\s+' ){ [void]$funcStarts.Add($n) } }
if($funcStarts.Count -eq 0){ Die 'NO_FUNCTIONS_FOUND' }
[void]$funcStarts.Add($lines.Count) # sentinel

$ops = @('-lt','-le','-gt','-ge','-eq','-ne')
for($fi=0;$fi -lt ($funcStarts.Count-1);$fi++){
  $s = $funcStarts[$fi]
  $e = $funcStarts[$fi+1]-1
  if($lines[$s] -notmatch '\[\s*ref\s*\]\s*\$i\b'){ continue }
  for($k=$s;$k -le $e;$k++){
    $ln = $lines[$k]
    $before = $ln
    foreach($op in $ops){
      # Replace standalone $i <op> with $i.Value <op> (avoid $id / $item etc)
      $pat = '(?<![\w$])\$i\s*' + [regex]::Escape($op) + '\b'
      $rep = '$i.Value ' + $op
      $ln = [regex]::Replace($ln, $pat, $rep)
    }
    if($ln -ne $before){ $lines[$k] = $ln; $changed++ }
  }
}

if($changed -eq 0){ Die 'REPLACE_NOOP: no $i comparisons rewritten (expected at least one)' }

# Fail if any remaining compare uses $i directly (within any [ref]$i function)
for($fi=0;$fi -lt ($funcStarts.Count-1);$fi++){
  $s = $funcStarts[$fi]; $e = $funcStarts[$fi+1]-1
  if($lines[$s] -notmatch '\[\s*ref\s*\]\s*\$i\b'){ continue }
  for($k=$s;$k -le $e;$k++){
    $ln = $lines[$k]
    if($ln -match '(?<![\w$])\$i\s*-(lt|le|gt|ge|eq|ne)\b'){ Die ("PATCH_INCOMPLETE: still compares $i directly at line " + ($k+1)) }
  }
}

Write-Utf8NoBomLf $Runner ((@($lines) -join "`n") + "`n")
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner + " comparisons_fixed=" + $changed) -ForegroundColor Green
