# SPDX-License-Identifier: MIT

param(
    [Parameter(Mandatory = $true)] [string] $Library,
    [Parameter(Mandatory = $true)] [string] $TaskRds,
    [ValidateSet("cpu", "cuda", "metal")] [string] $Backend = "cpu",
    [ValidateSet("float32", "float64")] [string] $Precision = "float32",
    [ValidateRange(1, 1000)] [int] $Replicates = 11,
    [Parameter(Mandatory = $true)] [string] $OutputCsv,
    [string] $Rscript = "Rscript.exe"
)

$ErrorActionPreference = "Stop"
$worker = Join-Path $PSScriptRoot "cifar_worker.R"
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    "fastpls-cifar-" + [guid]::NewGuid().ToString("N")
)
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

try {
    $results = for ($replicate = 1; $replicate -le $Replicates; $replicate++) {
        $replicateCsv = Join-Path $temporaryDirectory "replicate-$replicate.csv"
        & $Rscript $worker $Library $TaskRds $Backend $Precision |
            Set-Content -Encoding utf8 $replicateCsv
        if ($LASTEXITCODE -ne 0) {
            throw "CIFAR worker failed for replicate $replicate"
        }

        $row = Import-Csv $replicateCsv
        if ($row.Count -ne 1) {
            throw "Expected one result row for replicate $replicate"
        }
        $row | Select-Object @{Name = "replicate"; Expression = {$replicate}}, *
    }

    $outputDirectory = Split-Path -Parent $OutputCsv
    if ($outputDirectory -and !(Test-Path $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory | Out-Null
    }
    $results | Export-Csv -NoTypeInformation -Encoding utf8 $OutputCsv
} finally {
    Remove-Item -Recurse -Force $temporaryDirectory -ErrorAction SilentlyContinue
}
