param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}
function Read-Utf8([string]$p){ [System.IO.File]::ReadAllText($p,[System.Text.UTF8Encoding]::new($false)) }
function Read-Bytes([string]$p){ [System.IO.File]::ReadAllBytes($p) }
function Sha256Hex([byte[]]$Bytes){
  if($null -eq $Bytes){ $Bytes = @() }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash([byte[]]$Bytes) } finally { $sha.Dispose() }
  $sb = New-Object System.Text.StringBuilder
  for($i=0;$i -lt $h.Length;$i++){ [void]$sb.Append($h[$i].ToString("x2")) }
  $sb.ToString()
}

# ------------------------------------------
# CanonJSON v1 (flat, no nested generation)
# ------------------------------------------
function _EscJsonString([string]$s){
  if($null -eq $s){ return "" }
  $sb = New-Object System.Text.StringBuilder
  for($i=0;$i -lt $s.Length;$i++){
    $ch = $s[$i]; $code = [int][char]$ch
    if($code -lt 32){ [void]$sb.Append("\u" + $code.ToString("x4")) }
    elseif($code -eq 34){ [void]$sb.Append('\"') }
    elseif($code -eq 92){ [void]$sb.Append('\\') }
    else{ [void]$sb.Append($ch) }
  }
  $sb.ToString()
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
  $stack = New-Object System.Collections.Generic.Stack[object]
  $root = $null
  $curProp = $null
  function NewObjFrame(){ return [pscustomobject]@{ kind="object"; map=(New-Object System.Collections.Generic.Dictionary[string,object]([System.StringComparer]::Ordinal)); seen=(New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)) } }
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
        $ht = @{}; foreach($k in $f.map.Keys){ $ht[$k] = $f.map[$k] }
        AddValue ([pscustomobject]@{ t="object"; v=$ht })
        break
      }
      ([System.Text.Json.JsonTokenType]::StartArray) { $stack.Push((NewArrFrame)); break }
      ([System.Text.Json.JsonTokenType]::EndArray) {
        $f = $stack.Pop(); $arr = $f.list.ToArray()
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
function CanonJsonText([byte[]]$bytes){
  $node = _ParseJsonToNode $bytes
  $sb = New-Object System.Text.StringBuilder
  _EmitCanonJson $node $sb
  $sb.ToString()
}

# ------------------------------------------
# Flat runner we will write/replace
# ------------------------------------------
$ScriptsDir = Join-Path $RepoRoot "scripts"
EnsureDir $ScriptsDir
$Target = Join-Path $ScriptsDir "_RUN_csl_add_vectors_and_conformance_v1.ps1"
$ConfDir = Join-Path $RepoRoot "conformance"
EnsureDir $ConfDir
$ConfRun = Join-Path $ConfDir "_RUN_conformance_v1.ps1"

$R = New-Object System.Collections.Generic.List[string]
[void]$R.Add('param([Parameter(Mandatory=$true)][string]$RepoRoot,[ValidateSet("All","WriteVectors","ConformanceOnly")][string]$Mode="All")')
[void]$R.Add('$ErrorActionPreference="Stop"' )
[void]$R.Add('Set-StrictMode -Version Latest' )
[void]$R.Add('function Die([string]$m){ throw $m }' )
[void]$R.Add('function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }' )
[void]$R.Add('function Write-Utf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }; $t=$Text.Replace("`r`n","`n").Replace("`r","`n"); if(-not $t.EndsWith("`n")){ $t+="`n" }; $enc=New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }' )
[void]$R.Add('function Read-Utf8([string]$p){ [System.IO.File]::ReadAllText($p,[System.Text.UTF8Encoding]::new($false)) }' )
[void]$R.Add('function Read-Bytes([string]$p){ [System.IO.File]::ReadAllBytes($p) }' )
[void]$R.Add('function Sha256Hex([byte[]]$Bytes){ if($null -eq $Bytes){ $Bytes=@() }; $sha=[System.Security.Cryptography.SHA256]::Create(); try{ $h=$sha.ComputeHash([byte[]]$Bytes) } finally { $sha.Dispose() }; $sb=New-Object System.Text.StringBuilder; for($i=0;$i -lt $h.Length;$i++){ [void]$sb.Append($h[$i].ToString("x2")) }; $sb.ToString() }' )
[void]$R.Add('# --- CanonJsonText is implemented in this file to avoid dot-sourcing ---' )
[void]$R.Add('function _EscJsonString([string]$s){ if($null -eq $s){ return "" }; $sb=New-Object System.Text.StringBuilder; for($i=0;$i -lt $s.Length;$i++){ $ch=$s[$i]; $code=[int][char]$ch; if($code -lt 32){ [void]$sb.Append("\u"+$code.ToString("x4")) } elseif($code -eq 34){ [void]$sb.Append('\"') } elseif($code -eq 92){ [void]$sb.Append('\\') } else { [void]$sb.Append($ch) } }; $sb.ToString() }' )
[void]$R.Add('function _EmitCanonJson($node,[System.Text.StringBuilder]$sb){ $t=$node.t; if($t -eq "null"){ [void]$sb.Append("null"); return }; if($t -eq "bool"){ if($node.v){ [void]$sb.Append("true") } else { [void]$sb.Append("false") }; return }; if($t -eq "string"){ [void]$sb.Append('"' + (_EscJsonString [string]$node.v) + '"'); return }; if($t -eq "int"){ [void]$sb.Append([string]$node.v); return }; if($t -eq "array"){ [void]$sb.Append("["); $a=@(@($node.v)); for($i=0;$i -lt $a.Count;$i++){ if($i -gt 0){ [void]$sb.Append(",") }; _EmitCanonJson $a[$i] $sb }; [void]$sb.Append("]"); return }; if($t -eq "object"){ [void]$sb.Append("{"); $keys=New-Object System.Collections.Generic.List[string]; foreach($k in $node.v.Keys){ [void]$keys.Add([string]$k) }; $keys.Sort([System.StringComparer]::Ordinal); for($i=0;$i -lt $keys.Count;$i++){ if($i -gt 0){ [void]$sb.Append(",") }; $k=$keys[$i]; [void]$sb.Append('"' + (_EscJsonString $k) + '":'); _EmitCanonJson $node.v[$k] $sb }; [void]$sb.Append("}"); return }; Die ("CSL_E_INTERNAL_UNKNOWN_NODE_TYPE: "+$t) }' )
[void]$R.Add('function _ParseJsonToNode([byte[]]$bytes){ if($null -eq $bytes){ $bytes=@() }; $r=New-Object System.Text.Json.Utf8JsonReader(,$bytes,[System.Text.Json.JsonReaderOptions]@{AllowTrailingCommas=$false;CommentHandling=[System.Text.Json.JsonCommentHandling]::Disallow}); $stack=New-Object System.Collections.Generic.Stack[object]; $root=$null; $curProp=$null; function NewObjFrame(){ [pscustomobject]@{kind="object";map=(New-Object System.Collections.Generic.Dictionary[string,object]([System.StringComparer]::Ordinal));seen=(New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal))} }; function NewArrFrame(){ [pscustomobject]@{kind="array";list=(New-Object System.Collections.Generic.List[object])} }; function AddValue($val){ if($stack.Count -eq 0){ $script:root=$val; return }; $top=$stack.Peek(); if($top.kind -eq "array"){ [void]$top.list.Add($val); return }; if($top.kind -eq "object"){ if([string]::IsNullOrEmpty($script:curProp)){ Die "CSL_E_PROP_MISSING" }; $p=[string]$script:curProp; if(-not $top.seen.Add($p)){ Die ("CSL_E_DUPKEY: "+$p) }; $top.map[$p]=$val; $script:curProp=$null; return }; Die ("CSL_E_INTERNAL_BAD_STACK_KIND: "+$top.kind) }; while($r.Read()){ switch($r.TokenType){ ([System.Text.Json.JsonTokenType]::StartObject){ $stack.Push((NewObjFrame)); break } ([System.Text.Json.JsonTokenType]::EndObject){ $f=$stack.Pop(); $ht=@{}; foreach($k in $f.map.Keys){ $ht[$k]=$f.map[$k] }; AddValue ([pscustomobject]@{t="object";v=$ht}); break } ([System.Text.Json.JsonTokenType]::StartArray){ $stack.Push((NewArrFrame)); break } ([System.Text.Json.JsonTokenType]::EndArray){ $f=$stack.Pop(); $arr=$f.list.ToArray(); AddValue ([pscustomobject]@{t="array";v=$arr}); break } ([System.Text.Json.JsonTokenType]::PropertyName){ $script:curProp=$r.GetString(); break } ([System.Text.Json.JsonTokenType]::String){ AddValue ([pscustomobject]@{t="string";v=$r.GetString()}); break } ([System.Text.Json.JsonTokenType]::True){ AddValue ([pscustomobject]@{t="bool";v=$true}); break } ([System.Text.Json.JsonTokenType]::False){ AddValue ([pscustomobject]@{t="bool";v=$false}); break } ([System.Text.Json.JsonTokenType]::Null){ AddValue ([pscustomobject]@{t="null";v=$null}); break } ([System.Text.Json.JsonTokenType]::Number){ $raw=[System.Text.Encoding]::UTF8.GetString($r.ValueSpan); if($raw -match '[\.eE]'){ Die ("CSL_E_FLOAT_FORBIDDEN: "+$raw) }; if(-not ($raw -match '^-?(0|[1-9][0-9]*)$')){ Die ("CSL_E_BAD_NUMBER: "+$raw) }; $n=[Int64]$raw; if([math]::Abs([double]$n) -gt 9007199254740991){ Die ("CSL_E_INT_RANGE: "+$raw) }; AddValue ([pscustomobject]@{t="int";v=$raw}); break } default { Die ("CSL_E_TOKEN_UNSUPPORTED: "+[string]$r.TokenType) } } }; if($null -eq $root){ Die "CSL_E_EMPTY_JSON" }; $root }' )
[void]$R.Add('function CanonJsonText([byte[]]$bytes){ $node=_ParseJsonToNode $bytes; $sb=New-Object System.Text.StringBuilder; _EmitCanonJson $node $sb; $sb.ToString() }' )
[void]$R.Add('')
[void]$R.Add('# ----- vector writers -----')
[void]$R.Add('$CJ = Join-Path $RepoRoot "testdata\canonjson\v1"; EnsureDir $CJ')
[void]$R.Add('$HL = Join-Path $RepoRoot "testdata\hashlaw\v1"; EnsureDir $HL')
[void]$R.Add('function WriteCanonVector([string]$id,[string]$input,[string]$expectedCanon,[string]$notes){ $d=Join-Path $CJ $id; EnsureDir $d; Write-Utf8NoBomLf (Join-Path $d "input.json") $input; Write-Utf8NoBomLf (Join-Path $d "expected.canon.json") $expectedCanon; $enc=New-Object System.Text.UTF8Encoding($false); $h="sha256:"+ (Sha256Hex ($enc.GetBytes($expectedCanon))); Write-Utf8NoBomLf (Join-Path $d "expected.sha256.txt") ($h+"`n"); Write-Utf8NoBomLf (Join-Path $d "notes.md") $notes }' )
[void]$R.Add('function WriteRejectVector([string]$id,[string]$input,[string]$expectedErr,[string]$notes){ $d=Join-Path $CJ $id; EnsureDir $d; Write-Utf8NoBomLf (Join-Path $d "input.json") $input; Write-Utf8NoBomLf (Join-Path $d "expected.error.txt") ($expectedErr+"`n"); Write-Utf8NoBomLf (Join-Path $d "notes.md") $notes }' )
[void]$R.Add('function RemoveObjectHashAndCanon([byte[]]$jsonBytes){ $node=_ParseJsonToNode $jsonBytes; if($node.t -ne "object"){ Die "CSL_E_HASHLAW_ROOT_NOT_OBJECT" }; if($node.v.ContainsKey("object_hash")){ $node.v.Remove("object_hash") | Out-Null }; $sb=New-Object System.Text.StringBuilder; _EmitCanonJson $node $sb; $txt=$sb.ToString(); $enc=New-Object System.Text.UTF8Encoding($false); $enc.GetBytes($txt) }' )
[void]$R.Add('function WriteHashLawVector([string]$id,[string]$objJson,[string]$notes){ $d=Join-Path $HL $id; EnsureDir $d; Write-Utf8NoBomLf (Join-Path $d "object.without_object_hash.json") $objJson; $bytes=Read-Bytes (Join-Path $d "object.without_object_hash.json"); $canonBytes=RemoveObjectHashAndCanon $bytes; $h="sha256:" + (Sha256Hex $canonBytes); Write-Utf8NoBomLf (Join-Path $d "expected.object_hash.txt") ($h+"`n"); Write-Utf8NoBomLf (Join-Path $d "notes.md") $notes }' )
[void]$R.Add('')
[void]$R.Add('if($Mode -ne "ConformanceOnly"){' )
[void]$R.Add('  WriteCanonVector "0001_min_object" "{""b"":1,""a"":2}" "{""a"":2,""b"":1}" "# 0001_min_object`nKey ordering, integer values.`n"' )
[void]$R.Add('  WriteCanonVector "0002_string_escapes" "{""s"":""a\""b\\c`n""}" "{""s"":""a\""b\\c\u000a""}" "# 0002_string_escapes`nEscapes: quote, backslash, control char newline must be \\u000a.`n"' )
[void]$R.Add('  WriteCanonVector "0003_array_order" "{""a"":[3,2,1]}" "{""a"":[3,2,1]}" "# 0003_array_order`nArray order preserved.`n"' )
[void]$R.Add('  WriteRejectVector "9001_reject_dup_keys" "{""a"":1,""a"":2}" "CSL_E_DUPKEY: a" "# 9001_reject_dup_keys`nDuplicate keys MUST fail.`n"' )
[void]$R.Add('  WriteRejectVector "9002_reject_float" "{""a"":1.2}" "CSL_E_FLOAT_FORBIDDEN: 1.2" "# 9002_reject_float`nFloats forbidden in CSL v1.`n"' )
[void]$R.Add('  WriteHashLawVector "0101_manifest_object_hash" "{""schema"":""packet.manifest.v1"",""kind"":""packet.constitution.v1"",""created_time"":""2026-02-16T00:00:00Z"",""producer"":""single-tenant/demo/authority/csl"",""producer_instance"":""demo-offline-1"",""files"":[]}" "# 0101_manifest_object_hash`nHash of canonical bytes of object (no object_hash field present).`n"' )
[void]$R.Add('  WriteHashLawVector "0102_receipt_object_hash" "{""schema"":""csl.receipt.v1"",""ts_utc"":""2026-02-16T00:00:00Z"",""type"":""conformance.ok.v1"",""note"":""demo""}" "# 0102_receipt_object_hash`nReceipt hash example.`n"' )
[void]$R.Add('  Write-Host ("WROTE: " + $CJ) -ForegroundColor Green' )
[void]$R.Add('  Write-Host ("WROTE: " + $HL) -ForegroundColor Green' )
[void]$R.Add('}' )
[void]$R.Add('')
[void]$R.Add('if($Mode -ne "WriteVectors"){' )
[void]$R.Add('  $pass = 0' )
[void]$R.Add('  $cjDirs = Get-ChildItem -LiteralPath $CJ -Directory | Sort-Object Name' )
[void]$R.Add('  foreach($d in $cjDirs){' )
[void]$R.Add('    $in = Join-Path $d.FullName "input.json"' )
[void]$R.Add('    $expCanon = Join-Path $d.FullName "expected.canon.json"' )
[void]$R.Add('    $expErr = Join-Path $d.FullName "expected.error.txt"' )
[void]$R.Add('    try {' )
[void]$R.Add('      $canon = CanonJsonText (Read-Bytes $in)' )
[void]$R.Add('      if(Test-Path -LiteralPath $expErr -PathType Leaf){ Die ("EXPECTED_ERROR_BUT_GOT_OK: " + $d.Name) }' )
[void]$R.Add('      $expected = Read-Utf8 $expCanon' )
[void]$R.Add('      if($canon -ne $expected){ Die ("CANON_MISMATCH: " + $d.Name) }' )
[void]$R.Add('      $enc = New-Object System.Text.UTF8Encoding($false)' )
[void]$R.Add('      $gotHash = "sha256:" + (Sha256Hex ($enc.GetBytes($canon)))' )
[void]$R.Add('      $expHash = (Read-Utf8 (Join-Path $d.FullName "expected.sha256.txt")).Trim()' )
[void]$R.Add('      if($gotHash -ne $expHash){ Die ("HASH_MISMATCH: " + $d.Name) }' )
[void]$R.Add('      $pass++' )
[void]$R.Add('    } catch {' )
[void]$R.Add('      if(Test-Path -LiteralPath $expErr -PathType Leaf){' )
[void]$R.Add('        $want = (Read-Utf8 $expErr).Trim()' )
[void]$R.Add('        $got  = [string]$_.Exception.Message' )
[void]$R.Add('        if($got -ne $want){ throw ("REJECT_MISMATCH: " + $d.Name + " want=" + $want + " got=" + $got) }' )
[void]$R.Add('        $pass++' )
[void]$R.Add('      } else { throw }' )
[void]$R.Add('    }' )
[void]$R.Add('  }' )
[void]$R.Add('  Write-Host ("OK: CANONJSON_V1 vectors=" + $pass) -ForegroundColor Green' )
[void]$R.Add('  $hlDirs = Get-ChildItem -LiteralPath $HL -Directory | Sort-Object Name' )
[void]$R.Add('  foreach($d in $hlDirs){' )
[void]$R.Add('    $obj = Join-Path $d.FullName "object.without_object_hash.json"' )
[void]$R.Add('    $expected = (Read-Utf8 (Join-Path $d.FullName "expected.object_hash.txt")).Trim()' )
[void]$R.Add('    $canonBytes = RemoveObjectHashAndCanon (Read-Bytes $obj)' )
[void]$R.Add('    $got = "sha256:" + (Sha256Hex $canonBytes)' )
[void]$R.Add('    if($got -ne $expected){ Die ("HASHLAW_MISMATCH: " + $d.Name + " expected=" + $expected + " got=" + $got) }' )
[void]$R.Add('  }' )
[void]$R.Add('  Write-Host ("OK: HASHLAW_V1 vectors=" + $hlDirs.Count) -ForegroundColor Green' )
[void]$R.Add('  Write-Host "OK: CONFORMANCE_V1_ALL_GREEN" -ForegroundColor Green' )
[void]$R.Add('}' )

Write-Utf8NoBomLf $Target (($R.ToArray() -join "`n") + "`n")
Write-Utf8NoBomLf $ConfRun ('param([Parameter(Mandatory=$true)][string]$RepoRoot)' + "`n" + '$PSExe = (Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe")' + "`n" + '& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1") -RepoRoot $RepoRoot -Mode ConformanceOnly | Out-Host' + "`n")
Write-Host ("OK: WROTE: " + $Target) -ForegroundColor Green
Write-Host ("OK: WROTE: " + $ConfRun) -ForegroundColor Green
