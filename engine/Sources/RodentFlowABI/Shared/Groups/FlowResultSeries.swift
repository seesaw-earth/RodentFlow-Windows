// FlowResultSeries.swift — a series stored with a session result (time bins, per-CS values, trials),
// as RodentFlow 1.x defines it (ResultSeries). Used by the group comparison on both platforms.

import Foundation

struct FlowResultSeries: Codable, Hashable, Identifiable {
    let key: String
    let name: String
    let unit: String
    let xLabel: String
    let x: [Double]
    let y: [Double]
    var id: String { key }
}
