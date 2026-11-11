// GroupStyle.swift — display order, color and inclusion of a group in a task's group comparison
// (RodentFlow 1.x GroupStyle; the same JSON on both platforms).

import Foundation

struct GroupStyle: Codable, Hashable {
    var order: Int
    var colorIndex: Int
    var included: Bool
}
