# Prepares a checkout to build without touching system-wide state.
#
# Resolves the compiler pinned in toolchain.lock.json, verifies its digest
# before extracting, and places it in a project-local ignored directory. It
# installs nothing globally and never overwrites an existing Zig installation.
#
# Exit codes: 0 ready, 1 verification or download failure, 2 usage error.

[CmdletBinding()]
param(
    [switch] $Offline,
    [switch] $Check,
    [switch] $Quiet,
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
Usage: bootstrap.ps1 [options]

Prepares this checkout to build: resolves the pinned compiler, verifies its
digest, and installs it into a project-local ignored directory.

Options:
  -Offline       Use only what is already cached; do not reach the network
  -Check         Verify the environment and exit without downloading
  -Quiet         Suppress progress output
  -Help          Show this message

Exit codes:
  0  ready to build
  1  verification, download, or policy failure
  2  usage error
'@ | Write-Output
}

if ($Help) { Show-Usage; exit 0 }

function Say([string] $Message) {
    if (-not $Quiet) { Write-Output $Message }
}

function Fail([string] $Message) {
    Write-Error "bootstrap: $Message"
    exit 1
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$manifestPath = Join-Path $repositoryRoot 'toolchain.lock.json'
$toolRoot = Join-Path $repositoryRoot '.tools'
$specification = 'docs/PLATFORM_SPEC.md'

if (-not (Test-Path $manifestPath)) {
    Fail "missing $manifestPath; the toolchain is not pinned"
}

# The specification is local-only during the private implementation stage. The
# check is repository-level, so it lives here rather than in the Zig tools.
function Test-SpecificationExclusion {
    if (-not (Test-Path (Join-Path $repositoryRoot '.git'))) { return }
    if (-not (Test-Path (Join-Path $repositoryRoot $specification))) { return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }

    & git -C $repositoryRoot check-ignore -q $specification
    if ($LASTEXITCODE -ne 0) {
        Fail "$specification is not excluded; add /$specification to .git/info/exclude"
    }

    # Failure of the next command is the expected success condition: the file
    # must not be tracked.
    & git -C $repositoryRoot ls-files --error-unmatch $specification 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Fail "$specification is tracked by Git; the local-only policy forbids committing it"
    }
    Say "ok    $specification is excluded and untracked"
}

function Get-HostTarget {
    $architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'x86_64' }
        'Arm64' { 'aarch64' }
        default { Fail "unsupported architecture '$_'" }
    }
    return "$architecture-windows"
}

Test-SpecificationExclusion

$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
$target = Get-HostTarget
$version = $manifest.zig.version

if ([string]::IsNullOrWhiteSpace($version)) {
    Fail "could not read the pinned compiler version from $manifestPath"
}

$canonical = $manifest.compilers | Where-Object { $_.version -eq $version } | Select-Object -First 1
if ($null -eq $canonical) { Fail "the manifest has no entry for pinned version $version" }

$archiveEntry = $canonical.archives | Where-Object { $_.target -eq $target } | Select-Object -First 1
if ($null -eq $archiveEntry) { Fail "no pinned archive for target '$target'" }

Say "ok    host target $target"
Say "ok    pinned compiler $version"

$installed = Join-Path $toolRoot "zig-$version-$target"
$executable = Join-Path $installed 'zig.exe'

if (Test-Path $executable) {
    Say "ok    pinned compiler already present at $installed"
    if ($Check) { exit 0 }
    Say ''
    Say 'Add it to PATH for this session:'
    Say "  `$env:PATH = `"$installed;`$env:PATH`""
    exit 0
}

if ($Check) { Fail 'pinned compiler is not installed; run bootstrap.ps1 without -Check' }
if ($Offline) { Fail 'pinned compiler is not cached and -Offline was requested' }

$downloadRoot = Join-Path $toolRoot 'download'
New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
$archive = Join-Path $downloadRoot "zig-$version-$target.zip"

if (-not (Test-Path $archive)) {
    Say "..    downloading $($archiveEntry.source)"
    $partial = "$archive.partial"
    try {
        Invoke-WebRequest -Uri $archiveEntry.source -OutFile $partial -UseBasicParsing
    } catch {
        Fail "download failed: $($_.Exception.Message)"
    }
    Move-Item -Force $partial $archive
}

$observed = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLowerInvariant()
if ($observed -ne $archiveEntry.sha256) {
    Remove-Item -Force $archive
    Fail @"
digest mismatch for $target
  expected $($archiveEntry.sha256)
  observed $observed
The archive was discarded. Nothing was installed.
"@
}
Say 'ok    digest verified'

$staging = Join-Path $toolRoot "staging-$PID"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

try {
    Expand-Archive -Path $archive -DestinationPath $staging -Force
} catch {
    Fail "extraction failed: $($_.Exception.Message)"
}

$extracted = Get-ChildItem -Path $staging -Directory | Select-Object -First 1
if ($null -eq $extracted) { Fail 'archive did not contain a compiler directory' }

if (Test-Path $installed) { Remove-Item -Recurse -Force $installed }
Move-Item $extracted.FullName $installed
Remove-Item -Recurse -Force $staging

if (-not (Test-Path $executable)) { Fail 'extracted tree has no zig executable' }

Say "ok    installed to $installed"
Say ''
Say 'Add it to PATH for this session:'
Say "  `$env:PATH = `"$installed;`$env:PATH`""
Say ''
Say 'Then verify the checkout:'
Say '  zig build doctor'
