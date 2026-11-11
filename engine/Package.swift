// swift-tools-version:5.9
//
// RodentFlowABI — the RodentFlow shared engine (Foundation only) plus a flat C ABI, built as one
// dynamic library for the Windows app to load.
//
// Why one module: the shared sources carry no access modifiers, so everything in them is `internal`
// and only visible inside its own module. The C ABI files therefore live in the SAME target as the
// copied `Shared/` sources instead of a separate target that could not see `PoseTrack`, `Analyzer`
// and the rest.
//
// Build:  swift build -c release            (Windows, macOS or Linux)
// Output: .build/release/RodentFlowABI.dll  (Windows) / libRodentFlowABI.so / .dylib
//
// swift-tools-version 5.9 keeps the Swift 5 language mode, which is what the shared sources are
// written for (the iOS / macOS apps and tools/run_shared_tests.sh compile them the same way).

import PackageDescription

let package = Package(
    name: "RodentFlowABI",
    products: [
        .library(name: "RodentFlowABI", type: .dynamic, targets: ["RodentFlowABI"]),
    ],
    targets: [
        .target(
            name: "RodentFlowABI",
            exclude: ["Shared/SYNC_STAMP.txt"]
        ),
    ]
)
