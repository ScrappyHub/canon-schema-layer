param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function Read-Utf8([string]$p){ return [System.IO.File]::ReadAllText($p,[System.Text.UTF8Encoding]::new($false)) }
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

$RunPath = Join-Path $RepoRoot "scripts\_RUN_csl_bootstrap_v1.ps1"
if(-not (Test-Path -LiteralPath $RunPath -PathType Leaf)){ Die ("MISSING_RUNNER: " + $RunPath) }
$raw = Read-Utf8 $RunPath

# Fix $pid collisions with built-in $PID (case-insensitive).
# Replace variable names in the runner file (deterministic, safe).
$raw2 = $raw
$raw2 = $raw2.Replace("$"+"pidTxt","$"+"PacketIdText")
$raw2 = $raw2.Replace("$"+"pidPath","$"+"PacketIdPath")
$raw2 = $raw2.Replace("$"+"pid ","$"+"PacketIdPath ")
$raw2 = $raw2.Replace("$"+"pid)","$"+"PacketIdPath)")
$raw2 = $raw2.Replace("$"+"pid,","$"+"PacketIdPath,")
$raw2 = $raw2.Replace("$"+"pid`n","$"+"PacketIdPath`n")

if($raw2 -eq $raw){ Die "PATCH_NOOP_OR_PATTERN_MISS: runner did not change (already fixed or unexpected content)" }
Write-Utf8NoBomLf $RunPath $raw2
Parse-GateFile $RunPath
Write-Host ("PATCH_OK+PARSE_OK: " + $RunPath) -ForegroundColor Green
