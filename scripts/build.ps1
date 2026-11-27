#Requires -Version 7.2
# Copyright 2026 The Haze Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

<#
.SYNOPSIS
  Builds Haze on Windows. The PowerShell counterpart of scripts/build.sh.

.DESCRIPTION
  scripts\build.ps1 dev|release [target ...]

    dev      component build in out\Dev, fast to link
    release  official build in out\Release

  Targets default to "chrome". The tree must exist already: run
  scripts/fetch.sh, scripts/prepare.sh and scripts/patch.sh apply from Git Bash
  first. HAZE_JOBS overrides the number of parallel jobs.

  Like build.sh, this syncs overlay\ to build\src\haze\, fetches the tools
  ungoogled-chromium prunes from what Chromium's own DEPS declares, writes
  args.gn, runs gn gen and then ninja, and logs to build\logs\.

  PowerShell 7.2 is the minimum because older versions turn a native command's
  stderr into terminating errors under ErrorActionPreference Stop.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [ValidateSet('dev', 'release')]
  [string] $Config,

  [Parameter(Position = 1, ValueFromRemainingArguments)]
  [string[]] $Targets = @('chrome')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# The progress bar of the web cmdlets slows large downloads down a lot, and
# downloads go through curl.exe anyway; this keeps other cmdlets quiet too.
$ProgressPreference = 'SilentlyContinue'
# For [IO.Compression.ZipFile], which cipd packages are extracted with.
Add-Type -AssemblyName System.IO.Compression.FileSystem

$HazeRoot = Split-Path -Parent $PSScriptRoot
$ScriptsDir = $PSScriptRoot
$BuildDir = Join-Path $HazeRoot 'build'
$SrcDir = Join-Path $BuildDir 'src'
$DownloadDir = Join-Path $BuildDir 'download_cache'
$LogDir = Join-Path $BuildDir 'logs'
$UngoogledDir = Join-Path $HazeRoot 'ungoogled-chromium'
$FlagsDir = Join-Path $HazeRoot 'flags'
$OutDir = Join-Path $SrcDir ($Config -eq 'dev' ? 'out\Dev' : 'out\Release')
$Gn = Join-Path $SrcDir 'buildtools\win\gn.exe'
$Ninja = Join-Path $SrcDir 'third_party\ninja\ninja.exe'
$LogFile = $null
$Python = $null

# --- Logging ----------------------------------------------------------------

function Write-Log([string] $Line) {
  if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $Line -Encoding utf8NoBOM }
}

function Write-Step([string] $Message) {
  Write-Host "==> $Message" -ForegroundColor Cyan
  Write-Log "==> $Message"
}

function Write-Info([string] $Message) {
  Write-Host "    $Message"
  Write-Log "    $Message"
}

function Write-HazeWarning([string] $Message) {
  Write-Host "warning: $Message" -ForegroundColor Yellow
  Write-Log "warning: $Message"
}

function Stop-Haze([string] $Message) {
  Write-Log "error: $Message"
  throw "build.ps1: $Message"
}

# Runs a native command, tees its output into the log, and stops on failure.
function Invoke-Native([string] $Exe, [string[]] $Arguments) {
  Write-Log "+ $Exe $($Arguments -join ' ')"
  & $Exe @Arguments 2>&1 | ForEach-Object {
    $text = "$_"
    Write-Host $text
    Write-Log $text
  }
  if ($LASTEXITCODE -ne 0) {
    Stop-Haze "command failed (exit $LASTEXITCODE): $Exe $($Arguments -join ' ')"
  }
}

# --- Checks -----------------------------------------------------------------

function Get-PinnedVersion {
  (Get-Content -Raw (Join-Path $HazeRoot 'chromium_version.txt')).Trim()
}

function Assert-Versions {
  $pinned = Get-PinnedVersion
  $theirs = (Get-Content -Raw (Join-Path $UngoogledDir 'chromium_version.txt')).Trim()
  if ($pinned -ne $theirs) {
    Stop-Haze "chromium_version.txt is $pinned but ungoogled-chromium is pinned to $theirs"
  }
  $versionFile = Join-Path $SrcDir 'chrome\VERSION'
  if (-not (Test-Path -LiteralPath $versionFile)) {
    Stop-Haze "no prepared tree at $SrcDir; run scripts/fetch.sh, scripts/prepare.sh and scripts/patch.sh apply in Git Bash first"
  }
  $parts = @{}
  foreach ($line in Get-Content -LiteralPath $versionFile) {
    if ($line -match '^(MAJOR|MINOR|BUILD|PATCH)=(\d+)$') { $parts[$Matches[1]] = $Matches[2] }
  }
  $tree = '{0}.{1}.{2}.{3}' -f $parts.MAJOR, $parts.MINOR, $parts.BUILD, $parts.PATCH
  if ($tree -ne $pinned) {
    Stop-Haze "build\src is Chromium $tree, but chromium_version.txt pins $pinned"
  }
}

# Same rule as haze_require_python in lib.sh: python.org installs have no
# python3.exe, and "python3" may then be the Microsoft Store stub.
function Find-Python {
  foreach ($name in 'python3', 'python') {
    foreach ($cmd in @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) {
      if ($cmd.Source -like '*\WindowsApps\*') { continue }
      & $cmd.Source -I -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>$null
      if ($LASTEXITCODE -eq 0) { return $cmd.Source }
      Write-HazeWarning "$($cmd.Source) is older than Python 3.10"
    }
  }
  Stop-Haze 'no Python 3.10 or newer found; install it from python.org with "Add python.exe to PATH"'
}

function Assert-Command([string] $Name) {
  if (-not (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)) {
    Stop-Haze "required command not found: $Name"
  }
}

# Chromium builds with clang-cl but needs Visual Studio's headers, libraries and
# tools, plus a specific Windows SDK. vs_toolchain.py looks for the version
# Chromium pins; DEPOT_TOOLS_WIN_TOOLCHAIN=0 makes it use the local install
# instead of Google's packaged toolchain, which needs Google credentials.
function Initialize-VisualStudio {
  $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'

  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere)) {
    Stop-Haze 'Visual Studio is not installed (no vswhere.exe)'
  }
  $vs = & $vswhere -latest -products * -version '[18.0,19.0)' `
    -requires Microsoft.VisualStudio.Workload.NativeDesktop Microsoft.VisualStudio.Component.VC.ATLMFC `
    -property installationPath
  if (-not $vs) {
    Stop-Haze 'need Visual Studio 2026 (18.x) with "Desktop development with C++" and "C++ ATL/MFC"'
  }
  # vs_toolchain.py only guesses the standard install paths; tell it.
  $env:vs2026_install = $vs
  Write-Info "Visual Studio: $vs"

  $toolchainPy = Get-Content -Raw (Join-Path $SrcDir 'build\vs_toolchain.py')
  if ($toolchainPy -notmatch "SDK_VERSION = '([0-9.]+)'") {
    Stop-Haze 'cannot read SDK_VERSION from build\vs_toolchain.py'
  }
  $sdk = $Matches[1]
  $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
  if (-not (Test-Path -LiteralPath (Join-Path $kits "Include\$sdk"))) {
    Stop-Haze "need Windows SDK $sdk (Visual Studio Installer, Individual components)"
  }
  Write-Info "Windows SDK: $sdk"

  # The debugging tools ship with the SDK but are a separate option. Chromium
  # needs a dbghelp.dll new enough for its large-page PDBs.
  $dbghelp = Join-Path $kits 'Debuggers\x64\dbghelp.dll'
  if (-not (Test-Path -LiteralPath $dbghelp)) {
    Stop-Haze 'need the Windows SDK "Debugging Tools for Windows" (Apps > Windows Software Development Kit > Modify)'
  }
  $dbgVersion = [version](Get-Item -LiteralPath $dbghelp).VersionInfo.ProductVersion
  if ($dbgVersion -lt [version]'10.0.26100.3323') {
    Write-HazeWarning "Debugging Tools are $dbgVersion; Chromium asks for 10.0.26100.3323 or newer"
  }
}

# --- Source tree ------------------------------------------------------------

# overlay\ is the source of truth; build\src\haze\ is a copy kept identical.
function Sync-Overlay {
  Write-Step 'syncing overlay\ -> build\src\haze\'
  $from = Join-Path $HazeRoot 'overlay'
  $to = Join-Path $SrcDir 'haze'
  & robocopy $from $to /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
  # robocopy exit codes below 8 mean success (1 = files copied).
  if ($LASTEXITCODE -ge 8) { Stop-Haze "robocopy failed with exit code $LASTEXITCODE" }
  $global:LASTEXITCODE = 0
}

# Same as haze_src_git_settings and haze_exclude_generated in lib.sh. The
# exclude list is shared through scripts\src_git_exclude.
function Initialize-SrcGit {
  Invoke-Native git @('-C', $SrcDir, 'config', 'core.autocrlf', 'false')
  Invoke-Native git @('-C', $SrcDir, 'config', 'core.eol', 'lf')
  Invoke-Native git @('-C', $SrcDir, 'config', 'core.longpaths', 'true')

  $exclude = Join-Path $SrcDir '.git\info\exclude'
  New-Item -ItemType Directory -Force -Path (Split-Path $exclude) | Out-Null
  $present = @()
  if (Test-Path -LiteralPath $exclude) { $present = @(Get-Content -LiteralPath $exclude) }
  foreach ($line in Get-Content (Join-Path $ScriptsDir 'src_git_exclude')) {
    if ($line -eq '' -or $line.StartsWith('#') -or $present -contains $line) { continue }
    [IO.File]::AppendAllText($exclude, "$line`n")
  }
}

# --- Tools from DEPS --------------------------------------------------------

function Get-DepsEntry([string] $Deps, [string[]] $Query) {
  $out = & $Python -I (Join-Path $ScriptsDir 'deps_tool.py') $Deps @Query
  if ($LASTEXITCODE -ne 0) { Stop-Haze "deps_tool.py $($Query -join ' ') failed" }
  return ($out -split ' ')
}

function Save-Url([string] $Url, [string] $Path) {
  New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
  Invoke-Native curl.exe @('-sSfL', '-o', $Path, $Url)
}

# Extracting with Python keeps .tar.xz working whatever tar.exe supports.
function Expand-Tarball([string] $Archive, [string] $Dest) {
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  Invoke-Native $Python @('-I', '-c', @'
import sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    if hasattr(tarfile, 'data_filter'):
        archive.extractall(sys.argv[2], filter='data')
    else:
        archive.extractall(sys.argv[2])
'@, $Archive, $Dest)
}

# A cipd package, at the version DEPS (or a sub-DEPS) pins.
function Install-CipdPackage([string] $Deps, [string] $Entry, [string] $Dest,
                             [string] $Sentinel, [string] $Label) {
  if (Test-Path -LiteralPath $Sentinel) { return }
  Write-Step "fetching $Label"
  $package, $version = Get-DepsEntry $Deps @('cipd', $Entry)
  $package = $package.Replace('${{platform}}', 'windows-amd64').Replace('${{arch}}', 'amd64')
  $zip = Join-Path $DownloadDir ("{0}-{1}.zip" -f ($package -split '/')[-1], ($version -replace '[:@]', '_'))
  Save-Url "https://chrome-infra-packages.appspot.com/dl/$package/+/$version" $zip
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  [IO.Compression.ZipFile]::ExtractToDirectory($zip, $Dest, $true)
  if (-not (Test-Path -LiteralPath $Sentinel)) {
    Stop-Haze "$Label package did not contain $(Split-Path -Leaf $Sentinel)"
  }
  Write-Info "$Label $version"
}

# A Google Storage object, checked against the sha256 DEPS declares.
function Install-GcsDep([string] $Entry, [string] $Dest, [string] $Sentinel, [string] $Label) {
  if (Test-Path -LiteralPath $Sentinel) { return }
  Write-Step "fetching $Label"
  $bucket, $object, $sha, $output = Get-DepsEntry (Join-Path $SrcDir 'DEPS') @('gcs', $Entry, 'win', 'x64')
  $file = Join-Path $DownloadDir (($object -split '/')[-1])
  Save-Url "https://storage.googleapis.com/$bucket/$object" $file
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash -ne $sha) {
    Remove-Item -LiteralPath $file
    Stop-Haze "$Label does not match the sha256 DEPS declares for it"
  }
  # An object_name can be a bare hash, so output_file decides, as in gclient.
  $name = $output -eq '-' ? $object : $output
  if ($name -match '\.(tar\.xz|tar\.gz|tgz)$') {
    Expand-Tarball $file $Dest
  } elseif ($output -ne '-') {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item -LiteralPath $file -Destination (Join-Path $Dest $output) -Force
  } else {
    Stop-Haze "${Label}: DEPS names no output_file and the object is not an archive"
  }
  if (-not (Test-Path -LiteralPath $Sentinel)) {
    Stop-Haze "$Label download did not provide $(Split-Path -Leaf $Sentinel)"
  }
  Write-Info "$Label ready"
}

# rc.exe is not a dep but a DEPS hook that downloads the blob named by the
# SHA-1 in a file checked into the tree.
function Install-RcExe {
  $rc = Join-Path $SrcDir 'build\toolchain\win\rc\win\rc.exe'
  if (Test-Path -LiteralPath $rc) { return }
  Write-Step 'fetching rc.exe'
  $bucket, $sha1File = Get-DepsEntry (Join-Path $SrcDir 'DEPS') @('hook', 'rc_win')
  $sha1 = (Get-Content -Raw (Join-Path $SrcDir ($sha1File -replace '^src/', ''))).Trim()
  $tmp = Join-Path $DownloadDir "rc-$sha1.exe"
  Save-Url "https://storage.googleapis.com/$bucket/$sha1" $tmp
  if ((Get-FileHash -Algorithm SHA1 -LiteralPath $tmp).Hash -ne $sha1) {
    Remove-Item -LiteralPath $tmp
    Stop-Haze 'rc.exe does not match the SHA-1 in rc.exe.sha1'
  }
  Copy-Item -LiteralPath $tmp -Destination $rc
  Write-Info 'rc.exe ready'
}

function Install-Toolchain {
  Write-Step 'checking toolchain'
  Push-Location $SrcDir
  try {
    # Domain substitution rewrote the download URLs in these scripts; this
    # variable points clang's and rust's updaters back at the real bucket.
    $env:CDS_CLANG_BUCKET_OVERRIDE = 'https://commondatastorage.googleapis.com/chromium-browser-clang'
    Invoke-Native $Python @('tools\clang\scripts\update.py')
    Invoke-Native $Python @('tools\rust\update_rust.py')
  } finally {
    Pop-Location
  }

  $deps = Join-Path $SrcDir 'DEPS'
  # gn and ninja come from DEPS too, so nothing beyond Python, Git and Visual
  # Studio has to be installed by hand.
  Install-CipdPackage $deps 'src/buildtools/win' (Join-Path $SrcDir 'buildtools\win') $Gn 'gn'
  Install-CipdPackage $deps 'src/third_party/ninja' (Join-Path $SrcDir 'third_party\ninja') $Ninja 'ninja'
  # .gn runs every build script with //third_party/cpython3/host/bin/python3,
  # which ungoogled prunes. Chromium's own Python package goes back there; on
  # Windows, CreateProcess adds the .exe.
  $cpython = Join-Path $SrcDir 'third_party\cpython3\host'
  Install-CipdPackage $deps 'src/third_party/cpython3/host' $cpython (Join-Path $cpython 'bin\python3.exe') 'Python (for build scripts)'
  Install-RcExe

  $format = Join-Path $SrcDir 'buildtools\win-format'
  Install-GcsDep 'src/buildtools/win-format' $format (Join-Path $format 'clang-format.exe') 'clang-format'
  $libclang = Join-Path $SrcDir 'third_party\llvm-libclang'
  Install-GcsDep 'src/third_party/llvm-libclang' $libclang (Join-Path $libclang 'bindings\python\clang\cindex.py') 'libclang'
  $node = Join-Path $SrcDir 'third_party\node\win'
  Install-GcsDep 'src/third_party/node/win' $node (Join-Path $node 'node.exe') 'node'

  $devtools = Join-Path $SrcDir 'third_party\devtools-frontend\src'
  $esbuild = Join-Path $devtools 'third_party\esbuild'
  Install-CipdPackage (Join-Path $devtools 'DEPS') 'third_party/esbuild' $esbuild (Join-Path $esbuild 'esbuild.exe') 'esbuild'
  $typescript = Join-Path $SrcDir 'third_party\typescript\windows-amd64\src'
  Install-CipdPackage $deps 'src/third_party/typescript/windows-amd64/src' $typescript (Join-Path $typescript 'lib\tsc.exe') 'TypeScript'
  $go = Join-Path $SrcDir 'third_party\dawn\tools\golang\windows-amd64'
  Install-CipdPackage (Join-Path $SrcDir 'third_party\dawn\DEPS') 'tools/golang/windows-amd64' $go (Join-Path $go 'bin\go.exe') 'Go (for Dawn)'
}

# --- gn and ninja -----------------------------------------------------------

# Same layout as build.sh: ungoogled's flags.gn, then flags\<config>.gn, then
# flags\<config>.win.gn for args GN declares on Windows only.
function Write-Args {
  Write-Step 'writing args.gn'
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $tag = (& git -C $UngoogledDir describe --tags --exact-match 2>$null)
  $parts = @(
    "# Generated by scripts/build.ps1 for the $Config config. Do not edit.",
    "# Edit flags/$Config.gn instead.",
    '',
    "# --- ungoogled-chromium ${tag}: flags.gn ---",
    (Get-Content -Raw (Join-Path $UngoogledDir 'flags.gn')).TrimEnd(),
    '',
    "# --- Haze: flags/$Config.gn ---",
    (Get-Content -Raw (Join-Path $FlagsDir "$Config.gn")).TrimEnd()
  )
  $platformFlags = Join-Path $FlagsDir "$Config.win.gn"
  if (Test-Path -LiteralPath $platformFlags) {
    $parts += @('', "# --- Haze: flags/$Config.win.gn ---", (Get-Content -Raw $platformFlags).TrimEnd())
  }
  [IO.File]::WriteAllText((Join-Path $OutDir 'args.gn'), (($parts -join "`n") + "`n"))
}

function Invoke-GnGen {
  Write-Step 'gn gen'
  Push-Location $SrcDir
  try {
    # --fail-on-unused-args turns a stale or misspelled arg into an error.
    Invoke-Native $Gn @('gen', $OutDir, '--fail-on-unused-args')
  } finally {
    Pop-Location
  }
}

function Invoke-Ninja {
  $jobs = $env:HAZE_JOBS ? $env:HAZE_JOBS : [Environment]::ProcessorCount
  Write-Step "ninja: $($Targets -join ' ')"
  Invoke-Native $Ninja (@('-C', $OutDir, '-j', "$jobs") + $Targets)
}

# --- Main -------------------------------------------------------------------

function Main {
  New-Item -ItemType Directory -Force -Path $LogDir, $DownloadDir | Out-Null
  $script:LogFile = Join-Path $LogDir ("build-{0}-{1}.log" -f $Config, (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'"))
  $started = Get-Date

  Write-Step "build $Config ($($Targets -join ' '))"
  Write-Info "log $LogFile"
  Assert-Command git
  Assert-Command curl.exe
  $script:Python = Find-Python
  Write-Info "Python: $Python"
  Assert-Versions
  Initialize-VisualStudio
  Initialize-SrcGit
  Sync-Overlay
  Install-Toolchain
  Write-Args
  Invoke-GnGen
  Invoke-Ninja

  $elapsed = (Get-Date) - $started
  Write-Step ("build $Config done in {0}h {1:00}m {2:00}s" -f [int][math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds)
  Write-Info "output $OutDir"
}

Main
