<#
  Copies the Foundation-only part of the RodentFlow shared engine out of the iOS / macOS source tree
  into this repository, with the same filter the apps' own tools/shared_sources.sh uses.

      powershell -ExecutionPolicy Bypass -File engine\sync_shared.ps1 -AppRoot "C:\…\RodentFlow-2.1 shell"

  Run this whenever the shared engine changes in the apps, then rebuild and re-run
  check\check_abi.py, which tells you if the ABI layer still matches the engine.
#>
param([Parameter(Mandatory = $true)][string]$AppRoot)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$target = Join-Path $here "Sources\RodentFlowABI\Shared"
$source = Join-Path $AppRoot "Shared"
if (-not (Test-Path $source)) { throw "No Shared folder in $AppRoot" }

# Excluded, because they need Apple frameworks or are user interface:
#   Vision/      Core ML and Core Image (replaced by RodentFlow.Onnx and FramePreparation)
#   PoseUI/ GroupsUI/ TST/Views TST/Model TST/Video TST/Detection   SwiftUI and AppKit
#   VideoPatch/  hardware video encoding
#   TSTArchiveSave.swift
$exclude = @("\Vision\", "\GroupsUI\", "\PoseUI\", "\VideoPatch\",
             "\TST\Views\", "\TST\Model\", "\TST\Video\", "\TST\Detection\")

if (Test-Path $target) { Remove-Item $target -Recurse -Force }
New-Item -ItemType Directory -Path $target | Out-Null

$files = Get-ChildItem $source -Recurse -Filter *.swift | Where-Object {
    $rel = $_.FullName.Substring($source.Length)
    ($_.Name -ne "TSTArchiveSave.swift") -and -not ($exclude | Where-Object { $rel -like "*$_*" })
} | Sort-Object FullName

foreach ($f in $files) {
    $rel = $f.FullName.Substring($source.Length).TrimStart("\")
    $dest = Join-Path $target $rel
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Copy-Item $f.FullName $dest -Force
}

# The two text files the engine reads at run time through Bundle.main.
$resources = Join-Path $here "Resources"
New-Item -ItemType Directory -Path $resources -Force | Out-Null
Copy-Item (Join-Path $source "PoseEngine\Resources\EnglishTranslations.json") $resources -Force
Copy-Item (Join-Path $source "PoseEngine\Resources\L10nPatterns.json") $resources -Force

$hash = (Get-FileHash -Algorithm SHA256 -InputStream (
    [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes(
        ($files | ForEach-Object { Get-Content $_.FullName -Raw }) -join ""))
)).Hash.ToLower()

@"
source: $AppRoot
synced: $(Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
files: $($files.Count)
sha256 of concatenated sources: $hash
"@ | Set-Content (Join-Path $target "SYNC_STAMP.txt")

Write-Host "copied $($files.Count) files into $target"
Write-Host "now run:  python check\check_abi.py engine\Sources\RodentFlowABI engine\Sources\RodentFlowABI\ABI\*.swift"
