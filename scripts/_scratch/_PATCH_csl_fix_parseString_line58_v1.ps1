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

$Runner = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
$raw = [System.IO.File]::ReadAllText($Runner,[System.Text.UTF8Encoding]::new($false))
$raw = $raw.Replace("`r`n","`n").Replace("`r","`n")
$lines = $raw -split "`n",-1

# Locate _ParseString block
$start = -1; $end = -1
for($i=0;$i -lt $lines.Length;$i++){ if($lines[$i] -match '^function\s+_ParseString\s*\('){ $start=$i; break } }
if($start -lt 0){ Die 'NEEDLE_NOT_FOUND: function _ParseString(' }
for($i=$start+1;$i -lt $lines.Length;$i++){ if($lines[$i] -match '^function\s+' ){ $end=$i-1; break } }
if($end -lt 0){ $end = $lines.Length-1 }

# Replace the exact broken line: if($ch -ne '\'  (line ends there)
$fixed = '    if([int][char]$ch -ne 92){ [void]$sb.Append($ch); $i.Value++; continue }'
$did = $false
for($k=$start;$k -le $end;$k++){
  $ln = $lines[$k]
  if($ln -match '^\s*if\(\$ch\s*\-ne\s*''\\''\s*$'){
    $lines[$k] = $fixed
    $did = $true
    # If next line is the same fixed line, remove it (prevents duplicate logic)
    if(($k+1) -lt $lines.Length){
      $nxt = $lines[$k+1]
      if($nxt -eq $fixed){
        $before = @() + $lines[0..$k]
        if(($k+2) -le ($lines.Length-1)){ $after = @() + $lines[($k+2)..($lines.Length-1)] } else { $after = @() }
        $lines = @($before + $after)
      }
    }
    break
  }
}
if(-not $did){ Die 'REPLACE_NOOP: broken if($ch -ne '\' line not found inside _ParseString' }

$out = ($lines -join "`n")
if(-not $out.EndsWith("`n")){ $out += "`n" }
Write-Utf8NoBomLf $Runner $out
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner) -ForegroundColor Green
