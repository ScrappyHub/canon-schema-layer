param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
$Runner = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
$lines = Get-Content -LiteralPath $Runner -Encoding UTF8
$changed = 0
for($n=0;$n -lt $lines.Count;$n++){
  $ln = $lines[$n]
  $before = $ln
  if($ln -match 'New-Object\s+System\.Collections\.Generic\.Dictionary\[string,object\]\s*\(\s*\[System\.StringComparer\]::Ordinal\s*\)' ){
    $ln = "    `$map = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,object]' -ArgumentList @([System.StringComparer]::Ordinal)"
  }
  if($ln -match 'New-Object\s+System\.Collections\.Generic\.HashSet\[string\]\s*\(\s*\[System\.StringComparer\]::Ordinal\s*\)' ){
    $ln = "    `$set = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList @([System.StringComparer]::Ordinal)"
  }
  if($ln -ne $before){ $lines[$n] = $ln; $changed++ }
}
if($changed -lt 1){ Die "REPLACE_NOOP: did not find Dictionary/HashSet generic New-Object forms" }
# Write back with LF only + trailing LF
$t = (@($lines) -join "`n")
$t = $t.Replace("`r`n","`n").Replace("`r","`n")
if(-not $t.EndsWith("`n")){ $t += "`n" }
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllBytes($Runner, $enc.GetBytes($t))
# parse-gate runner
$tok=$null; $err=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tok,[ref]$err)
if($err -and $err.Count -gt 0){ $x=$err[0]; Die ("RUNNER_PARSE_FAIL: {0}:{1}:{2}: {3}" -f $Runner,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message) }
Write-Host ("PATCH_OK+RUNNER_PARSE_OK: " + $Runner + " changes=" + $changed) -ForegroundColor Green
