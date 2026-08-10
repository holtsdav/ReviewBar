import Foundation

extension String {
    var displayStatus: String {
        split(separator: "_").map { $0.lowercased().capitalized }.joined(separator: " ")
    }
}
