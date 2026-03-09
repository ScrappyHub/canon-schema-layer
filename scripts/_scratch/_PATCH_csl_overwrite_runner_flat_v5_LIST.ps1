param([Parameter(Mandatory=$true)][string]$RepoRoot)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function EnsureDir([string]$p){
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}
function Parse-GateFile([string]$Path){
  $t=$null; $e=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
  if($e -and $e.Count -gt 0){
    $x=$e[0]
    Die ("PARSE_GATE_FAIL: {0}:{1}:{2}: {3}" -f $Path,$x.Extent.StartLineNumber,$x.Extent.StartColumnNumber,$x.Message)
  }
}

$Target = Join-Path $RepoRoot 'scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1'

# Build runner as lines (avoids nested here-string terminators)
$R = New-Object System.Collections.Generic.List[string]

# ---- header ----
[void]$R.Add('param(')
[void]$R.Add('  [Parameter(Mandatory=$true)][string]$RepoRoot,')
[void]$R.Add('  [ValidateSet(''All'',''WriteVectors'',''ConformanceOnly'')][string]$Mode=''All''')
[void]$R.Add(')')
[void]$R.Add('')
[void]$R.Add('$ErrorActionPreference="Stop"')
[void]$R.Add('Set-StrictMode -Version Latest')
[void]$R.Add('')
[void]$R.Add('function Die([string]$m){ throw $m }')
[void]$R.Add('function EnsureDir([string]$p){')
[void]$R.Add('  if(-not (Test-Path -LiteralPath $p -PathType Container)){')
[void]$R.Add('    New-Item -ItemType Directory -Force -Path $p | Out-Null')
[void]$R.Add('  }')
[void]$R.Add('}')
[void]$R.Add('function Write-Utf8NoBomLf([string]$Path,[string]$Text){')
[void]$R.Add('  $dir = Split-Path -Parent $Path')
[void]$R.Add('  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }')
[void]$R.Add('  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")')
[void]$R.Add('  if (-not $t.EndsWith("`n")) { $t += "`n" }')
[void]$R.Add('  $enc = New-Object System.Text.UTF8Encoding($false)')
[void]$R.Add('  [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))')
[void]$R.Add('}')
[void]$R.Add('function Read-Utf8([string]$p){ [System.IO.File]::ReadAllText($p,[System.Text.UTF8Encoding]::new($false)) }')
[void]$R.Add('function Read-Bytes([string]$p){ [System.IO.File]::ReadAllBytes($p) }')
[void]$R.Add('')
[void]$R.Add('function Sha256Hex([byte[]]$Bytes){')
[void]$R.Add('  if($null -eq $Bytes){ $Bytes=@() }')
[void]$R.Add('  $sha=[System.Security.Cryptography.SHA256]::Create()')
[void]$R.Add('  try { $h=$sha.ComputeHash([byte[]]$Bytes) } finally { $sha.Dispose() }')
[void]$R.Add('  $sb=New-Object System.Text.StringBuilder')
[void]$R.Add('  for($i=0;$i -lt $h.Length;$i++){ [void]$sb.Append($h[$i].ToString(''x2'')) }')
[void]$R.Add('  $sb.ToString()')
[void]$R.Add('}')
[void]$R.Add('')

# ---- JSON strict parser + canon emitter ----
# (We keep your exact logic, but as lines; this avoids all backslash-quote parser traps)

$JsonBlock = @(
'function _Utf8ToString([byte[]]$b){',
'  if($null -eq $b){ $b=@() }',
'  $enc = New-Object System.Text.UTF8Encoding($false,$true)',
'  $enc.GetString($b)',
'}',
'function _IsWs([char]$c){ return ($c -eq [char]9 -or $c -eq [char]10 -or $c -eq [char]13 -or $c -eq [char]32) }',
'function _SkipWs([string]$s,[ref]$i){ while($i.Value -lt $s.Length -and (_IsWs $s[$i.Value])){ $i.Value++ } }',
'function _ParseHex4([string]$s,[ref]$i){',
'  if(($i.Value + 4) -gt $s.Length){ Die ''CSL_E_BAD_ESCAPE_U'' }',
'  $hex = $s.Substring($i.Value,4)',
'  if(-not ($hex -match ''^[0-9A-Fa-f]{4}$'')){ Die ''CSL_E_BAD_ESCAPE_U'' }',
'  $i.Value += 4',
'  return [int]::Parse($hex,[System.Globalization.NumberStyles]::HexNumber)',
'}',
'function _ParseString([string]$s,[ref]$i){',
'  if($s[$i.Value] -ne ''"''){ Die ''CSL_E_STRING_EXPECTED'' }',
'  $i.Value++',
'  $sb = New-Object System.Text.StringBuilder',
'  while($true){',
'    if($i.Value -ge $s.Length){ Die ''CSL_E_UNTERMINATED_STRING'' }',
'    $ch = $s[$i.Value]',
'    if($ch -eq ''"''){ $i.Value++; break }',
'    if([int][char]$ch -lt 32){ Die ''CSL_E_STRING_CTRL'' }',
'    if($ch -ne ''\''' + '){ [void]$sb.Append($ch); $i.Value++; continue }',
'    $i.Value++',
'    if($i.Value -ge $s.Length){ Die ''CSL_E_BAD_ESCAPE'' }',
'    $e = $s[$i.Value]',
'    switch($e){',
'      ''"''  { [void]$sb.Append(''"'');  $i.Value++; break }',
'      ''\''  { [void]$sb.Append(''\'' );  $i.Value++; break }',
'      ''/''  { [void]$sb.Append(''/'');  $i.Value++; break }',
'      ''b''  { [void]$sb.Append([char]8);  $i.Value++; break }',
'      ''f''  { [void]$sb.Append([char]12); $i.Value++; break }',
'      ''n''  { [void]$sb.Append([char]10); $i.Value++; break }',
'      ''r''  { [void]$sb.Append([char]13); $i.Value++; break }',
'      ''t''  { [void]$sb.Append([char]9);  $i.Value++; break }',
'      ''u''  { $i.Value++; $cp = _ParseHex4 $s ([ref]$i); [void]$sb.Append([char]$cp); break }',
'      default { Die ''CSL_E_BAD_ESCAPE'' }',
'    }',
'  }',
'  return $sb.ToString()',
'}',
'function _ParseNumberToken([string]$s,[ref]$i){',
'  $start = $i.Value',
'  if($s[$i.Value] -eq ''-''){ $i.Value++ }',
'  if($i.Value -ge $s.Length){ Die ''CSL_E_BAD_NUMBER'' }',
'  if($s[$i.Value] -eq ''0''){ $i.Value++ } else {',
'    if(-not ($s[$i.Value] -match ''[1-9]'')){ Die ''CSL_E_BAD_NUMBER'' }',
'    while($i.Value -lt $s.Length -and ($s[$i.Value] -match ''[0-9]'')){ $i.Value++ }',
'  }',
'  if($i.Value -lt $s.Length){ $c = $s[$i.Value]; if($c -eq ''.'' -or $c -eq ''e'' -or $c -eq ''E''){ Die (''CSL_E_FLOAT_FORBIDDEN: '' + $s.Substring($start,[Math]::Min(16,$s.Length-$start))) } }',
'  $raw = $s.Substring($start, $i.Value - $start)',
'  if(-not ($raw -match ''^-?(0|[1-9][0-9]*)$'')){ Die (''CSL_E_BAD_NUMBER: '' + $raw) }',
'  $n = [Int64]$raw',
'  if([math]::Abs([double]$n) -gt 9007199254740991){ Die (''CSL_E_INT_RANGE: '' + $raw) }',
'  return $raw',
'}',
'function _ParseValue([string]$s,[ref]$i){',
'  _SkipWs $s ([ref]$i)',
'  if($i.Value -ge $s.Length){ Die ''CSL_E_UNEXPECTED_EOF'' }',
'  $ch = $s[$i.Value]',
'  if($ch -eq ''"''){ $str=_ParseString $s ([ref]$i); return [pscustomobject]@{ t=''string''; v=$str } }',
'  if($ch -eq ''{''){',
'    $i.Value++',
'    $map = New-Object System.Collections.Generic.Dictionary[string,object]([System.StringComparer]::Ordinal)',
'    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)',
'    _SkipWs $s ([ref]$i)',
'    if($i.Value -lt $s.Length -and $s[$i.Value] -eq ''}''){ $i.Value++; return [pscustomobject]@{ t=''object''; v=$map } }',
'    while($true){',
'      _SkipWs $s ([ref]$i)',
'      if($i.Value -ge $s.Length -or $s[$i.Value] -ne ''"''){ Die ''CSL_E_PROP_EXPECTED'' }',
'      $k = _ParseString $s ([ref]$i)',
'      if(-not $seen.Add($k)){ Die (''CSL_E_DUPKEY: '' + $k) }',
'      _SkipWs $s ([ref]$i)',
'      if($i.Value -ge $s.Length -or $s[$i.Value] -ne '':'' ){ Die ''CSL_E_COLON_EXPECTED'' }',
'      $i.Value++',
'      $val = _ParseValue $s ([ref]$i)',
'      $map[$k] = $val',
'      _SkipWs $s ([ref]$i)',
'      if($i.Value -ge $s.Length){ Die ''CSL_E_UNTERMINATED_OBJECT'' }',
'      if($s[$i.Value] -eq ''}''){ $i.Value++; break }',
'      if($s[$i.Value] -ne '',''){ Die ''CSL_E_COMMA_EXPECTED'' }',
'      $i.Value++',
'    }',
'    return [pscustomobject]@{ t=''object''; v=$map }',
'  }',
'  if($ch -eq ''[''){',
'    $i.Value++',
'    $list = New-Object System.Collections.Generic.List[object]',
'    _SkipWs $s ([ref]$i)',
'    if($i.Value -lt $s.Length -and $s[$i.Value] -eq '']''){ $i.Value++; return [pscustomobject]@{ t=''array''; v=$list.ToArray() } }',
'    while($true){',
'      $val = _ParseValue $s ([ref]$i)',
'      [void]$list.Add($val)',
'      _SkipWs $s ([ref]$i)',
'      if($i.Value -ge $s.Length){ Die ''CSL_E_UNTERMINATED_ARRAY'' }',
'      if($s[$i.Value] -eq '']''){ $i.Value++; break }',
'      if($s[$i.Value] -ne '',''){ Die ''CSL_E_COMMA_EXPECTED'' }',
'      $i.Value++',
'    }',
'    return [pscustomobject]@{ t=''array''; v=$list.ToArray() }',
'  }',
'  if($ch -eq ''t'' -and ($i.Value+4) -le $s.Length -and $s.Substring($i.Value,4) -eq ''true''){ $i.Value+=4; return [pscustomobject]@{ t=''bool''; v=$true } }',
'  if($ch -eq ''f'' -and ($i.Value+5) -le $s.Length -and $s.Substring($i.Value,5) -eq ''false''){ $i.Value+=5; return [pscustomobject]@{ t=''bool''; v=$false } }',
'  if($ch -eq ''n'' -and ($i.Value+4) -le $s.Length -and $s.Substring($i.Value,4) -eq ''null''){ $i.Value+=4; return [pscustomobject]@{ t=''null''; v=$null } }',
'  if($ch -eq ''-'' -or ($ch -match ''[0-9]'')){ $raw=_ParseNumberToken $s ([ref]$i); return [pscustomobject]@{ t=''int''; v=$raw } }',
'  Die (''CSL_E_TOKEN_UNSUPPORTED: '' + $ch)',
'}',
'function Parse-StrictJson([byte[]]$bytes){',
'  $s = _Utf8ToString $bytes',
'  $i = 0',
'  $node = _ParseValue $s ([ref]$i)',
'  _SkipWs $s ([ref]$i)',
'  if($i -ne $s.Length){ Die ''CSL_E_TRAILING_GARBAGE'' }',
'  return $node',
'}',
'function _EscJsonString([string]$s){',
'  if($null -eq $s){ return '''' }',
'  $sb=New-Object System.Text.StringBuilder',
'  for($i=0;$i -lt $s.Length;$i++){',
'    $ch=$s[$i]',
'    $code=[int][char]$ch',
'    if($code -lt 32){ [void]$sb.Append(''\u'' + $code.ToString(''x4'')) }',
'    elseif($code -eq 34){ [void]$sb.Append(''\"'') }',
'    elseif($code -eq 92){ [void]$sb.Append(''\\'') }',
'    else { [void]$sb.Append($ch) }',
'  }',
'  $sb.ToString()',
'}'
)

foreach($line in $JsonBlock){ [void]$R.Add($line) }

# NOTE: For brevity, this patcher only repairs the runner parse & header and core JSON routines.
# If you need the rest (canon emit + vectors + conformance), we append from a file if present.
$Tail = Join-Path $RepoRoot 'scripts\_scratch\_runner_tail_v5.txt'
if(Test-Path -LiteralPath $Tail -PathType Leaf){
  $tailText = [System.IO.File]::ReadAllText($Tail,[System.Text.UTF8Encoding]::new($false))
  foreach($line in ($tailText -replace "`r`n","`n" -split "`n")){ [void]$R.Add($line) }
} else {
  [void]$R.Add('')
  [void]$R.Add('Die ''CSL_E_MISSING_TAIL_BLOCK: scripts\_scratch\_runner_tail_v5.txt''')
}

Write-Utf8NoBomLf $Target (($R.ToArray() -join "`n") + "`n")
Parse-GateFile $Target
Write-Host ("PATCH_OK+PARSE_OK: " + $Target) -ForegroundColor Green
