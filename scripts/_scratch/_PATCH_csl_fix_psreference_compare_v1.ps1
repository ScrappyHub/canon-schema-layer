param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function Parse-GateFile([string]$Path){
  $t=$null; $e=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
  if($e -and $e.Count -gt 0){ $x=$e[0]; Die ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message) }
}
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}

$Runner = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
$raw = [System.IO.File]::ReadAllText($Runner,[System.Text.UTF8Encoding]::new($false))

# 1) Make Parse-StrictJson use a ref-int so $i is always PSReference and comparisons must use .Value
$raw = [regex]::Replace($raw, '(?s)function\s+Parse-StrictJson\s*\(\[byte\[\]\]\$bytes\)\s*\{.*?\}', { param($m)
  $blk = $m.Value
  $blk = $blk -replace '\$\s*i\s*=\s*0', '$i = [ref]0'
  $blk = $blk -replace 'if\s*\(\s*\$i\s*-ne\s*\$s\.Length\s*\)', 'if($i.Value -ne $s.Length)'
  return $blk
})

# 2) Fix any remaining comparisons like: $i -lt / -ge / -eq ... to $i.Value -lt ...
$raw = [regex]::Replace($raw, '(?m)(?<!\.)\$(i)\s*-(lt|le|gt|ge|eq|ne)\b', '$${1}.Value -$2')

Write-Utf8NoBomLf $Runner $raw
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner) -ForegroundColor Green
