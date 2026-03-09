param([Parameter(Mandatory=$true)][string]$RepoRoot)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function NowUtc(){ return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") }
function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}
function Read-Bytes([string]$p){ return [System.IO.File]::ReadAllBytes($p) }
function Sha256Hex([byte[]]$Bytes){
  if($null -eq $Bytes){ $Bytes = @() }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $h = $sha.ComputeHash([byte[]]$Bytes)
  } finally { $sha.Dispose() }
  $sb = New-Object System.Text.StringBuilder
  for($i=0;$i -lt $h.Length;$i++){ [void]$sb.Append($h[$i].ToString("x2")) }
  return $sb.ToString()
}
function Sha256Tag([byte[]]$Bytes){ return ("sha256:" + (Sha256Hex $Bytes)) }

# ------------------------------
# Canonical JSON v1 (Executable)
# - stable object key ordering (ordinal)
# - no whitespace
# - strings escaped deterministically
# - numbers: integers only, safe range <= 9007199254740991
# - reject duplicate keys, floats, NaN/Infinity
# ------------------------------
function _EscJsonString([string]$s){
  if($null -eq $s){ return "" }
  $sb = New-Object System.Text.StringBuilder
  for($i=0;$i -lt $s.Length;$i++){
    $ch = $s[$i]
    $code = [int][char]$ch
    if($code -lt 32){ [void]$sb.Append("\u" + $code.ToString("x4")) }
    elseif($code -eq 34){ [void]$sb.Append('\"') }
    elseif($code -eq 92){ [void]$sb.Append('\\') }
    else{ [void]$sb.Append($ch) }
  }
  return $sb.ToString()
}

function _EmitCanonJson($node, [System.Text.StringBuilder]$sb){
  $t = $node.t
  if($t -eq "null"){ [void]$sb.Append("null"); return }
  if($t -eq "bool"){ if($node.v){ [void]$sb.Append("true") } else { [void]$sb.Append("false") }; return }
  if($t -eq "string"){ [void]$sb.Append('"' + (_EscJsonString [string]$node.v) + '"'); return }
  if($t -eq "int"){ [void]$sb.Append([string]$node.v); return }
  if($t -eq "array"){
    [void]$sb.Append("[")
    $a = @(@($node.v))
    for($i=0;$i -lt $a.Count;$i++){ if($i -gt 0){ [void]$sb.Append(",") }; _EmitCanonJson $a[$i] $sb }
    [void]$sb.Append("]")
    return
  }
  if($t -eq "object"){
    [void]$sb.Append("{")
    $keys = New-Object System.Collections.Generic.List[string]
    foreach($k in $node.v.Keys){ [void]$keys.Add([string]$k) }
    $keys.Sort([System.StringComparer]::Ordinal)
    for($i=0;$i -lt $keys.Count;$i++){
      if($i -gt 0){ [void]$sb.Append(",") }
      $k = $keys[$i]
      [void]$sb.Append('"' + (_EscJsonString $k) + '":')
      _EmitCanonJson $node.v[$k] $sb
    }
    [void]$sb.Append("}")
    return
  }
  Die ("CSL_E_INTERNAL_UNKNOWN_NODE_TYPE: " + $t)
}

function _ParseJsonToNode([byte[]]$bytes){
  if($null -eq $bytes){ $bytes = @() }
  $r = New-Object System.Text.Json.Utf8JsonReader(,$bytes, [System.Text.Json.JsonReaderOptions]@{ AllowTrailingCommas=$false; CommentHandling=[System.Text.Json.JsonCommentHandling]::Disallow })
  $stack = New-Object System.Collections.Generic.Stack[object]  # frames
  $root = $null
  $curProp = $null

  function NewObjFrame(){
    return [pscustomobject]@{ kind="object"; map=(New-Object System.Collections.Generic.Dictionary[string,object]([System.StringComparer]::Ordinal)); seen=(New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)) }
  }
  function NewArrFrame(){ return [pscustomobject]@{ kind="array"; list=(New-Object System.Collections.Generic.List[object]) } }

  function AddValue($val){
    if($stack.Count -eq 0){ $script:root = $val; return }
    $top = $stack.Peek()
    if($top.kind -eq "array"){ [void]$top.list.Add($val); return }
    if($top.kind -eq "object"){
      if([string]::IsNullOrEmpty($script:curProp)){ Die "CSL_E_PROP_MISSING" }
      $p = [string]$script:curProp
      if(-not $top.seen.Add($p)){ Die ("CSL_E_DUPKEY: " + $p) }
      $top.map[$p] = $val
      $script:curProp = $null
      return
    }
    Die ("CSL_E_INTERNAL_BAD_STACK_KIND: " + $top.kind)
  }

  while($r.Read()){
    switch($r.TokenType){
      ([System.Text.Json.JsonTokenType]::StartObject) { $stack.Push((NewObjFrame)); break }
      ([System.Text.Json.JsonTokenType]::EndObject) {
        $f = $stack.Pop()
        $ht = @{}
        foreach($k in $f.map.Keys){ $ht[$k] = $f.map[$k] }
        AddValue ([pscustomobject]@{ t="object"; v=$ht })
        break
      }
      ([System.Text.Json.JsonTokenType]::StartArray) { $stack.Push((NewArrFrame)); break }
      ([System.Text.Json.JsonTokenType]::EndArray) {
        $f = $stack.Pop()
        $arr = $f.list.ToArray()
        AddValue ([pscustomobject]@{ t="array"; v=$arr })
        break
      }
      ([System.Text.Json.JsonTokenType]::PropertyName) { $script:curProp = $r.GetString(); break }
      ([System.Text.Json.JsonTokenType]::String) { AddValue ([pscustomobject]@{ t="string"; v=$r.GetString() }); break }
      ([System.Text.Json.JsonTokenType]::True) { AddValue ([pscustomobject]@{ t="bool"; v=$true }); break }
      ([System.Text.Json.JsonTokenType]::False) { AddValue ([pscustomobject]@{ t="bool"; v=$false }); break }
      ([System.Text.Json.JsonTokenType]::Null) { AddValue ([pscustomobject]@{ t="null"; v=$null }); break }
      ([System.Text.Json.JsonTokenType]::Number) {
        $raw = [System.Text.Encoding]::UTF8.GetString($r.ValueSpan)
        if($raw -match '[\.eE]' ){ Die ("CSL_E_FLOAT_FORBIDDEN: " + $raw) }
        if(-not ($raw -match '^-?(0|[1-9][0-9]*)$')){ Die ("CSL_E_BAD_NUMBER: " + $raw) }
        $n = [Int64]$raw
        if([math]::Abs([double]$n) -gt 9007199254740991){ Die ("CSL_E_INT_RANGE: " + $raw) }
        AddValue ([pscustomobject]@{ t="int"; v=$raw })
        break
      }
      default { Die ("CSL_E_TOKEN_UNSUPPORTED: " + [string]$r.TokenType) }
    }
  }
  if($null -eq $root){ Die "CSL_E_EMPTY_JSON" }
  return $root
}

function CanonJsonBytesFromInputFile([string]$path){
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ Die ("MISSING_INPUT: " + $path) }
  $bytes = Read-Bytes $path
  $node = _ParseJsonToNode $bytes
  $sb = New-Object System.Text.StringBuilder
  _EmitCanonJson $node $sb
  $txt = $sb.ToString()
  $enc = New-Object System.Text.UTF8Encoding($false)
  return $enc.GetBytes($txt)
}

# ------------------------------
# Bootstrap: repo skeleton + minimal golden vectors (Option A)
# ------------------------------
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ Die ("MISSING_REPOROOT: " + $RepoRoot) }

$SpecDir = Join-Path $RepoRoot "SPEC"
$SchemasDir = Join-Path $RepoRoot "schemas\csl"
$VecRoot = Join-Path $RepoRoot "test_vectors\packet_constitution_v1\option_a\minimal_ok"
$PktRoot = Join-Path $VecRoot "packet"
$ExpRoot = Join-Path $VecRoot "expected"

EnsureDir $SpecDir
EnsureDir $SchemasDir
EnsureDir $PktRoot
EnsureDir $ExpRoot
EnsureDir (Join-Path $PktRoot "payload")
EnsureDir (Join-Path $PktRoot "signatures")

# Write spec placeholders (deterministic stubs; you will fill later)
Write-Utf8NoBomLf (Join-Path $SpecDir "canon_bytes.v1.md") "# CSL Canonical Bytes v1 (NORMATIVE)`n(locked: UTF-8 no BOM, LF, object keys sorted ordinal, no whitespace, stable escaping, integers only safe range, reject dup keys/floats)`n"
Write-Utf8NoBomLf (Join-Path $SpecDir "hash_law.v1.md") "# Hash Law v1`nsha256 = SHA-256(canonical bytes)`nobject_hash = sha256(canonical bytes of object with object_hash omitted)`n"
Write-Utf8NoBomLf (Join-Path $SpecDir "packetid_law.v1.md") "# PacketId Law v1 (Option A default)`nPacketId = sha256(canonical bytes(manifest-without-id))`npacket_id.txt stores PacketId`nsha256sums generated last over final bytes`n"
Write-Utf8NoBomLf (Join-Path $SpecDir "upgrade_rules.v1.md") "# Upgrade Rules v1`nv1 immutable; v2 new names + adapters; canon bytes changes => v2`n"

# Minimal packet payload
$helloPath = Join-Path $PktRoot "payload\hello.txt"
Write-Utf8NoBomLf $helloPath "hello`n"
$helloBytes = Read-Bytes $helloPath
$helloSha = Sha256Hex $helloBytes
$helloTag = "sha256:" + $helloSha

# Minimal manifest.json (Option A: no packet_id)
$manifestPath = Join-Path $PktRoot "manifest.json"
$created = "2026-02-16T00:00:00Z"  # fixed for golden determinism
$manifest = '{"schema":"packet.manifest.v1","kind":"packet.constitution.v1","created_time":"' + $created + '","producer":"single-tenant/demo/authority/csl","producer_instance":"demo-offline-1","files":[{"path":"payload/hello.txt","bytes":6,"sha256":"' + $helloTag + '"}]}'
Write-Utf8NoBomLf $manifestPath $manifest

# Compute PacketId from on-disk manifest bytes (manifest-without-id == manifest file in Option A)
$mBytes = Read-Bytes $manifestPath
$pktHex = Sha256Hex $mBytes
$pktId = "sha256:" + $pktHex

# Persist packet_id.txt
$PacketIdPath = Join-Path $PktRoot "packet_id.txt"
Write-Utf8NoBomLf $PacketIdPath ($pktId + "`n")

# Stub signature files (transport law requires signatures/** hashed; cryptographic signing comes later)
$sigEnvPath = Join-Path $PktRoot "signatures\sig_envelope.json"
$sigPath = Join-Path $PktRoot "signatures\manifest.sig"
Write-Utf8NoBomLf $sigEnvPath '{"schema":"csl.sig_envelope.v1","namespace":"packet/manifest","principal":"single-tenant/demo/authority/csl","key_id":"demo-ed25519","signed_object_kind":"manifest","signed_object_sha256":"sha256:' + (Sha256Hex (Read-Bytes $manifestPath)) + '","sig_ref":{"kind":"uri","uri":"signatures/manifest.sig"},"created_time":"' + $created + '"}'
Write-Utf8NoBomLf $sigPath "STUB_SIGNATURE_V1`n"

# Generate sha256sums.txt LAST (final bytes on disk)
$sumPath = Join-Path $PktRoot "sha256sums.txt"
$req = New-Object System.Collections.Generic.List[string]
[void]$req.Add("manifest.json")
[void]$req.Add("packet_id.txt")
[void]$req.Add("payload/hello.txt")
[void]$req.Add("signatures/manifest.sig")
[void]$req.Add("signatures/sig_envelope.json")
$req.Sort([System.StringComparer]::Ordinal)
$lines = New-Object System.Collections.Generic.List[string]
foreach($rel in $req){
  $p = Join-Path $PktRoot $rel
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("MISSING_REQUIRED_FILE: " + $rel) }
  $h = Sha256Hex (Read-Bytes $p)
  [void]$lines.Add(($h + "  " + ($rel -replace "\\\\","/")))
}
Write-Utf8NoBomLf $sumPath (($lines.ToArray() -join "`n") + "`n")

# Expected outputs (golden)
Write-Utf8NoBomLf (Join-Path $ExpRoot "expected_packet_id.txt") ($pktId + "`n")
Write-Utf8NoBomLf (Join-Path $ExpRoot "expected_sha256sums.txt") ([System.IO.File]::ReadAllText($sumPath,[System.Text.UTF8Encoding]::new($false)))
Write-Utf8NoBomLf (Join-Path $ExpRoot "expected_verify_result.json") '{"result":"ok","packet_id":"' + $pktId + '","manifest_sha256":"sha256:' + (Sha256Hex (Read-Bytes $manifestPath)) + '","sha256sums_sha256":"sha256:' + (Sha256Hex (Read-Bytes $sumPath)) + '"}'
Write-Utf8NoBomLf (Join-Path $ExpRoot "notes.md") "# minimal_ok`nOption A golden packet. Signatures are stubbed; crypto verify will be added when NeverLost trust is wired.`n"

# ------------------------------
# Conformance: verify Packet Constitution v1 (Option A minimal_ok)
# ------------------------------
function Verify-Packet_OptionA_Minimal([string]$PacketRoot){
  $m = Join-Path $PacketRoot "manifest.json"
  $PacketIdPath = Join-Path $PacketRoot "packet_id.txt"
  $sums = Join-Path $PacketRoot "sha256sums.txt"
  if(-not (Test-Path -LiteralPath $m -PathType Leaf)){ Die "VERIFY_FAIL_MISSING_MANIFEST" }
  if(-not (Test-Path -LiteralPath $PacketIdPath -PathType Leaf)){ Die "VERIFY_FAIL_MISSING_PACKET_ID" }
  if(-not (Test-Path -LiteralPath $sums -PathType Leaf)){ Die "VERIFY_FAIL_MISSING_SHA256SUMS" }

  $mBytes = Read-Bytes $m
  $computedPid = "sha256:" + (Sha256Hex $mBytes)
  $PacketIdText = [System.IO.File]::ReadAllText($PacketIdPath,[System.Text.UTF8Encoding]::new($false)).Replace("`r`n","`n").Replace("`r","`n").Trim()
  if([string]$PacketIdText -ne [string]$computedPid){ Die ("VERIFY_FAIL_PACKET_ID_MISMATCH expected=" + $PacketIdText + " computed=" + $computedPid) }

  $sumLines = [System.IO.File]::ReadAllText($sums,[System.Text.UTF8Encoding]::new($false)).Replace("`r`n","`n").Replace("`r","`n").Split("`n") | Where-Object { $_ -ne "" }
  $sumLines = @(@($sumLines))
  foreach($ln in $sumLines){
    $mch = [regex]::Match($ln,'^([0-9a-f]{64})\s\s(.+)$')
    if(-not $mch.Success){ Die ("VERIFY_FAIL_BAD_SHA256SUMS_LINE: " + $ln) }
    $hex = $mch.Groups[1].Value
    $rel = $mch.Groups[2].Value
    $p = Join-Path $PacketRoot ($rel -replace "/","\")
    if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("VERIFY_FAIL_MISSING_FILE: " + $rel) }
    $h = Sha256Hex (Read-Bytes $p)
    if($h -ne $hex){ Die ("VERIFY_FAIL_HASH_MISMATCH: " + $rel + " expected=" + $hex + " got=" + $h) }
  }
  return $computedPid
}

$okPid = Verify-Packet_OptionA_Minimal $PktRoot
Write-Host ("OK: PACKET_CONSTITUTION_V1_OPTION_A_MINIMAL packet_id=" + $okPid) -ForegroundColor Green
Write-Host ("WROTE: " + $VecRoot) -ForegroundColor Green

