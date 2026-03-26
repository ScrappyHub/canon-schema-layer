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

  $PacketPath = Join-Path $CprRepoRoot "test_vectors\packet_constitution_v1\minimal"
  if (-not (Test-Path -LiteralPath $PacketPath -PathType Container)) {
    Fail "CPR_MINIMAL_VECTOR_MISSING"
  }

  $PSExe = (Get-Command powershell.exe).Source
  $Output = & $PSExe `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File (Join-Path $RepoRoot "scripts\csl_verify_packet_with_cpr_v1.ps1") `
    -RepoRoot $RepoRoot `
    -PacketPath $PacketPath `
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
