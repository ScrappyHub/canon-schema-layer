param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){
  throw ("CSL_RELEASE_HYGIENE_FAIL:" + $m)
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

function ReadUtf8([string]$p){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){
    Fail ("READ_MISSING:" + $p)
  }
  return [System.IO.File]::ReadAllText($p,(Utf8NoBom))
}

function WriteUtf8NoBomLfText([string]$p,[string]$t){
  $dir = Split-Path -Parent $p
  if($dir){ EnsureDir $dir }
  $u = NormalizeLf $t
  [System.IO.File]::WriteAllBytes($p,(Utf8NoBom).GetBytes($u))
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){
    Fail ("WRITE_FAILED:" + $p)
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

function RequireGit(){
  $g = Get-Command git.exe -ErrorAction SilentlyContinue
  if($null -eq $g){
    $g = Get-Command git -ErrorAction SilentlyContinue
  }
  if($null -eq $g){
    Fail "GIT_MISSING"
  }
}

$RepoRoot   = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $RepoRoot "scripts"
$DocsDir    = Join-Path $RepoRoot "docs"
$FreezeDir  = Join-Path $RepoRoot "test_vectors\tier0_frozen\csl_nfl_packet_green_20260308"

$FreezeRunner = Join-Path $ScriptsDir "_RUN_freeze_csl_nfl_packet_green_v1.ps1"
$EmitScript   = Join-Path $ScriptsDir "csl_emit_nfl_packet_v1.ps1"
$VerifyScript = Join-Path $ScriptsDir "verify_csl_nfl_packet_v1.ps1"
$Selftest     = Join-Path $ScriptsDir "selftest_csl_nfl_packet_v1.ps1"

foreach($p in @($FreezeRunner,$EmitScript,$VerifyScript,$Selftest)){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){
    Fail ("MISSING_REQUIRED_SCRIPT:" + $p)
  }
  ParseGateFile $p
}

if(-not (Test-Path -LiteralPath $FreezeDir -PathType Container)){
  Fail ("MISSING_FROZEN_BUNDLE:" + $FreezeDir)
}

$LockDoc   = Join-Path $DocsDir "CSL_NFL_PACKET_LOCK.md"
$StatusDoc = Join-Path $DocsDir "CSL_CANONICAL_STATUS.md"

if(-not (Test-Path -LiteralPath $LockDoc -PathType Leaf)){ Fail "MISSING_LOCK_DOC" }
if(-not (Test-Path -LiteralPath $StatusDoc -PathType Leaf)){ Fail "MISSING_STATUS_DOC" }

$ReadmePath = Join-Path $RepoRoot "README.md"
$ReadmeText = @"
# CSL

CSL is the canonical conformance / spec-layer instrument.

## Locked NFL Integration

CSL now has a locked deterministic NFL-style packet path.

Canonical locked surface:
- scripts/csl_emit_nfl_packet_v1.ps1
- scripts/verify_csl_nfl_packet_v1.ps1
- scripts/selftest_csl_nfl_packet_v1.ps1
- scripts/_RUN_freeze_csl_nfl_packet_green_v1.ps1

Canonical lock docs:
- docs/CSL_NFL_PACKET_LOCK.md
- docs/CSL_CANONICAL_STATUS.md

Canonical frozen evidence:
- test_vectors/tier0_frozen/csl_nfl_packet_green_20260308

## Locked result

The CSL NFL packet selftest and freeze are GREEN and frozen for Tier-0 integration scope.

## Current scope

This locked scope proves:
- deterministic CSL emit of an NFL-style packet
- deterministic CSL verify of that packet
- deterministic receipt bundle emission
- deterministic frozen evidence bundle
"@
WriteUtf8NoBomLfText $ReadmePath $ReadmeText

$ReleaseNote = Join-Path $DocsDir "CSL_NFL_PACKET_RELEASE_NOTE.md"
$ReleaseText = @"
# CSL NFL Packet Release Note

Status:
- GREEN
- LOCKED
- FROZEN

Canonical tags:
- csl-nfl-packet-green-20260308
- csl-nfl-release-hygiene-20260308

Canonical docs:
- docs/CSL_NFL_PACKET_LOCK.md
- docs/CSL_CANONICAL_STATUS.md

Canonical frozen evidence:
- test_vectors/tier0_frozen/csl_nfl_packet_green_20260308

Summary:
- CSL emits an NFL-style packet deterministically
- CSL verifies that packet deterministically
- selftest emits deterministic receipts
- frozen evidence bundle exists and is locked
- release hygiene pass completed
"@
WriteUtf8NoBomLfText $ReleaseNote $ReleaseText

RequireGit
Set-Location $RepoRoot

$gitDir = Join-Path $RepoRoot ".git"
if(-not (Test-Path -LiteralPath $gitDir -PathType Container)){
  git init | Out-Host
  if($LASTEXITCODE -ne 0){ Fail "GIT_INIT_FAILED" }
}

git branch -M main | Out-Host
if($LASTEXITCODE -ne 0){ Fail "GIT_BRANCH_MAIN_FAILED" }

git config --local core.autocrlf false
if($LASTEXITCODE -ne 0){ Fail "GIT_SET_AUTOCRLF_FAILED" }

git config --local core.filemode false
if($LASTEXITCODE -ne 0){ Fail "GIT_SET_FILEMODE_FAILED" }

git add -- README.md docs scripts test_vectors proofs | Out-Host
if($LASTEXITCODE -ne 0){ Fail "GIT_ADD_FAILED" }

$staged = @(git status --short)
if($LASTEXITCODE -ne 0){ Fail "GIT_STATUS_FAILED" }

if(@(@($staged)).Count -gt 0){
  git commit -m "CSL: lock NFL packet integration, frozen evidence, and release hygiene" | Out-Host
  if($LASTEXITCODE -ne 0){ Fail "GIT_COMMIT_FAILED" }
}

$tagGreen = "csl-nfl-packet-green-20260308"
$tagHyg   = "csl-nfl-release-hygiene-20260308"

$tagsNow = @(git tag --list)
if($LASTEXITCODE -ne 0){ Fail "GIT_TAG_LIST_FAILED" }

$hasGreen = $false
$hasHyg   = $false
foreach($t in @(@($tagsNow))){
  if([string]$t -eq $tagGreen){ $hasGreen = $true }
  if([string]$t -eq $tagHyg){ $hasHyg = $true }
}

if(-not $hasGreen){
  git tag $tagGreen | Out-Host
  if($LASTEXITCODE -ne 0){ Fail "GIT_TAG_GREEN_FAILED" }
}

if(-not $hasHyg){
  git tag $tagHyg | Out-Host
  if($LASTEXITCODE -ne 0){ Fail "GIT_TAG_HYGIENE_FAILED" }
}

Write-Host "CSL_RELEASE_HYGIENE_OK" -ForegroundColor Green
Write-Host ("README=" + $ReadmePath) -ForegroundColor Green
Write-Host ("RELEASE_NOTE=" + $ReleaseNote) -ForegroundColor Green
Write-Host ("TAG_GREEN=" + $tagGreen) -ForegroundColor Green
Write-Host ("TAG_HYGIENE=" + $tagHyg) -ForegroundColor Green