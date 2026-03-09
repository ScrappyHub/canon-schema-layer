param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){
  throw ("CSL_NFL_FREEZE_FAIL:" + $m)
}

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function Utf8NoBom(){
  New-Object System.Text.UTF8Encoding($false)
}

function NormalizeLf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}

function ReadUtf8([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("READ_MISSING:" + $Path)
  }
  return [System.IO.File]::ReadAllText($Path,(Utf8NoBom))
}

function WriteUtf8NoBomLfText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $u = NormalizeLf $Text
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($u))
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("WRITE_FAILED:" + $Path)
  }
}

function ParseGateFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("PARSEGATE_MISSING:" + $Path)
  }
  $tok = $null
  $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  if($err -and @(@($err)).Count -gt 0){
    $m = ($err | Select-Object -First 12 | ForEach-Object { $_.ToString() }) -join " | "
    Fail ("PARSEGATE_FAIL:" + $Path + "::" + $m)
  }
}

function Sha256Hex([string]$Path){
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function RelPath([string]$Root,[string]$Full){
  $bs = [char]92
  $r = (Resolve-Path -LiteralPath $Root).Path.TrimEnd($bs)
  $f = (Resolve-Path -LiteralPath $Full).Path
  if($f.Length -lt $r.Length){ return $f.Replace($bs,[char]47) }
  if($f.Substring(0,$r.Length).ToLowerInvariant() -ne $r.ToLowerInvariant()){ return $f.Replace($bs,[char]47) }
  $rel = $f.Substring($r.Length).TrimStart($bs)
  return $rel.Replace($bs,[char]47)
}

function WriteSha256Sums([string]$Root,[string]$OutPath,[string[]]$FilesAbs){
  $rows = New-Object System.Collections.Generic.List[string]
  foreach($fp in $FilesAbs){
    if(-not (Test-Path -LiteralPath $fp -PathType Leaf)){
      Fail ("SHA256SUMS_MISSING_FILE:" + $fp)
    }
    $hex = Sha256Hex $fp
    $rel = RelPath $Root $fp
    [void]$rows.Add(($hex + "  " + $rel))
  }
  WriteUtf8NoBomLfText $OutPath ((@($rows.ToArray()) -join "`n") + "`n")
}

function CopyDirDeterministic([string]$src,[string]$dst){
  if(-not (Test-Path -LiteralPath $src -PathType Container)){
    Fail ("COPY_SRC_MISSING:" + $src)
  }
  if(Test-Path -LiteralPath $dst){
    Remove-Item -LiteralPath $dst -Recurse -Force
  }
  EnsureDir $dst
  Get-ChildItem -LiteralPath $src -Force | Sort-Object Name | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse -Force
  }
}

$RepoRoot   = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $RepoRoot "scripts"
$ProofsDir  = Join-Path $RepoRoot "proofs"
$RcptRoot   = Join-Path $ProofsDir "receipts"
$DocsDir    = Join-Path $RepoRoot "docs"
$FreezeRoot = Join-Path $RepoRoot "test_vectors\tier0_frozen"

if(-not (Test-Path -LiteralPath $RcptRoot -PathType Container)){
  Fail ("MISSING_RECEIPTS_ROOT:" + $RcptRoot)
}

EnsureDir $DocsDir
EnsureDir $FreezeRoot

$SelftestScript = Join-Path $ScriptsDir "selftest_csl_nfl_packet_v1.ps1"
$EmitScript     = Join-Path $ScriptsDir "csl_emit_nfl_packet_v1.ps1"
$VerifyScript   = Join-Path $ScriptsDir "verify_csl_nfl_packet_v1.ps1"

foreach($p in @($SelftestScript,$EmitScript,$VerifyScript)){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){
    Fail ("MISSING_REQUIRED_SCRIPT:" + $p)
  }
  ParseGateFile $p
}

$Latest = Get-ChildItem -LiteralPath $RcptRoot -Directory |
  Where-Object { $_.Name -match '^\d{8}T\d{6}Z$' } |
  Sort-Object Name |
  Select-Object -Last 1

if($null -eq $Latest){
  Fail "NO_TIMESTAMP_RECEIPT_BUNDLES_FOUND"
}

$LatestBundle = $Latest.FullName

$Req = @(
  (Join-Path $LatestBundle "emit.result.json"),
  (Join-Path $LatestBundle "verify.result.1.json"),
  (Join-Path $LatestBundle "verify.result.2.json"),
  (Join-Path $LatestBundle "csl.nfl_packet.selftest.v1.ndjson"),
  (Join-Path $LatestBundle "sha256sums.txt")
)

foreach($p in $Req){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){
    Fail ("LATEST_BUNDLE_MISSING_REQUIRED_FILE:" + $p)
  }
}

$ReceiptObj = (ReadUtf8 (Join-Path $LatestBundle "csl.nfl_packet.selftest.v1.ndjson") | ConvertFrom-Json -ErrorAction Stop)
if($null -eq $ReceiptObj){ Fail "RECEIPT_PARSE_EMPTY" }

$PacketRoot = [string]$ReceiptObj.packet_root
$ManifestSha = [string]$ReceiptObj.manifest_sha256
$SumsSha = [string]$ReceiptObj.sha256sums_sha256

if([string]::IsNullOrWhiteSpace($PacketRoot)){ Fail "RECEIPT_PACKET_ROOT_MISSING" }
if(-not (Test-Path -LiteralPath $PacketRoot -PathType Container)){ Fail ("PACKET_ROOT_MISSING:" + $PacketRoot) }

$FreezeName = "csl_nfl_packet_green_20260308"
$FreezeDir  = Join-Path $FreezeRoot $FreezeName

CopyDirDeterministic $LatestBundle $FreezeDir

$LockPath = Join-Path $DocsDir "CSL_NFL_PACKET_LOCK.md"
$LockText = @"
# CSL NFL Packet Lock

Status: GREEN / LOCKED

Canonical latest green bundle:
- $LatestBundle

Frozen bundle:
- $FreezeDir

Canonical locked scripts:
- scripts/csl_emit_nfl_packet_v1.ps1
- scripts/verify_csl_nfl_packet_v1.ps1
- scripts/selftest_csl_nfl_packet_v1.ps1

Locked packet root:
- $PacketRoot

Locked positive hashes:
- MANIFEST_SHA256=$ManifestSha
- SHA256SUMS_SHA256=$SumsSha

Tier-0 integration claim:
- CSL emits an NFL-style packet deterministically
- CSL verifies that packet deterministically
- selftest emits deterministic receipt bundle
- bundle sha256 evidence is generated
- locked surfaces parse-gate under PS5.1 StrictMode
"@
WriteUtf8NoBomLfText $LockPath $LockText

$StatusPath = Join-Path $DocsDir "CSL_CANONICAL_STATUS.md"
$StatusText = @"
# CSL Canonical Status

Instrument: CSL (Conformance / Spec Layer)

Current locked integration:
- NFL packet emission + verification path is GREEN

Canonical role in this integration:
- emit deterministic NFL-style packet fixture
- verify manifest + sha256 coverage deterministically
- produce deterministic selftest evidence bundle

Current state:
- Tier-0 integration GREEN
- Tier-0 integration LOCKED

Latest green bundle:
- $LatestBundle

Frozen bundle:
- $FreezeDir

Locked packet root:
- $PacketRoot

Next work after this lock:
- optional release-hygiene pass
- optional HashCanon-facing frozen handoff
- optional WatchTower-facing CSL packet handoff
"@
WriteUtf8NoBomLfText $StatusPath $StatusText

$ManifestPath = Join-Path $FreezeDir "FREEZE_MANIFEST.txt"
$ManifestText = @"
CSL_NFL_PACKET_FREEZE_OK
LATEST_BUNDLE=$LatestBundle
FROZEN_BUNDLE=$FreezeDir
LOCK_NOTE=$LockPath
STATUS_NOTE=$StatusPath
PACKET_ROOT=$PacketRoot
MANIFEST_SHA256=$ManifestSha
SHA256SUMS_SHA256=$SumsSha
"@
WriteUtf8NoBomLfText $ManifestPath $ManifestText

$bundleFiles = Get-ChildItem -LiteralPath $FreezeDir -Recurse -File | Sort-Object FullName
$abs = New-Object System.Collections.Generic.List[string]
foreach($f in $bundleFiles){
  if($f.FullName -ne (Join-Path $FreezeDir "sha256sums.txt")){
    [void]$abs.Add($f.FullName)
  }
}
$FreezeSums = Join-Path $FreezeDir "sha256sums.txt"
WriteSha256Sums $FreezeDir $FreezeSums ($abs.ToArray())

Write-Host "CSL_NFL_PACKET_FREEZE_OK" -ForegroundColor Green
Write-Host ("LATEST_BUNDLE=" + $LatestBundle) -ForegroundColor Green
Write-Host ("FROZEN_BUNDLE=" + $FreezeDir) -ForegroundColor Green
Write-Host ("LOCK_NOTE=" + $LockPath) -ForegroundColor Green
Write-Host ("STATUS_NOTE=" + $StatusPath) -ForegroundColor Green
Write-Host ("PACKET_ROOT=" + $PacketRoot) -ForegroundColor Green