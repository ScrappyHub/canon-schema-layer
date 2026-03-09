param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ Die 'EnsureDir: empty path' }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $t=$Text.Replace("`r`n","`n").Replace("`r","`n"); if(-not $t.EndsWith("`n")){ $t += "`n" }; $enc=New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }
function Parse-GateFile([string]$Path){ $t=$null;$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e); if($e -and $e.Count -gt 0){ $x=$e[0]; Die ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message) } }

$Runner = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
$lines = Get-Content -LiteralPath $Runner -Encoding UTF8
$changed = 0

# Split a string by top-level commas (ignores commas inside (), [], {}, and inside quotes)
function Split-TopLevelComma([string]$s){
  $parts = New-Object System.Collections.Generic.List[string]
  $sb = New-Object System.Text.StringBuilder
  $p=0;$b=0;$c=0;$inS=$false;$inD=$false;$esc=$false
  for($i=0;$i -lt $s.Length;$i++){
    $ch = $s[$i]
    if($esc){ [void]$sb.Append($ch); $esc=$false; continue }
    if($inS){ if($ch -eq "'"){ $inS=$false }; [void]$sb.Append($ch); continue }
    if($inD){ if($ch -eq '`'){ $esc=$true; [void]$sb.Append($ch); continue } ; if($ch -eq '"'){ $inD=$false }; [void]$sb.Append($ch); continue }
    if($ch -eq "'"){ $inS=$true; [void]$sb.Append($ch); continue }
    if($ch -eq '"'){ $inD=$true; [void]$sb.Append($ch); continue }
    switch($ch){
      '(' { $p++; [void]$sb.Append($ch); continue }
      ')' { if($p -gt 0){ $p-- }; [void]$sb.Append($ch); continue }
      '[' { $b++; [void]$sb.Append($ch); continue }
      ']' { if($b -gt 0){ $b-- }; [void]$sb.Append($ch); continue }
      '{' { $c++; [void]$sb.Append($ch); continue }
      '}' { if($c -gt 0){ $c-- }; [void]$sb.Append($ch); continue }
      ',' {
        if(($p -eq 0) -and ($b -eq 0) -and ($c -eq 0)){
          $parts.Add($sb.ToString().Trim()) | Out-Null
          [void]$sb.Clear()
          continue
        }
      }
    }
    [void]$sb.Append($ch)
  }
  $tail = $sb.ToString().Trim()
  if($tail.Length -gt 0){ $parts.Add($tail) | Out-Null }
  return @($parts.ToArray())
}

for($n=0;$n -lt $lines.Count;$n++){
  $ln = $lines[$n]
  if($ln -notmatch '\bNew-Object\s+@\('){ continue }
  $before = $ln
  $m = [regex]::Match($ln, '\bNew-Object\s+@\((?<inner>.*)\)\s*$')
  if(-not $m.Success){ continue }
  $inner = $m.Groups['inner'].Value
  $parts = Split-TopLevelComma $inner
  if($parts.Count -lt 1){ Die ("NEWOBJECT_SPLAT_BAD_INNER at line " + ($n+1)) }
  $typeExpr = $parts[0]
  if([string]::IsNullOrWhiteSpace($typeExpr)){ Die ("NEWOBJECT_SPLAT_EMPTY_TYPENAME at line " + ($n+1)) }
  if($parts.Count -eq 1){
    $ln = [regex]::Replace($ln, '\bNew-Object\s+@\((?<inner>.*)\)\s*$', ("New-Object -TypeName " + $typeExpr))
  } else {
    $rest = ($parts[1..($parts.Count-1)] -join ', ')
    $ln = [regex]::Replace($ln, '\bNew-Object\s+@\((?<inner>.*)\)\s*$', ("New-Object -TypeName " + $typeExpr + " -ArgumentList @(" + $rest + ")"))
  }
  if($ln -ne $before){ $lines[$n] = $ln; $changed++ }
}

if($changed -eq 0){ Die 'REPLACE_NOOP: no New-Object @(...) patterns rewritten' }
Write-Utf8NoBomLf $Runner ((@($lines) -join "`n") + "`n")
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner + " newobject_fixes=" + $changed) -ForegroundColor Green
