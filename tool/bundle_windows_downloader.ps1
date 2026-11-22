param(
  [Parameter(Mandatory=$true)][string]$Destination
)
$ErrorActionPreference = 'Stop'
# Pin both versions and hashes. Never use /latest/ in the packaging path.
$ytVersion = '2026.10.26'
$denoVersion = '2.9.8'
$tools = Join-Path $Destination 'tools'
New-Item -ItemType Directory -Force $tools | Out-Null
function Get-Verified($Url, $Output, $Sha256) {
  Invoke-WebRequest -Uri $Url -OutFile $Output
  if ((Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Sha256) {
    throw "SHA256 mismatch for $Url"
  }
}
Get-Verified "https://github.com/yt-dlp/yt-dlp/releases/download/$ytVersion/yt-dlp.exe" (Join-Path $tools 'yt-dlp.exe') 'f5389d3698ecde4ef06f4e6b1ce0294fe9ac1396228c8990b8d3416d6d177a7d'
$archive = Join-Path $tools 'deno.zip'
Get-Verified "https://github.com/denoland/deno/releases/download/v$denoVersion/deno-x86_64-pc-windows-msvc.zip" $archive 'cba84b26e0df5ae7f74fc66b86a95b866872a86292ebd84fa1e959927edd93bf'
Expand-Archive -LiteralPath $archive -DestinationPath $tools -Force
Remove-Item -LiteralPath $archive
$licenses = Join-Path $tools 'licenses'
New-Item -ItemType Directory -Force $licenses | Out-Null
Invoke-WebRequest "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$ytVersion/LICENSE" -OutFile (Join-Path $licenses 'yt-dlp-LICENSE')
Invoke-WebRequest "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$ytVersion/THIRD_PARTY_LICENSES.txt" -OutFile (Join-Path $licenses 'yt-dlp-THIRD_PARTY_LICENSES.txt')
# Includes Deno's MIT license and bundled dependency notices.
& (Join-Path $tools 'deno.exe') --license | Set-Content -Encoding utf8 (Join-Path $licenses 'deno-LICENSE.txt')
if ($LASTEXITCODE -ne 0) { throw 'Deno license extraction failed' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../docs/windows-downloader.md') -Destination (Join-Path $tools 'README.md')
if ((& (Join-Path $tools 'yt-dlp.exe') --ignore-config --version) -ne $ytVersion) { throw 'Wrong yt-dlp version' }
if ($LASTEXITCODE -ne 0) { throw 'yt-dlp did not start' }
