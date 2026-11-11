<#
  Builds the engine, then the .NET projects, then runs the self-check.

      powershell -ExecutionPolicy Bypass -File build\build_all.ps1

  The WinUI app needs Windows; the rest builds anywhere .NET 8 runs.
#>
param([string]$Configuration = "Release", [switch]$SkipEngine, [switch]$SkipApp)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not $SkipEngine) {
    & (Join-Path $PSScriptRoot "build_engine.ps1")
}

Write-Host "`nRestoring and building the .NET projects…"
# RodentFlow.Onnx needs Microsoft.ML.OnnxRuntime, so NuGet has to be reachable. If the repo still
# has the offline NuGet.config, rename it first.
$offline = Join-Path $root "NuGet.config"
if (Test-Path $offline) {
    $text = Get-Content $offline -Raw
    if ($text -match "<clear\s*/>") {
        Write-Warning "NuGet.config has no package sources. Renaming it so packages can be restored."
        Move-Item $offline (Join-Path $root "NuGet.config.offline") -Force
    }
}

$projects = @(
    "src\RodentFlow.Engine\RodentFlow.Engine.csproj",
    "src\RodentFlow.Core\RodentFlow.Core.csproj",
    "src\RodentFlow.Onnx\RodentFlow.Onnx.csproj",
    "src\RodentFlow.Cli\RodentFlow.Cli.csproj",
    "tools\RodentFlow.SelfCheck\RodentFlow.SelfCheck.csproj"
)
if (-not $SkipApp) { $projects += "src\RodentFlow.App\RodentFlow.App.csproj" }

foreach ($p in $projects) {
    Write-Host "`n--- $p"
    dotnet build (Join-Path $root $p) -c $Configuration --nologo
    if ($LASTEXITCODE -ne 0) { throw "$p failed to build" }
}

Write-Host "`nRunning the self-check…"
dotnet run --project (Join-Path $root "tools\RodentFlow.SelfCheck") -c $Configuration --nologo
if ($LASTEXITCODE -ne 0) { throw "the self-check failed" }

Write-Host "`ndone"
