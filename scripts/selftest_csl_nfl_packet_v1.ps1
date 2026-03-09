param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){
  throw ("CSL_NFL_PACKET_SELFTEST_FAIL:" + $m)
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

function FindResultObject([object[]]$items){
  foreach($x in @(@($items))){
    if($null -ne $x){
      $names = @($x.PSObject.Properties.Name)
      if(($names -contains "ok") -or ($names -contains "packet_root") -or ($names -contains "digest_sha256")){
        return $x
      }
    }
  }
  return $null
}

$RepoRoot   = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $RepoRoot "scripts"
$ProofsDir  = Join-Path $RepoRoot "proofs"
$RcptRoot   = Join-Path $ProofsDir "receipts"
$TvRoot     = Join-Path $RepoRoot "test_vectors"
$CaseRoot   = Join-Path $TvRoot "csl_nfl_packet_v1"

EnsureDir $ProofsDir
EnsureDir $RcptRoot
EnsureDir $TvRoot
EnsureDir $CaseRoot

$EmitScript   = Join-Path $ScriptsDir "csl_emit_nfl_packet_v1.ps1"
$VerifyScript = Join-Path $ScriptsDir "verify_csl_nfl_packet_v1.ps1"

if(-not (Test-Path -LiteralPath $EmitScript -PathType Leaf)){ Fail ("MISSING_EMIT_SCRIPT:" + $EmitScript) }
if(-not (Test-Path -LiteralPath $VerifyScript -PathType Leaf)){ Fail ("MISSING_VERIFY_SCRIPT:" + $VerifyScript) }

ParseGateFile $EmitScript
ParseGateFile $VerifyScript
ParseGateFile $MyInvocation.MyCommand.Path

$CaseDir = Join-Path $CaseRoot "minimal_valid"
if(Test-Path -LiteralPath $CaseDir){
  Remove-Item -LiteralPath $CaseDir -Recurse -Force
}
EnsureDir $CaseDir

$InputRoot = Join-Path $CaseDir "input"
$PacketRoot = Join-Path $CaseDir "packet"
EnsureDir $InputRoot

$CanonJsonDir = Join-Path $InputRoot "canonjson_v1"
$HashLawDir   = Join-Path $InputRoot "hashlaw_v1"
EnsureDir $CanonJsonDir
EnsureDir $HashLawDir

$CanonJsonCase = Join-Path $CanonJsonDir "minimal_object.json"
$HashLawCase   = Join-Path $HashLawDir "minimal_hashlaw_object.json"

WriteUtf8NoBomLfText $CanonJsonCase '{"a":1,"b":"two"}'
WriteUtf8NoBomLfText $HashLawCase '{"name":"csl-minimal","object_hash":"0000000000000000000000000000000000000000000000000000000000000000"}'

$emitRes = & $EmitScript -RepoRoot $RepoRoot -InputRoot $InputRoot -OutPacketRoot $PacketRoot
if(-not $emitRes){ Fail "EMIT_NO_OUTPUT" }

$emitObj = FindResultObject @($emitRes)
if($null -eq $emitObj){ Fail "EMIT_NO_OBJECT" }

if(-not (Test-Path -LiteralPath $PacketRoot -PathType Container)){ Fail ("PACKET_ROOT_MISSING:" + $PacketRoot) }

$ManifestPath = Join-Path $PacketRoot "manifest.json"
$SumsPath     = Join-Path $PacketRoot "sha256sums.txt"
$PayloadDir   = Join-Path $PacketRoot "payload"

if(-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)){ Fail ("MANIFEST_MISSING:" + $ManifestPath) }
if(-not (Test-Path -LiteralPath $SumsPath -PathType Leaf)){ Fail ("SHA256SUMS_MISSING:" + $SumsPath) }
if(-not (Test-Path -LiteralPath $PayloadDir -PathType Container)){ Fail ("PAYLOAD_DIR_MISSING:" + $PayloadDir) }

$verifyRes1 = & $VerifyScript -RepoRoot $RepoRoot -PacketRoot $PacketRoot
if(-not $verifyRes1){ Fail "VERIFY1_NO_OUTPUT" }

$verifyObj1 = FindResultObject @($verifyRes1)
if($null -eq $verifyObj1){ Fail "VERIFY1_NO_OBJECT" }
if(-not ($verifyObj1.PSObject.Properties.Name -contains "ok")){ Fail "VERIFY1_MISSING_OK" }
if(-not [bool]$verifyObj1.ok){ Fail "VERIFY1_NOT_OK" }

$verifyRes2 = & $VerifyScript -RepoRoot $RepoRoot -PacketRoot $PacketRoot
if(-not $verifyRes2){ Fail "VERIFY2_NO_OUTPUT" }

$verifyObj2 = FindResultObject @($verifyRes2)
if($null -eq $verifyObj2){ Fail "VERIFY2_NO_OBJECT" }
if(-not ($verifyObj2.PSObject.Properties.Name -contains "ok")){ Fail "VERIFY2_MISSING_OK" }
if(-not [bool]$verifyObj2.ok){ Fail "VERIFY2_NOT_OK" }

$manifestHash1 = Sha256Hex $ManifestPath
$manifestHash2 = Sha256Hex $ManifestPath
if($manifestHash1 -ne $manifestHash2){ Fail "MANIFEST_HASH_DRIFT" }

$sumsHash1 = Sha256Hex $SumsPath
$sumsHash2 = Sha256Hex $SumsPath
if($sumsHash1 -ne $sumsHash2){ Fail "SHA256SUMS_HASH_DRIFT" }

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$BundleDir = Join-Path $RcptRoot $stamp
EnsureDir $BundleDir

$EmitJsonPath   = Join-Path $BundleDir "emit.result.json"
$Verify1Json    = Join-Path $BundleDir "verify.result.1.json"
$Verify2Json    = Join-Path $BundleDir "verify.result.2.json"
$ReceiptPath    = Join-Path $BundleDir "csl.nfl_packet.selftest.v1.ndjson"

WriteUtf8NoBomLfText $EmitJsonPath (($emitObj | ConvertTo-Json -Depth 8 -Compress) + "`n")
WriteUtf8NoBomLfText $Verify1Json  (($verifyObj1 | ConvertTo-Json -Depth 8 -Compress) + "`n")
WriteUtf8NoBomLfText $Verify2Json  (($verifyObj2 | ConvertTo-Json -Depth 8 -Compress) + "`n")

$receiptObj = [ordered]@{
  schema = "csl.nfl_packet.selftest.v1"
  utc = $stamp
  ok = $true
  repo_root = $RepoRoot
  input_root = $InputRoot
  packet_root = $PacketRoot
  manifest_sha256 = $manifestHash1
  sha256sums_sha256 = $sumsHash1
  bundle_dir = $BundleDir
}
WriteUtf8NoBomLfText $ReceiptPath ((($receiptObj | ConvertTo-Json -Compress)) + "`n")

$bundleFiles = @(Get-ChildItem -LiteralPath $BundleDir -Recurse -File | Sort-Object FullName)
$abs = New-Object System.Collections.Generic.List[string]
foreach($f in $bundleFiles){
  [void]$abs.Add($f.FullName)
}
$BundleSums = Join-Path $BundleDir "sha256sums.txt"
WriteSha256Sums $BundleDir $BundleSums ($abs.ToArray())

Write-Output "CSL_NFL_PACKET_SELFTEST_OK"
Write-Output ("PACKET_ROOT=" + $PacketRoot)
Write-Output ("MANIFEST_SHA256=" + $manifestHash1)
Write-Output ("SHA256SUMS_SHA256=" + $sumsHash1)
Write-Output ("BUNDLE_DIR=" + $BundleDir)