#requires -Version 5.1
<#
.SYNOPSIS
  Install the cc-handoff client on Windows.

.DESCRIPTION
  Copies cc-handoff.exe and cc-handoff-mcp.exe into
  $env:LOCALAPPDATA\Programs\cc-handoff\, prepends that directory to the
  current user's PATH if missing, and (with -RegisterTask) registers a Task
  Scheduler entry that runs `cc-handoff watch` at logon.

  Run from the repo root after `make windows`, or pass -BinDir to point at
  the directory holding the .exe files.

.PARAMETER BinDir
  Directory containing cc-handoff.exe and cc-handoff-mcp.exe. Defaults to
  the bin/ directory of the repo, looking for the *-windows-amd64.exe
  artifacts produced by the Makefile.

.PARAMETER RegisterTask
  Also register the cc-handoff-watch scheduled task in the current repo's
  working directory. Run from inside a repo that already has
  .cc-handoff.toml configured.
#>
[CmdletBinding()]
param(
  [string]$BinDir = (Join-Path (Get-Location) "bin"),
  [switch]$RegisterTask
)

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\cc-handoff'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# Accept either the cross-build artifact name (cc-handoff-windows-amd64.exe)
# or the plain name (cc-handoff.exe), copying whichever exists.
$pairs = @(
  @{ Src = 'cc-handoff-windows-amd64.exe'; Alt = 'cc-handoff.exe';     Dst = 'cc-handoff.exe' },
  @{ Src = 'cc-handoff-mcp-windows-amd64.exe'; Alt = 'cc-handoff-mcp.exe'; Dst = 'cc-handoff-mcp.exe' }
)
foreach ($p in $pairs) {
  $src = Join-Path $BinDir $p.Src
  if (-not (Test-Path $src)) { $src = Join-Path $BinDir $p.Alt }
  if (-not (Test-Path $src)) {
    throw "missing binary in $BinDir (looked for $($p.Src) and $($p.Alt)); build first: make windows"
  }
  Copy-Item -Force $src (Join-Path $installDir $p.Dst)
}

# Prepend installDir to the user's PATH if not already there.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $userPath) { $userPath = '' }
$paths = $userPath -split ';' | Where-Object { $_ -ne '' }
if ($paths -notcontains $installDir) {
  $newPath = (@($installDir) + $paths) -join ';'
  [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  Write-Host "added $installDir to user PATH (open a new terminal to pick it up)"
}

Write-Host "installed cc-handoff to $installDir"

if ($RegisterTask) {
  $bin = Join-Path $installDir 'cc-handoff.exe'
  $xmlFile = Join-Path $env:TEMP 'cc-handoff-watch.xml'
  # The template declares <?xml ... encoding="UTF-8"?>; write the bytes as
  # UTF-8 without BOM so the declaration matches, otherwise schtasks rejects
  # the file. PowerShell 5.1's `>` and `Out-File` default to UTF-16 LE BOM.
  $xml = & $bin watch print-unit
  [System.IO.File]::WriteAllText($xmlFile, ($xml -join "`n"), [System.Text.UTF8Encoding]::new($false))
  schtasks.exe /Create /XML $xmlFile /TN cc-handoff-watch /F | Out-Null
  Remove-Item $xmlFile
  Write-Host "registered scheduled task 'cc-handoff-watch' (start with: schtasks /Run /TN cc-handoff-watch)"
}

Write-Host ''
Write-Host 'next steps:'
Write-Host '  cc-handoff init               # generate %AppData%\cc-handoff\config.toml + repo .cc-handoff.toml'
if (-not $RegisterTask) {
  Write-Host '  cc-handoff watch print-unit > t.xml'
  Write-Host '  schtasks /Create /XML t.xml /TN cc-handoff-watch'
}
