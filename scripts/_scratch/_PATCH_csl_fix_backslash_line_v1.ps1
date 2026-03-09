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

# Fix the corrupted backslash-compare line inside _ParseString
$needle = 'if($ch -ne '
$idx = $raw.IndexOf($needle)
if($idx -lt 0){ Die "NEEDLE_NOT_FOUND: cannot locate _ParseString backslash compare line" }

# Replace any line that starts with "    if($ch -ne" and contains "Append($ch); $i.Value++; continue"
$raw2 = [regex]::Replace($raw, '(?m)^\s*if\(\$ch\s*\-ne.*Append\(\$ch\);\s*\$i\.Value\+\+;\s*continue\s*\}\s*$', '    if($ch -ne ''\\''){ [void]$sb.Append($ch); $i.Value++; continue }')
if($raw2 -eq $raw){ Die "REPLACE_NOOP: pattern did not match (runner may differ)" }

Write-Utf8NoBomLf $Runner $raw2
Parse-GateFile $Runner
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner) -ForegroundColor Green
