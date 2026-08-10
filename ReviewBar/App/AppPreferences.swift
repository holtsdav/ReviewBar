import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        static let favoriteAppIDs = "ReviewBar.favoriteAppIDs"
        static let appListSort = "ReviewBar.appListSort"
        static let appActivityFilter = "ReviewBar.appActivityFilter"
    }

    private let defaults: UserDefaults?

    private(set) var favoriteAppIDs: Set<String> {
        didSet { defaults?.set(favoriteAppIDs.sorted(), forKey: Key.favoriteAppIDs) }
    }

    var appListSort: AppListSort {
        didSet { defaults?.set(appListSort.rawValue, forKey: Key.appListSort) }
    }

    var appActivityFilter: AppActivityFilter {
        didSet { defaults?.set(appActivityFilter.rawValue, forKey: Key.appActivityFilter) }
    }

    init(
        defaults: UserDefaults? = .standard,
        favoriteAppIDs: Set<String>? = nil,
        appListSort: AppListSort? = nil,
        appActivityFilter: AppActivityFilter? = nil
    ) {
        self.defaults = defaults
        self.favoriteAppIDs = favoriteAppIDs
            ?? Set(defaults?.stringArray(forKey: Key.favoriteAppIDs) ?? [])
        self.appListSort = appListSort
            ?? defaults.flatMap { $0.string(forKey: Key.appListSort) }.flatMap(AppListSort.init(rawValue:))
            ?? .name
        self.appActivityFilter = appActivityFilter
            ?? defaults.flatMap { $0.string(forKey: Key.appActivityFilter) }.flatMap(AppActivityFilter.init(rawValue:))
            ?? .all
    }

    func isFavorite(appID: String) -> Bool {
        favoriteAppIDs.contains(appID)
    }

    func toggleFavorite(appID: String) {
        if favoriteAppIDs.contains(appID) {
            favoriteAppIDs.remove(appID)
        } else {
            favoriteAppIDs.insert(appID)
        }
    }

    func clearAccountScopedData() {
        favoriteAppIDs = []
        if appActivityFilter == .favorites {
            appActivityFilter = .all
        }
    }

    func resetUITestState() {
        favoriteAppIDs = []
        appListSort = .name
        appActivityFilter = .all
    }
}
