# Cross-platform MSVC SDK install for Zig *-windows-msvc on Windows hosts.
# Mirror of setup-msvc.sh.
#
# Invoked from build.zig via velopack.addMsvcupSetupStep(b, install_dir).
# Reads three env vars set by the build:
#
#   VELOPACK_ZIG_ENV_FILE    -- path to tools/msvcup.env
#   VELOPACK_ZIG_GEN_SCRIPT  -- path to tools/gen_zig_libc_msvc.zig
#   VELOPACK_ZIG_ZIG         -- path to the zig binary
#
# Single positional argument: <install-dir>.

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'

$EnvFile = $env:VELOPACK_ZIG_ENV_FILE
$GenScript = $env:VELOPACK_ZIG_GEN_SCRIPT
$Zig = if ($env:VELOPACK_ZIG_ZIG) { $env:VELOPACK_ZIG_ZIG } else { 'zig' }

if (-not $EnvFile) { throw 'missing VELOPACK_ZIG_ENV_FILE' }
if (-not $GenScript) { throw 'missing VELOPACK_ZIG_GEN_SCRIPT' }
if (-not (Test-Path -LiteralPath $EnvFile)) { throw "missing $EnvFile" }

Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    if ($_ -match '^([^=]+)=(.*)$') {
        $value = $matches[2].Trim()
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        Set-Item -Path ('Env:' + $matches[1].Trim()) -Value $value
    }
}

if (-not $env:MSVCUP_TAG) { throw 'MSVCUP_TAG not set in env file' }
if (-not $env:MSVCUP_PACKAGES) { throw 'MSVCUP_PACKAGES not set in env file' }

$real = $Env:PROCESSOR_ARCHITECTURE
if ($real -eq 'AMD64') { $DlArch = 'x86_64' }
elseif ($real -eq 'ARM64') { $DlArch = 'aarch64' }
else { throw "unsupported PROCESSOR_ARCHITECTURE $real" }

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$ToolBin = Join-Path $InstallRoot 'msvcup-bin'
New-Item -ItemType Directory -Force -Path $ToolBin | Out-Null
$msvcup = Join-Path $ToolBin 'msvcup.exe'
$archive = "msvcup-$DlArch-windows.zip"
$url = "https://github.com/marler8997/msvcup/releases/download/$($env:MSVCUP_TAG)/$archive"

if (-not (Test-Path -LiteralPath $msvcup)) {
    Write-Host "Downloading msvcup ($archive)..."
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp $archive)
        Expand-Archive -LiteralPath (Join-Path $tmp $archive) -DestinationPath $ToolBin -Force
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# An install is "complete" only when the SDK headers, SDK system import
# libs, and MSVC toolchain are all present.  Wildcard matches the SDK
# version subdirectory.
$haveMsvc = Test-Path -LiteralPath (Join-Path $InstallRoot 'VC\Tools\MSVC')
$ucrtStdlib = Get-ChildItem -Path (Join-Path $InstallRoot 'Windows Kits\10\Include\*\ucrt\stdlib.h') -ErrorAction SilentlyContinue
$kernel32X64 = Get-ChildItem -Path (Join-Path $InstallRoot 'Windows Kits\10\Lib\*\um\x64\kernel32.Lib') -ErrorAction SilentlyContinue
$needInstall = -not ($haveMsvc -and $ucrtStdlib -and $kernel32X64)
if ($needInstall) {
    Write-Host "Running msvcup install into $InstallRoot (first run can take several minutes)..."
    $pkgs = $env:MSVCUP_PACKAGES -split '\s+'
    & $msvcup install $InstallRoot --manifest-update-off @pkgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Vendor GameInput.h from MSVCUP_GAMEINPUT_PACKAGE into the base SDK's um/.
# The base SDK (22621) lacks it; the package that has it (26100) has a broken
# shared/ so it can't be installed into the main tree.  Install it to a scratch
# dir, copy just the one header, discard the rest.  Idempotent: skipped once the
# header is in place, so re-runs don't re-download the 26100 package.
$mainUm = Get-ChildItem -Path (Join-Path $InstallRoot 'Windows Kits\10\Include\*\um') -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mainUm -and $env:MSVCUP_GAMEINPUT_PACKAGE) {
    $gameInput = Join-Path $mainUm.FullName 'GameInput.h'
    if (-not (Test-Path -LiteralPath $gameInput)) {
        Write-Host "Vendoring GameInput.h from $($env:MSVCUP_GAMEINPUT_PACKAGE)..."
        $giTmp = Join-Path $InstallRoot '.gameinput-src'
        Remove-Item -LiteralPath $giTmp -Recurse -Force -ErrorAction SilentlyContinue
        & $msvcup install $giTmp --manifest-update-off $env:MSVCUP_GAMEINPUT_PACKAGE
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        $giSrc = Get-ChildItem -Path (Join-Path $giTmp 'Windows Kits\10\Include\*\um\GameInput.h') -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($giSrc) {
            Copy-Item -LiteralPath $giSrc.FullName -Destination $gameInput -Force
            Write-Host "  -> $gameInput"
        } else {
            Write-Warning "GameInput.h not found in $($env:MSVCUP_GAMEINPUT_PACKAGE)"
        }
        Remove-Item -LiteralPath $giTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& $Zig run $GenScript -- $InstallRoot x64 (Join-Path $InstallRoot 'zig-libc-x64.ini')
& $Zig run $GenScript -- $InstallRoot arm64 (Join-Path $InstallRoot 'zig-libc-arm64.ini')
Write-Host 'Done.'
