#requires -Version 5.1
<#
.SYNOPSIS
  Package the cc-handoff GUI for Windows, embedding cc-handoff.exe so the app
  needs no separate CLI install.

.DESCRIPTION
  Run on Windows from the repo root (Flutter's Windows desktop build only works
  on Windows). Builds the Flutter Windows app, obtains cc-handoff.exe (built
  locally with Go if available, else a cross-built bin\cc-handoff-windows-<arch>.exe
  produced by scripts/package.sh on macOS), copies it next to the runner .exe so
  cli.dart resolves it by absolute path, and zips the result into dist\.

.PARAMETER Arch
  amd64 (default) or arm64 — selects the cross-built fallback binary name.
#>
[CmdletBinding()]
param(
  [ValidateSet('amd64','arm64')]
  [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' })
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root

$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$ldflags = "-X 'github.com/cc-collaboration/internal/version.Version=$version'"
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist, (Join-Path $root 'bin') | Out-Null

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw 'flutter not found on PATH' }

# 1. cc-handoff.exe — build with local Go, else reuse the cross-built artifact.
$exe = Join-Path $root 'bin\cc-handoff.exe'
if (Get-Command go -ErrorAction SilentlyContinue) {
  Write-Host '==> building cc-handoff.exe with go'
  $env:CGO_ENABLED = '0'
  & go build -ldflags $ldflags -o $exe ./cmd/cc-handoff
} else {
  $cross = Join-Path $root "bin\cc-handoff-windows-$Arch.exe"
  if (-not (Test-Path $cross)) {
    throw "go not found and no $cross — run scripts/package.sh on macOS first (it cross-builds), or install Go."
  }
  Copy-Item -Force $cross $exe
}

# 2. Flutter Windows build.
Write-Host '==> flutter build windows --release'
Push-Location app
try { & flutter build windows --release } finally { Pop-Location }

# Locate the runner Release dir (x64 or arm64) by the one containing data\.
$rel = Get-ChildItem -Path (Join-Path $root 'app\build\windows') -Recurse -Directory -Filter 'Release' -ErrorAction SilentlyContinue |
  Where-Object { Test-Path (Join-Path $_.FullName 'data') } |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $rel) { throw 'Windows build output (runner\Release) not found under app\build\windows' }

# 3. Embed cc-handoff.exe next to the runner .exe.
Write-Host "==> embedding cc-handoff.exe into $rel"
Copy-Item -Force $exe (Join-Path $rel 'cc-handoff.exe')

# 4. Zip.
$zip = Join-Path $dist "cc-handoff-windows-$Arch-v$version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $rel '*') -DestinationPath $zip
Write-Host "  OK $zip"
Write-Host ''
Write-Host "done -> $dist"
