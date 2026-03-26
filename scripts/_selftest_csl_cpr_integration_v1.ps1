param(
  [Parameter(Mandatory=$true)]
  [string]$RepoRoot,
  [Parameter(Mandatory=$false)]
  [string]$CprRepoRoot = "C:\dev\cpr"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [System.IO.Path]::IsPathRooted($RepoRoot)) {
  $RepoRoot = Join-Path $PSScriptRoot ".."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$CprRepoRoot = [System.IO.Path]::GetFullPath($CprRepoRoot)

function Fail([string]$Code) {
  Write-Host ("CSL_CPR_SELFTEST_FAIL:" + $Code) -ForegroundColor Red
  exit 1
}

function Parse-GateFile([string]$Path) {
  $Tok = $null
  $Err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tok,[ref]$Err)
  if ($Err -and $Err.Count -gt 0) {
    $E = $Err[0]
    throw ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$E.Extent.StartLineNumber,$E.Extent.StartColumnNumber,$E.Message)
  }
}

try {
  Parse-GateFile (Join-Path $RepoRoot "scripts\csl_verify_packet_with_cpr_v1.ps1")
  Parse-GateFile (Join-Path $CprRepoRoot "cli\cpr.ps1")

  $VectorPath = Join-Path $CprRepoRoot "test_vectors\packet_constitution_v1\minimal"
  if (-not (Test-Path -LiteralPath $VectorPath -PathType Container)) {
    Fail "CPR_MINIMAL_VECTOR_MISSING"
  }

  $RunRoot = Join-Path $RepoRoot "proofs\_csl_cpr_selftest_packet"
  if (Test-Path -LiteralPath $RunRoot) {
    Remove-Item -LiteralPath $RunRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $RunRoot "payload") -Force | Out-Null

  Copy-Item -LiteralPath (Join-Path $VectorPath "manifest.json") -Destination (Join-Path $RunRoot "manifest.json") -Force
  Copy-Item -LiteralPath (Join-Path $VectorPath "packet_id.txt") -Destination (Join-Path $RunRoot "packet_id.txt") -Force
  Copy-Item -LiteralPath (Join-Path $VectorPath "sha256sums.txt") -Destination (Join-Path $RunRoot "sha256sums.txt") -Force
  Copy-Item -LiteralPath (Join-Path $VectorPath "payload\hello.txt") -Destination (Join-Path $RunRoot "payload\hello.txt") -Force

  $PSExe = (Get-Command powershell.exe).Source
  $Output = & $PSExe `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File (Join-Path $RepoRoot "scripts\csl_verify_packet_with_cpr_v1.ps1") `
    -RepoRoot $RepoRoot `
    -PacketPath $RunRoot `
    -CprRepoRoot $CprRepoRoot 2>&1

  $ExitCode = $LASTEXITCODE
  $OutputText = (($Output | ForEach-Object { $_.ToString() }) -join "`n")

  if ($ExitCode -ne 0) {
    $OutputText | Out-Host
    Fail "VERIFY_EXIT_NONZERO"
  }
  if ($OutputText -notmatch 'CSL_CPR_VERIFY_OK') {
    $OutputText | Out-Host
    Fail "VERIFY_TOKEN_MISSING"
  }

  $ReceiptPath = Join-Path $RepoRoot "proofs\receipts\csl.cpr.ndjson"
  if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
    Fail "RECEIPT_LOG_MISSING"
  }

  $ReceiptText = [System.IO.File]::ReadAllText($ReceiptPath)
  if ($ReceiptText -notmatch '"delegated_to":"CPR"') {
    Fail "DELEGATION_RECEIPT_MISSING"
  }

  Write-Host "CSL_CPR_SELFTEST_OK" -ForegroundColor Green
  exit 0
}
catch {
  Write-Host ("CSL_CPR_SELFTEST_FAIL:UNHANDLED:" + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
