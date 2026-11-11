<#
  Builds the RodentFlow shared engine plus its C ABI into RodentFlowABI.dll.

      powershell -ExecutionPolicy Bypass -File build\build_engine.ps1

  Needs the Swift toolchain for Windows:
      winget install --id Swift.Toolchain -e
  and a Visual Studio build environment (the Swift installer sets this up; if `swift build` cannot
  find a linker, run this from the "x64 Native Tools Command Prompt").

  @_cdecl functions are plain C symbols, but a Windows DLL only exports what it is told to export.
  If the DLL comes out without them, this script links again with build\rodentflow.def, which lists
  every entry point.
#>
param(
    [string]$Configuration = "release",
    [switch]$SkipExportCheck
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root "engine"

Write-Host "Swift toolchain:"
swift --version
if ($LASTEXITCODE -ne 0) { throw "swift was not found. Install it with: winget install --id Swift.Toolchain -e" }

Push-Location $engine
try {
    Write-Host "`nBuilding RodentFlowABI ($Configuration)…"
    swift build -c $Configuration --scratch-path .build
    if ($LASTEXITCODE -ne 0) { throw "swift build failed" }

    $dll = Join-Path $engine ".build\$Configuration\RodentFlowABI.dll"
    if (-not (Test-Path $dll)) {
        # SwiftPM puts the product under a triple-named folder on some toolchains.
        $found = Get-ChildItem -Path (Join-Path $engine ".build") -Recurse -Filter "RodentFlowABI.dll" |
                 Select-Object -First 1
        if (-not $found) { throw "RodentFlowABI.dll was not produced. Look at the build output above." }
        $dll = $found.FullName
    }
    Write-Host "built $dll"

    if (-not $SkipExportCheck) {
        $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
        if ($dumpbin) {
            $exports = & dumpbin /exports $dll | Out-String
            if ($exports -notmatch "rf_run_open") {
                Write-Warning "The DLL does not export rf_run_open. Linking again with rodentflow.def…"
                $def = Join-Path $PSScriptRoot "rodentflow.def"
                swift build -c $Configuration --scratch-path .build -Xlinker "/DEF:$def"
                if ($LASTEXITCODE -ne 0) { throw "The second link failed. See build\README_CN.md." }
                $exports = & dumpbin /exports $dll | Out-String
                if ($exports -notmatch "rf_run_open") { throw "Still no exports; see build\README_CN.md." }
            }
            Write-Host "exports look right (rf_run_open is there)"
        } else {
            Write-Host "dumpbin not on PATH, so the exports were not checked. Run this from a"
            Write-Host "Visual Studio developer prompt to have it checked."
        }
    }
}
finally { Pop-Location }

# Put the DLL and the two text files the engine reads next to each app that needs them.
$targets = @(
    (Join-Path $root "src\RodentFlow.Cli\bin\Debug\net8.0"),
    (Join-Path $root "src\RodentFlow.Cli\bin\Release\net8.0")
)
foreach ($t in $targets) {
    if (Test-Path $t) {
        Copy-Item $dll $t -Force
        Copy-Item (Join-Path $root "engine\Resources\*.json") $t -Force
        Write-Host "copied into $t"
    }
}
Write-Host "`ndone"
