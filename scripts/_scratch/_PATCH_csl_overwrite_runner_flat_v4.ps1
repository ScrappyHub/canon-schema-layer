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
  if($null -eq $Bytes){ $Bytes=@() }
  $sha=[System.Security.Cryptography.SHA256]::Create()
  try { $h=$sha.ComputeHash([byte[]]$Bytes) } finally { $sha.Dispose() }
  $sb=New-Object System.Text.StringBuilder
  for($i=0;$i -lt $h.Length;$i++){ [void]$sb.Append($h[$i].ToString("x2")) }
  $sb.ToString()
}
function _EscJsonString([string]$s){
  if($null -eq $s){ return "" }
  $sb=New-Object System.Text.StringBuilder
  for($i=0;$i -lt $s.Length;$i++){
    $ch=$s[$i]
    $code=[int][char]$ch
    if($code -lt 32){ [void]$sb.Append("\u" + $code.ToString("x4")) }
    elseif($code -eq 34){ [void]$sb.Append("\\\"") }
    elseif($code -eq 92){ [void]$sb.Append("\\\\") }
    else { [void]$sb.Append($ch) }
  }
  $sb.ToString()
}
function _EmitCanonJson($node,[System.Text.StringBuilder]$sb){
  $t=$node.t
  if($t -eq "null"){ [void]$sb.Append("null"); return }
  if($t -eq "bool"){ if($node.v){ [void]$sb.Append("true") } else { [void]$sb.Append("false") }; return }
  if($t -eq "string"){ [void]$sb.Append("`"" + (_EscJsonString [string]$node.v) + "`""); return }
  if($t -eq "int"){ [void]$sb.Append([string]$node.v); return }
  if($t -eq "array"){
    [void]$sb.Append("[")
    $a=@(@($node.v))
    for($i=0;$i -lt $a.Count;$i++){ if($i -gt 0){ [void]$sb.Append(",") }; _EmitCanonJson $a[$i] $sb }
    [void]$sb.Append("]")
    return
  }
  if($t -eq "object"){
    [void]$sb.Append("{")
    $keys=New-Object System.Collections.Generic.List[string]
    foreach($k in $node.v.Keys){ [void]$keys.Add([string]$k) }
    $keys.Sort([System.StringComparer]::Ordinal)
    for($i=0;$i -lt $keys.Count;$i++){
      if($i -gt 0){ [void]$sb.Append(",") }
      $k=$keys[$i]
      [void]$sb.Append("`"" + (_EscJsonString $k) + "`":")
      _EmitCanonJson $node.v[$k] $sb
    }
    [void]$sb.Append("}")
    return
  }
  Die ("CSL_E_INTERNAL_UNKNOWN_NODE_TYPE: " + $t)
}
function _ParseJsonToNode([byte[]]$bytes){
  if($null -eq $bytes){ $bytes=@() }
  $opts = New-Object System.Text.Json.JsonReaderOptions
  $opts.AllowTrailingCommas = $false
  $opts.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
  $r = New-Object System.Text.Json.Utf8JsonReader(,$bytes,$opts)
  $stack = New-Object System.Collections.Generic.Stack[object]
  $root = $null
  $curProp = $null
  function NewObj(){ [pscustomobject]@{ kind="object"; map=(New-Object System.Collections.Generic.Dictionary[string,object]([System.StringComparer]::Ordinal)); seen=(New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)) } }
  function NewArr(){ [pscustomobject]@{ kind="array"; list=(New-Object System.Collections.Generic.List[object]) } }
  function AddVal($val){
    if($stack.Count -eq 0){ $script:root = $val; return }
    $top = $stack.Peek()
    if($top.kind -eq "array"){ [void]$top.list.Add($val); return }
    if($top.kind -eq "object"){
      if([string]::IsNullOrEmpty([string]$script:curProp)){ Die "CSL_E_PROP_MISSING" }
      $p=[string]$script:curProp
      if(-not $top.seen.Add($p)){ Die ("CSL_E_DUPKEY: " + $p) }
      $top.map[$p]=$val
      $script:curProp=$null
      return
    }
    Die ("CSL_E_INTERNAL_BAD_STACK_KIND: " + $top.kind)
  }
  while($r.Read()){
    switch($r.TokenType){
      ([System.Text.Json.JsonTokenType]::StartObject) { $stack.Push((NewObj)); break }
      ([System.Text.Json.JsonTokenType]::EndObject)   {
        $f=$stack.Pop(); $ht=@{}; foreach($k in $f.map.Keys){ $ht[$k]=$f.map[$k] }
        AddVal ([pscustomobject]@{ t="object"; v=$ht }); break
      }
      ([System.Text.Json.JsonTokenType]::StartArray)  { $stack.Push((NewArr)); break }
      ([System.Text.Json.JsonTokenType]::EndArray)    { $f=$stack.Pop(); $arr=$f.list.ToArray(); AddVal ([pscustomobject]@{ t="array"; v=$arr }); break }
      ([System.Text.Json.JsonTokenType]::PropertyName){ $script:curProp=$r.GetString(); break }
      ([System.Text.Json.JsonTokenType]::String)      { AddVal ([pscustomobject]@{ t="string"; v=$r.GetString() }); break }
      ([System.Text.Json.JsonTokenType]::True)        { AddVal ([pscustomobject]@{ t="bool"; v=$true }); break }
      ([System.Text.Json.JsonTokenType]::False)       { AddVal ([pscustomobject]@{ t="bool"; v=$false }); break }
      ([System.Text.Json.JsonTokenType]::Null)        { AddVal ([pscustomobject]@{ t="null"; v=$null }); break }
      ([System.Text.Json.JsonTokenType]::Number)      {
        $raw=[System.Text.Encoding]::UTF8.GetString($r.ValueSpan)
        if($raw -match "[\.eE]"){ Die ("CSL_E_FLOAT_FORBIDDEN: " + $raw) }
        if(-not ($raw -match "^-?(0|[1-9][0-9]*)$")){ Die ("CSL_E_BAD_NUMBER: " + $raw) }
        $n=[Int64]$raw
        if([math]::Abs([double]$n) -gt 9007199254740991){ Die ("CSL_E_INT_RANGE: " + $raw) }
        AddVal ([pscustomobject]@{ t="int"; v=$raw }); break
      }
      default { Die ("CSL_E_TOKEN_UNSUPPORTED: " + [string]$r.TokenType) }
    }
  }
  if($null -eq $root){ Die "CSL_E_EMPTY_JSON" }
  return $root
}
function CanonJsonText([byte[]]$bytes){ $node=_ParseJsonToNode $bytes; $sb=New-Object System.Text.StringBuilder; _EmitCanonJson $node $sb; $sb.ToString() }
function CanonTextFromFile([string]$p){ CanonJsonText (Read-Bytes $p) }

$Target = Join-Path $RepoRoot "scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1"
$Runner = New-Object System.Collections.Generic.List[string]
[void]$Runner.Add("param([Parameter(Mandatory=$true)][string]$RepoRoot,[ValidateSet(""All"",""WriteVectors"",""ConformanceOnly"")][string]$Mode=""All"")")
[void]$Runner.Add("$ErrorActionPreference=""Stop""")
[void]$Runner.Add("Set-StrictMode -Version Latest")
[void]$Runner.Add("function Die([string]$m){ throw $m }")
[void]$Runner.Add("function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }")
[void]$Runner.Add("function Write-Utf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }; $t=$Text.Replace(""`r`n"",""`n"").Replace(""`r"",""`n""); if(-not $t.EndsWith(""`n"")){ $t += ""`n"" }; $enc=New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }")
[void]$Runner.Add("function Read-Utf8([string]$p){ [System.IO.File]::ReadAllText($p,[System.Text.UTF8Encoding]::new($false)) }")
[void]$Runner.Add("function Read-Bytes([string]$p){ [System.IO.File]::ReadAllBytes($p) }")
[void]$Runner.Add("function Sha256Hex([byte[]]$Bytes){ if($null -eq $Bytes){ $Bytes=@() }; $sha=[System.Security.Cryptography.SHA256]::Create(); try{ $h=$sha.ComputeHash([byte[]]$Bytes) } finally { $sha.Dispose() }; $sb=New-Object System.Text.StringBuilder; for($i=0;$i -lt $h.Length;$i++){ [void]$sb.Append($h[$i].ToString(""x2"")) }; $sb.ToString() }")
[void]$Runner.Add("function _EscJsonString([string]$s){ if($null -eq $s){ return """" }; $sb=New-Object System.Text.StringBuilder; for($i=0;$i -lt $s.Length;$i++){ $ch=$s[$i]; $code=[int][char]$ch; if($code -lt 32){ [void]$sb.Append(""\\u"" + $code.ToString(""x4"")) } elseif($code -eq 34){ [void]$sb.Append(""\\\""") } elseif($code -eq 92){ [void]$sb.Append(""\\\\"") } else { [void]$sb.Append($ch) } }; $sb.ToString() }")
[void]$Runner.Add("function _EmitCanonJson($node,[System.Text.StringBuilder]$sb){ $t=$node.t; if($t -eq ""null""){ [void]$sb.Append(""null""); return }; if($t -eq ""bool""){ if($node.v){ [void]$sb.Append(""true"") } else { [void]$sb.Append(""false"") }; return }; if($t -eq ""string""){ [void]$sb.Append(""`"""" + (_EscJsonString [string]$node.v) + ""`""""); return }; if($t -eq ""int""){ [void]$sb.Append([string]$node.v); return }; if($t -eq ""array""){ [void]$sb.Append(""[""); $a=@(@($node.v)); for($i=0;$i -lt $a.Count;$i++){ if($i -gt 0){ [void]$sb.Append("","") }; _EmitCanonJson $a[$i] $sb }; [void]$sb.Append("")]""); return }; if($t -eq ""object""){ [void]$sb.Append(""{""); $keys=New-Object System.Collections.Generic.List[string]; foreach($k in $node.v.Keys){ [void]$keys.Add([string]$k) }; $keys.Sort([System.StringComparer]::Ordinal); for($i=0;$i -lt $keys.Count;$i++){ if($i -gt 0){ [void]$sb.Append("","") }; $k=$keys[$i]; [void]$sb.Append(""`"""" + (_EscJsonString $k) + ""`":""); _EmitCanonJson $node.v[$k] $sb }; [void]$sb.Append(""}""); return }; Die (""CSL_E_INTERNAL_UNKNOWN_NODE_TYPE: "" + $t) }")
[void]$Runner.Add("function _ParseJsonToNode([byte[]]$bytes){ if($null -eq $bytes){ $bytes=@() }; $opts=New-Object System.Text.Json.JsonReaderOptions; $opts.AllowTrailingCommas=$false; $opts.CommentHandling=[System.Text.Json.JsonCommentHandling]::Disallow; $r=New-Object System.Text.Json.Utf8JsonReader(,$bytes,$opts); $stack=New-Object System.Collections.Generic.Stack[object]; $root=$null; $curProp=$null; function NewObj(){ [pscustomobject]@{kind=""object"";map=(New-Object System.Collections.Generic.Dictionary[string,object]([System.StringComparer]::Ordinal));seen=(New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal))} }; function NewArr(){ [pscustomobject]@{kind=""array"";list=(New-Object System.Collections.Generic.List[object])} }; function AddVal($val){ if($stack.Count -eq 0){ $script:root=$val; return }; $top=$stack.Peek(); if($top.kind -eq ""array""){ [void]$top.list.Add($val); return }; if($top.kind -eq ""object""){ if([string]::IsNullOrEmpty([string]$script:curProp)){ Die ""CSL_E_PROP_MISSING"" }; $p=[string]$script:curProp; if(-not $top.seen.Add($p)){ Die (""CSL_E_DUPKEY: "" + $p) }; $top.map[$p]=$val; $script:curProp=$null; return }; Die (""CSL_E_INTERNAL_BAD_STACK_KIND: "" + $top.kind) }; while($r.Read()){ switch($r.TokenType){ ([System.Text.Json.JsonTokenType]::StartObject){ $stack.Push((NewObj)); break } ([System.Text.Json.JsonTokenType]::EndObject){ $f=$stack.Pop(); $ht=@{}; foreach($k in $f.map.Keys){ $ht[$k]=$f.map[$k] }; AddVal ([pscustomobject]@{t=""object"";v=$ht}); break } ([System.Text.Json.JsonTokenType]::StartArray){ $stack.Push((NewArr)); break } ([System.Text.Json.JsonTokenType]::EndArray){ $f=$stack.Pop(); $arr=$f.list.ToArray(); AddVal ([pscustomobject]@{t=""array"";v=$arr}); break } ([System.Text.Json.JsonTokenType]::PropertyName){ $script:curProp=$r.GetString(); break } ([System.Text.Json.JsonTokenType]::String){ AddVal ([pscustomobject]@{t=""string"";v=$r.GetString()}); break } ([System.Text.Json.JsonTokenType]::True){ AddVal ([pscustomobject]@{t=""bool"";v=$true}); break } ([System.Text.Json.JsonTokenType]::False){ AddVal ([pscustomobject]@{t=""bool"";v=$false}); break } ([System.Text.Json.JsonTokenType]::Null){ AddVal ([pscustomobject]@{t=""null"";v=$null}); break } ([System.Text.Json.JsonTokenType]::Number){ $raw=[System.Text.Encoding]::UTF8.GetString($r.ValueSpan); if($raw -match ""[\.eE]""){ Die (""CSL_E_FLOAT_FORBIDDEN: "" + $raw) }; if(-not ($raw -match ""^-?(0|[1-9][0-9]*)$"")){ Die (""CSL_E_BAD_NUMBER: "" + $raw) }; $n=[Int64]$raw; if([math]::Abs([double]$n) -gt 9007199254740991){ Die (""CSL_E_INT_RANGE: "" + $raw) }; AddVal ([pscustomobject]@{t=""int"";v=$raw}); break } default{ Die (""CSL_E_TOKEN_UNSUPPORTED: "" + [string]$r.TokenType) } } }; if($null -eq $root){ Die ""CSL_E_EMPTY_JSON"" }; $root }")
[void]$Runner.Add("function CanonJsonText([byte[]]$bytes){ $node=_ParseJsonToNode $bytes; $sb=New-Object System.Text.StringBuilder; _EmitCanonJson $node $sb; $sb.ToString() }")
[void]$Runner.Add("function RemoveObjectHashAndCanon([byte[]]$jsonBytes){ $node=_ParseJsonToNode $jsonBytes; if($node.t -ne ""object""){ Die ""CSL_E_HASHLAW_ROOT_NOT_OBJECT"" }; if($node.v.ContainsKey(""object_hash"")){ $node.v.Remove(""object_hash"") | Out-Null }; $sb=New-Object System.Text.StringBuilder; _EmitCanonJson $node $sb; $txt=$sb.ToString(); $enc=New-Object System.Text.UTF8Encoding($false); $enc.GetBytes($txt) }")
[void]$Runner.Add("")
[void]$Runner.Add("$CJ = Join-Path $RepoRoot ""testdata\canonjson\v1""")
[void]$Runner.Add("$HL = Join-Path $RepoRoot ""testdata\hashlaw\v1""")
[void]$Runner.Add("if($Mode -eq ""All"" -or $Mode -eq ""WriteVectors""){")
[void]$Runner.Add("  EnsureDir $CJ; EnsureDir $HL")
[void]$Runner.Add("  function WriteCanonVector([string]$id,[string]$input,[string]$expectedCanon,[string]$notes){ $d=Join-Path $CJ $id; EnsureDir $d; Write-Utf8NoBomLf (Join-Path $d ""input.json"") $input; Write-Utf8NoBomLf (Join-Path $d ""expected.canon.json"") $expectedCanon; $enc=New-Object System.Text.UTF8Encoding($false); $h=Sha256Hex ($enc.GetBytes($expectedCanon)); Write-Utf8NoBomLf (Join-Path $d ""expected.sha256.txt"") (""sha256:"" + $h + ""`n""); Write-Utf8NoBomLf (Join-Path $d ""notes.md"") $notes }")
[void]$Runner.Add("  function WriteRejectVector([string]$id,[string]$input,[string]$expectedErr,[string]$notes){ $d=Join-Path $CJ $id; EnsureDir $d; Write-Utf8NoBomLf (Join-Path $d ""input.json"") $input; Write-Utf8NoBomLf (Join-Path $d ""expected.error.txt"") ($expectedErr + ""`n""); Write-Utf8NoBomLf (Join-Path $d ""notes.md"") $notes }")
[void]$Runner.Add("  function WriteHashLawVector([string]$id,[string]$objJson,[string]$notes){ $d=Join-Path $HL $id; EnsureDir $d; Write-Utf8NoBomLf (Join-Path $d ""object.without_object_hash.json"") $objJson; $bytes=Read-Bytes (Join-Path $d ""object.without_object_hash.json""); $canonNoHash=RemoveObjectHashAndCanon $bytes; $h=""sha256:"" + (Sha256Hex $canonNoHash); Write-Utf8NoBomLf (Join-Path $d ""expected.object_hash.txt"") ($h + ""`n""); Write-Utf8NoBomLf (Join-Path $d ""notes.md"") $notes }")
[void]$Runner.Add("  WriteCanonVector ""0001_min_object"" ""{""""b"""":1,""""a"""":2}"" ""{""""a"""":2,""""b"""":1}"" ""# 0001_min_object`nKey ordering, integer values.`n""")
[void]$Runner.Add("  WriteCanonVector ""0002_string_escapes"" ""{""""s"""":""""a\\""b\\\\c`n""""}"" ""{""""s"""":""""a\\""b\\\\c\\u000a""""}"" ""# 0002_string_escapes`nEscapes: quote, backslash, newline must be \\u000a.`n""")
[void]$Runner.Add("  WriteCanonVector ""0003_array_order"" ""{""""a"""":[3,2,1]}"" ""{""""a"""":[3,2,1]}"" ""# 0003_array_order`nArray order preserved.`n""")
[void]$Runner.Add("  WriteRejectVector ""9001_reject_dup_keys"" ""{""""a"""":1,""""a"""":2}"" ""CSL_E_DUPKEY: a"" ""# 9001_reject_dup_keys`nDuplicate keys MUST fail.`n""")
[void]$Runner.Add("  WriteRejectVector ""9002_reject_float"" ""{""""a"""":1.2}"" ""CSL_E_FLOAT_FORBIDDEN: 1.2"" ""# 9002_reject_float`nFloats forbidden in CSL v1.`n""")
[void]$Runner.Add("  WriteHashLawVector ""0101_manifest_object_hash"" ""{""""schema"""":""""packet.manifest.v1"""",""""kind"""":""""packet.constitution.v1"""",""""created_time"""":""""2026-02-16T00:00:00Z"""",""""producer"""":""""single-tenant/demo/authority/csl"""",""""producer_instance"""":""""demo-offline-1"""",""""files"""":[]}"" ""# 0101_manifest_object_hash`nHash of canonical bytes of object (no object_hash).`n""")
[void]$Runner.Add("  WriteHashLawVector ""0102_receipt_object_hash"" ""{""""schema"""":""""csl.receipt.v1"""",""""ts_utc"""":""""2026-02-16T00:00:00Z"""",""""type"""":""""conformance.ok.v1"""",""""note"""":""""demo""""}"" ""# 0102_receipt_object_hash`nReceipt hash example.`n""")
[void]$Runner.Add("  Write-Host (""WROTE: "" + $CJ) -ForegroundColor Green")
[void]$Runner.Add("  Write-Host (""WROTE: "" + $HL) -ForegroundColor Green")
[void]$Runner.Add("}")
[void]$Runner.Add("if($Mode -eq ""All"" -or $Mode -eq ""ConformanceOnly""){")
[void]$Runner.Add("  $cjDirs = Get-ChildItem -LiteralPath $CJ -Directory | Sort-Object Name")
[void]$Runner.Add("  $pass=0")
[void]$Runner.Add("  foreach($d in $cjDirs){")
[void]$Runner.Add("    $in = Join-Path $d.FullName ""input.json""")
[void]$Runner.Add("    $expCanon = Join-Path $d.FullName ""expected.canon.json""")
[void]$Runner.Add("    $expErr = Join-Path $d.FullName ""expected.error.txt""")
[void]$Runner.Add("    try {")
[void]$Runner.Add("      $canon = CanonJsonText (Read-Bytes $in)")
[void]$Runner.Add("      if(Test-Path -LiteralPath $expErr -PathType Leaf){ Die (""EXPECTED_ERROR_BUT_GOT_OK: "" + $d.Name) }")
[void]$Runner.Add("      $expected = Read-Utf8 $expCanon")
[void]$Runner.Add("      if($canon -ne $expected){ Die (""CANON_MISMATCH: "" + $d.Name) }")
[void]$Runner.Add("      $enc=New-Object System.Text.UTF8Encoding($false)")
[void]$Runner.Add("      $h = ""sha256:"" + (Sha256Hex ($enc.GetBytes($canon)))")
[void]$Runner.Add("      $expHash = (Read-Utf8 (Join-Path $d.FullName ""expected.sha256.txt"")).Trim()")
[void]$Runner.Add("      if($h -ne $expHash){ Die (""HASH_MISMATCH: "" + $d.Name) }")
[void]$Runner.Add("      $pass++")
[void]$Runner.Add("    } catch {")
[void]$Runner.Add("      if(Test-Path -LiteralPath $expErr -PathType Leaf){")
[void]$Runner.Add("        $want=(Read-Utf8 $expErr).Trim()")
[void]$Runner.Add("        $got=[string]$_.Exception.Message")
[void]$Runner.Add("        if($got -ne $want){ throw (""REJECT_MISMATCH: "" + $d.Name + "" want="" + $want + "" got="" + $got) }")
[void]$Runner.Add("        $pass++")
[void]$Runner.Add("      } else { throw }")
[void]$Runner.Add("    }")
[void]$Runner.Add("  }")
[void]$Runner.Add("  Write-Host (""OK: CANONJSON_V1 vectors="" + $pass) -ForegroundColor Green")
[void]$Runner.Add("  $hlDirs = Get-ChildItem -LiteralPath $HL -Directory | Sort-Object Name")
[void]$Runner.Add("  foreach($d in $hlDirs){")
[void]$Runner.Add("    $obj = Join-Path $d.FullName ""object.without_object_hash.json""")
[void]$Runner.Add("    $expected = (Read-Utf8 (Join-Path $d.FullName ""expected.object_hash.txt"")).Trim()")
[void]$Runner.Add("    $canonBytes = RemoveObjectHashAndCanon (Read-Bytes $obj)")
[void]$Runner.Add("    $got = ""sha256:"" + (Sha256Hex $canonBytes)")
[void]$Runner.Add("    if($got -ne $expected){ Die (""HASHLAW_MISMATCH: "" + $d.Name + "" expected="" + $expected + "" got="" + $got) }")
[void]$Runner.Add("  }")
[void]$Runner.Add("  Write-Host (""OK: HASHLAW_V1 vectors="" + $hlDirs.Count) -ForegroundColor Green")
[void]$Runner.Add("  Write-Host ""OK: CONFORMANCE_V1_ALL_GREEN"" -ForegroundColor Green")
[void]$Runner.Add("}")
Write-Utf8NoBomLf $Target (($Runner.ToArray() -join "`n") + "`n")
$t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Target,[ref]$t,[ref]$e); if($e -and $e.Count -gt 0){ $x=$e[0]; Die ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Target,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message) }
Write-Host ("PATCH_OK+PARSE_OK: " + $Target) -ForegroundColor Green
