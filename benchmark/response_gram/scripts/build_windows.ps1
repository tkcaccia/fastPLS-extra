param(
    [Parameter(Mandatory = $true)]
    [string]$SourceArchive,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$OpenBlasRoot,
    [string]$MklRoot = "",
    [string]$RtoolsRoot = "C:\rtools45",
    [int]$Jobs = 6
)

$ErrorActionPreference = "Stop"

if (Test-Path -LiteralPath $Destination) {
    throw "Destination already exists: $Destination"
}
if (-not (Test-Path -LiteralPath $SourceArchive)) {
    throw "Source archive not found: $SourceArchive"
}
if (-not (Test-Path -LiteralPath $OpenBlasRoot)) {
    throw "OpenBLAS root not found: $OpenBlasRoot"
}

New-Item -ItemType Directory -Path $Destination | Out-Null
& "$env:SystemRoot\System32\tar.exe" -xzf $SourceArchive -C $Destination
if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract $SourceArchive"
}

$compilerBin = Join-Path $RtoolsRoot "x86_64-w64-mingw32.static.posix\bin"
$toolsBin = Join-Path $RtoolsRoot "usr\bin"
$compiler = Join-Path $compilerBin "g++.exe"
$make = Join-Path $toolsBin "make.exe"
$env:PATH = "$compilerBin;$toolsBin;$(Join-Path $OpenBlasRoot 'bin');$env:PATH"
$env:OPENBLAS_ROOT = $OpenBlasRoot
if ($MklRoot) {
    if (-not (Test-Path -LiteralPath $MklRoot)) {
        throw "oneMKL root not found: $MklRoot"
    }
    $env:MKLROOT = $MklRoot
    $env:PATH = "$(Join-Path $MklRoot 'bin');$env:PATH"
}

$build = Join-Path $Destination "build"
$configureArguments = @(
    "-S", $Destination,
    "-B", $build,
    "-G", "Unix Makefiles",
    "-DCMAKE_MAKE_PROGRAM=$make",
    "-DCMAKE_CXX_COMPILER=$compiler",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DGRAM_ENABLE_MKL=$(if ($MklRoot) { 'ON' } else { 'OFF' })",
    "-DGRAM_ENABLE_BLIS=OFF",
    "-DGRAM_ENABLE_LIBXSMM=OFF",
    "-DGRAM_ENABLE_BLASFEO=OFF"
)
& cmake @configureArguments
if ($LASTEXITCODE -ne 0) {
    throw "CMake configuration failed"
}

cmake --build $build --parallel $Jobs
if ($LASTEXITCODE -ne 0) {
    throw "CMake build failed"
}
