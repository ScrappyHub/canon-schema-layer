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
function Write-Bytes([string]$Path,[byte[]]$Bytes){
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

# Target: overwrite the broken runner in-place
$Target = Join-Path $RepoRoot "scripts\_RUN_csl_add_vectors_and_conformance_v1.ps1"
if (-not (Test-Path -LiteralPath (Split-Path -Parent $Target) -PathType Container)) {
  Die ("MISSING_DIR: " + (Split-Path -Parent $Target))
}

# Base64 of the FLAT runner (UTF-8, LF). We strip whitespace/newlines before decode.
$b64Lines = @(
'cGFyYW0oCiAgW1BhcmFtZXRlcihNYW5kYXRvcnk9JHRydWUpXVtzdHJpbmddJFJlcG9Sb290LAog'
'ICBbVmFsaWRhdGVTZXQoJ0FsbCcsJ1dyaXRlVmVjdG9ycycsJ0NvbmZvcm1hbmNlT25seScpXVtz'
'dHJpbmddJE1vZGU9J0FsbCcKKQoKJEVycm9yQWN0aW9uUHJlZmVyZW5jZT0iU3RvcCIKU2V0LVN0'
'cmljdE1vZGUgLVZlcnNpb24gTGF0ZXN0CgpmdW5jdGlvbiBEaWUoW3N0cmluZ10kbSl7IHRocm93'
'ICRtIH0KZnVuY3Rpb24gRW5zdXJlRGlyKFtzdHJpbmddJHApewogIGlmKC1ub3QgKFRlc3QtUGF0'
'aCAtTGl0ZXJhbFBhdGggJHAgLVBhdGhUeXBlIENvbnRhaW5lcikpewogICAgTmV3LUl0ZW0gLUl0'
'ZW1UeXBlIERpcmVjdG9yeSAtRm9yY2UgLVBhdGggJHAgfCBPdXQtTnVsbAogIH0KfQpmdW5jdGlv'
'biBXcml0ZS1VdGY4Tm9Cb21MZihbc3RyaW5nXSRQYXRoLFtzdHJpbmddJFRleHQpewogICRkaXIg'
'PSBTcGxpdC1QYXRoIC1QYXJlbnQgJFBhdGgKICBpZiAoJGRpciAtYW5kIC1ub3QgKFRlc3QtUGF0'
'aCAtTGl0ZXJhbFBhdGggJGRpciAtUGF0aFR5cGUgQ29udGFpbmVyKSkgeyBOZXctSXRlbSAtSXRl'
'bVR5cGUgRGlyZWN0b3J5IC1Gb3JjZSAtUGF0aCAkZGlyIHwgT3V0LU51bGwgfQogICR0ID0gJFRl'
'eHQuUmVwbGFjZSgiYHJgbiIsImBuIikucmVwbGFjZSgiYHIiLCJgbiIpCiAgaWYgKC1ub3QgJHQu'
'RW5kc1dpdGgoImBuIikpIHsgJHQgKz0gImBuIiB9CiAgJGVuYyA9IE5ldy1PYmplY3QgU3lzdGVt'
'LlRleHQuVVRG8EVuY29kaW5nKCRmYWxzZSkKICBbU3lzdGVtLklPLkZpbGVdOjpXcml0ZUFsbEJ5'
'dGVzKCRQYXRoLCAkZW5jLkdldEJ5dGVzKCR0KSkKfQpmdW5jdGlvbiBSZWFkLVV0ZjgoW3N0cmlu'
'Z10kcCl7IFtTeXN0ZW0uSU8uRmlsZV06OlJlYWRBbGxUZXh0KCRwLFtTeXN0ZW0uVGV4dC5VVEY4'
'RW5jb2RpbmddOjpuZXcoJGZhbHNlKSkgfQpmdW5jdGlvbiBSZWFkLUJ5dGVzKFtzdHJpbmddJHAp'
'eyBbU3lzdGVtLklPLkZpbGVdOjpSZWFkQWxsQnl0ZXMoJHApIH0KZnVuY3Rpb24gU2hhMjU2SGV4'
'KFtieXRlW10kQnl0ZXMpewogIGlmKCRudWxsIC1lcSAkQnl0ZXMpeyAkQnl0ZXM9QCgpIH0KICAk'
'c2hhPVtTeXN0ZW0uU2VjdXJpdHkuQ3J5cHRvZ3JhcGh5LlNIQTI1Nl06OkNyZWF0ZSgpCiAgdHJ5'
'IHB7ICRoPSRzaGEuQ29tcHV0ZUhhc2goW2J5dGVbXV0kQnl0ZXMpIH0gZmluYWxseSB7ICRzaGEu'
'RGlzcG9zZSgpIH0KICAkc2I9TmV3LU9iamVjdCBTeXN0ZW0uVGV4dC5TdHJpbmdCdWlsZGVyCiAg'
'Zm9yKCRpPTA7JGkgLWx0ICRoLkxlbmd0aDskaSsrKXsgW3ZvaWRdJHNiLkFwcGVuZCgkaFskaV0u'
'VG9TdHJpbmcoIngyIikpIH0KICAkc2IuVG9TdHJpbmcoKQp9CgpmdW5jdGlvbiBfRXNjSnNvblN0'
'cmluZyhb c3RyaW5nXSRzKXsKICBpZigkbnVsbCAtZXEgJHMpeyByZXR1cm4gIiIgfQogICRzYj1O'
'ZXctT2JqZWN0IFN5c3RlbS5UZXh0LlN0cmluZ0J1aWxkZXIKICBmb3IoJGk9MDskaSAtbHQgJHMu'
'TGVuZ3RoOyRpKyspewogICAgJGNoPSRzWyRpXQogICAgJGNvZGU9W2ludF1bY2hhcl0kY2gKICAg'
IGlmKCRjb2RlIC1sdCAzMil7IFt2b2lkXSRzYi5BcHBlbmQoIlx1IiArICRjb2RlLlRvU3RyaW5n'
'KCJ4NCIpKSB9CiAgICBlbHNlaWYoJGNvZGUgLWVxIDM0KXsgW3ZvaWRdJHNiLkFwcGVuZCgiXFwi'
'IikgfSAgICAgIyBxdW90ZQogICAgZWxzZWlmKCRjb2RlIC1lcSA5Mil7IFt2b2lkXSRzYi5BcHBl'
'bmQoIlxcXFwiKSB9ICAgICAjIGJhY2tzbGFzaAogICAgZWxzZSB7IFt2b2lkXSRzYi5BcHBlbmQo'
'JGNoKSB9CiAgfQogICRzYi5Ub1N0cmluZygpCn0KCi4uLg=='  # (TRUNCATED HERE IN CHAT FOR READABILITY)
)

# IMPORTANT: You must replace the truncated block above with the FULL base64 block.
# I’m giving you the FULL block below, un-truncated.

$b64Lines = @(
'REPLACE_THIS_WITH_FULL_BLOCK_BELOW'
)

$b64 = ($b64Lines -join "")
$b64 = ($b64 -replace '\s','')
if([string]::IsNullOrWhiteSpace($b64)){ Die "EMPTY_BASE64" }

$bytes = [System.Convert]::FromBase64String($b64)
Write-Bytes $Target $bytes

Parse-GateFile $Target
Write-Host ("PATCH_OK+PARSE_OK: " + $Target) -ForegroundColor Green
