param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$InputRoot,
  [Parameter(Mandatory=$true)][string]$OutPacketRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){
  throw ("CSL_EMIT_NFL_PACKET_FAIL:" + $m)
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

function Sha256HexBytes([byte[]]$Bytes){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($Bytes)
    return ([System.BitConverter]::ToString($hash)).Replace("-","").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Sha256HexFile([string]$Path){
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function CopyFileDeterministic([string]$Src,[string]$Dst){
  if(-not (Test-Path -LiteralPath $Src -PathType Leaf)){
    Fail ("COPY_SOURCE_MISSING:" + $Src)
  }
  $dir = Split-Path -Parent $Dst
  if($dir){ EnsureDir $dir }
  $bytes = [System.IO.File]::ReadAllBytes($Src)
  [System.IO.File]::WriteAllBytes($Dst,$bytes)
  if(-not (Test-Path -LiteralPath $Dst -PathType Leaf)){
    Fail ("COPY_DEST_MISSING:" + $Dst)
  }
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

function EscapeJsonString([string]$s){
  if($null -eq $s){ return "" }
  $bs = [string][char]92
  $dq = [string][char]34
  $t = $s.Replace($bs,$bs+$bs).Replace($dq,$bs+$dq)
  $t = $t.Replace([string][char]8,'\b')
  $t = $t.Replace([string][char]12,'\f')
  $t = $t.Replace([string][char]10,'\n')
  $t = $t.Replace([string][char]13,'\r')
  $t = $t.Replace([string][char]9,'\t')
  return $t
}

function QuoteJson([string]$s){
  return ('"' + (EscapeJsonString $s) + '"')
}

function GetDeterministicFiles([string]$Root){
  if(-not (Test-Path -LiteralPath $Root -PathType Container)){
    Fail ("INPUT_ROOT_MISSING:" + $Root)
  }
  return @(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName)
}

function BuildManifestJson([string]$PayloadRoot,[string[]]$PayloadRelPaths,[string]$SourceRoot){
  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add("{")
  [void]$lines.Add('  "schema":"csl.nfl.packet.manifest.v1",')
  [void]$lines.Add('  "source_instrument":"csl",')
  [void]$lines.Add('  "packet_type":"csl_nfl_packet_v1",')
  [void]$lines.Add('  "source_root":' + (QuoteJson $SourceRoot) + ',')
  [void]$lines.Add('  "payload_files":[')

  for($i = 0; $i -lt $PayloadRelPaths.Count; $i++){
    $comma = ""
    if($i -lt ($PayloadRelPaths.Count - 1)){ $comma = "," }
    [void]$lines.Add('    ' + (QuoteJson $PayloadRelPaths[$i]) + $comma)
  }

  [void]$lines.Add('  ]')
  [void]$lines.Add("}")
  return ((@($lines.ToArray()) -join "`n") + "`n")
}

function WriteSha256Sums([string]$Root,[string]$OutPath,[string[]]$FilesAbs){
  $rows = New-Object System.Collections.Generic.List[string]
  foreach($fp in $FilesAbs){
    if(-not (Test-Path -LiteralPath $fp -PathType Leaf)){
      Fail ("SHA256SUMS_MISSING_FILE:" + $fp)
    }
    $hex = Sha256HexFile $fp
    $rel = RelPath $Root $fp
    [void]$rows.Add(($hex + "  " + $rel))
  }
  WriteUtf8NoBomLfText $OutPath ((@($rows.ToArray()) -join "`n") + "`n")
}

$RepoRoot      = (Resolve-Path -LiteralPath $RepoRoot).Path
$InputRoot     = (Resolve-Path -LiteralPath $InputRoot).Path

if(Test-Path -LiteralPath $OutPacketRoot){
  Remove-Item -LiteralPath $OutPacketRoot -Recurse -Force
}
EnsureDir $OutPacketRoot

$ScriptsDir  = Join-Path $RepoRoot "scripts"
$ManifestPath = Join-Path $OutPacketRoot "manifest.json"
$PayloadRoot  = Join-Path $OutPacketRoot "payload"
$SumsPath     = Join-Path $OutPacketRoot "sha256sums.txt"

EnsureDir $PayloadRoot

ParseGateFile $MyInvocation.MyCommand.Path

$inputFiles = @(GetDeterministicFiles $InputRoot)
if(@(@($inputFiles)).Count -lt 1){
  Fail "INPUT_ROOT_HAS_NO_FILES"
}

$payloadRelPaths = New-Object System.Collections.Generic.List[string]
$payloadAbsPaths = New-Object System.Collections.Generic.List[string]

foreach($f in $inputFiles){
  $rel = RelPath $InputRoot $f.FullName
  if([string]::IsNullOrWhiteSpace($rel)){ Fail ("EMPTY_RELATIVE_PATH:" + $f.FullName) }
  if($rel.Contains("../") -or $rel.Contains("..\")){ Fail ("TRAVERSAL_RELATIVE_PATH:" + $rel) }

  $dst = Join-Path $PayloadRoot $rel
  CopyFileDeterministic $f.FullName $dst

  [void]$payloadRelPaths.Add((RelPath $OutPacketRoot $dst))
  [void]$payloadAbsPaths.Add($dst)
}

$manifestText = BuildManifestJson -PayloadRoot $PayloadRoot -PayloadRelPaths @($payloadRelPaths.ToArray()) -SourceRoot $InputRoot
WriteUtf8NoBomLfText $ManifestPath $manifestText

$sumInputs = New-Object System.Collections.Generic.List[string]
[void]$sumInputs.Add($ManifestPath)
foreach($p in @($payloadAbsPaths.ToArray())){
  [void]$sumInputs.Add($p)
}
WriteSha256Sums $OutPacketRoot $SumsPath ($sumInputs.ToArray())

$manifestSha256 = Sha256HexFile $ManifestPath
$sha256sumsSha256 = Sha256HexFile $SumsPath

$result = [pscustomobject]@{
  ok = $true
  schema = "csl.emit.nfl_packet.result.v1"
  repo_root = $RepoRoot
  input_root = $InputRoot
  packet_root = $OutPacketRoot
  manifest_path = $ManifestPath
  sha256sums_path = $SumsPath
  manifest_sha256 = $manifestSha256
  sha256sums_sha256 = $sha256sumsSha256
  payload_file_count = [int]$payloadAbsPaths.Count
}

$result