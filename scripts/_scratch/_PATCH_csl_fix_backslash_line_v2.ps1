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

# Replace the one corrupted line inside _ParseString:
$fixed = '    if($ch -ne ''\''){ [void]$sb.Append($ch); $i.Value++; continue }'
$did = $false
for($k=0;$k -lt $lines.Length;$k++){
  $ln = $lines[$k]
  if($ln -match 'Append\(\$ch\)' -and $ln -match 'continue'){
    $lines[$k] = $fixed
    $did = $true
    break
  }
}
if(-not $did){ Die 'REPLACE_NOOP: could not find Append($ch)+continue line to replace' }

$out = ($lines -join "`n")
if(-not $out.EndsWith("`n")){ $out += "`n" }
Write-Utf8NoBomLf $Runner $out
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner) -ForegroundColor Green
