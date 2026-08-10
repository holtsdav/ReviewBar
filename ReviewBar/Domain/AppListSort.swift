import Foundation

enum AppListSort: String, CaseIterable, Sendable {
    case favoritesFirst
    case name
    case recentActivity
    case newActivity

    var title: String {
        switch self {
        case .favoritesFirst: "Favorites First"
        case .name: "Name"
        case .recentActivity: "Recent Activity"
        case .newActivity: "New Activity"
        }
    }
}
