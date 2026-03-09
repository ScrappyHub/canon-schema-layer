param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$PacketRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){
  throw ("VERIFY_CSL_NFL_PACKET_FAIL:" + $m)
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

function Sha256HexFile([string]$Path){
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

function ReadSha256Sums([string]$Path){
  $txt = NormalizeLf (ReadUtf8 $Path)
  $lines = @($txt -split "`n")
  $rows = New-Object System.Collections.Generic.List[object]

  foreach($line in $lines){
    if([string]::IsNullOrWhiteSpace($line)){ continue }
    if($line -notmatch '^[0-9a-fA-F]{64}  (.+)$'){
      Fail ("BAD_SHA256SUM_LINE:" + $line)
    }
    $hex = $line.Substring(0,64).ToLowerInvariant()
    $rel = [string]$Matches[1]
    [void]$rows.Add([pscustomobject]@{
      sha256 = $hex
      rel = $rel
    })
  }

  return @($rows.ToArray())
}

$RepoRoot   = (Resolve-Path -LiteralPath $RepoRoot).Path
$PacketRoot = (Resolve-Path -LiteralPath $PacketRoot).Path
$ScriptsDir = Join-Path $RepoRoot "scripts"

ParseGateFile $MyInvocation.MyCommand.Path

$ManifestPath = Join-Path $PacketRoot "manifest.json"
$PayloadRoot  = Join-Path $PacketRoot "payload"
$SumsPath     = Join-Path $PacketRoot "sha256sums.txt"

if(-not (Test-Path -LiteralPath $PacketRoot -PathType Container)){ Fail ("PACKET_ROOT_MISSING:" + $PacketRoot) }
if(-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)){ Fail ("MANIFEST_MISSING:" + $ManifestPath) }
if(-not (Test-Path -LiteralPath $PayloadRoot -PathType Container)){ Fail ("PAYLOAD_ROOT_MISSING:" + $PayloadRoot) }
if(-not (Test-Path -LiteralPath $SumsPath -PathType Leaf)){ Fail ("SHA256SUMS_MISSING:" + $SumsPath) }

$manifestTxt = ReadUtf8 $ManifestPath
if([string]::IsNullOrWhiteSpace($manifestTxt)){ Fail "MANIFEST_EMPTY" }

$manifestObj = $manifestTxt | ConvertFrom-Json -ErrorAction Stop
if($null -eq $manifestObj){ Fail "MANIFEST_PARSE_EMPTY" }

if(-not ($manifestObj.PSObject.Properties.Name -contains "schema")){ Fail "MANIFEST_SCHEMA_MISSING" }
if([string]$manifestObj.schema -ne "csl.nfl.packet.manifest.v1"){ Fail "MANIFEST_SCHEMA_INVALID" }

if(-not ($manifestObj.PSObject.Properties.Name -contains "payload_files")){ Fail "MANIFEST_PAYLOAD_FILES_MISSING" }

$manifestPayloadFiles = @(@($manifestObj.payload_files))
if(@(@($manifestPayloadFiles)).Count -lt 1){ Fail "MANIFEST_PAYLOAD_FILES_EMPTY" }

$sumRows = @(ReadSha256Sums $SumsPath)
if(@(@($sumRows)).Count -lt 2){ Fail "SHA256SUMS_TOO_SMALL" }

$seen = @{}
foreach($row in $sumRows){
  $rel = [string]$row.rel
  if($seen.ContainsKey($rel)){ Fail ("DUPLICATE_SHA256SUM_ENTRY:" + $rel) }
  $seen[$rel] = $true

  if($rel.Contains("../") -or $rel.Contains("..\")){ Fail ("TRAVERSAL_PATH:" + $rel) }

  $full = Join-Path $PacketRoot $rel
  if(-not (Test-Path -LiteralPath $full -PathType Leaf)){
    Fail ("MISSING_TARGET:" + $rel)
  }

  $actual = Sha256HexFile $full
  if($actual -ne [string]$row.sha256){
    Fail ("SHA256_MISMATCH:" + $rel + ":expected=" + [string]$row.sha256 + ":actual=" + $actual)
  }
}

if(-not $seen.ContainsKey("manifest.json")){ Fail "MANIFEST_NOT_COVERED" }

foreach($p in $manifestPayloadFiles){
  $rel = [string]$p
  if([string]::IsNullOrWhiteSpace($rel)){ Fail "MANIFEST_PAYLOAD_REL_EMPTY" }
  if($rel.Contains("../") -or $rel.Contains("..\")){ Fail ("MANIFEST_TRAVERSAL_PATH:" + $rel) }
  if(-not $seen.ContainsKey($rel)){ Fail ("MANIFEST_PAYLOAD_NOT_COVERED:" + $rel) }
}

$result = [pscustomobject]@{
  ok = $true
  schema = "csl.verify.nfl_packet.result.v1"
  repo_root = $RepoRoot
  packet_root = $PacketRoot
  manifest_path = $ManifestPath
  sha256sums_path = $SumsPath
  manifest_sha256 = (Sha256HexFile $ManifestPath)
  sha256sums_sha256 = (Sha256HexFile $SumsPath)
  sha256_entry_count = [int]$sumRows.Count
  payload_file_count = [int]$manifestPayloadFiles.Count
}

$result